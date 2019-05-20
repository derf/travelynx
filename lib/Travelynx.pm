package Travelynx;
use Mojo::Base 'Mojolicious';

use Mojo::Pg;
use Mojolicious::Plugin::Authentication;
use Cache::File;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use DateTime;
use Encode qw(decode encode);
use Geo::Distance;
use JSON;
use List::Util qw(first);
use List::MoreUtils qw(after_incl before_incl);
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use Travelynx::Helper::Sendmail;

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

	$self->defaults( layout => 'default' );

	$self->hook(
		before_dispatch => sub {
			my ($self) = @_;

          # The "theme" cookie is set client-side if the theme we delivered was
          # changed by dark mode detection or by using the theme switcher). It's
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
				action  => 3,
			};
		}
	);
	$self->attr(
		token_types => sub {
			return [qw(status history action)];
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
			my ( $self, $station, $lookbehind, $lookahead ) = @_;

			$lookbehind //= 180;
			$lookahead  //= 30;

			my @station_matches
			  = Travel::Status::DE::IRIS::Stations::get_station($station);

			if ( @station_matches == 1 ) {
				$station = $station_matches[0][0];
				my $status = Travel::Status::DE::IRIS->new(
					station        => $station,
					main_cache     => $self->app->cache_iris_main,
					realtime_cache => $self->app->cache_iris_rt,
					lookbehind     => 20,
					datetime => DateTime->now( time_zone => 'Europe/Berlin' )
					  ->subtract( minutes => $lookbehind ),
					lookahead   => $lookbehind + $lookahead,
					lwp_options => {
						timeout => 10,
						agent   => 'travelynx/' . $self->app->config->{version},
					},
				);
				return {
					results       => [ $status->results ],
					errstr        => $status->errstr,
					station_ds100 => (
						$status->station ? $status->station->{ds100} : 'undef'
					),
					station_name =>
					  ( $status->station ? $status->station->{name} : 'undef' ),
				};
			}
			elsif ( @station_matches > 1 ) {
				return {
					results => [],
					errstr  => 'Ambiguous station name',
				};
			}
			else {
				return {
					results => [],
					errstr  => 'Unknown station name',
				};
			}
		}
	);

	# Returns (journey id, error)
	# Must be called during a transaction.
	# Must perform a rollback on error.
	$self->helper(
		'add_journey' => sub {
			my ( $self, %opt ) = @_;

			my $db          = $opt{db};
			my $uid         = $self->current_user->{id};
			my $now         = DateTime->now( time_zone => 'Europe/Berlin' );
			my $dep_station = get_station( $opt{dep_station} );
			my $arr_station = get_station( $opt{arr_station} );

			if ( not $dep_station ) {
				return ( undef, 'Unbekannter Startbahnhof' );
			}
			if ( not $arr_station ) {
				return ( undef, 'Unbekannter Zielbahnhof' );
			}

			my $entry = {
				user_id            => $uid,
				train_type         => $opt{train_type},
				train_line         => $opt{train_line},
				train_no           => $opt{train_no},
				train_id           => 'manual',
				checkin_station_id => $self->get_station_id(
					ds100 => $dep_station->[0],
					name  => $dep_station->[1],
				),
				checkin_time        => $now,
				sched_departure     => $opt{sched_departure},
				real_departure      => $opt{rt_departure},
				checkout_station_id => $self->get_station_id(
					ds100 => $arr_station->[0],
					name  => $arr_station->[1],
				),
				sched_arrival => $opt{sched_arrival},
				real_arrival  => $opt{rt_arrival},
				checkout_time => $now,
				edited        => 0x3fff,
				cancelled     => $opt{cancelled} ? 1 : 0,
				route         => $dep_station->[1] . '|' . $arr_station->[1],
			};

			if ( $opt{comment} ) {
				$entry->{messages} = '0:' . $opt{comment};
			}

			my $journey_id = undef;
			eval {
				$journey_id
				  = $db->insert( 'journeys', $entry, { returning => 'id' } )
				  ->hash->{id};
				$self->invalidate_stats_cache( $opt{rt_departure}, $db );
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
			my ( $self, $station, $train_id ) = @_;

			my $status = $self->get_departures( $station, 140, 30 );
			if ( $status->{errstr} ) {
				return ( undef, $status->{errstr} );
			}
			else {
				my ($train)
				  = first { $_->train_id eq $train_id } @{ $status->{results} };
				if ( not defined $train ) {
					return ( undef, "Train ${train_id} not found" );
				}
				else {

					my $user = $self->get_user_status;
					if ( $user->{checked_in} or $user->{cancelled} ) {

						if (    $user->{train_id} eq $train_id
							and $user->{dep_ds100} eq $status->{station_ds100} )
						{
							# checking in twice is harmless
							return ( $train, undef );
						}

						# Otherwise, someone forgot to check out first
						$self->checkout( $station, 1 );
					}

					eval {
						$self->pg->db->insert(
							'in_transit',
							{
								user_id   => $self->current_user->{id},
								cancelled => $train->departure_is_cancelled
								? 1
								: 0,
								checkin_station_id => $self->get_station_id(
									ds100 => $status->{station_ds100},
									name  => $status->{station_name}
								),
								checkin_time =>
								  DateTime->now( time_zone => 'Europe/Berlin' ),
								dep_platform    => $train->platform,
								train_type      => $train->type,
								train_line      => $train->line_no,
								train_no        => $train->train_no,
								train_id        => $train->train_id,
								sched_departure => $train->sched_departure,
								real_departure  => $train->departure,
								route           => join( '|', $train->route ),
								messages        => join(
									'|',
									map {
										( $_->[0] ? $_->[0]->epoch : q{} ) . ':'
										  . $_->[1]
									} $train->messages
								)
							}
						);
					};
					if ($@) {
						my $uid = $self->current_user->{id};
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						return ( undef, 'INSERT failed: ' . $@ );
					}
					$self->run_hook( $self->current_user->{id}, 'checkin' );
					return ( $train, undef );
				}
			}
		}
	);

	$self->helper(
		'undo' => sub {
			my ( $self, $journey_id ) = @_;
			my $uid = $self->current_user->{id};

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

				$self->invalidate_stats_cache( $cache_ts, $db );

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

			my $db = $self->pg->db;
			my $status = $self->get_departures( $station, 120, 120 );
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
			  = $db->select( 'in_transit', '*', { user_id => $uid } )->hash;
			my ($train)
			  = first { $_->train_id eq $train_id } @{ $status->{results} };

			# Store the intended checkout station regardless of this operation's
			# success.
			my $new_checkout_station_id = $self->get_station_id(
				ds100 => $status->{station_ds100},
				name  => $status->{station_name}
			);
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

			if ( not( defined $train or $force ) ) {
				return ( 1, undef );
			}

			my $has_arrived = 0;

			eval {

				my $tx = $db->begin;

				if ( defined $train ) {
					$has_arrived = $train->arrival->epoch < $now->epoch ? 1 : 0;
					$db->update(
						'in_transit',
						{
							checkout_time => $now,
							arr_platform  => $train->platform,
							sched_arrival => $train->sched_arrival,
							real_arrival  => $train->arrival,
							cancelled => $train->arrival_is_cancelled ? 1 : 0,
							route     => join( '|', $train->route ),
							messages  => join(
								'|',
								map {
									( $_->[0] ? $_->[0]->epoch : q{} ) . ':'
									  . $_->[1]
								} $train->messages
							),
						},
						{ user_id => $uid }
					);
				}

				$journey
				  = $db->select( 'in_transit', '*', { user_id => $uid } )->hash;

				if ( $has_arrived or $force ) {
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
		'update_journey_part' => sub {
			my ( $self, $db, $journey_id, $key, $value ) = @_;
			my $rows;

			my $journey = $self->get_journey(
				db         => $db,
				journey_id => $journey_id,
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
			my ( $self, $journey ) = @_;

			if ( $journey->{sched_duration} and $journey->{sched_duration} < 0 )
			{
				return
'Die geplante Dauer dieser Zugfahrt ist negativ. Zeitreisen werden aktuell nicht unterstützt.';
			}
			if ( $journey->{rt_duration} and $journey->{rt_duration} < 0 ) {
				return
'Die Dauer dieser Zugfahrt ist negativ. Zeitreisen werden aktuell nicht unterstützt.';
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

			return undef;
		}
	);

	$self->helper(
		'get_station_id' => sub {
			my ( $self, %opt ) = @_;

			my $res = $self->pg->db->select( 'stations', ['id'],
				{ ds100 => $opt{ds100} } );
			my $res_h = $res->hash;

			if ($res_h) {
				$res->finish;
				return $res_h->{id};
			}

			$self->pg->db->insert(
				'stations',
				{
					ds100 => $opt{ds100},
					name  => $opt{name},
				}
			);
			$res = $self->pg->db->select( 'stations', ['id'],
				{ ds100 => $opt{ds100} } );
			my $id = $res->hash->{id};
			$res->finish;
			return $id;
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
				or $journey->{checkin}->epoch != $checkin_epoch
				or $journey->{checkout}->epoch != $checkout_epoch )
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
				$self->invalidate_stats_cache( $journey->{rt_departure} );
				return undef;
			}
			return sprintf( 'Deleted %d rows, expected 1', $rows );
		}
	);

	$self->helper(
		'get_journey_stats' => sub {
			my ( $self, %opt ) = @_;

			if ( $opt{cancelled} ) {
				$self->app->log->warning(
'get_journey_stats called with illegal option cancelled => 1'
				);
				return {};
			}

			my $uid   = $opt{uid} // $self->current_user->{id};
			my $year  = $opt{year} // 0;
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

			$self->pg->db->insert(
				'journey_stats',
				{
					user_id => $uid,
					year    => $year,
					month   => $month,
					data    => JSON->new->encode($stats),
				}
			);

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
		'get_connection_targets' => sub {
			my ( $self, %opt ) = @_;

			my $uid       = $opt{uid} // $self->current_user->{id};
			my $threshold = $opt{threshold}
			  // DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( weeks => 6 );
			my $db = $opt{db} // $self->pg->db;

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

			my $res = $db->query(
				qq{
					select
					count(stations.name) as count,
					stations.name as dest
					from journeys
					left outer join stations on checkout_station_id = stations.id
					where user_id = ?
					and checkin_station_id = ?
					and real_departure > ?
					group by stations.name
					order by count desc;
				},
				$uid,
				$journey->{checkout_station_id},
				$threshold
			);
			my @destinations = $res->hashes->grep( sub { shift->{count} > 2 } )
			  ->map( sub { shift->{dest} } )->each;
			return @destinations;
		}
	);

	$self->helper(
		'get_connecting_trains' => sub {
			my ( $self, %opt ) = @_;

			my $status = $self->get_user_status;

			if ( not $status->{arr_ds100} ) {
				return;
			}

			my @destinations = $self->get_connection_targets(%opt);
			@destinations = grep { $_ ne $status->{dep_name} } @destinations;

			if ( not @destinations ) {
				return;
			}

			my $stationboard
			  = $self->get_departures( $status->{arr_ds100}, 0, 60 );
			if ( $stationboard->{errstr} ) {
				return;
			}
			my @results;
			my %via_count = map { $_ => 0 } @destinations;
			for my $train ( @{ $stationboard->{results} } ) {
				if ( not $train->departure ) {
					next;
				}
				if ( $train->departure->epoch < $status->{real_arrival}->epoch )
				{
					next;
				}
				if ( $train->train_id eq $status->{train_id} ) {
					next;
				}
				my @via = ( $train->route_post, $train->route_end );
				for my $dest (@destinations) {
					if ( $via_count{$dest} < 3
						and List::Util::any { $_ eq $dest } @via )
					{
						push( @results, [ $train, $dest ] );
						$via_count{$dest}++;
						next;
					}
				}
			}

			@results = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map {
				[
					$_,
					$_->[0]->departure->epoch // $_->[0]->sched_departur->epoch
				]
			  } @results;

			return @results;
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

			my @travels;

			my $res = $db->select( 'journeys_str', '*', \%where, \%order );

			for my $entry ( $res->hashes->each ) {

				my $ref = {
					id              => $entry->{journey_id},
					type            => $entry->{train_type},
					line            => $entry->{train_line},
					no              => $entry->{train_no},
					from_name       => $entry->{dep_name},
					checkin         => epoch_to_dt( $entry->{checkin_ts} ),
					sched_departure => epoch_to_dt( $entry->{sched_dep_ts} ),
					rt_departure    => epoch_to_dt( $entry->{real_dep_ts} ),
					to_name         => $entry->{arr_name},
					checkout        => epoch_to_dt( $entry->{checkout_ts} ),
					sched_arrival   => epoch_to_dt( $entry->{sched_arr_ts} ),
					rt_arrival      => epoch_to_dt( $entry->{real_arr_ts} ),
					messages        => $entry->{messages}
					? [ split( qr{[|]}, $entry->{messages} ) ]
					: undef,
					route => $entry->{route}
					? [ split( qr{[|]}, $entry->{route} ) ]
					: undef,
					edited => $entry->{edited},
				};

				if ( $opt{verbose} ) {
					$ref->{cancelled} = $entry->{cancelled};
					my @parsed_messages;
					for my $message ( @{ $ref->{messages} // [] } ) {
						my ( $ts, $msg ) = split( qr{:}, $message );
						push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
					}
					$ref->{messages} = [ reverse @parsed_messages ];
					$ref->{sched_duration}
					  = $ref->{sched_arrival}->epoch
					  ? $ref->{sched_arrival}->epoch
					  - $ref->{sched_departure}->epoch
					  : undef;
					$ref->{rt_duration}
					  = $ref->{rt_arrival}->epoch
					  ? $ref->{rt_arrival}->epoch - $ref->{rt_departure}->epoch
					  : undef;
					my ( $km, $skip )
					  = $self->get_travel_distance( $ref->{from_name},
						$ref->{to_name}, $ref->{route} );
					$ref->{km_route}   = $km;
					$ref->{skip_route} = $skip;
					( $km, $skip )
					  = $self->get_travel_distance( $ref->{from_name},
						$ref->{to_name},
						[ $ref->{from_name}, $ref->{to_name} ] );
					$ref->{km_beeline}   = $km;
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
		'get_user_status' => sub {
			my ( $self, $uid ) = @_;

			$uid //= $self->current_user->{id};

			my $db = $self->pg->db;
			my $now = DateTime->now( time_zone => 'Europe/Berlin' );

			my $in_transit
			  = $db->select( 'in_transit_str', '*', { user_id => $uid } )->hash;

			if ($in_transit) {

				my @route = split( qr{[|]}, $in_transit->{route} // q{} );
				my @route_after;
				my $is_after = 0;
				for my $station (@route) {

					if ($is_after) {
						push( @route_after, $station );
					}
					if ( $station eq $in_transit->{dep_name} ) {
						$is_after = 1;
					}
				}

				my $ts = $in_transit->{checkout_ts}
				  // $in_transit->{checkin_ts};
				my $action_time = epoch_to_dt($ts);

				my $ret = {
					checked_in      => !$in_transit->{cancelled},
					cancelled       => $in_transit->{cancelled},
					timestamp       => $action_time,
					timestamp_delta => $now->epoch - $action_time->epoch,
					train_type      => $in_transit->{train_type},
					train_line      => $in_transit->{train_line},
					train_no        => $in_transit->{train_no},
					train_id        => $in_transit->{train_id},
					sched_departure =>
					  epoch_to_dt( $in_transit->{sched_dep_ts} ),
					real_departure => epoch_to_dt( $in_transit->{real_dep_ts} ),
					dep_ds100      => $in_transit->{dep_ds100},
					dep_name       => $in_transit->{dep_name},
					dep_platform   => $in_transit->{dep_platform},
					sched_arrival => epoch_to_dt( $in_transit->{sched_arr_ts} ),
					real_arrival  => epoch_to_dt( $in_transit->{real_arr_ts} ),
					arr_ds100     => $in_transit->{arr_ds100},
					arr_name      => $in_transit->{arr_name},
					arr_platform  => $in_transit->{arr_platform},
					route_after   => \@route_after,
					messages      => $in_transit->{messages}
					? [ split( qr{[|]}, $in_transit->{messages} ) ]
					: undef,
				};

				my @parsed_messages;
				for my $message ( @{ $ret->{messages} // [] } ) {
					my ( $ts, $msg ) = split( qr{:}, $message );
					push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
				}
				$ret->{messages} = [ reverse @parsed_messages ];

				$ret->{departure_countdown}
				  = $ret->{real_departure}->epoch - $now->epoch;
				if ( $in_transit->{real_arr_ts} ) {
					$ret->{arrival_countdown}
					  = $ret->{real_arrival}->epoch - $now->epoch;
					$ret->{journey_duration} = $ret->{real_arrival}->epoch
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
			)->hash;

			if ($latest) {
				my $ts          = $latest->{checkout_ts};
				my $action_time = epoch_to_dt($ts);
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
					dep_name        => $latest->{dep_name},
					dep_platform    => $latest->{dep_platform},
					sched_arrival   => epoch_to_dt( $latest->{sched_arr_ts} ),
					real_arrival    => epoch_to_dt( $latest->{real_arr_ts} ),
					arr_ds100       => $latest->{arr_ds100},
					arr_name        => $latest->{arr_name},
					arr_platform    => $latest->{arr_platform},
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

			my $ret = {
				deprecated => \0,
				checkedIn  => (
					     $status->{checked_in}
					  or $status->{cancelled}
				) ? \1 : \0,
				fromStation => {
					ds100         => $status->{dep_ds100},
					name          => $status->{dep_name},
					uic           => undef,
					longitude     => undef,
					latitude      => undef,
					scheduledTime => $status->{sched_departure}->epoch || undef,
					realTime      => $status->{real_departure}->epoch || undef,
				},
				toStation => {
					ds100         => $status->{arr_ds100},
					name          => $status->{arr_name},
					uic           => undef,
					longitude     => undef,
					latitude      => undef,
					scheduledTime => $status->{sched_arrival}->epoch || undef,
					realTime      => $status->{real_arrival}->epoch || undef,
				},
				train => {
					type => $status->{train_type},
					line => $status->{train_line},
					no   => $status->{train_no},
					id   => $status->{train_id},
				},
				actionTime => $status->{timestamp}->epoch,
			};

			if ( $status->{dep_ds100} ) {
				my @station_descriptions
				  = Travel::Status::DE::IRIS::Stations::get_station(
					$status->{dep_ds100} );
				if ( @station_descriptions == 1 ) {
					(
						undef, undef,
						$ret->{fromStation}{uic},
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
						undef, undef,
						$ret->{toStation}{uic},
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

			my $distance = 0;
			my $skipped  = 0;
			my $geo      = Geo::Distance->new();
			my @route    = after_incl { $_ eq $from } @{$route_ref};
			@route = before_incl { $_ eq $to } @route;

			if ( @route < 2 ) {

				# I AM ERROR
				return 0;
			}

			my $prev_station = get_station( shift @route );
			if ( not $prev_station ) {
				return 0;
			}

			for my $station_name (@route) {
				if ( my $station = get_station($station_name) ) {
					if ( $#{$prev_station} >= 4 and $#{$station} >= 4 ) {
						$distance
						  += $geo->distance( 'kilometer', $prev_station->[3],
							$prev_station->[4], $station->[3], $station->[4] );
					}
					else {
						$skipped++;
					}
					$prev_station = $station;
				}
			}

			return ( $distance, $skipped );
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

			my $next_departure = epoch_to_dt(0);

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
				if ( $journey->{sched_departure} and $journey->{rt_departure} )
				{
					$delay_dep
					  += (  $journey->{rt_departure}->epoch
						  - $journey->{sched_departure}->epoch ) / 60;
				}
				if ( $journey->{sched_arrival} and $journey->{rt_arrival} ) {
					$delay_arr
					  += (  $journey->{rt_arrival}->epoch
						  - $journey->{sched_arrival}->epoch ) / 60;
				}

				# Note that journeys are sorted from recent to older entries
				if (    $journey->{rt_arrival}
					and $next_departure->epoch
					and $next_departure->epoch - $journey->{rt_arrival}->epoch
					< ( 60 * 60 ) )
				{
					if ( $next_departure->epoch - $journey->{rt_arrival}->epoch
						< 0 )
					{
						push( @inconsistencies,
							$next_departure->strftime('%d.%m.%Y %H:%M') );
					}
					else {
						$interchange_real
						  += (  $next_departure->epoch
							  - $journey->{rt_arrival}->epoch )
						  / 60;
					}
				}
				else {
					$num_journeys++;
				}
				$next_departure = $journey->{rt_departure};
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
	$r->get('/api/v0/:user_action/:token')->to('api#get_v0');
	$r->get('/api/v1/:user_action/:token')->to('api#get_v1');
	$r->get('/login')->to('account#login_form');
	$r->get('/recover')->to('account#request_password_reset');
	$r->get('/recover/:id/:token')->to('account#recover_password');
	$r->get('/register')->to('account#registration_form');
	$r->get('/reg/:id/:token')->to('account#verify');
	$r->get('/status/:name')->to('traveling#user_status');
	$r->get('/ajax/status/:name')->to('traveling#public_status_card');
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
	$authed_r->get('/ajax/status_card.html')->to('traveling#status_card');
	$authed_r->get('/cancelled')->to('traveling#cancelled');
	$authed_r->get('/account/password')->to('account#password_form');
	$authed_r->get('/account/mail')->to('account#change_mail');
	$authed_r->get('/export.json')->to('account#json_export');
	$authed_r->get('/history.json')->to('traveling#json_history');
	$authed_r->get('/history')->to('traveling#history');
	$authed_r->get('/history/:year')->to('traveling#yearly_history');
	$authed_r->get('/history/:year/:month')->to('traveling#monthly_history');
	$authed_r->get('/journey/add')->to('traveling#add_journey_form');
	$authed_r->get('/journey/:id')->to('traveling#journey_details');
	$authed_r->get('/s/*station')->to('traveling#station');
	$authed_r->get('/confirm_mail/:token')->to('account#confirm_mail');
	$authed_r->post('/account/privacy')->to('account#privacy');
	$authed_r->post('/account/hooks')->to('account#webhook');
	$authed_r->post('/journey/add')->to('traveling#add_journey_form');
	$authed_r->post('/journey/edit')->to('traveling#edit_journey');
	$authed_r->post('/account/password')->to('account#change_password');
	$authed_r->post('/account/mail')->to('account#change_mail');
	$authed_r->post('/delete')->to('account#delete');
	$authed_r->post('/logout')->to('account#do_logout');
	$authed_r->post('/set_token')->to('api#set_token');

}

1;
