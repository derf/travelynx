package Travelynx;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: MIT

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
use JSON;
use List::Util;
use List::UtilsBy qw(uniq_by);
use List::MoreUtils qw(first_index);
use Travel::Status::DE::DBWagenreihung;
use Travel::Status::DE::IRIS::Stations;
use Travelynx::Helper::DBDB;
use Travelynx::Helper::HAFAS;
use Travelynx::Helper::IRIS;
use Travelynx::Helper::Sendmail;
use Travelynx::Helper::Traewelling;
use Travelynx::Model::InTransit;
use Travelynx::Model::Journeys;
use Travelynx::Model::JourneyStatsCache;
use Travelynx::Model::Traewelling;
use Travelynx::Model::Users;
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
		time_zone => 'Europe/Berlin',
		locale    => 'de-DE',
	);
}

sub get_station {
	my ( $station_name, $exact_match ) = @_;

	my @candidates
	  = Travel::Status::DE::IRIS::Stations::get_station($station_name);

	if ( @candidates == 1 ) {
		if ( not $exact_match ) {
			return $candidates[0];
		}
		if (   $candidates[0][0] eq $station_name
			or $candidates[0][1] eq $station_name
			or $candidates[0][2] eq $station_name )
		{
			return $candidates[0];
		}
		return undef;
	}
	return undef;
}

