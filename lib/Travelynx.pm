package Travelynx;
use Mojo::Base 'Mojolicious';

use Mojo::Pg;
use Mojo::Promise;
use Mojolicious::Plugin::Authentication;
use Cache::File;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use DateTime;
use DateTime::Format::Strptime;
use Encode qw(decode encode);
use File::Slurp qw(read_file);
use Geo::Distance;
use JSON;
use List::Util;
use List::MoreUtils qw(after_incl before_incl);
use Travel::Status::DE::DBWagenreihung;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use Travelynx::Helper::Sendmail;
use XML::LibXML;

sub check_password {
	my ( $password, $hash ) = @_;

	if ( bcrypt( $password, $hash ) eq $hash ) {
		return 1;
	}
	return 0;
}

sub epoch_to_dt {
	my ($epoch) = @_;

	# Bugs (and user errors) may lead to undefined timestamps. Set them to
	# 1970-01-01 to avoid crashing and show obviously wrong data instead.
	$epoch //= 0;

	return DateTime->from_epoch(
		epoch     => $epoch,
		time_zone => 'Europe/Berlin'
	);
}

sub get_station {
	my ($station_name) = @_;

	my @candidates
	  = Travel::Status::DE::IRIS::Stations::get_station($station_name);

	if ( @candidates == 1 ) {
		return $candidates[0];
	}
	return undef;
}