sub startup {
	my ($self) = @_;

	push( @{ $self->commands->namespaces }, 'Travelynx::Command' );

	$self->defaults( layout => 'default' );

	$self->types->type( csv  => 'text/csv; charset=utf-8' );
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
				my $user_info
				  = $self->users->get_login_data( name => $username );
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
				history_intern => 0x10,
				history_latest => 0x20,
				history_full   => 0x40,
			};
		}
	);

	$self->attr(
		journey_edit_mask => sub {
			return {
				sched_departure => 0x0001,
				real_departure  => 0x0002,
				from_station    => 0x0004,
				route           => 0x0010,
				is_cancelled    => 0x0020,
				sched_arrival   => 0x0100,
				real_arrival    => 0x0200,
				to_station      => 0x0400,
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
		hafas => sub {
			my ($self) = @_;
			state $hafas = Travelynx::Helper::HAFAS->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->app->config->{version},
			);
		}
	);

	$self->helper(
		iris => sub {
			my ($self) = @_;
			state $iris = Travelynx::Helper::IRIS->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->url_for('/')->to_abs,
				version        => $self->app->config->{version},
			);
		}
	);

	$self->helper(
		traewelling => sub {
			my ($self) = @_;
			state $trwl = Travelynx::Model::Traewelling->new( pg => $self->pg );
		}
	);

	$self->helper(
		traewelling_api => sub {
			my ($self) = @_;
			state $trwl_api = Travelynx::Helper::Traewelling->new(
				log        => $self->app->log,
				model      => $self->traewelling,
				root_url   => $self->url_for('/')->to_abs,
				user_agent => $self->ua,
				version    => $self->app->config->{version},
			);
		}
	);

	$self->helper(
		in_transit => sub {
			my ($self) = @_;
			state $in_transit = Travelynx::Model::InTransit->new(
				log => $self->app->log,
				pg  => $self->pg,
			);
		}
	);

	$self->helper(
		journey_stats_cache => sub {
			my ($self) = @_;
			state $journey_stats_cache
			  = Travelynx::Model::JourneyStatsCache->new(
				log => $self->app->log,
				pg  => $self->pg,
			  );
		}
	);

	$self->helper(
		journeys => sub {
			my ($self) = @_;
			state $journeys = Travelynx::Model::Journeys->new(
				log             => $self->app->log,
				pg              => $self->pg,
				stats_cache     => $self->journey_stats_cache,
				renamed_station => $self->app->renamed_station,
				station_by_eva  => $self->app->station_by_eva,
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
		sendmail => sub {
			state $sendmail = Travelynx::Helper::Sendmail->new(
				config => ( $self->config->{mail} // {} ),
				log    => $self->log
			);
		}
	);

	$self->helper(
		users => sub {
			my ($self) = @_;
			state $users = Travelynx::Model::Users->new( pg => $self->pg );
		}
	);

	$self->helper(
		dbdb => sub {
			my ($self) = @_;
			state $dbdb = Travelynx::Helper::DBDB->new(
				log        => $self->app->log,
				cache      => $self->app->cache_iris_main,
				root_url   => $self->url_for('/')->to_abs,
				user_agent => $self->ua,
				version    => $self->app->config->{version},
			);
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

	$self->helper(
		'checkin' => sub {
			my ( $self, %opt ) = @_;

			my $station  = $opt{station};
			my $train_id = $opt{train_id};
			my $uid      = $opt{uid} // $self->current_user->{id};
			my $db       = $opt{db} // $self->pg->db;

			my $status = $self->iris->get_departures(
				station    => $station,
				lookbehind => 140,
				lookahead  => 40
			);
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

					my $user = $self->get_user_status( $uid, $db );
					if ( $user->{checked_in} or $user->{cancelled} ) {

						if (    $user->{train_id} eq $train_id
							and $user->{dep_eva} eq $status->{station_eva} )
						{
							# checking in twice is harmless
							return ( $train, undef );
						}

						# Otherwise, someone forgot to check out first
						$self->checkout(
							station => $station,
							force   => 1,
							uid     => $uid,
							db      => $db
						);
					}

					eval {
						$self->in_transit->add(
							uid           => $uid,
							db            => $db,
							departure_eva => $status->{station_eva},
							train         => $train,
							route => [ $self->iris->route_diff($train) ],
						);
					};
					if ($@) {
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						return ( undef, 'INSERT failed: ' . $@ );
					}
					if ( not $opt{in_transaction} ) {

						# mustn't be called during a transaction
						$self->add_route_timestamps( $uid, $train, 1 );
						$self->run_hook( $uid, 'checkin' );
					}
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
				eval { $self->in_transit->delete( uid => $uid ); };
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

				my $journey = $self->journeys->pop(
					uid        => $uid,
					db         => $db,
					journey_id => $journey_id
				);

				if ( $journey->{edited} ) {
					die(
"Cannot undo a journey which has already been edited. Please delete manually.\n"
					);
				}

				delete $journey->{edited};
				delete $journey->{id};

				$self->in_transit->add_from_journey(
					db      => $db,
					journey => $journey
				);

				my $cache_ts = DateTime->now( time_zone => 'Europe/Berlin' );
				if ( $journey->{real_departure}
					=~ m{ ^ (?<year> \d{4} ) - (?<month> \d{2} ) }x )
				{
					$cache_ts->set(
						year  => $+{year},
						month => $+{month}
					);
				}

				$self->journey_stats_cache->invalidate(
					ts  => $cache_ts,
					db  => $db,
					uid => $uid
				);

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

	$self->helper(
		'checkout' => sub {
			my ( $self, %opt ) = @_;

			my $station = $opt{station};
			my $force   = $opt{force};
			my $uid     = $opt{uid};
			my $db      = $opt{db} // $self->pg->db;
			my $status  = $self->iris->get_departures(
				station    => $station,
				lookbehind => 120,
				lookahead  => 120
			);
			$uid //= $self->current_user->{id};
			my $user     = $self->get_user_status( $uid, $db );
			my $train_id = $user->{train_id};

			if ( not $user->{checked_in} and not $user->{cancelled} ) {
				return ( 0, 'You are not checked into any train' );
			}
			if ( $status->{errstr} and not $force ) {
				return ( 1, $status->{errstr} );
			}

			my $now     = DateTime->now( time_zone => 'Europe/Berlin' );
			my $journey = $self->in_transit->get(
				uid       => $uid,
				with_data => 1
			);

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
				$status = $self->iris->get_departures(
					station      => $station,
					lookbehind   => 120,
					lookahead    => 180,
					with_related => 1
				);
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
			$self->in_transit->set_arrival_eva(
				uid         => $uid,
				db          => $db,
				arrival_eva => $new_checkout_station_id
			);

			# If in_transit already contains arrival data for another estimated
			# destination, we must invalidate it.
			if ( defined $journey->{checkout_station_id}
				and $journey->{checkout_station_id}
				!= $new_checkout_station_id )
			{
				$self->in_transit->unset_arrival_data(
					uid => $uid,
					db  => $db
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
						$self->in_transit->set_arrival_times(
							uid           => $uid,
							db            => $db,
							sched_arrival => $sched_arr,
							rt_arrival    => $rt_arr
						);
					}
				}
				if ( not $force ) {

					# mustn't be called during a transaction
					if ( not $opt{in_transaction} ) {
						$self->run_hook( $uid, 'update' );
					}
					return ( 1, undef );
				}
			}

			my $has_arrived = 0;

			eval {

				my $tx;
				if ( not $opt{in_transaction} ) {
					$tx = $db->begin;
				}

				if ( defined $train and not $train->arrival and not $force ) {
					my $train_no = $train->train_no;
					die("Train ${train_no} has no arrival timestamp\n");
				}
				elsif ( defined $train and $train->arrival ) {
					$self->in_transit->set_arrival(
						uid   => $uid,
						db    => $db,
						train => $train,
						route => [ $self->iris->route_diff($train) ]
					);

					$has_arrived = $train->arrival->epoch < $now->epoch ? 1 : 0;
					if ($has_arrived) {
						my @unknown_stations
						  = $self->grep_unknown_stations( $train->route );
						if (@unknown_stations) {
							$self->app->log->warn(
								sprintf(
'Route of %s %s (%s -> %s) contains unknown stations: %s',
									$train->type,
									$train->train_no,
									$train->origin,
									$train->destination,
									join( ', ', @unknown_stations )
								)
							);
						}
					}
				}

				$journey = $self->in_transit->get(
					uid => $uid,
					db  => $db
				);

				if ( $has_arrived or $force ) {
					$self->journeys->add_from_in_transit(
						db      => $db,
						journey => $journey
					);
					$self->in_transit->delete(
						uid => $uid,
						db  => $db
					);

					my $cache_ts = $now->clone;
					if ( $journey->{real_departure}
						=~ m{ ^ (?<year> \d{4} ) - (?<month> \d{2} ) }x )
					{
						$cache_ts->set(
							year  => $+{year},
							month => $+{month}
						);
					}
					$self->journey_stats_cache->invalidate(
						ts  => $cache_ts,
						db  => $db,
						uid => $uid
					);
				}
				elsif ( defined $train and $train->arrival_is_cancelled ) {

               # This branch is only taken if the deparure was not cancelled,
               # i.e., if the train was supposed to go here but got
               # redirected or cancelled on the way and not from the start on.
               # If the departure itself was cancelled, the user route is
               # cancelled_from action -> 'cancelled journey' panel on main page
               # -> cancelled_to action -> force checkout (causing the
               # previous branch to be taken due to $force)
					$journey->{cancelled} = 1;
					$self->journeys->add_from_in_transit(
						db      => $db,
						journey => $journey
					);
					$self->in_transit->set_cancelled_destination(
						uid                   => $uid,
						db                    => $db,
						cancelled_destination => $train->station,
					);
				}

				if ( not $opt{in_transaction} ) {
					$tx->commit;
				}
			};

			if ($@) {
				$self->app->log->error("Checkout($uid): $@");
				return ( 1, 'Checkout error: ' . $@ );
			}

			if ( $has_arrived or $force ) {
				if ( not $opt{in_transaction} ) {
					$self->run_hook( $uid, 'checkout' );
				}
				return ( 0, undef );
			}
			if ( not $opt{in_transaction} ) {
				$self->run_hook( $uid, 'update' );
				$self->add_route_timestamps( $uid, $train, 0 );
			}
			return ( 1, undef );
		}
	);

	# This helper should only be called directly when also providing a user ID.
	# If you don't have one, use current_user() instead (get_user_data will
	# delegate to it anyways).
	$self->helper(
		'get_user_data' => sub {
			my ( $self, $uid ) = @_;

			$uid //= $self->current_user->{id};

			return $self->users->get_data( uid => $uid );
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
					return;
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->mark_hook_status( $uid, $hook->{url}, 0, $err );
					if ($callback) {
						&$callback();
					}
					return;
				}
			)->wait;
		}
	);

	$self->helper(
		'add_route_timestamps' => sub {
			my ( $self, $uid, $train, $is_departure ) = @_;

			$uid //= $self->current_user->{id};

			my $db = $self->pg->db;

# TODO "with_timestamps" is misleading, there are more differences between in_transit and in_transit_str
# Here it's only needed because of dep_eva / arr_eva names
			my $journey = $self->in_transit->get(
				db              => $db,
				uid             => $uid,
				with_data       => 1,
				with_timestamps => 1
			);

			if ( not $journey ) {
				return;
			}

			if ( $journey->{data}{trip_id}
				and not $journey->{polyline} )
			{
				my ( $origin_eva, $destination_eva, $polyline_str );
				$self->hafas->get_polyline_p( $train,
					$journey->{data}{trip_id} )->then(
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

						my $pl_res = $db->select(
							'polylines',
							['id'],
							{
								origin_eva      => $origin_eva,
								destination_eva => $destination_eva,
								polyline        => $polyline_str
							},
							{ limit => 1 }
						);

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
							$self->in_transit->set_polyline_id(
								uid         => $uid,
								db          => $db,
								polyline_id => $polyline_id
							);
						}
						return;
					}
				)->catch(
					sub {
						my ($err) = @_;
						if ( $err =~ m{extra content at the end}i ) {
							$self->app->log->debug(
								"add_route_timestamps: $err");
						}
						else {
							$self->app->log->warn("add_route_timestamps: $err");
						}
						return;
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

			$self->hafas->get_json_p(
				"${base}&date=${date_yy}&trainname=${train_no}")->then(
				sub {
					my ($trainsearch) = @_;

					# Fallback: Take first result
					my $result = $trainsearch->{suggestions}[0];
					$trainlink = $result->{trainLink};

					# Try finding a result for the current date
					for
					  my $suggestion ( @{ $trainsearch->{suggestions} // [] } )
					{

       # Drunken API, sail with care. Both date formats are used interchangeably
						if (
							$suggestion->{depDate}
							and (  $suggestion->{depDate} eq $date_yy
								or $suggestion->{depDate} eq $date_yyyy )
						  )
						{
            # Train numbers are not unique, e.g. IC 149 refers both to the
            # InterCity service Amsterdam -> Berlin and to the InterCity service
            # Koebenhavns Lufthavn st -> Aarhus.  One workaround is making
            # requests with the stationFilter=80 parameter.  Checking the origin
            # station seems to be the more generic solution, so we do that
            # instead.
							if ( $suggestion->{dep} eq $train->origin ) {
								$result    = $suggestion;
								$trainlink = $suggestion->{trainLink};
								last;
							}
						}
					}

					if ( not $trainlink ) {
						$self->app->log->debug("trainlink not found");
						return Mojo::Promise->reject("trainlink not found");
					}

                 # Calculate and store trip_id.
                 # The trip_id's date part doesn't seem to matter -- so far,
                 # HAFAS is happy as long as the date part starts with a number.
                 # HAFAS-internal tripIDs use this format (withouth leading zero
                 # for day of month < 10) though, so let's stick with it.
					my $date_map = $date_yyyy;
					$date_map =~ tr{.}{}d;
					my $trip_id = sprintf( '1|%d|%d|%d|%s',
						$result->{id},   $result->{cycle},
						$result->{pool}, $date_map );

					$self->in_transit->update_data(
						uid  => $uid,
						db   => $db,
						data => { trip_id => $trip_id }
					);

					my $base2
					  = 'https://reiseauskunft.bahn.de/bin/traininfo.exe/dn';
					return $self->hafas->get_json_p(
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
					return $self->hafas->get_xml_p(
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

					$self->in_transit->set_route_data(
						uid            => $uid,
						db             => $db,
						route          => $route,
						delay_messages => [
							map { [ $_->[0]->epoch, $_->[1] ] }
							  $train->delay_messages
						],
						qos_messages => [
							map { [ $_->[0]->epoch, $_->[1] ] }
							  $train->qos_messages
						],
						him_messages => $traininfo2->{messages},
					);
					return;
				}
			)->catch(
				sub {
					my ($err) = @_;
					if ( $err eq 'trainlink not found' ) {
						$self->app->log->debug("add_route_timestamps: $err");
					}
					else {
						$self->app->log->warn("add_route_timestamps: $err");
					}
					return;
				}
			)->wait;

			if ( $train->sched_departure ) {
				$self->dbdb->has_wagonorder_p( $train->sched_departure,
					$train->train_no )->then(
					sub {
						return $self->dbdb->get_wagonorder_p(
							$train->sched_departure, $train->train_no );
					}
				)->then(
					sub {
						my ($wagonorder) = @_;

						my $data      = {};
						my $user_data = {};

						if ( $is_departure and not exists $wagonorder->{error} )
						{
							$data->{wagonorder_dep}   = $wagonorder;
							$user_data->{wagongroups} = [];
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
							$self->in_transit->update_data(
								uid  => $uid,
								db   => $db,
								data => $data
							);
							$self->in_transit->update_user_data(
								uid       => $uid,
								db        => $db,
								user_data => $user_data
							);
						}
						elsif ( not $is_departure
							and not exists $wagonorder->{error} )
						{
							$data->{wagonorder_arr} = $wagonorder;
							$self->in_transit->update_data(
								uid  => $uid,
								db   => $db,
								data => $data
							);
						}
						return;
					}
				)->catch(
					sub {
						# no wagonorder? no problem.
						return;
					}
				)->wait;
			}

			if ($is_departure) {
				$self->dbdb->get_stationinfo_p( $journey->{dep_eva} )->then(
					sub {
						my ($station_info) = @_;
						my $data = { stationinfo_dep => $station_info };

						$self->in_transit->update_data(
							uid  => $uid,
							db   => $db,
							data => $data
						);
						return;
					}
				)->catch(
					sub {
						# no stationinfo? no problem.
						return;
					}
				)->wait;
			}

			if ( $journey->{arr_eva} and not $is_departure ) {
				$self->dbdb->get_stationinfo_p( $journey->{arr_eva} )->then(
					sub {
						my ($station_info) = @_;
						my $data = { stationinfo_arr => $station_info };

						$self->in_transit->update_data(
							uid  => $uid,
							db   => $db,
							data => $data
						);
						return;
					}
				)->catch(
					sub {
						# no stationinfo? no problem.
						return;
					}
				)->wait;
			}
		}
	);

	$self->helper(
		'get_latest_dest_id' => sub {
			my ( $self, %opt ) = @_;

			my $uid = $opt{uid} // $self->current_user->{id};
			my $db  = $opt{db}  // $self->pg->db;

			if (
				my $id = $self->in_transit->get_checkout_station_id(
					uid => $uid,
					db  => $db
				)
			  )
			{
				return $id;
			}

			return $self->journeys->get_latest_checkout_station_id(
				uid => $uid,
				db  => $db
			);
		}
	);

	$self->helper(
		'get_connection_targets' => sub {
			my ( $self, %opt ) = @_;

			my $uid = $opt{uid} //= $self->current_user->{id};
			my $threshold = $opt{threshold}
			  // DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( months => 4 );
			my $db        = $opt{db} //= $self->pg->db;
			my $min_count = $opt{min_count} // 3;

			if ( $opt{destination_name} ) {
				return ( $opt{destination_name} );
			}

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
			  ->map( sub { shift->{dest} } )->each;
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
			my $use_history = $self->users->use_history( uid => $uid );

			my ( $eva, $exclude_via, $exclude_train_id, $exclude_before );
			my $now = $self->now->epoch;
			my ( $stationinfo, $arr_epoch, $arr_platform );

			if ( $opt{eva} ) {
				if ( $use_history & 0x01 ) {
					$eva = $opt{eva};
				}
				elsif ( $opt{destination_name} ) {
					$eva = $opt{eva};
				}
			}
			else {
				if ( $use_history & 0x02 ) {
					my $status = $self->get_user_status;
					$eva              = $status->{arr_eva};
					$exclude_via      = $status->{dep_name};
					$exclude_train_id = $status->{train_id};
					$arr_platform     = $status->{arr_platform};
					$stationinfo      = $status->{extra_data}{stationinfo_arr};
					if ( $status->{real_arrival} ) {
						$exclude_before = $arr_epoch
						  = $status->{real_arrival}->epoch;
					}
				}
			}

			$exclude_before //= $now - 300;

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

			my $stationboard = $self->iris->get_departures(
				station      => $eva,
				lookbehind   => 10,
				lookahead    => 40,
				with_related => 1
			);
			if ( $stationboard->{errstr} ) {
				return;
			}
			@{ $stationboard->{results} } = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map  { [ $_, $_->departure ? $_->departure->epoch : 0 ] }
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

                 # Show all past and up to two future departures per destination
							if ( not $train->departure
								or $train->departure->epoch >= $now )
							{
								$via_count{$dest}++;
							}
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

			for my $result (@results) {
				my $train = $result->[0];
				my @message_ids
				  = List::Util::uniq map { $_->[1] } $train->raw_messages;
				$train->{message_id} = { map { $_ => 1 } @message_ids };
				my $interchange_duration;
				if ( exists $stationinfo->{i} ) {
					$interchange_duration
					  = $stationinfo->{i}{$arr_platform}{ $train->platform };
					$interchange_duration //= $stationinfo->{i}{"*"};
				}
				if ( defined $interchange_duration ) {
					my $interchange_time
					  = ( $train->departure->epoch - $arr_epoch ) / 60;
					if ( $interchange_time < $interchange_duration ) {
						$train->{interchange_text} = 'Anschluss knapp';
						$train->{interchange_icon} = 'warning';
					}
					elsif ( $interchange_time == $interchange_duration ) {
						$train->{interchange_text}
						  = 'Anschluss könnte knapp werden';
						$train->{interchange_icon} = 'directions_run';
					}

       #else {
       #	$train->{interchange_text} = 'Anschluss wird voraussichtlich erreicht';
       #	$train->{interchange_icon} = 'check';
       #}
				}
			}

			return ( @results, @cancellations );
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
			my ( $self, $uid, $db ) = @_;

			$uid //= $self->current_user->{id};
			$db  //= $self->pg->db;

			my $now   = DateTime->now( time_zone => 'Europe/Berlin' );
			my $epoch = $now->epoch;

			my $in_transit = $self->in_transit->get(
				uid             => $uid,
				db              => $db,
				with_data       => 1,
				with_timestamps => 1
			);

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

			my ( $latest, $latest_cancellation ) = $self->journeys->get_latest(
				uid => $uid,
				db  => $db
			);

			if ( $latest_cancellation and $latest_cancellation->{cancelled} ) {
				if ( my $station
					= $self->app->station_by_eva
					->{ $latest_cancellation->{dep_eva} } )
				{
					$latest_cancellation->{dep_ds100} = $station->[0];
					$latest_cancellation->{dep_name}  = $station->[1];
				}
				if ( my $station
					= $self->app->station_by_eva
					->{ $latest_cancellation->{arr_eva} } )
				{
					$latest_cancellation->{arr_ds100} = $station->[0];
					$latest_cancellation->{arr_name}  = $station->[1];
				}
			}
			else {
				$latest_cancellation = undef;
			}

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
					cancellation    => $latest_cancellation,
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
				cancellation    => $latest_cancellation,
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
		'traewelling_to_travelynx' => sub {
			my ( $self, %opt ) = @_;
			my $traewelling = $opt{traewelling};
			my $user_data   = $opt{user_data};
			my $uid         = $user_data->{user_id};

			if ( not $traewelling->{checkin}
				or $self->now->epoch - $traewelling->{checkin}->epoch > 900 )
			{
				$self->log->debug("... not checked in");
				return;
			}
			if (    $traewelling->{status_id}
				and $user_data->{data}{latest_pull_status_id}
				and $traewelling->{status_id}
				== $user_data->{data}{latest_pull_status_id} )
			{
				$self->log->debug("... already handled");
				return;
			}
			$self->log->debug("... checked in");
			my $user_status = $self->get_user_status($uid);
			if ( $user_status->{checked_in} ) {
				$self->log->debug(
					"... also checked in via travelynx. aborting.");
				return;
			}

			if ( $traewelling->{category}
				!~ m{^ (?: national .* | regional .* | suburban ) $ }x )
			{
				$self->log->debug(
					"... status is not a train, but $traewelling->{category}");
				$self->traewelling->log(
					uid => $uid,
					message =>
"$traewelling->{line} nach $traewelling->{arr_name}  ist keine Zugfahrt (HAFAS-Kategorie '$traewelling->{category}')",
					status_id => $traewelling->{status_id},
				);
				$self->traewelling->set_latest_pull_status_id(
					uid       => $uid,
					status_id => $traewelling->{status_id}
				);
				return;
			}

			my $dep = $self->iris->get_departures(
				station    => $traewelling->{dep_eva},
				lookbehind => 60,
				lookahead  => 40
			);
			if ( $dep->{errstr} ) {
				$self->traewelling->log(
					uid => $uid,
					message =>
"Fehler bei $traewelling->{line} nach $traewelling->{arr_name}: $dep->{errstr}",
					status_id => $traewelling->{status_id},
					is_error  => 1,
				);
				return;
			}
			my ( $train_ref, $train_id );
			for my $train ( @{ $dep->{results} } ) {
				if ( $train->line ne $traewelling->{line} ) {
					next;
				}
				if ( not $train->sched_departure
					or $train->sched_departure->epoch
					!= $traewelling->{dep_dt}->epoch )
				{
					next;
				}
				if (
					not List::Util::first { $_ eq $traewelling->{arr_name} }
					$train->route_post
				  )
				{
					next;
				}
				$train_id  = $train->train_id;
				$train_ref = $train;
				last;
			}
			if ($train_id) {
				$self->log->debug("... found train: $train_id");

				my $db = $self->pg->db;
				my $tx = $db->begin;

				my ( undef, $err ) = $self->checkin(
					station        => $traewelling->{dep_eva},
					train_id       => $train_id,
					uid            => $uid,
					in_transaction => 1,
					db             => $db
				);

				if ( not $err ) {
					( undef, $err ) = $self->checkout(
						station        => $traewelling->{arr_eva},
						train_id       => 0,
						uid            => $uid,
						in_transaction => 1,
						db             => $db
					);
					if ( not $err ) {
						$self->log->debug("... success!");
						if ( $traewelling->{message} ) {
							$self->in_transit->update_user_data(
								uid => $uid,
								db  => $db,
								user_data =>
								  { comment => $traewelling->{message} }
							);
						}
						$self->traewelling->log(
							uid => $uid,
							db  => $db,
							message =>
"Eingecheckt in $traewelling->{line} nach $traewelling->{arr_name}",
							status_id => $traewelling->{status_id},
						);
						$self->traewelling->set_latest_pull_status_id(
							uid       => $uid,
							status_id => $traewelling->{status_id},
							db        => $db
						);

						$tx->commit;
					}
				}
				if ($err) {
					$self->log->debug("... error: $err");
					$self->traewelling->log(
						uid => $uid,
						message =>
"Fehler bei $traewelling->{line} nach $traewelling->{arr_name}: $err",
						status_id => $traewelling->{status_id},
						is_error  => 1
					);
				}
			}
			else {
				$self->traewelling->log(
					uid => $uid,
					message =>
"$traewelling->{line} nach $traewelling->{arr_name} nicht gefunden",
					status_id => $traewelling->{status_id},
					is_error  => 1
				);
			}
		}
	);

	$self->helper(
		'journeys_to_map_data' => sub {
			my ( $self, %opt ) = @_;

			my @journeys       = @{ $opt{journeys} // [] };
			my $route_type     = $opt{route_type} // 'polybee';
			my $include_manual = $opt{include_manual} ? 1 : 0;

			my $location = $self->app->coordinates_by_station;

			my $with_polyline = $route_type eq 'beeline' ? 0 : 1;

			if ( not @journeys ) {
				return {
					skipped_journeys    => [],
					station_coordinates => [],
					polyline_groups     => [],
				};
			}

			my $json = JSON->new->utf8;

			my $first_departure = $journeys[-1]->{rt_departure};
			my $last_departure  = $journeys[0]->{rt_departure};

			my @stations = List::Util::uniq map { $_->{to_name} } @journeys;
			push( @stations,
				List::Util::uniq map { $_->{from_name} } @journeys );
			@stations = List::Util::uniq @stations;
			my @station_coordinates = map { [ $location->{$_}, $_ ] }
			  grep { exists $location->{$_} } @stations;

			my @station_pairs;
			my @polylines;
			my %seen;

			my @skipped_journeys;
			my @polyline_journeys = grep { $_->{polyline} } @journeys;
			my @beeline_journeys  = grep { not $_->{polyline} } @journeys;

			if ( $route_type eq 'polyline' ) {
				@beeline_journeys = ();
			}
			elsif ( $route_type eq 'beeline' ) {
				push( @beeline_journeys, @polyline_journeys );
				@polyline_journeys = ();
			}

			for my $journey (@polyline_journeys) {
				my @polyline = @{ $journey->{polyline} };
				my $from_eva = $journey->{from_eva};
				my $to_eva   = $journey->{to_eva};

				my $from_index
				  = first_index { $_->[2] and $_->[2] == $from_eva } @polyline;
				my $to_index
				  = first_index { $_->[2] and $_->[2] == $to_eva } @polyline;

				if (   $from_index == -1
					or $to_index == -1 )
				{
					# Fall back to route
					delete $journey->{polyline};
					next;
				}

				my $key
				  = $from_eva . '!'
				  . $to_eva . '!'
				  . ( $to_index - $from_index );

				if ( $seen{$key} ) {
					next;
				}

				$seen{$key} = 1;

				# direction does not matter at the moment
				$key
				  = $to_eva . '!'
				  . $from_eva . '!'
				  . ( $to_index - $from_index );
				$seen{$key} = 1;

				@polyline = @polyline[ $from_index .. $to_index ];
				my @polyline_coords;
				for my $coord (@polyline) {
					push( @polyline_coords, [ $coord->[1], $coord->[0] ] );
				}
				push( @polylines, [@polyline_coords] );
			}

			for my $journey (@beeline_journeys) {

				my @route = map { $_->[0] } @{ $journey->{route} };

				my $from_index
				  = first_index { $_ eq $journey->{from_name} } @route;
				my $to_index = first_index { $_ eq $journey->{to_name} } @route;

				if ( $from_index == -1 ) {
					my $rename = $self->app->renamed_station;
					$from_index = first_index {
						( $rename->{$_} // $_ ) eq $journey->{from_name}
					}
					@route;
				}
				if ( $to_index == -1 ) {
					my $rename = $self->app->renamed_station;
					$to_index = first_index {
						( $rename->{$_} // $_ ) eq $journey->{to_name}
					}
					@route;
				}

				if (   $from_index == -1
					or $to_index == -1 )
				{
					push( @skipped_journeys,
						[ $journey, 'Start/Ziel nicht in Route gefunden' ] );
					next;
				}

          # Manual journey entries are only included if one of the following
          # conditions is satisfied:
          # * their route has more than two elements (-> probably more than just
          #   start and stop station), or
          # * $include_manual is true (-> user wants to see incomplete routes)
          # This avoids messing up the map in case an A -> B connection has been
          # tracked both with a regular checkin (-> detailed route shown on map)
          # and entered manually (-> beeline also shown on map, typically
          # significantly differs from detailed route) -- unless the user
          # sets include_manual, of course.
				if (    $journey->{edited} & 0x0010
					and @route <= 2
					and not $include_manual )
				{
					push( @skipped_journeys,
						[ $journey, 'Manueller Eintrag ohne Unterwegshalte' ] );
					next;
				}

				@route = @route[ $from_index .. $to_index ];

				my $key = join( '|', @route );

				if ( $seen{$key} ) {
					next;
				}

				$seen{$key} = 1;

				# direction does not matter at the moment
				$seen{ join( '|', reverse @route ) } = 1;

				my $prev_station = shift @route;
				for my $station (@route) {
					push( @station_pairs, [ $prev_station, $station ] );
					$prev_station = $station;
				}
			}

			@station_pairs = uniq_by { $_->[0] . '|' . $_->[1] } @station_pairs;
			@station_pairs = grep {
				      exists $location->{ $_->[0] }
				  and exists $location->{ $_->[1] }
			} @station_pairs;
			@station_pairs
			  = map { [ $location->{ $_->[0] }, $location->{ $_->[1] } ] }
			  @station_pairs;

			my $ret = {
				skipped_journeys    => \@skipped_journeys,
				station_coordinates => \@station_coordinates,
				polyline_groups     => [
					{
						polylines => $json->encode( \@station_pairs ),
						color     => '#673ab7',
						opacity   => $with_polyline ? 0.4 : 0.6,
					},
					{
						polylines => $json->encode( \@polylines ),
						color     => '#673ab7',
						opacity   => 0.8,
					}
				],
			};

			if (@station_coordinates) {
				my @lats = map { $_->[0][0] } @station_coordinates;
				my @lons = map { $_->[0][1] } @station_coordinates;
				my $min_lat = List::Util::min @lats;
				my $max_lat = List::Util::max @lats;
				my $min_lon = List::Util::min @lons;
				my $max_lon = List::Util::max @lons;
				$ret->{bounds}
				  = [ [ $min_lat, $min_lon ], [ $max_lat, $max_lon ] ];
			}

			return $ret;
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
	$r->get('/p/:name')->to('traveling#public_profile');
	$r->get('/p/:name/j/:id')->to('traveling#public_journey_details');
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
	$authed_r->get('/account/traewelling')->to('traewelling#settings');
	$authed_r->get('/account/insight')->to('account#insight');
	$authed_r->get('/ajax/status_card.html')->to('traveling#status_card');
	$authed_r->get('/cancelled')->to('traveling#cancelled');
	$authed_r->get('/fgr')->to('passengerrights#list_candidates');
	$authed_r->get('/account/password')->to('account#password_form');
	$authed_r->get('/account/mail')->to('account#change_mail');
	$authed_r->get('/export.json')->to('account#json_export');
	$authed_r->get('/history.json')->to('traveling#json_history');
	$authed_r->get('/history.csv')->to('traveling#csv_history');
	$authed_r->get('/history')->to('traveling#history');
	$authed_r->get('/history/commute')->to('traveling#commute');
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
	$authed_r->post('/account/traewelling')->to('traewelling#settings');
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