sub startup {
	my ($self) = @_;

	push( @{ $self->commands->namespaces }, 'Travelynx::Command' );

	$self->defaults( layout => 'default' );

	$self->types->type( json => 'application/json; charset=utf-8' );

	$self->plugin('Config');

	if ( $self->config->{secrets} ) {
		$self->secrets( $self->config->{secrets} );
	}

	chomp $self->app->config->{version};

	$self->plugin(
		authentication => {
			autoload_user => 1,
			fail_render   => { template => 'login' },
			load_user     => sub {
				my ( $self, $uid ) = @_;
				return $self->get_user_data($uid);
			},
			validate_user => sub {
				my ( $self, $username, $password, $extradata ) = @_;
				my $user_info = $self->get_user_password($username);
				if ( not $user_info ) {
					return undef;
				}
				if ( $user_info->{status} != 1 ) {
					return undef;
				}
				if ( check_password( $password, $user_info->{password_hash} ) )
				{
					return $user_info->{id};
				}
				return undef;
			},
		}
	);
	$self->sessions->default_expiration( 60 * 60 * 24 * 180 );

	# Starting with v8.11, Mojolicious sends SameSite=Lax Cookies by default.
	# In theory, "The default lax value provides a reasonable balance between
	# security and usability for websites that want to maintain user's logged-in
	# session after the user arrives from an external link". In practice,
	# Safari (both iOS and macOS) does not send a SameSite=lax cookie when
	# following a link from an external site. So, marudor.de providing a
	# checkin link to travelynx.de/s/whatever does not work because the user
	# is not logged in due to Safari not sending the cookie.
	#
	# This looks a lot like a Safari bug, but we can't do anything about it. So
	# we don't set the SameSite flag at all for now.
	#
	# --derf, 2019-05-01
	$self->sessions->samesite(undef);

	$self->defaults( layout => 'default' );

	$self->hook(
		before_dispatch => sub {
			my ($self) = @_;

           # The "theme" cookie is set client-side if the theme we delivered was
           # changed by dark mode detection or by using the theme switcher. It's
           # not part of Mojolicious' session data (and can't be, due to
           # signing and HTTPOnly), so we need to add it here.
			for my $cookie ( @{ $self->req->cookies } ) {
				if ( $cookie->name eq 'theme' ) {
					$self->session( theme => $cookie->value );
					return;
				}
			}
		}
	);

	$self->attr(
		cache_iris_main => sub {
			my ($self) = @_;

			return Cache::File->new(
				cache_root      => $self->app->config->{cache}->{schedule},
				default_expires => '6 hours',
				lock_level      => Cache::File::LOCK_LOCAL(),
			);
		}
	);

	$self->attr(
		cache_iris_rt => sub {
			my ($self) = @_;

			return Cache::File->new(
				cache_root      => $self->app->config->{cache}->{realtime},
				default_expires => '70 seconds',
				lock_level      => Cache::File::LOCK_LOCAL(),
			);
		}
	);

	$self->attr(
		token_type => sub {
			return {
				status  => 1,
				history => 2,
				travel  => 3,
				import  => 4,
			};
		}
	);
	$self->attr(
		token_types => sub {
			return [qw(status history travel import)];
		}
	);

	$self->attr(
		account_public_mask => sub {
			return {
				status_intern  => 0x01,
				status_extern  => 0x02,
				status_comment => 0x04,
			};
		}
	);

	$self->attr(
		journey_edit_mask => sub {
			return {
				sched_departure => 0x0001,
				real_departure  => 0x0002,
				route           => 0x0010,
				is_cancelled    => 0x0020,
				sched_arrival   => 0x0100,
				real_arrival    => 0x0200,
			};
		}
	);

	$self->attr(
		coordinates_by_station => sub {
			my $legacy_names = $self->app->renamed_station;
			my %location;
			for
			  my $station ( Travel::Status::DE::IRIS::Stations::get_stations() )
			{
				if ( $station->[3] ) {
					$location{ $station->[1] }
					  = [ $station->[4], $station->[3] ];
				}
			}
			while ( my ( $old_name, $new_name ) = each %{$legacy_names} ) {
				$location{$old_name} = $location{$new_name};
			}
			return \%location;
		}
	);

# https://de.wikipedia.org/wiki/Liste_nach_Gemeinden_und_Regionen_benannter_IC/ICE-Fahrzeuge#Namensgebung_ICE-Triebz%C3%BCge_nach_Gemeinden
# via https://github.com/marudor/BahnhofsAbfahrten/blob/master/src/server/Reihung/ICENaming.ts
	$self->attr(
		ice_name => sub {
			my $id_to_name = JSON->new->utf8->decode(
				scalar read_file('share/ice_names.json') );
			return $id_to_name;
		}
	);

	$self->attr(
		renamed_station => sub {
			my $legacy_to_new = JSON->new->utf8->decode(
				scalar read_file('share/old_station_names.json') );
			return $legacy_to_new;
		}
	);

	$self->attr(
		station_by_eva => sub {
			my %map;
			for
			  my $station ( Travel::Status::DE::IRIS::Stations::get_stations() )
			{
				$map{ $station->[2] } = $station;
			}
			return \%map;
		}
	);

	$self->helper(
		sendmail => sub {
			state $sendmail = Travelynx::Helper::Sendmail->new(
				config => ( $self->config->{mail} // {} ),
				log    => $self->log
			);
		}
	);

	$self->helper(
		pg => sub {
			my ($self) = @_;
			my $config = $self->app->config;

			my $dbname = $config->{db}->{database};
			my $host   = $config->{db}->{host} // 'localhost';
			my $port   = $config->{db}->{port} // 5432;
			my $user   = $config->{db}->{user};
			my $pw     = $config->{db}->{password};

			state $pg
			  = Mojo::Pg->new("postgresql://${user}\@${host}:${port}/${dbname}")
			  ->password($pw);
		}
	);

	$self->helper(
		'now' => sub {
			return DateTime->now( time_zone => 'Europe/Berlin' );
		}
	);

	$self->helper(
		'numify_skipped_stations' => sub {
			my ( $self, $count ) = @_;

			if ( $count == 0 ) {
				return 'INTERNAL ERROR';
			}
			if ( $count == 1 ) {
				return
'Eine Station ohne Geokoordinaten wurde nicht berücksichtigt.';
			}
			return
"${count} Stationen ohne Geookordinaten wurden nicht berücksichtigt.";
		}
	);

	$self->helper(
		'get_departures' => sub {
			my ( $self, $station, $lookbehind, $lookahead, $with_related ) = @_;

			$lookbehind   //= 180;
			$lookahead    //= 30;
			$with_related //= 0;

			my @station_matches
			  = Travel::Status::DE::IRIS::Stations::get_station($station);

			if ( @station_matches == 1 ) {
				$station = $station_matches[0][0];
				my $status = Travel::Status::DE::IRIS->new(
					station        => $station,
					main_cache     => $self->app->cache_iris_main,
					realtime_cache => $self->app->cache_iris_rt,
					keep_transfers => 1,
					lookbehind     => 20,
					datetime => DateTime->now( time_zone => 'Europe/Berlin' )
					  ->subtract( minutes => $lookbehind ),
					lookahead   => $lookbehind + $lookahead,
					lwp_options => {
						timeout => 10,
						agent   => 'travelynx/' . $self->app->config->{version},
					},
					with_related => $with_related,
				);
				return {
					results => [ $status->results ],
					errstr  => $status->errstr,
					station_ds100 =>
					  ( $status->station ? $status->station->{ds100} : undef ),
					station_eva =>
					  ( $status->station ? $status->station->{uic} : undef ),
					station_name =>
					  ( $status->station ? $status->station->{name} : undef ),
					related_stations => [ $status->related_stations ],
				};
			}
			elsif ( @station_matches > 1 ) {
				return {
					results => [],
					errstr  => 'Mehrdeutiger Stationsname. Mögliche Eingaben: '
					  . join( q{, }, map { $_->[1] } @station_matches ),
				};
			}
			else {
				return {
					results => [],
					errstr  => 'Unbekannte Station',
				};
			}
		}
	);

	$self->helper(
		'grep_unknown_stations' => sub {
			my ( $self, @stations ) = @_;

			my @unknown_stations;
			for my $station (@stations) {
				my $station_info = get_station($station);
				if ( not $station_info ) {
					push( @unknown_stations, $station );
				}
			}
			return @unknown_stations;
		}
	);

	# Returns (journey id, error)
	# Must be called during a transaction.
	# Must perform a rollback on error.
	$self->helper(
		'add_journey' => sub {
			my ( $self, %opt ) = @_;

			my $db          = $opt{db};
			my $uid         = $opt{uid} // $self->current_user->{id};
			my $now         = DateTime->now( time_zone => 'Europe/Berlin' );
			my $dep_station = get_station( $opt{dep_station} );
			my $arr_station = get_station( $opt{arr_station} );

			if ( not $dep_station ) {
				return ( undef, 'Unbekannter Startbahnhof' );
			}
			if ( not $arr_station ) {
				return ( undef, 'Unbekannter Zielbahnhof' );
			}

			my $daily_journey_count = $db->select(
				'journeys_str',
				'count(*) as count',
				{
					user_id     => $uid,
					real_dep_ts => {
						-between => [
							$opt{rt_departure}->clone->subtract( days => 1 )
							  ->epoch,
							$opt{rt_departure}->epoch
						],
					},
				}
			)->hash->{count};

			if ( $daily_journey_count >= 100 ) {
				return ( undef,
"In den 24 Stunden vor der angegebenen Abfahrtszeit wurden ${daily_journey_count} weitere Fahrten angetreten. Das kann nicht stimmen."
				);
			}

			my @route = ( [ $dep_station->[1], {}, undef ] );

			if ( $opt{route} ) {
				my @unknown_stations;
				for my $station ( @{ $opt{route} } ) {
					my $station_info = get_station($station);
					if ($station_info) {
						push( @route, [ $station_info->[1], {}, undef ] );
					}
					else {
						push( @route, [ $station, {}, undef ] );
						push( @unknown_stations, $station );
					}
				}

				if ( not $opt{lax} ) {
					if ( @unknown_stations == 1 ) {
						return ( undef,
							"Unbekannter Unterwegshalt: $unknown_stations[0]" );
					}
					elsif (@unknown_stations) {
						return ( undef,
							'Unbekannte Unterwegshalte: '
							  . join( ', ', @unknown_stations ) );
					}
				}
			}

			push( @route, [ $arr_station->[1], {}, undef ] );

			if ( $route[0][0] eq $route[1][0] ) {
				shift(@route);
			}

			if ( $route[-2][0] eq $route[-1][0] ) {
				pop(@route);
			}

			my $entry = {
				user_id             => $uid,
				train_type          => $opt{train_type},
				train_line          => $opt{train_line},
				train_no            => $opt{train_no},
				train_id            => 'manual',
				checkin_station_id  => $dep_station->[2],
				checkin_time        => $now,
				sched_departure     => $opt{sched_departure},
				real_departure      => $opt{rt_departure},
				checkout_station_id => $arr_station->[2],
				sched_arrival       => $opt{sched_arrival},
				real_arrival        => $opt{rt_arrival},
				checkout_time       => $now,
				edited              => 0x3fff,
				cancelled           => $opt{cancelled} ? 1 : 0,
				route               => JSON->new->encode( \@route ),
			};

			if ( $opt{comment} ) {
				$entry->{user_data}
				  = JSON->new->encode( { comment => $opt{comment} } );
			}

			my $journey_id = undef;
			eval {
				$journey_id
				  = $db->insert( 'journeys', $entry, { returning => 'id' } )
				  ->hash->{id};
				$self->invalidate_stats_cache( $opt{rt_departure}, $db, $uid );
			};

			if ($@) {
				$self->app->log->error("add_journey($uid): $@");
				return ( undef, 'add_journey failed: ' . $@ );
			}

			return ( $journey_id, undef );
		}
	);

	$self->helper(
		'checkin' => sub {
			my ( $self, $station, $train_id, $uid ) = @_;

			$uid //= $self->current_user->{id};

			my $status = $self->get_departures( $station, 140, 40, 0 );
			if ( $status->{errstr} ) {
				return ( undef, $status->{errstr} );
			}
			else {
				my ($train) = List::Util::first { $_->train_id eq $train_id }
				@{ $status->{results} };
				if ( not defined $train ) {
					return ( undef, "Train ${train_id} not found" );
				}
				else {

					my $user = $self->get_user_status($uid);
					if ( $user->{checked_in} or $user->{cancelled} ) {

						if (    $user->{train_id} eq $train_id
							and $user->{dep_eva} eq $status->{station_eva} )
						{
							# checking in twice is harmless
							return ( $train, undef );
						}

						# Otherwise, someone forgot to check out first
						$self->checkout( $station, 1, $uid );
					}

					eval {
						my $json = JSON->new;
						$self->pg->db->insert(
							'in_transit',
							{
								user_id   => $uid,
								cancelled => $train->departure_is_cancelled
								? 1
								: 0,
								checkin_station_id => $status->{station_eva},
								checkin_time =>
								  DateTime->now( time_zone => 'Europe/Berlin' ),
								dep_platform    => $train->platform,
								train_type      => $train->type,
								train_line      => $train->line_no,
								train_no        => $train->train_no,
								train_id        => $train->train_id,
								sched_departure => $train->sched_departure,
								real_departure  => $train->departure,
								route           => $json->encode(
									[ $self->route_diff($train) ]
								),
								messages => $json->encode(
									[
										map { [ $_->[0]->epoch, $_->[1] ] }
										  $train->messages
									]
								)
							}
						);
					};
					if ($@) {
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						return ( undef, 'INSERT failed: ' . $@ );
					}
					$self->add_route_timestamps( $uid, $train, 1 );
					$self->run_hook( $uid, 'checkin' );
					return ( $train, undef );
				}
			}
		}
	);

	$self->helper(
		'undo' => sub {
			my ( $self, $journey_id, $uid ) = @_;
			$uid //= $self->current_user->{id};

			if ( $journey_id eq 'in_transit' ) {
				eval {
					$self->pg->db->delete( 'in_transit', { user_id => $uid } );
				};
				if ($@) {
					$self->app->log->error("Undo($uid, $journey_id): $@");
					return "Undo($journey_id): $@";
				}
				$self->run_hook( $uid, 'undo' );
				return undef;
			}
			if ( $journey_id !~ m{ ^ \d+ $ }x ) {
				return 'Invalid Journey ID';
			}

			eval {
				my $db = $self->pg->db;
				my $tx = $db->begin;

				my $journey = $db->select(
					'journeys',
					'*',
					{
						user_id => $uid,
						id      => $journey_id
					}
				)->hash;
				$db->delete(
					'journeys',
					{
						user_id => $uid,
						id      => $journey_id
					}
				);

				if ( $journey->{edited} ) {
					die(
"Cannot undo a journey which has already been edited. Please delete manually.\n"
					);
				}

				delete $journey->{edited};
				delete $journey->{id};

				$db->insert( 'in_transit', $journey );

				my $cache_ts = DateTime->now( time_zone => 'Europe/Berlin' );
				if ( $journey->{real_departure}
					=~ m{ ^ (?<year> \d{4} ) - (?<month> \d{2} ) }x )
				{
					$cache_ts->set(
						year  => $+{year},
						month => $+{month}
					);
				}

				$self->invalidate_stats_cache( $cache_ts, $db, $uid );

				$tx->commit;
			};
			if ($@) {
				$self->app->log->error("Undo($uid, $journey_id): $@");
				return "Undo($journey_id): $@";
			}
			$self->run_hook( $uid, 'undo' );
			return undef;
		}
	);

	# Statistics are partitioned by real_departure, which must be provided
	# when calling this function e.g. after journey deletion or editing.
	# If a joureny's real_departure has been edited, this function must be
	# called twice: once with the old and once with the new value.
	$self->helper(
		'invalidate_stats_cache' => sub {
			my ( $self, $ts, $db, $uid ) = @_;

			$uid //= $self->current_user->{id};
			$db  //= $self->pg->db;

			$self->pg->db->delete(
				'journey_stats',
				{
					user_id => $uid,
					year    => $ts->year,
					month   => $ts->month,
				}
			);
			$self->pg->db->delete(
				'journey_stats',
				{
					user_id => $uid,
					year    => $ts->year,
					month   => 0,
				}
			);
		}
	);

	$self->helper(
		'checkout' => sub {
			my ( $self, $station, $force, $uid ) = @_;

			my $db     = $self->pg->db;
			my $status = $self->get_departures( $station, 120, 120, 0 );
			$uid //= $self->current_user->{id};
			my $user     = $self->get_user_status($uid);
			my $train_id = $user->{train_id};

			if ( not $user->{checked_in} and not $user->{cancelled} ) {
				return ( 0, 'You are not checked into any train' );
			}
			if ( $status->{errstr} and not $force ) {
				return ( 1, $status->{errstr} );
			}

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );
			my $journey
			  = $db->select( 'in_transit', '*', { user_id => $uid } )
			  ->expand->hash;

			# Note that a train may pass the same station several times.
			# Notable example: S41 / S42 ("Ringbahn") both starts and
			# terminates at Berlin Südkreuz
			my ($train) = List::Util::first {
				$_->train_id eq $train_id
				  and $_->sched_arrival
				  and $_->sched_arrival->epoch > $user->{sched_departure}->epoch
			}
			@{ $status->{results} };

			$train //= List::Util::first { $_->train_id eq $train_id }
			@{ $status->{results} };

			my $new_checkout_station_id = $status->{station_eva};

          # When a checkout is triggered by a checkin, there is an edge case
          # with related stations.
          # Assume a user travels from A to B1, then from B2 to C. B1 and B2 are
          # relatd stations (e.g. "Frankfurt Hbf" and "Frankfurt Hbf(tief)").
          # Now, if they check in for the journey from B2 to C, and have not yet
          # checked out of the previous train, $train is undef as B2 is not B1.
          # Redo the request with with_related => 1 to avoid this case.
          # While at it, we increase the lookahead to handle long journeys as
          # well.
			if ( not $train ) {
				$status = $self->get_departures( $station, 120, 180, 1 );
				($train) = List::Util::first { $_->train_id eq $train_id }
				@{ $status->{results} };
				if (    $train
					and $self->app->station_by_eva->{ $train->station_uic } )
				{
					$new_checkout_station_id = $train->station_uic;
				}
			}

			# Store the intended checkout station regardless of this operation's
			# success.
			$db->update(
				'in_transit',
				{
					checkout_station_id => $new_checkout_station_id,
				},
				{ user_id => $uid }
			);

			# If in_transit already contains arrival data for another estimated
			# destination, we must invalidate it.
			if ( defined $journey->{checkout_station_id}
				and $journey->{checkout_station_id}
				!= $new_checkout_station_id )
			{
				$db->update(
					'in_transit',
					{
						checkout_time => undef,
						arr_platform  => undef,
						sched_arrival => undef,
						real_arrival  => undef,
					},
					{ user_id => $uid }
				);
			}

			if ( not defined $train ) {

               # Arrival time via IRIS is unknown, so the train probably has not
               # arrived yet. Fall back to HAFAS.
               # TODO support cases where $station is EVA or DS100 code
				if (
					my $station_data
					= List::Util::first { $_->[0] eq $station }
					@{ $journey->{route} }
				  )
				{
					$station_data = $station_data->[1];
					if ( $station_data->{sched_arr} ) {
						my $sched_arr
						  = epoch_to_dt( $station_data->{sched_arr} );
						my $rt_arr = $sched_arr->clone;
						if (    $station_data->{adelay}
							and $station_data->{adelay} =~ m{^\d+$} )
						{
							$rt_arr->add( minutes => $station_data->{adelay} );
						}
						$db->update(
							'in_transit',
							{
								sched_arrival => $sched_arr,
								real_arrival  => $rt_arr
							},
							{ user_id => $uid }
						);
					}
				}
				if ( not $force ) {
					$self->run_hook( $uid, 'update' );
					return ( 1, undef );
				}
			}

			my $has_arrived = 0;

			eval {

				my $tx = $db->begin;

				if ( defined $train ) {

					if ( not $train->arrival ) {
						die("Train has no arrival timestamp\n");
					}

					$has_arrived = $train->arrival->epoch < $now->epoch ? 1 : 0;
					my $json = JSON->new;
					$db->update(
						'in_transit',
						{
							checkout_time => $now,
							arr_platform  => $train->platform,
							sched_arrival => $train->sched_arrival,
							real_arrival  => $train->arrival,
							cancelled => $train->arrival_is_cancelled ? 1 : 0,
							route =>
							  $json->encode( [ $self->route_diff($train) ] ),
							messages => $json->encode(
								[
									map { [ $_->[0]->epoch, $_->[1] ] }
									  $train->messages
								]
							)
						},
						{ user_id => $uid }
					);
					if ($has_arrived) {
						my @unknown_stations
						  = $self->grep_unknown_stations( $train->route );
						if (@unknown_stations) {
							$self->app->log->warn(
								'Encountered unknown stations: '
								  . join( ', ', @unknown_stations ) );
						}
					}
				}

				$journey
				  = $db->select( 'in_transit', '*', { user_id => $uid } )->hash;

				if ( $has_arrived or $force ) {
					delete $journey->{data};
					$journey->{edited}        = 0;
					$journey->{checkout_time} = $now;
					$db->insert( 'journeys', $journey );
					$db->delete( 'in_transit', { user_id => $uid } );

					my $cache_ts = $now->clone;
					if ( $journey->{real_departure}
						=~ m{ ^ (?<year> \d{4} ) - (?<month> \d{2} ) }x )
					{
						$cache_ts->set(
							year  => $+{year},
							month => $+{month}
						);
					}
					$self->invalidate_stats_cache( $cache_ts, $db, $uid );
				}

				$tx->commit;
			};

			if ($@) {
				$self->app->log->error("Checkout($uid): $@");
				return ( 1, 'Checkout error: ' . $@ );
			}

			if ( $has_arrived or $force ) {
				$self->run_hook( $uid, 'checkout' );
				return ( 0, undef );
			}
			$self->run_hook( $uid, 'update' );
			$self->add_route_timestamps( $uid, $train, 0 );
			return ( 1, undef );
		}
	);

	$self->helper(
		'mark_seen' => sub {
			my ( $self, $uid ) = @_;

			$self->pg->db->update(
				'users',
				{ last_seen => DateTime->now( time_zone => 'Europe/Berlin' ) },
				{ id        => $uid }
			);
		}
	);

	$self->helper(
		'update_in_transit_comment' => sub {
			my ( $self, $comment, $uid ) = @_;
			$uid //= $self->current_user->{id};

			my $status = $self->pg->db->select( 'in_transit', ['user_data'],
				{ user_id => $uid } )->expand->hash;
			if ( not $status ) {
				return;
			}
			$status->{user_data}{comment} = $comment;
			$self->pg->db->update(
				'in_transit',
				{ user_data => JSON->new->encode( $status->{user_data} ) },
				{ user_id   => $uid }
			);
		}
	);

	$self->helper(
		'update_journey_part' => sub {
			my ( $self, $db, $journey_id, $key, $value ) = @_;
			my $rows;

			my $journey = $self->get_journey(
				db            => $db,
				journey_id    => $journey_id,
				with_datetime => 1,
			);

			eval {
				if ( $key eq 'sched_departure' ) {
					$rows = $db->update(
						'journeys',
						{
							sched_departure => $value,
							edited          => $journey->{edited} | 0x0001,
						},
						{
							id => $journey_id,
						}
					)->rows;
				}
				elsif ( $key eq 'rt_departure' ) {
					$rows = $db->update(
						'journeys',
						{
							real_departure => $value,
							edited         => $journey->{edited} | 0x0002,
						},
						{
							id => $journey_id,
						}
					)->rows;

                 # stats are partitioned by rt_departure -> both the cache for
                 # the old value (see bottom of this function) and the new value
                 # (here) must be invalidated.
					$self->invalidate_stats_cache( $value, $db );
				}
				elsif ( $key eq 'sched_arrival' ) {
					$rows = $db->update(
						'journeys',
						{
							sched_arrival => $value,
							edited        => $journey->{edited} | 0x0100,
						},
						{
							id => $journey_id,
						}
					)->rows;
				}
				elsif ( $key eq 'rt_arrival' ) {
					$rows = $db->update(
						'journeys',
						{
							real_arrival => $value,
							edited       => $journey->{edited} | 0x0200,
						},
						{
							id => $journey_id,
						}
					)->rows;
				}
				elsif ( $key eq 'route' ) {
					my @new_route = map { [ $_, {}, undef ] } @{$value};
					$rows = $db->update(
						'journeys',
						{
							route  => JSON->new->encode( \@new_route ),
							edited => $journey->{edited} | 0x0010,
						},
						{
							id => $journey_id,
						}
					)->rows;
				}
				elsif ( $key eq 'cancelled' ) {
					$rows = $db->update(
						'journeys',
						{
							cancelled => $value,
							edited    => $journey->{edited} | 0x0020,
						},
						{
							id => $journey_id,
						}
					)->rows;
				}
				elsif ( $key eq 'comment' ) {
					$journey->{user_data}{comment} = $value;
					$rows = $db->update(
						'journeys',
						{
							user_data =>
							  JSON->new->encode( $journey->{user_data} ),
						},
						{
							id => $journey_id,
						}
					)->rows;
				}
				else {
					die("Invalid key $key\n");
				}
			};

			if ($@) {
				$self->app->log->error(
					"update_journey_part($journey_id, $key): $@");
				return "update_journey_part($key): $@";
			}
			if ( $rows == 1 ) {
				$self->invalidate_stats_cache( $journey->{rt_departure}, $db );
				return undef;
			}
			return 'UPDATE failed: did not match any journey part';
		}
	);

	$self->helper(
		'journey_sanity_check' => sub {
			my ( $self, $journey, $lax ) = @_;

			if ( defined $journey->{sched_duration}
				and $journey->{sched_duration} <= 0 )
			{
				return
'Die geplante Dauer dieser Zugfahrt ist ≤ 0. Teleportation und Zeitreisen werden aktuell nicht unterstützt.';
			}
			if ( defined $journey->{rt_duration}
				and $journey->{rt_duration} <= 0 )
			{
				return
'Die Dauer dieser Zugfahrt ist ≤ 0. Teleportation und Zeitreisen werden aktuell nicht unterstützt.';
			}
			if (    $journey->{sched_duration}
				and $journey->{sched_duration} > 60 * 60 * 24 )
			{
				return 'Die Zugfahrt ist länger als 24 Stunden.';
			}
			if (    $journey->{rt_duration}
				and $journey->{rt_duration} > 60 * 60 * 24 )
			{
				return 'Die Zugfahrt ist länger als 24 Stunden.';
			}
			if ( $journey->{kmh_route} > 500 or $journey->{kmh_beeline} > 500 )
			{
				return 'Zugfahrten mit über 500 km/h? Schön wär\'s.';
			}
			if ( $journey->{route} and @{ $journey->{route} } > 99 ) {
				my $stop_count = @{ $journey->{route} };
				return
"Die Zugfahrt hat $stop_count Unterwegshalte. Also ich weiß ja nicht so recht.";
			}
			if ( $journey->{edited} & 0x0010 and not $lax ) {
				my @unknown_stations
				  = $self->grep_unknown_stations( map { $_->[0] }
					  @{ $journey->{route} } );
				if (@unknown_stations) {
					return 'Unbekannte Station(en): '
					  . join( ', ', @unknown_stations );
				}
			}

			return undef;
		}
	);

	$self->helper(
		'verify_registration_token' => sub {
			my ( $self, $uid, $token ) = @_;

			my $db = $self->pg->db;
			my $tx = $db->begin;

			my $res = $db->select(
				'pending_registrations',
				'count(*) as count',
				{
					user_id => $uid,
					token   => $token
				}
			);

			if ( $res->hash->{count} ) {
				$db->update( 'users', { status => 1 }, { id => $uid } );
				$db->delete( 'pending_registrations', { user_id => $uid } );
				$tx->commit;
				return 1;
			}
			return;
		}
	);

	$self->helper(
		'get_uid_by_name_and_mail' => sub {
			my ( $self, $name, $email ) = @_;

			my $res = $self->pg->db->select(
				'users',
				['id'],
				{
					name   => $name,
					email  => $email,
					status => 1
				}
			);

			if ( my $user = $res->hash ) {
				return $user->{id};
			}
			return;
		}
	);

	$self->helper(
		'get_privacy_by_name' => sub {
			my ( $self, $name ) = @_;

			my $res = $self->pg->db->select(
				'users',
				[ 'id', 'public_level' ],
				{
					name   => $name,
					status => 1
				}
			);

			if ( my $user = $res->hash ) {
				return $user;
			}
			return;
		}
	);

	$self->helper(
		'set_privacy' => sub {
			my ( $self, $uid, $public_level ) = @_;

			$self->pg->db->update(
				'users',
				{ public_level => $public_level },
				{ id           => $uid }
			);
		}
	);

	$self->helper(
		'mark_for_password_reset' => sub {
			my ( $self, $db, $uid, $token ) = @_;

			my $res = $db->select(
				'pending_passwords',
				'count(*) as count',
				{ user_id => $uid }
			);
			if ( $res->hash->{count} ) {
				return 'in progress';
			}

			$db->insert(
				'pending_passwords',
				{
					user_id => $uid,
					token   => $token,
					requested_at =>
					  DateTime->now( time_zone => 'Europe/Berlin' )
				}
			);

			return undef;
		}
	);

	$self->helper(
		'verify_password_token' => sub {
			my ( $self, $uid, $token ) = @_;

			my $res = $self->pg->db->select(
				'pending_passwords',
				'count(*) as count',
				{
					user_id => $uid,
					token   => $token
				}
			);

			if ( $res->hash->{count} ) {
				return 1;
			}
			return;
		}
	);

	$self->helper(
		'mark_for_mail_change' => sub {
			my ( $self, $db, $uid, $email, $token ) = @_;

			$db->insert(
				'pending_mails',
				{
					user_id => $uid,
					email   => $email,
					token   => $token,
					requested_at =>
					  DateTime->now( time_zone => 'Europe/Berlin' )
				},
				{
					on_conflict => \
'(user_id) do update set email = EXCLUDED.email, token = EXCLUDED.token, requested_at = EXCLUDED.requested_at'
				},
			);
		}
	);

	$self->helper(
		'change_mail_with_token' => sub {
			my ( $self, $uid, $token ) = @_;

			my $db = $self->pg->db;
			my $tx = $db->begin;

			my $res_h = $db->select(
				'pending_mails',
				['email'],
				{
					user_id => $uid,
					token   => $token
				}
			)->hash;

			if ($res_h) {
				$db->update(
					'users',
					{ email => $res_h->{email} },
					{ id    => $uid }
				);
				$db->delete( 'pending_mails', { user_id => $uid } );
				$tx->commit;
				return 1;
			}
			return;
		}
	);

	$self->helper(
		'remove_password_token' => sub {
			my ( $self, $uid, $token ) = @_;

			$self->pg->db->delete(
				'pending_passwords',
				{
					user_id => $uid,
					token   => $token
				}
			);
		}
	);

	# This helper should only be called directly when also providing a user ID.
	# If you don't have one, use current_user() instead (get_user_data will
	# delegate to it anyways).
	$self->helper(
		'get_user_data' => sub {
			my ( $self, $uid ) = @_;

			$uid //= $self->current_user->{id};

			my $user_data = $self->pg->db->select(
				'users',
				'id, name, status, public_level, email, '
				  . 'extract(epoch from registered_at) as registered_at_ts, '
				  . 'extract(epoch from last_seen) as last_seen_ts, '
				  . 'extract(epoch from deletion_requested) as deletion_requested_ts',
				{ id => $uid }
			)->hash;

			if ($user_data) {
				return {
					id            => $user_data->{id},
					name          => $user_data->{name},
					status        => $user_data->{status},
					is_public     => $user_data->{public_level},
					email         => $user_data->{email},
					registered_at => DateTime->from_epoch(
						epoch     => $user_data->{registered_at_ts},
						time_zone => 'Europe/Berlin'
					),
					last_seen => DateTime->from_epoch(
						epoch     => $user_data->{last_seen_ts},
						time_zone => 'Europe/Berlin'
					),
					deletion_requested => $user_data->{deletion_requested_ts}
					? DateTime->from_epoch(
						epoch     => $user_data->{deletion_requested_ts},
						time_zone => 'Europe/Berlin'
					  )
					: undef,
				};
			}
			return undef;
		}
	);

	$self->helper(
		'get_api_token' => sub {
			my ( $self, $uid ) = @_;
			$uid //= $self->current_user->{id};

			my $token = {};
			my $res   = $self->pg->db->select(
				'tokens',
				[ 'type', 'token' ],
				{ user_id => $uid }
			);

			for my $entry ( $res->hashes->each ) {
				$token->{ $self->app->token_types->[ $entry->{type} - 1 ] }
				  = $entry->{token};
			}

			return $token;
		}
	);

	$self->helper(
		'get_webhook' => sub {
			my ( $self, $uid ) = @_;
			$uid //= $self->current_user->{id};

			my $res_h
			  = $self->pg->db->select( 'webhooks_str', '*',
				{ user_id => $uid } )->hash;

			$res_h->{latest_run} = epoch_to_dt( $res_h->{latest_run_ts} );

			return $res_h;
		}
	);

	$self->helper(
		'set_webhook' => sub {
			my ( $self, %opt ) = @_;

			$opt{uid} //= $self->current_user->{id};

			if ( $opt{token} ) {
				$opt{token} =~ tr{\r\n}{}d;
			}

			my $res = $self->pg->db->insert(
				'webhooks',
				{
					user_id => $opt{uid},
					enabled => $opt{enabled},
					url     => $opt{url},
					token   => $opt{token}
				},
				{
					on_conflict => \
'(user_id) do update set enabled = EXCLUDED.enabled, url = EXCLUDED.url, token = EXCLUDED.token, errored = null, latest_run = null, output = null'
				}
			);
		}
	);

	$self->helper(
		'mark_hook_status' => sub {
			my ( $self, $uid, $url, $success, $text ) = @_;

			if ( length($text) > 1000 ) {
				$text = substr( $text, 0, 1000 ) . '…';
			}

			$self->pg->db->update(
				'webhooks',
				{
					errored    => $success ? 0 : 1,
					latest_run => DateTime->now( time_zone => 'Europe/Berlin' ),
					output     => $text,
				},
				{
					user_id => $uid,
					url     => $url
				}
			);
		}
	);

	$self->helper(
		'run_hook' => sub {
			my ( $self, $uid, $reason, $callback ) = @_;

			my $hook = $self->get_webhook($uid);

			if ( not $hook->{enabled} or not $hook->{url} =~ m{^ https?:// }x )
			{
				if ($callback) {
					&$callback();
				}
				return;
			}

			my $status    = $self->get_user_status_json_v1($uid);
			my $header    = {};
			my $hook_body = {
				reason => $reason,
				status => $status,
			};

			if ( $hook->{token} ) {
				$header->{Authorization} = "Bearer $hook->{token}";
				$header->{'User-Agent'}
				  = 'travelynx/' . $self->app->config->{version};
			}

			my $ua = $self->ua;
			if ($callback) {
				$ua->request_timeout(4);
			}
			else {
				$ua->request_timeout(10);
			}

			$ua->post_p( $hook->{url} => $header => json => $hook_body )->then(
				sub {
					my ($tx) = @_;
					if ( my $err = $tx->error ) {
						$self->mark_hook_status( $uid, $hook->{url}, 0,
							"HTTP $err->{code} $err->{message}" );
					}
					else {
						$self->mark_hook_status( $uid, $hook->{url}, 1,
							$tx->result->body );
					}
					if ($callback) {
						&$callback();
					}
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->mark_hook_status( $uid, $hook->{url}, 0, $err );
					if ($callback) {
						&$callback();
					}
				}
			)->wait;
		}
	);

	$self->helper(
		'get_user_password' => sub {
			my ( $self, $name ) = @_;

			my $res_h = $self->pg->db->select(
				'users',
				'id, name, status, password as password_hash',
				{ name => $name }
			)->hash;

			return $res_h;
		}
	);

	$self->helper(
		'add_user' => sub {
			my ( $self, $db, $user_name, $email, $token, $password ) = @_;

          # This helper must be called during a transaction, as user creation
          # may fail even after the database entry has been generated, e.g.  if
          # the registration mail cannot be sent. We therefore use $db (the
          # database handle performing the transaction) instead of $self->pg->db
          # (which may be a new handle not belonging to the transaction).

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			my $res = $db->insert(
				'users',
				{
					name          => $user_name,
					status        => 0,
					public_level  => 0,
					email         => $email,
					password      => $password,
					registered_at => $now,
					last_seen     => $now,
				},
				{ returning => 'id' }
			);
			my $uid = $res->hash->{id};

			$db->insert(
				'pending_registrations',
				{
					user_id => $uid,
					token   => $token
				}
			);

			return $uid;
		}
	);

	$self->helper(
		'flag_user_deletion' => sub {
			my ( $self, $uid ) = @_;

			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			$self->pg->db->update(
				'users',
				{ deletion_requested => $now },
				{
					id => $uid,
				}
			);
		}
	);

	$self->helper(
		'unflag_user_deletion' => sub {
			my ( $self, $uid ) = @_;

			$self->pg->db->update(
				'users',
				{
					deletion_requested => undef,
				},
				{
					id => $uid,
				}
			);
		}
	);

	$self->helper(
		'set_user_password' => sub {
			my ( $self, $uid, $password ) = @_;

			$self->pg->db->update(
				'users',
				{ password => $password },
				{ id       => $uid }
			);
		}
	);

	$self->helper(
		'check_if_user_name_exists' => sub {
			my ( $self, $user_name ) = @_;

			my $count = $self->pg->db->select(
				'users',
				'count(*) as count',
				{ name => $user_name }
			)->hash->{count};

			if ($count) {
				return 1;
			}
			return 0;
		}
	);

	$self->helper(
		'check_if_mail_is_blacklisted' => sub {
			my ( $self, $mail ) = @_;

			my $count = $self->pg->db->select(
				'users',
				'count(*) as count',
				{
					email  => $mail,
					status => 0,
				}
			)->hash->{count};

			if ($count) {
				return 1;
			}

			$count = $self->pg->db->select(
				'mail_blacklist',
				'count(*) as count',
				{
					email     => $mail,
					num_tries => { '>', 1 },
				}
			)->hash->{count};

			if ($count) {
				return 1;
			}
			return 0;
		}
	);

	$self->helper(
		'delete_journey' => sub {
			my ( $self, $journey_id, $checkin_epoch, $checkout_epoch ) = @_;
			my $uid = $self->current_user->{id};

			my @journeys = $self->get_user_travels(
				uid        => $uid,
				journey_id => $journey_id
			);
			if ( @journeys == 0 ) {
				return 'Journey not found';
			}
			my $journey = $journeys[0];

			# Double-check (comparing both ID and action epoch) to make sure we
			# are really deleting the right journey and the user isn't just
			# playing around with POST requests.
			if (   $journey->{id} != $journey_id
				or $journey->{checkin_ts} != $checkin_epoch
				or $journey->{checkout_ts} != $checkout_epoch )
			{
				return 'Invalid journey data';
			}

			my $rows;
			eval {
				$rows = $self->pg->db->delete(
					'journeys',
					{
						user_id => $uid,
						id      => $journey_id,
					}
				)->rows;
			};

			if ($@) {
				$self->app->log->error("Delete($uid, $journey_id): $@");
				return 'DELETE failed: ' . $@;
			}

			if ( $rows == 1 ) {
				$self->invalidate_stats_cache(
					epoch_to_dt( $journey->{rt_dep_ts} ) );
				return undef;
			}
			return sprintf( 'Deleted %d rows, expected 1', $rows );
		}
	);

	$self->helper(
		'get_journey_stats' => sub {
			my ( $self, %opt ) = @_;

			if ( $opt{cancelled} ) {
				$self->app->log->warn(
'get_journey_stats called with illegal option cancelled => 1'
				);
				return {};
			}

			my $uid   = $opt{uid}   // $self->current_user->{id};
			my $year  = $opt{year}  // 0;
			my $month = $opt{month} // 0;

			# Assumption: If the stats cache contains an entry it is up-to-date.
			# -> Cache entries must be explicitly invalidated whenever the user
			# checks out of a train or manually edits/adds a journey.

			my $res = $self->pg->db->select(
				'journey_stats',
				['data'],
				{
					user_id => $uid,
					year    => $year,
					month   => $month
				}
			);

			my $res_h = $res->expand->hash;

			if ($res_h) {
				$res->finish;
				return $res_h->{data};
			}

			my $interval_start = DateTime->new(
				time_zone => 'Europe/Berlin',
				year      => 2000,
				month     => 1,
				day       => 1,
				hour      => 0,
				minute    => 0,
				second    => 0,
			);

          # I wonder if people will still be traveling by train in the year 3000
			my $interval_end = $interval_start->clone->add( years => 1000 );

			if ( $opt{year} and $opt{month} ) {
				$interval_start->set(
					year  => $opt{year},
					month => $opt{month}
				);
				$interval_end = $interval_start->clone->add( months => 1 );
			}
			elsif ( $opt{year} ) {
				$interval_start->set( year => $opt{year} );
				$interval_end = $interval_start->clone->add( years => 1 );
			}

			my @journeys = $self->get_user_travels(
				uid       => $uid,
				cancelled => $opt{cancelled} ? 1 : 0,
				verbose   => 1,
				after     => $interval_start,
				before    => $interval_end
			);
			my $stats = $self->compute_journey_stats(@journeys);

			eval {
				$self->pg->db->insert(
					'journey_stats',
					{
						user_id => $uid,
						year    => $year,
						month   => $month,
						data    => JSON->new->encode($stats),
					}
				);
			};
			if ( my $err = $@ ) {
				if ( $err =~ m{duplicate key value violates unique constraint} )
				{
                 # When a user opens the same history page several times in
                 # short succession, there is a race condition where several
                 # Mojolicious workers execute this helper, notice that there is
                 # no up-to-date history, compute it, and insert it using the
                 # statement above. This will lead to a uniqueness violation
                 # in each successive insert. However, this is harmless, and
                 # thus ignored.
				}
				else {
					# Otherwise we probably have a problem.
					die($@);
				}
			}

			return $stats;
		}
	);

	$self->helper(
		'history_years' => sub {
			my ( $self, $uid ) = @_;
			$uid //= $self->current_user->{id},

			  my $res = $self->pg->db->select(
				'journeys',
				'distinct extract(year from real_departure) as year',
				{ user_id  => $uid },
				{ order_by => { -asc => 'year' } }
			  );

			my @ret;
			for my $row ( $res->hashes->each ) {
				push( @ret, [ $row->{year}, $row->{year} ] );
			}
			return @ret;
		}
	);

	$self->helper(
		'history_months' => sub {
			my ( $self, $uid ) = @_;
			$uid //= $self->current_user->{id},

			  my $res = $self->pg->db->select(
				'journeys',
				"distinct to_char(real_departure, 'YYYY.MM') as yearmonth",
				{ user_id  => $uid },
				{ order_by => { -asc => 'yearmonth' } }
			  );

			my @ret;
			for my $row ( $res->hashes->each ) {
				my ( $year, $month ) = split( qr{[.]}, $row->{yearmonth} );
				push( @ret, [ "${year}/${month}", "${month}.${year}" ] );
			}
			return @ret;
		}
	);

	$self->helper(
		'route_diff' => sub {
			my ( $self, $train ) = @_;
			my @json_route;
			my @route       = $train->route;
			my @sched_route = $train->sched_route;

			my $route_idx = 0;
			my $sched_idx = 0;

			while ( $route_idx <= $#route and $sched_idx <= $#sched_route ) {
				if ( $route[$route_idx] eq $sched_route[$sched_idx] ) {
					push( @json_route, [ $route[$route_idx], {}, undef ] );
					$route_idx++;
					$sched_idx++;
				}

				# this branch is inefficient, but won't be taken frequently
				elsif ( not( grep { $_ eq $route[$route_idx] } @sched_route ) )
				{
					push( @json_route,
						[ $route[$route_idx], {}, 'additional' ],
					);
					$route_idx++;
				}
				else {
					push( @json_route,
						[ $sched_route[$sched_idx], {}, 'cancelled' ],
					);
					$sched_idx++;
				}
			}
			while ( $route_idx <= $#route ) {
				push( @json_route, [ $route[$route_idx], {}, 'additional' ], );
				$route_idx++;
			}
			while ( $sched_idx <= $#sched_route ) {
				push( @json_route,
					[ $sched_route[$sched_idx], {}, 'cancelled' ],
				);
				$sched_idx++;
			}
			return @json_route;
		}
	);

	$self->helper(
		'get_dbdb_station_p' => sub {
			my ( $self, $eva ) = @_;

			my $url = "https://lib.finalrewind.org/dbdb/s/${eva}.json";

			my $cache   = $self->app->cache_iris_main;
			my $promise = Mojo::Promise->new;

			if ( my $content = $cache->thaw($url) ) {
				$promise->resolve($content);
				return $promise;
			}

			$self->ua->request_timeout(5)->get_p($url)->then(
				sub {
					my ($tx) = @_;
					my $body = decode( 'utf-8', $tx->res->body );

					my $json = JSON->new->decode($body);
					$cache->freeze( $url, $json );
					$promise->resolve($json);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
				}
			)->wait;
			return $promise;
		}
	);

	$self->helper(
		'has_wagonorder_p' => sub {
			my ( $self, $ts, $train_no ) = @_;
			my $api_ts = $ts->strftime('%Y%m%d%H%M');
			my $url
			  = "https://lib.finalrewind.org/dbdb/has_wagonorder/${train_no}/${api_ts}";
			my $cache   = $self->app->cache_iris_main;
			my $promise = Mojo::Promise->new;

			if ( my $content = $cache->get($url) ) {
				if ( $content eq 'y' ) {
					$promise->resolve;
					return $promise;
				}
				elsif ( $content eq 'n' ) {
					$promise->reject;
					return $promise;
				}
			}

			$self->ua->request_timeout(5)->head_p($url)->then(
				sub {
					my ($tx) = @_;
					if ( $tx->result->is_success ) {
						$cache->set( $url, 'y' );
						$promise->resolve;
					}
					else {
						$cache->set( $url, 'n' );
						$promise->reject;
					}
				}
			)->catch(
				sub {
					$cache->set( $url, 'n' );
					$promise->reject;
				}
			)->wait;
			return $promise;
		}
	);

	$self->helper(
		'get_wagonorder_p' => sub {
			my ( $self, $ts, $train_no ) = @_;
			my $api_ts = $ts->strftime('%Y%m%d%H%M');
			my $url
			  = "https://www.apps-bahn.de/wr/wagenreihung/1.0/${train_no}/${api_ts}";

			my $cache   = $self->app->cache_iris_main;
			my $promise = Mojo::Promise->new;

			if ( my $content = $cache->thaw($url) ) {
				$promise->resolve($content);
				return $promise;
			}

			$self->ua->request_timeout(5)->get_p($url)->then(
				sub {
					my ($tx) = @_;
					my $body = decode( 'utf-8', $tx->res->body );

					my $json = JSON->new->decode($body);
					$cache->freeze( $url, $json );
					$promise->resolve($json);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
				}
			)->wait;
			return $promise;
		}
	);

	$self->helper(
		'get_hafas_polyline_p' => sub {
			my ( $self, $train, $trip_id ) = @_;

			my $line = $train->line // 0;
			my $url
			  = "https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
			my $cache   = $self->app->cache_iris_main;
			my $promise = Mojo::Promise->new;
			my $version = $self->app->config->{version};

			if ( my $content = $cache->thaw($url) ) {
				$promise->resolve($content);
				return $promise;
			}

			$self->ua->request_timeout(5)->get_p(
				$url => {
					'User-Agent' =>
"travelynx/${version} +https://finalrewind.org/projects/travelynx"
				}
			)->then(
				sub {
					my ($tx) = @_;
					my $body = decode( 'utf-8', $tx->res->body );
					my $json = JSON->new->decode($body);
					my @coordinate_list;

					for my $feature ( @{ $json->{polyline}{features} } ) {
						if ( exists $feature->{geometry}{coordinates} ) {
							my $coord = $feature->{geometry}{coordinates};
							if ( exists $feature->{properties}{type}
								and $feature->{properties}{type} eq 'stop' )
							{
								push( @{$coord}, $feature->{properties}{id} );
							}
							push( @coordinate_list, $coord );
						}
					}

					my $ret = {
						name     => $json->{line}{name} // '?',
						polyline => [@coordinate_list],
						raw      => $json,
					};

					$cache->freeze( $url, $ret );
					$promise->resolve($ret);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
				}
			)->wait;

			return $promise;
		}
	);

	$self->helper(
		'get_hafas_tripid_p' => sub {
			my ( $self, $train ) = @_;

			my $promise = Mojo::Promise->new;
			my $cache   = $self->app->cache_iris_main;
			my $eva     = $train->station_uic;

			my $dep_ts = DateTime->now( time_zone => 'Europe/Berlin' );
			my $url
			  = "https://2.db.transport.rest/stations/${eva}/departures?duration=5&when=$dep_ts";

			if ( $train->sched_departure ) {
				$dep_ts = $train->sched_departure->epoch;
				$url
				  = "https://2.db.transport.rest/stations/${eva}/departures?duration=5&when=$dep_ts";
			}
			elsif ( $train->sched_arrival ) {
				$dep_ts = $train->sched_arrival->epoch;
				$url
				  = "https://2.db.transport.rest/stations/${eva}/arrivals?duration=5&when=$dep_ts";
			}

			if ( my $content = $cache->get($url) ) {
				$promise->resolve($content);
				return $promise;
			}

			$self->ua->request_timeout(5)->get_p(
				$url => {
					'User-Agent' => 'travelynx/' . $self->app->config->{version}
				}
			)->then(
				sub {
					my ($tx) = @_;
					my $body = decode( 'utf-8', $tx->res->body );
					my $json = JSON->new->decode($body);

					for my $result ( @{$json} ) {
						if (    $result->{line}
							and $result->{line}{fahrtNr} == $train->train_no )
						{
							my $trip_id = $result->{tripId};
							$cache->set( $url, $trip_id );
							$promise->resolve($trip_id);
							return;
						}
					}
					$promise->reject;
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
				}
			)->wait;

			return $promise;
		}
	);

	$self->helper(
		'get_hafas_json_p' => sub {
			my ( $self, $url ) = @_;

			my $cache   = $self->app->cache_iris_main;
			my $promise = Mojo::Promise->new;

			if ( my $content = $cache->thaw($url) ) {
				$promise->resolve($content);
				return $promise;
			}

			$self->ua->request_timeout(5)->get_p($url)->then(
				sub {
					my ($tx) = @_;
					my $body = decode( 'ISO-8859-15', $tx->res->body );

					$body =~ s{^TSLs[.]sls = }{};
					$body =~ s{;$}{};
					$body =~ s{&#x0028;}{(}g;
					$body =~ s{&#x0029;}{)}g;
					my $json = JSON->new->decode($body);
					$cache->freeze( $url, $json );
					$promise->resolve($json);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->app->log->warn("get($url): $err");
					$promise->reject($err);
				}
			)->wait;
			return $promise;
		}
	);

	$self->helper(
		'get_hafas_xml_p' => sub {
			my ( $self, $url ) = @_;

			my $cache   = $self->app->cache_iris_rt;
			my $promise = Mojo::Promise->new;

			if ( my $content = $cache->thaw($url) ) {
				$promise->resolve($content);
				return $promise;
			}

			$self->ua->request_timeout(5)->get_p($url)->then(
				sub {
					my ($tx) = @_;
					my $body = decode( 'ISO-8859-15', $tx->res->body );
					my $tree;

					my $traininfo = {
						station  => {},
						messages => [],
					};

					# <SDay text="... &gt; ..."> is invalid HTML, but present in
					# regardless. As it is the last tag, we just throw it away.
					$body =~ s{<SDay [^>]*/>}{}s;
					eval { $tree = XML::LibXML->load_xml( string => $body ) };
					if ($@) {
						$self->app->log->warn("load_xml($url): $@");
						$cache->freeze( $url, $traininfo );
						$promise->resolve($traininfo);
						return;
					}

					for my $station ( $tree->findnodes('/Journey/St') ) {
						my $name   = $station->getAttribute('name');
						my $adelay = $station->getAttribute('adelay');
						my $ddelay = $station->getAttribute('ddelay');
						$traininfo->{station}{$name} = {
							adelay => $adelay,
							ddelay => $ddelay,
						};
					}

					for my $message ( $tree->findnodes('/Journey/HIMMessage') )
					{
						my $header  = $message->getAttribute('header');
						my $lead    = $message->getAttribute('lead');
						my $display = $message->getAttribute('display');
						push(
							@{ $traininfo->{messages} },
							{
								header  => $header,
								lead    => $lead,
								display => $display
							}
						);
					}

					$cache->freeze( $url, $traininfo );
					$promise->resolve($traininfo);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->app->log->warn("get($url): $err");
					$promise->reject($err);
				}
			)->wait;
			return $promise;
		}
	);

	$self->helper(
		'add_route_timestamps' => sub {
			my ( $self, $uid, $train, $is_departure ) = @_;

			$uid //= $self->current_user->{id};

			my $db = $self->pg->db;

			my $journey = $db->select(
				'in_transit_str',
				[ 'arr_eva', 'dep_eva', 'route', 'data' ],
				{ user_id => $uid }
			)->expand->hash;

			if ( not $journey ) {
				return;
			}

			if ( not $journey->{data}{trip_id} ) {
				my ( $origin_eva, $destination_eva, $polyline_str );
				$self->get_hafas_tripid_p($train)->then(
					sub {
						my ($trip_id) = @_;

						my $res = $db->select( 'in_transit', ['data'],
							{ user_id => $uid } );
						my $res_h = $res->expand->hash;
						my $data  = $res_h->{data} // {};

						$data->{trip_id} = $trip_id;

						$db->update(
							'in_transit',
							{ data    => JSON->new->encode($data) },
							{ user_id => $uid }
						);
						return $self->get_hafas_polyline_p( $train, $trip_id );
					}
				)->then(
					sub {
						my ($ret) = @_;
						my $polyline = $ret->{polyline};
						$origin_eva      = 0 + $ret->{raw}{origin}{id};
						$destination_eva = 0 + $ret->{raw}{destination}{id};

						# work around Cache::File turning floats into strings
						for my $coord ( @{$polyline} ) {
							@{$coord} = map { 0 + $_ } @{$coord};
						}

						$polyline_str = JSON->new->encode($polyline);

						return $db->select_p(
							'polylines',
							['id'],
							{
								origin_eva      => $origin_eva,
								destination_eva => $destination_eva,
								polyline        => $polyline_str
							},
							{ limit => 1 }
						);
					}
				)->then(
					sub {
						my ($pl_res) = @_;
						my $polyline_id;
						if ( my $h = $pl_res->hash ) {
							$polyline_id = $h->{id};
						}
						else {
							eval {
								$polyline_id = $db->insert(
									'polylines',
									{
										origin_eva      => $origin_eva,
										destination_eva => $destination_eva,
										polyline        => $polyline_str
									},
									{ returning => 'id' }
								)->hash->{id};
							};
							if ($@) {
								$self->app->log->warn(
									"add_route_timestamps: insert polyline: $@"
								);
							}
						}
						if ($polyline_id) {
							$db->update(
								'in_transit',
								{ polyline_id => $polyline_id },
								{ user_id     => $uid }
							);
						}
					}
				)->wait;
			}

			my ($platform) = ( ( $train->platform // 0 ) =~ m{(\d+)} );

			my $route = $journey->{route};

			my $base
			  = 'https://reiseauskunft.bahn.de/bin/trainsearch.exe/dn?L=vs_json.vs_hap&start=yes&rt=1';
			my $date_yy   = $train->start->strftime('%d.%m.%y');
			my $date_yyyy = $train->start->strftime('%d.%m.%Y');
			my $train_no  = $train->type . ' ' . $train->train_no;

			my ( $trainlink, $route_data );

			$self->get_hafas_json_p(
				"${base}&date=${date_yy}&trainname=${train_no}")->then(
				sub {
					my ($trainsearch) = @_;

					# Fallback: Take first result
					$trainlink = $trainsearch->{suggestions}[0]{trainLink};

					# Try finding a result for the current date
					for
					  my $suggestion ( @{ $trainsearch->{suggestions} // [] } )
					{

       # Drunken API, sail with care. Both date formats are used interchangeably
						if (   $suggestion->{depDate} eq $date_yy
							or $suggestion->{depDate} eq $date_yyyy )
						{
            # Train numbers are not unique, e.g. IC 149 refers both to the
            # InterCity service Amsterdam -> Berlin and to the InterCity service
            # Koebenhavns Lufthavn st -> Aarhus.  One workaround is making
            # requests with the stationFilter=80 parameter.  Checking the origin
            # station seems to be the more generic solution, so we do that
            # instead.
							if ( $suggestion->{dep} eq $train->origin ) {
								$trainlink = $suggestion->{trainLink};
								last;
							}
						}
					}

					if ( not $trainlink ) {
						$self->app->log->debug("trainlink not found");
						return Mojo::Promise->reject("trainlink not found");
					}
					my $base2
					  = 'https://reiseauskunft.bahn.de/bin/traininfo.exe/dn';
					return $self->get_hafas_json_p(
"${base2}/${trainlink}?rt=1&date=${date_yy}&L=vs_json.vs_hap"
					);
				}
			)->then(
				sub {
					my ($traininfo) = @_;
					if ( not $traininfo or $traininfo->{error} ) {
						$self->app->log->debug("traininfo error");
						return Mojo::Promise->reject("traininfo error");
					}
					my $routeinfo
					  = $traininfo->{suggestions}[0]{locations};

					my $strp = DateTime::Format::Strptime->new(
						pattern   => '%d.%m.%y %H:%M',
						time_zone => 'Europe/Berlin',
					);

					$route_data = {};

					for my $station ( @{$routeinfo} ) {
						my $arr
						  = $strp->parse_datetime(
							$station->{arrDate} . ' ' . $station->{arrTime} );
						my $dep
						  = $strp->parse_datetime(
							$station->{depDate} . ' ' . $station->{depTime} );
						$route_data->{ $station->{name} } = {
							sched_arr => $arr ? $arr->epoch : 0,
							sched_dep => $dep ? $dep->epoch : 0,
						};
					}

					my $base2
					  = 'https://reiseauskunft.bahn.de/bin/traininfo.exe/dn';
					return $self->get_hafas_xml_p(
						"${base2}/${trainlink}?rt=1&date=${date_yy}&L=vs_java3"
					);
				}
			)->then(
				sub {
					my ($traininfo2) = @_;

					for my $station ( keys %{$route_data} ) {
						for my $key (
							keys %{ $traininfo2->{station}{$station} // {} } )
						{
							$route_data->{$station}{$key}
							  = $traininfo2->{station}{$station}{$key};
						}
					}

					for my $station ( @{$route} ) {
						$station->[1]
						  = $route_data->{ $station->[0] };
					}

					my $res = $db->select( 'in_transit', ['data'],
						{ user_id => $uid } );
					my $res_h = $res->expand->hash;
					my $data  = $res_h->{data} // {};

					$data->{delay_msg} = [ map { [ $_->[0]->epoch, $_->[1] ] }
						  $train->delay_messages ];
					$data->{qos_msg} = [ map { [ $_->[0]->epoch, $_->[1] ] }
						  $train->qos_messages ];

					$data->{him_msg} = $traininfo2->{messages};

					$db->update(
						'in_transit',
						{
							route => JSON->new->encode($route),
							data  => JSON->new->encode($data)
						},
						{ user_id => $uid }
					);
				}
			)->wait;

			if ( $train->sched_departure ) {
				$self->has_wagonorder_p( $train->sched_departure,
					$train->train_no )->then(
					sub {
						return $self->get_wagonorder_p( $train->sched_departure,
							$train->train_no );
					}
				)->then(
					sub {
						my ($wagonorder) = @_;

						my $res = $db->select(
							'in_transit',
							[ 'data', 'user_data' ],
							{ user_id => $uid }
						);
						my $res_h     = $res->expand->hash;
						my $data      = $res_h->{data} // {};
						my $user_data = $res_h->{user_data} // {};

						if ( $is_departure and not exists $wagonorder->{error} )
						{
							$data->{wagonorder_dep} = $wagonorder;
							if ( exists $user_data->{wagongroups} ) {
								$user_data->{wagongroups} = [];
							}
							for my $group (
								@{
									$wagonorder->{data}{istformation}
									  {allFahrzeuggruppe} // []
								}
							  )
							{
								my @wagons;
								for
								  my $wagon ( @{ $group->{allFahrzeug} // [] } )
								{
									push(
										@wagons,
										{
											id => $wagon->{fahrzeugnummer},
											number =>
											  $wagon->{wagenordnungsnummer},
											type => $wagon->{fahrzeugtyp},
										}
									);
								}
								push(
									@{ $user_data->{wagongroups} },
									{
										name =>
										  $group->{fahrzeuggruppebezeichnung},
										from =>
										  $group->{startbetriebsstellename},
										to => $group->{zielbetriebsstellename},
										no => $group->{verkehrlichezugnummer},
										wagons => [@wagons],
									}
								);
							}
							$db->update(
								'in_transit',
								{
									data      => JSON->new->encode($data),
									user_data => JSON->new->encode($user_data)
								},
								{ user_id => $uid }
							);
						}
						elsif ( not $is_departure
							and not exists $wagonorder->{error} )
						{
							$data->{wagonorder_arr} = $wagonorder;
							$db->update(
								'in_transit',
								{ data    => JSON->new->encode($data) },
								{ user_id => $uid }
							);
						}
					}
				)->wait;
			}

			if ($is_departure) {
				$self->get_dbdb_station_p( $journey->{dep_eva} )->then(
					sub {
						my ($station_info) = @_;

						my $res = $db->select( 'in_transit', ['data'],
							{ user_id => $uid } );
						my $res_h = $res->expand->hash;
						my $data  = $res_h->{data} // {};

						$data->{stationinfo_dep} = $station_info;

						$db->update(
							'in_transit',
							{ data    => JSON->new->encode($data) },
							{ user_id => $uid }
						);
					}
				)->wait;
			}

			if ( $journey->{arr_eva} and not $is_departure ) {
				$self->get_dbdb_station_p( $journey->{arr_eva} )->then(
					sub {
						my ($station_info) = @_;

						my $res = $db->select( 'in_transit', ['data'],
							{ user_id => $uid } );
						my $res_h = $res->expand->hash;
						my $data  = $res_h->{data} // {};

						$data->{stationinfo_arr} = $station_info;

						$db->update(
							'in_transit',
							{ data    => JSON->new->encode($data) },
							{ user_id => $uid }
						);
					}
				)->wait;
			}
		}
	);

	$self->helper(
		'get_oldest_journey_ts' => sub {
			my ($self) = @_;

			my $res_h = $self->pg->db->select(
				'journeys_str',
				['sched_dep_ts'],
				{
					user_id => $self->current_user->{id},
				},
				{
					limit    => 1,
					order_by => {
						-asc => 'real_dep_ts',
					},
				}
			)->hash;

			if ($res_h) {
				return epoch_to_dt( $res_h->{sched_dep_ts} );
			}
			return undef;
		}
	);

	$self->helper(
		'get_latest_dest_id' => sub {
			my ( $self, %opt ) = @_;

			my $uid = $opt{uid} // $self->current_user->{id};
			my $db  = $opt{db}  // $self->pg->db;

			my $journey = $db->select( 'in_transit', ['checkout_station_id'],
				{ user_id => $uid } )->hash;
			if ( not $journey ) {
				$journey = $db->select(
					'journeys',
					['checkout_station_id'],
					{
						user_id   => $uid,
						cancelled => 0
					},
					{
						limit    => 1,
						order_by => { -desc => 'real_departure' }
					}
				)->hash;
			}

			if ( not $journey ) {
				return;
			}

			return $journey->{checkout_station_id};
		}
	);

	$self->helper(
		'get_connection_targets' => sub {
			my ( $self, %opt ) = @_;

			my $uid       = $opt{uid} //= $self->current_user->{id};
			my $threshold = $opt{threshold}
			  // DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( months => 4 );
			my $db        = $opt{db} //= $self->pg->db;
			my $min_count = $opt{min_count} // 3;

			my $dest_id = $opt{eva} // $self->get_latest_dest_id(%opt);

			if ( not $dest_id ) {
				return;
			}

			my $res = $db->query(
				qq{
					select
					count(checkout_station_id) as count,
					checkout_station_id as dest
					from journeys
					where user_id = ?
					and checkin_station_id = ?
					and real_departure > ?
					group by checkout_station_id
					order by count desc;
				},
				$uid,
				$dest_id,
				$threshold
			);
			my @destinations
			  = $res->hashes->grep( sub { shift->{count} >= $min_count } )
			  ->map( sub                { shift->{dest} } )->each;
			@destinations
			  = grep { $self->app->station_by_eva->{$_} } @destinations;
			@destinations
			  = map { $self->app->station_by_eva->{$_}->[1] } @destinations;
			return @destinations;
		}
	);

	$self->helper(
		'get_connecting_trains' => sub {
			my ( $self, %opt ) = @_;

			my $uid         = $opt{uid} //= $self->current_user->{id};
			my $use_history = $self->account_use_history($uid);

			my ( $eva, $exclude_via, $exclude_train_id, $exclude_before );

			if ( $opt{eva} ) {
				if ( $use_history & 0x01 ) {
					$eva = $opt{eva};
				}
			}
			else {
				if ( $use_history & 0x02 ) {
					my $status = $self->get_user_status;
					$eva              = $status->{arr_eva};
					$exclude_via      = $status->{dep_name};
					$exclude_train_id = $status->{train_id};
					if ( $status->{real_arrival} ) {
						$exclude_before = $status->{real_arrival}->epoch;
					}
				}
			}

			if ( not $eva ) {
				return;
			}

			my @destinations = $self->get_connection_targets(%opt);

			if ($exclude_via) {
				@destinations = grep { $_ ne $exclude_via } @destinations;
			}

			if ( not @destinations ) {
				return;
			}

			my $stationboard = $self->get_departures( $eva, 0, 40, 1 );
			if ( $stationboard->{errstr} ) {
				return;
			}
			@{ $stationboard->{results} } = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map { [ $_, $_->departure ? $_->departure->epoch : 0 ] }
			  @{ $stationboard->{results} };
			my @results;
			my @cancellations;
			my %via_count = map { $_ => 0 } @destinations;
			for my $train ( @{ $stationboard->{results} } ) {
				if ( not $train->departure ) {
					next;
				}
				if (    $exclude_before
					and $train->departure
					and $train->departure->epoch < $exclude_before )
				{
					next;
				}
				if (    $exclude_train_id
					and $train->train_id eq $exclude_train_id )
				{
					next;
				}

             # In general, this function is meant to return feasible
             # connections. However, cancelled connections may also be of
             # interest and are also useful for logging cancellations.
             # To satisfy both demands with (hopefully) little confusion and
             # UI clutter, this function returns two concatenated arrays:
             # actual connections (ordered by actual departure time) followed
             # by cancelled connections (ordered by scheduled departure time).
             # This is easiest to achieve in two separate loops.
             #
             # Note that a cancelled train may still have a matching destination
             # in its route_post, e.g. if it leaves out $eva due to
             # unscheduled route changes but continues on schedule afterwards
             # -- so it is only cancelled at $eva, not on the remainder of
             # the route. Also note that this specific case is not yet handled
             # properly by the cancellation logic etc.

				if ( $train->departure_is_cancelled ) {
					my @via
					  = ( $train->sched_route_post, $train->sched_route_end );
					for my $dest (@destinations) {
						if ( List::Util::any { $_ eq $dest } @via ) {
							push( @cancellations, [ $train, $dest ] );
							next;
						}
					}
				}
				else {
					my @via = ( $train->route_post, $train->route_end );
					for my $dest (@destinations) {
						if ( $via_count{$dest} < 2
							and List::Util::any { $_ eq $dest } @via )
						{
							push( @results, [ $train, $dest ] );
							$via_count{$dest}++;
							next;
						}
					}
				}
			}

			@results = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map {
				[
					$_,
					$_->[0]->departure->epoch // $_->[0]->sched_departure->epoch
				]
			  } @results;
			@cancellations = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map { [ $_, $_->[0]->sched_departure->epoch ] } @cancellations;

			return ( @results, @cancellations );
		}
	);

	$self->helper(
		'account_use_history' => sub {
			my ( $self, $uid, $value ) = @_;

			if ($value) {
				$self->pg->db->update(
					'users',
					{ use_history => $value },
					{ id          => $uid }
				);
			}
			else {
				return $self->pg->db->select( 'users', ['use_history'],
					{ id => $uid } )->hash->{use_history};
			}
		}
	);

	$self->helper(
		'get_user_travels' => sub {
			my ( $self, %opt ) = @_;

			my $uid = $opt{uid} || $self->current_user->{id};

			# If get_user_travels is called from inside a transaction, db
			# specifies the database handle performing the transaction.
			# Otherwise, we grab a fresh one.
			my $db = $opt{db} // $self->pg->db;

			my @select
			  = (
				qw(journey_id train_type train_line train_no checkin_ts sched_dep_ts real_dep_ts dep_eva checkout_ts sched_arr_ts real_arr_ts arr_eva edited route messages user_data)
			  );
			my %where = (
				user_id   => $uid,
				cancelled => 0
			);
			my %order = (
				order_by => {
					-desc => 'real_dep_ts',
				}
			);

			if ( $opt{cancelled} ) {
				$where{cancelled} = 1;
			}

			if ( $opt{limit} ) {
				$order{limit} = $opt{limit};
			}

			if ( $opt{journey_id} ) {
				$where{journey_id} = $opt{journey_id};
				delete $where{cancelled};
			}
			elsif ( $opt{after} and $opt{before} ) {
				$where{real_dep_ts} = {
					-between => [ $opt{after}->epoch, $opt{before}->epoch, ] };
			}

			if ( $opt{with_polyline} ) {
				push( @select, 'polyline' );
			}

			my @travels;

			my $res = $db->select( 'journeys_str', \@select, \%where, \%order );

			for my $entry ( $res->expand->hashes->each ) {

				my $ref = {
					id           => $entry->{journey_id},
					type         => $entry->{train_type},
					line         => $entry->{train_line},
					no           => $entry->{train_no},
					from_eva     => $entry->{dep_eva},
					checkin_ts   => $entry->{checkin_ts},
					sched_dep_ts => $entry->{sched_dep_ts},
					rt_dep_ts    => $entry->{real_dep_ts},
					to_eva       => $entry->{arr_eva},
					checkout_ts  => $entry->{checkout_ts},
					sched_arr_ts => $entry->{sched_arr_ts},
					rt_arr_ts    => $entry->{real_arr_ts},
					messages     => $entry->{messages},
					route        => $entry->{route},
					edited       => $entry->{edited},
					user_data    => $entry->{user_data},
				};

				if ( $opt{with_polyline} ) {
					$ref->{polyline} = $entry->{polyline};
				}

				if ( my $station
					= $self->app->station_by_eva->{ $ref->{from_eva} } )
				{
					$ref->{from_ds100} = $station->[0];
					$ref->{from_name}  = $station->[1];
				}
				if ( my $station
					= $self->app->station_by_eva->{ $ref->{to_eva} } )
				{
					$ref->{to_ds100} = $station->[0];
					$ref->{to_name}  = $station->[1];
				}

				if ( $opt{with_datetime} ) {
					$ref->{checkin} = epoch_to_dt( $ref->{checkin_ts} );
					$ref->{sched_departure}
					  = epoch_to_dt( $ref->{sched_dep_ts} );
					$ref->{rt_departure}  = epoch_to_dt( $ref->{rt_dep_ts} );
					$ref->{checkout}      = epoch_to_dt( $ref->{checkout_ts} );
					$ref->{sched_arrival} = epoch_to_dt( $ref->{sched_arr_ts} );
					$ref->{rt_arrival}    = epoch_to_dt( $ref->{rt_arr_ts} );
				}

				if ( $opt{verbose} ) {
					my $rename = $self->app->renamed_station;
					for my $stop ( @{ $ref->{route} } ) {
						if ( $rename->{ $stop->[0] } ) {
							$stop->[0] = $rename->{ $stop->[0] };
						}
					}
					$ref->{cancelled} = $entry->{cancelled};
					my @parsed_messages;
					for my $message ( @{ $ref->{messages} // [] } ) {
						my ( $ts, $msg ) = @{$message};
						push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
					}
					$ref->{messages} = [ reverse @parsed_messages ];
					$ref->{sched_duration}
					  = defined $ref->{sched_arr_ts}
					  ? $ref->{sched_arr_ts} - $ref->{sched_dep_ts}
					  : undef;
					$ref->{rt_duration}
					  = defined $ref->{rt_arr_ts}
					  ? $ref->{rt_arr_ts} - $ref->{rt_dep_ts}
					  : undef;
					my ( $km_route, $km_beeline, $skip )
					  = $self->get_travel_distance( $ref->{from_name},
						$ref->{to_name}, $ref->{route} );
					$ref->{km_route}     = $km_route;
					$ref->{skip_route}   = $skip;
					$ref->{km_beeline}   = $km_beeline;
					$ref->{skip_beeline} = $skip;
					my $kmh_divisor
					  = ( $ref->{rt_duration} // $ref->{sched_duration}
						  // 999999 ) / 3600;
					$ref->{kmh_route}
					  = $kmh_divisor ? $ref->{km_route} / $kmh_divisor : -1;
					$ref->{kmh_beeline}
					  = $kmh_divisor
					  ? $ref->{km_beeline} / $kmh_divisor
					  : -1;
				}

				push( @travels, $ref );
			}

			return @travels;
		}
	);

	$self->helper(
		'get_journey' => sub {
			my ( $self, %opt ) = @_;

			$opt{cancelled} = 'any';
			my @journeys = $self->get_user_travels(%opt);
			if ( @journeys == 0 ) {
				return undef;
			}

			return $journeys[0];
		}
	);

	$self->helper(
		'stationinfo_to_direction' => sub {
			my ( $self, $platform_info, $wagonorder, $prev_stop, $next_stop )
			  = @_;
			if ( $platform_info->{kopfgleis} ) {
				if ($next_stop) {
					return $platform_info->{direction} eq 'r' ? 'l' : 'r';
				}
				return $platform_info->{direction};
			}
			elsif ( $prev_stop
				and exists $platform_info->{direction_from}{$prev_stop} )
			{
				return $platform_info->{direction_from}{$prev_stop};
			}
			elsif ( $next_stop
				and exists $platform_info->{direction_from}{$next_stop} )
			{
				return $platform_info->{direction_from}{$next_stop} eq 'r'
				  ? 'l'
				  : 'r';
			}
			elsif ($wagonorder) {
				my $wr;
				eval {
					$wr
					  = Travel::Status::DE::DBWagenreihung->new(
						from_json => $wagonorder );
				};
				if (    $wr
					and $wr->sections
					and defined $wr->direction )
				{
					my $section_0 = ( $wr->sections )[0];
					my $direction = $wr->direction;
					if (    $section_0->name eq 'A'
						and $direction == 0 )
					{
						return $platform_info->{direction};
					}
					elsif ( $section_0->name ne 'A'
						and $direction == 100 )
					{
						return $platform_info->{direction};
					}
					elsif ( $platform_info->{direction} ) {
						return $platform_info->{direction} eq 'r'
						  ? 'l'
						  : 'r';
					}
					return;
				}
			}
		}
	);

	$self->helper(
		'journey_to_ajax_route' => sub {
			my ( $self, $journey ) = @_;

			my @route;

			for my $station ( @{ $journey->{route_after} } ) {
				my $station_desc = $station->[0];
				if ( $station->[1]{rt_arr} ) {
					$station_desc .= $station->[1]{sched_arr}->strftime(';%s');
					$station_desc .= $station->[1]{rt_arr}->strftime(';%s');
					if ( $station->[1]{rt_dep} ) {
						$station_desc
						  .= $station->[1]{sched_dep}->strftime(';%s');
						$station_desc .= $station->[1]{rt_dep}->strftime(';%s');
					}
					else {
						$station_desc .= ';0;0';
					}
				}
				else {
					$station_desc .= ';0;0;0;0';
				}
				push( @route, $station_desc );
			}

			return join( '|', @route );
		}
	);

	$self->helper(
		'get_user_status' => sub {
			my ( $self, $uid ) = @_;

			$uid //= $self->current_user->{id};

			my $db    = $self->pg->db;
			my $now   = DateTime->now( time_zone => 'Europe/Berlin' );
			my $epoch = $now->epoch;

			my $in_transit
			  = $db->select( 'in_transit_str', '*', { user_id => $uid } )
			  ->expand->hash;

			if ($in_transit) {

				if ( my $station
					= $self->app->station_by_eva->{ $in_transit->{dep_eva} } )
				{
					$in_transit->{dep_ds100} = $station->[0];
					$in_transit->{dep_name}  = $station->[1];
				}
				if ( $in_transit->{arr_eva}
					and my $station
					= $self->app->station_by_eva->{ $in_transit->{arr_eva} } )
				{
					$in_transit->{arr_ds100} = $station->[0];
					$in_transit->{arr_name}  = $station->[1];
				}

				my @route = @{ $in_transit->{route} // [] };
				my @route_after;
				my $dep_info;
				my $stop_before_dest;
				my $is_after = 0;
				for my $station (@route) {

					if (    $in_transit->{arr_name}
						and @route_after
						and $station->[0] eq $in_transit->{arr_name} )
					{
						$stop_before_dest = $route_after[-1][0];
					}
					if ($is_after) {
						push( @route_after, $station );
					}
					if (    $in_transit->{dep_name}
						and $station->[0] eq $in_transit->{dep_name} )
					{
						$is_after = 1;
						if ( @{$station} > 1 ) {
							$dep_info = $station->[1];
						}
					}
				}
				my $stop_after_dep = @route_after ? $route_after[0][0] : undef;

				my $ts = $in_transit->{checkout_ts}
				  // $in_transit->{checkin_ts};
				my $action_time = epoch_to_dt($ts);

				my $ret = {
					checked_in         => !$in_transit->{cancelled},
					cancelled          => $in_transit->{cancelled},
					timestamp          => $action_time,
					timestamp_delta    => $now->epoch - $action_time->epoch,
					train_type         => $in_transit->{train_type},
					train_line         => $in_transit->{train_line},
					train_no           => $in_transit->{train_no},
					train_id           => $in_transit->{train_id},
					boarding_countdown => -1,
					sched_departure =>
					  epoch_to_dt( $in_transit->{sched_dep_ts} ),
					real_departure => epoch_to_dt( $in_transit->{real_dep_ts} ),
					dep_ds100      => $in_transit->{dep_ds100},
					dep_eva        => $in_transit->{dep_eva},
					dep_name       => $in_transit->{dep_name},
					dep_platform   => $in_transit->{dep_platform},
					sched_arrival => epoch_to_dt( $in_transit->{sched_arr_ts} ),
					real_arrival  => epoch_to_dt( $in_transit->{real_arr_ts} ),
					arr_ds100     => $in_transit->{arr_ds100},
					arr_eva       => $in_transit->{arr_eva},
					arr_name      => $in_transit->{arr_name},
					arr_platform  => $in_transit->{arr_platform},
					route_after   => \@route_after,
					messages      => $in_transit->{messages},
					extra_data    => $in_transit->{data},
					comment       => $in_transit->{user_data}{comment},
				};

				my @parsed_messages;
				for my $message ( @{ $ret->{messages} // [] } ) {
					my ( $ts, $msg ) = @{$message};
					push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
				}
				$ret->{messages} = [ reverse @parsed_messages ];

				@parsed_messages = ();
				for my $message ( @{ $ret->{extra_data}{qos_msg} // [] } ) {
					my ( $ts, $msg ) = @{$message};
					push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
				}
				$ret->{extra_data}{qos_msg} = [@parsed_messages];

				if ( $dep_info and $dep_info->{sched_arr} ) {
					$dep_info->{sched_arr}
					  = epoch_to_dt( $dep_info->{sched_arr} );
					$dep_info->{rt_arr} = $dep_info->{sched_arr}->clone;
					if (    $dep_info->{adelay}
						and $dep_info->{adelay} =~ m{^\d+$} )
					{
						$dep_info->{rt_arr}
						  ->add( minutes => $dep_info->{adelay} );
					}
					$dep_info->{rt_arr_countdown} = $ret->{boarding_countdown}
					  = $dep_info->{rt_arr}->epoch - $epoch;
				}

				for my $station (@route_after) {
					if ( @{$station} > 1 ) {

						# Note: $station->[1]{sched_arr} may already have been
						# converted to a DateTime object in $station->[1] is
						# $dep_info. This can happen when a station is present
						# several times in a train's route, e.g. for Frankfurt
						# Flughafen in some nightly connections.
						my $times = $station->[1];
						if ( $times->{sched_arr}
							and ref( $times->{sched_arr} ) ne 'DateTime' )
						{
							$times->{sched_arr}
							  = epoch_to_dt( $times->{sched_arr} );
							$times->{rt_arr} = $times->{sched_arr}->clone;
							if (    $times->{adelay}
								and $times->{adelay} =~ m{^\d+$} )
							{
								$times->{rt_arr}
								  ->add( minutes => $times->{adelay} );
							}
							$times->{rt_arr_countdown}
							  = $times->{rt_arr}->epoch - $epoch;
						}
						if ( $times->{sched_dep}
							and ref( $times->{sched_dep} ) ne 'DateTime' )
						{
							$times->{sched_dep}
							  = epoch_to_dt( $times->{sched_dep} );
							$times->{rt_dep} = $times->{sched_dep}->clone;
							if (    $times->{ddelay}
								and $times->{ddelay} =~ m{^\d+$} )
							{
								$times->{rt_dep}
								  ->add( minutes => $times->{ddelay} );
							}
							$times->{rt_dep_countdown}
							  = $times->{rt_dep}->epoch - $epoch;
						}
					}
				}

				$ret->{departure_countdown}
				  = $ret->{real_departure}->epoch - $now->epoch;

				if (    $ret->{departure_countdown} > 0
					and $in_transit->{data}{wagonorder_dep} )
				{
					my $wr;
					eval {
						$wr
						  = Travel::Status::DE::DBWagenreihung->new(
							from_json => $in_transit->{data}{wagonorder_dep} );
					};
					if (    $wr
						and $wr->sections
						and $wr->wagons
						and defined $wr->direction )
					{
						$ret->{wagonorder} = $wr;
					}
				}

				if ( $in_transit->{real_arr_ts} ) {
					$ret->{arrival_countdown}
					  = $ret->{real_arrival}->epoch - $now->epoch;
					$ret->{journey_duration}
					  = $ret->{real_arrival}->epoch
					  - $ret->{real_departure}->epoch;
					$ret->{journey_completion}
					  = $ret->{journey_duration}
					  ? 1
					  - ( $ret->{arrival_countdown} / $ret->{journey_duration} )
					  : 1;
					if ( $ret->{journey_completion} > 1 ) {
						$ret->{journey_completion} = 1;
					}
					elsif ( $ret->{journey_completion} < 0 ) {
						$ret->{journey_completion} = 0;
					}

					my ($dep_platform_number)
					  = ( ( $ret->{dep_platform} // 0 ) =~ m{(\d+)} );
					if ( $dep_platform_number
						and exists $in_transit->{data}{stationinfo_dep}
						{$dep_platform_number} )
					{
						$ret->{dep_direction}
						  = $self->stationinfo_to_direction(
							$in_transit->{data}{stationinfo_dep}
							  {$dep_platform_number},
							$in_transit->{data}{wagonorder_dep},
							undef,
							$stop_after_dep
						  );
					}

					my ($arr_platform_number)
					  = ( ( $ret->{arr_platform} // 0 ) =~ m{(\d+)} );
					if ( $arr_platform_number
						and exists $in_transit->{data}{stationinfo_arr}
						{$arr_platform_number} )
					{
						$ret->{arr_direction}
						  = $self->stationinfo_to_direction(
							$in_transit->{data}{stationinfo_arr}
							  {$arr_platform_number},
							$in_transit->{data}{wagonorder_arr},
							$stop_before_dest,
							undef
						  );
					}

				}
				else {
					$ret->{arrival_countdown}  = undef;
					$ret->{journey_duration}   = undef;
					$ret->{journey_completion} = undef;
				}

				return $ret;
			}

			my $latest = $db->select(
				'journeys_str',
				'*',
				{
					user_id   => $uid,
					cancelled => 0
				},
				{
					order_by => { -desc => 'journey_id' },
					limit    => 1
				}
			)->expand->hash;

			if ($latest) {
				my $ts          = $latest->{checkout_ts};
				my $action_time = epoch_to_dt($ts);
				if ( my $station
					= $self->app->station_by_eva->{ $latest->{dep_eva} } )
				{
					$latest->{dep_ds100} = $station->[0];
					$latest->{dep_name}  = $station->[1];
				}
				if ( my $station
					= $self->app->station_by_eva->{ $latest->{arr_eva} } )
				{
					$latest->{arr_ds100} = $station->[0];
					$latest->{arr_name}  = $station->[1];
				}
				return {
					checked_in      => 0,
					cancelled       => 0,
					journey_id      => $latest->{journey_id},
					timestamp       => $action_time,
					timestamp_delta => $now->epoch - $action_time->epoch,
					train_type      => $latest->{train_type},
					train_line      => $latest->{train_line},
					train_no        => $latest->{train_no},
					train_id        => $latest->{train_id},
					sched_departure => epoch_to_dt( $latest->{sched_dep_ts} ),
					real_departure  => epoch_to_dt( $latest->{real_dep_ts} ),
					dep_ds100       => $latest->{dep_ds100},
					dep_eva         => $latest->{dep_eva},
					dep_name        => $latest->{dep_name},
					dep_platform    => $latest->{dep_platform},
					sched_arrival   => epoch_to_dt( $latest->{sched_arr_ts} ),
					real_arrival    => epoch_to_dt( $latest->{real_arr_ts} ),
					arr_ds100       => $latest->{arr_ds100},
					arr_eva         => $latest->{arr_eva},
					arr_name        => $latest->{arr_name},
					arr_platform    => $latest->{arr_platform},
					comment         => $latest->{user_data}{comment},
				};
			}

			return {
				checked_in      => 0,
				cancelled       => 0,
				no_journeys_yet => 1,
				timestamp       => epoch_to_dt(0),
				timestamp_delta => $now->epoch,
			};
		}
	);

	$self->helper(
		'get_user_status_json_v1' => sub {
			my ( $self, $uid ) = @_;
			my $status = $self->get_user_status($uid);

			# TODO simplify lon/lat (can be returned from get_user_status)

			my $ret = {
				deprecated => \0,
				checkedIn  => (
					     $status->{checked_in}
					  or $status->{cancelled}
				) ? \1 : \0,
				fromStation => {
					ds100         => $status->{dep_ds100},
					name          => $status->{dep_name},
					uic           => $status->{dep_eva},
					longitude     => undef,
					latitude      => undef,
					scheduledTime => $status->{sched_departure}
					? $status->{sched_departure}->epoch
					: undef,
					realTime => $status->{real_departure}
					? $status->{real_departure}->epoch
					: undef,
				},
				toStation => {
					ds100         => $status->{arr_ds100},
					name          => $status->{arr_name},
					uic           => $status->{arr_eva},
					longitude     => undef,
					latitude      => undef,
					scheduledTime => $status->{sched_arrival}
					? $status->{sched_arrival}->epoch
					: undef,
					realTime => $status->{real_arrival}
					? $status->{real_arrival}->epoch
					: undef,
				},
				train => {
					type => $status->{train_type},
					line => $status->{train_line},
					no   => $status->{train_no},
					id   => $status->{train_id},
				},
				actionTime => $status->{timestamp}
				? $status->{timestamp}->epoch
				: undef,
				intermediateStops => [],
			};

			for my $stop ( @{ $status->{route_after} // [] } ) {
				if ( $status->{arr_name} and $stop->[0] eq $status->{arr_name} )
				{
					last;
				}
				push(
					@{ $ret->{intermediateStops} },
					{
						name             => $stop->[0],
						scheduledArrival => $stop->[1]{sched_arr}
						? $stop->[1]{sched_arr}->epoch
						: undef,
						realArrival => $stop->[1]{rt_arr}
						? $stop->[1]{rt_arr}->epoch
						: undef,
						scheduledDeparture => $stop->[1]{sched_dep}
						? $stop->[1]{sched_dep}->epoch
						: undef,
						realDeparture => $stop->[1]{rt_dep}
						? $stop->[1]{rt_dep}->epoch
						: undef,
					}
				);
			}

			if ( $status->{dep_eva} ) {
				my @station_descriptions
				  = Travel::Status::DE::IRIS::Stations::get_station(
					$status->{dep_eva} );
				if ( @station_descriptions == 1 ) {
					(
						undef, undef, undef,
						$ret->{fromStation}{longitude},
						$ret->{fromStation}{latitude}
					) = @{ $station_descriptions[0] };
				}
			}

			if ( $status->{arr_ds100} ) {
				my @station_descriptions
				  = Travel::Status::DE::IRIS::Stations::get_station(
					$status->{arr_ds100} );
				if ( @station_descriptions == 1 ) {
					(
						undef, undef, undef,
						$ret->{toStation}{longitude},
						$ret->{toStation}{latitude}
					) = @{ $station_descriptions[0] };
				}
			}

			return $ret;
		}
	);

	$self->helper(
		'get_travel_distance' => sub {
			my ( $self, $from, $to, $route_ref ) = @_;

			my $distance_intermediate = 0;
			my $distance_beeline      = 0;
			my $skipped               = 0;
			my $geo                   = Geo::Distance->new();
			my @stations              = map { $_->[0] } @{$route_ref};
			my @route                 = after_incl { $_ eq $from } @stations;
			@route = before_incl { $_ eq $to } @route;

			if ( @route < 2 ) {

				# I AM ERROR
				return ( 0, 0 );
			}

			my $prev_station = get_station( shift @route );
			if ( not $prev_station ) {
				return ( 0, 0 );
			}

           # Geo-coordinates for stations outside Germany are not available
           # at the moment. When calculating distance with intermediate stops,
           # these are simply left out (as if they were not part of the route).
           # For beeline distance calculation, we use the route's first and last
           # station with known geo-coordinates.
			my $from_station_beeline;
			my $to_station_beeline;

			for my $station_name (@route) {
				if ( my $station = get_station($station_name) ) {
					if ( not $from_station_beeline and $#{$prev_station} >= 4 )
					{
						$from_station_beeline = $prev_station;
					}
					if ( $#{$station} >= 4 ) {
						$to_station_beeline = $station;
					}
					if ( $#{$prev_station} >= 4 and $#{$station} >= 4 ) {
						$distance_intermediate
						  += $geo->distance( 'kilometer', $prev_station->[3],
							$prev_station->[4], $station->[3], $station->[4] );
					}
					else {
						$skipped++;
					}
					$prev_station = $station;
				}
			}

			if ( $from_station_beeline and $to_station_beeline ) {
				$distance_beeline = $geo->distance(
					'kilometer',                $from_station_beeline->[3],
					$from_station_beeline->[4], $to_station_beeline->[3],
					$to_station_beeline->[4]
				);
			}

			return ( $distance_intermediate, $distance_beeline, $skipped );
		}
	);

	$self->helper(
		'compute_journey_stats' => sub {
			my ( $self, @journeys ) = @_;
			my $km_route         = 0;
			my $km_beeline       = 0;
			my $min_travel_sched = 0;
			my $min_travel_real  = 0;
			my $delay_dep        = 0;
			my $delay_arr        = 0;
			my $interchange_real = 0;
			my $num_trains       = 0;
			my $num_journeys     = 0;
			my @inconsistencies;

			my $next_departure = 0;

			for my $journey (@journeys) {
				$num_trains++;
				$km_route   += $journey->{km_route};
				$km_beeline += $journey->{km_beeline};
				if (    $journey->{sched_duration}
					and $journey->{sched_duration} > 0 )
				{
					$min_travel_sched += $journey->{sched_duration} / 60;
				}
				if ( $journey->{rt_duration} and $journey->{rt_duration} > 0 ) {
					$min_travel_real += $journey->{rt_duration} / 60;
				}
				if ( $journey->{sched_dep_ts} and $journey->{rt_dep_ts} ) {
					$delay_dep
					  += ( $journey->{rt_dep_ts} - $journey->{sched_dep_ts} )
					  / 60;
				}
				if ( $journey->{sched_arr_ts} and $journey->{rt_arr_ts} ) {
					$delay_arr
					  += ( $journey->{rt_arr_ts} - $journey->{sched_arr_ts} )
					  / 60;
				}

				# Note that journeys are sorted from recent to older entries
				if (    $journey->{rt_arr_ts}
					and $next_departure
					and $next_departure - $journey->{rt_arr_ts} < ( 60 * 60 ) )
				{
					if ( $next_departure - $journey->{rt_arr_ts} < 0 ) {
						push( @inconsistencies,
							epoch_to_dt($next_departure)
							  ->strftime('%d.%m.%Y %H:%M') );
					}
					else {
						$interchange_real
						  += ( $next_departure - $journey->{rt_arr_ts} ) / 60;
					}
				}
				else {
					$num_journeys++;
				}
				$next_departure = $journey->{rt_dep_ts};
			}
			return {
				km_route             => $km_route,
				km_beeline           => $km_beeline,
				num_trains           => $num_trains,
				num_journeys         => $num_journeys,
				min_travel_sched     => $min_travel_sched,
				min_travel_real      => $min_travel_real,
				min_interchange_real => $interchange_real,
				delay_dep            => $delay_dep,
				delay_arr            => $delay_arr,
				inconsistencies      => \@inconsistencies,
			};
		}
	);

	$self->helper(
		'navbar_class' => sub {
			my ( $self, $path ) = @_;

			if ( $self->req->url eq $self->url_for($path) ) {
				return 'active';
			}
			return q{};
		}
	);

	my $r = $self->routes;

	$r->get('/')->to('traveling#homepage');
	$r->get('/about')->to('static#about');
	$r->get('/api')->to('api#documentation');
	$r->get('/changelog')->to('static#changelog');
	$r->get('/impressum')->to('static#imprint');
	$r->get('/imprint')->to('static#imprint');
	$r->get('/offline')->to('static#offline');
	$r->get('/api/v1/:user_action/:token')->to('api#get_v1');
	$r->get('/login')->to('account#login_form');
	$r->get('/recover')->to('account#request_password_reset');
	$r->get('/recover/:id/:token')->to('account#recover_password');
	$r->get('/register')->to('account#registration_form');
	$r->get('/reg/:id/:token')->to('account#verify');
	$r->get('/status/:name')->to('traveling#user_status');
	$r->get('/status/:name/:ts')->to('traveling#user_status');
	$r->get('/ajax/status/:name')->to('traveling#public_status_card');
	$r->get('/ajax/status/:name/:ts')->to('traveling#public_status_card');
	$r->post('/api/v1/import')->to('api#import_v1');
	$r->post('/api/v1/travel')->to('api#travel_v1');
	$r->post('/action')->to('traveling#log_action');
	$r->post('/geolocation')->to('traveling#geolocation');
	$r->post('/list_departures')->to('traveling#redirect_to_station');
	$r->post('/login')->to('account#do_login');
	$r->post('/register')->to('account#register');
	$r->post('/recover')->to('account#request_password_reset');

	my $authed_r = $r->under(
		sub {
			my ($self) = @_;
			if ( $self->is_user_authenticated ) {
				return 1;
			}
			$self->render( 'login', redirect_to => $self->req->url );
			return undef;
		}
	);

	$authed_r->get('/account')->to('account#account');
	$authed_r->get('/account/privacy')->to('account#privacy');
	$authed_r->get('/account/hooks')->to('account#webhook');
	$authed_r->get('/account/insight')->to('account#insight');
	$authed_r->get('/ajax/status_card.html')->to('traveling#status_card');
	$authed_r->get('/cancelled')->to('traveling#cancelled');
	$authed_r->get('/fgr')->to('passengerrights#list_candidates');
	$authed_r->get('/account/password')->to('account#password_form');
	$authed_r->get('/account/mail')->to('account#change_mail');
	$authed_r->get('/export.json')->to('account#json_export');
	$authed_r->get('/history.json')->to('traveling#json_history');
	$authed_r->get('/history')->to('traveling#history');
	$authed_r->get('/history/map')->to('traveling#map_history');
	$authed_r->get('/history/:year')->to('traveling#yearly_history');
	$authed_r->get('/history/:year/:month')->to('traveling#monthly_history');
	$authed_r->get('/journey/add')->to('traveling#add_journey_form');
	$authed_r->get('/journey/comment')->to('traveling#comment_form');
	$authed_r->get('/journey/:id')->to('traveling#journey_details');
	$authed_r->get('/s/*station')->to('traveling#station');
	$authed_r->get('/confirm_mail/:token')->to('account#confirm_mail');
	$authed_r->post('/account/privacy')->to('account#privacy');
	$authed_r->post('/account/hooks')->to('account#webhook');
	$authed_r->post('/account/insight')->to('account#insight');
	$authed_r->post('/journey/add')->to('traveling#add_journey_form');
	$authed_r->post('/journey/comment')->to('traveling#comment_form');
	$authed_r->post('/journey/edit')->to('traveling#edit_journey');
	$authed_r->post('/journey/passenger_rights/*filename')
	  ->to('passengerrights#generate');
	$authed_r->post('/account/password')->to('account#change_password');
	$authed_r->post('/account/mail')->to('account#change_mail');
	$authed_r->post('/delete')->to('account#delete');
	$authed_r->post('/logout')->to('account#do_logout');
	$authed_r->post('/set_token')->to('api#set_token');

}

1;
