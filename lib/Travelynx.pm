package Travelynx;

# Copyright (C) 2020-2023 Birte Kristina Friesel
# Copyright (C) 2025 networkException <git@nwex.de>
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious';

use Mojo::Pg;
use Mojo::Promise;
use Mojolicious::Plugin::Authentication;
use Cache::File;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use DateTime;
use DateTime::Format::Strptime;
use Encode      qw(decode encode);
use File::Slurp qw(read_file);
use JSON;
use List::Util;
use List::UtilsBy   qw(uniq_by);
use List::MoreUtils qw(first_index);
use Travel::Status::DE::DBRIS::Formation;
use Travelynx::Helper::DBDB;
use Travelynx::Helper::DBRIS;
use Travelynx::Helper::EFA;
use Travelynx::Helper::HAFAS;
use Travelynx::Helper::IRIS;
use Travelynx::Helper::MOTIS;
use Travelynx::Helper::Sendmail;
use Travelynx::Helper::Traewelling;
use Travelynx::Model::InTransit;
use Travelynx::Model::Journeys;
use Travelynx::Model::JourneyStatsCache;
use Travelynx::Model::Stations;
use Travelynx::Model::Traewelling;
use Travelynx::Model::Users;

sub check_password {
	my ( $password, $hash ) = @_;

	if ( bcrypt( substr( $password, 0, 10000 ), $hash ) eq $hash ) {
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

	chomp $self->config->{version};
	$self->defaults( version => $self->config->{version} // 'UNKNOWN' );

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

	if ( my $oa = $self->config->{traewelling}{oauth} ) {
		$self->plugin(
			OAuth2 => {
				providers => {
					traewelling => {
						key           => $oa->{id},
						secret        => $oa->{secret},
						authorize_url =>
'https://traewelling.de/oauth/authorize?response_type=code',
						token_url => 'https://traewelling.de/oauth/token',
					}
				}
			}
		);
	}

	$self->sessions->default_expiration( 60 * 60 * 24 * 180 );

	# Starting with v8.11, Mojolicious sends SameSite=Lax Cookies by default.
	# In theory, "The default lax value provides a reasonable balance between
	# security and usability for websites that want to maintain user's logged-in
	# session after the user arrives from an external link". In practice,
	# Safari (both iOS and macOS) does not send a SameSite=lax cookie when
	# following a link from an external site. So, bahn.expert providing a
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

			state $cache = Cache::File->new(
				cache_root      => $self->app->config->{cache}->{schedule},
				default_expires => '6 hours',
				lock_level      => Cache::File::LOCK_LOCAL(),
			);
			return $cache;
		}
	);

	$self->attr(
		cache_iris_rt => sub {
			my ($self) = @_;

			state $cache = Cache::File->new(
				cache_root      => $self->app->config->{cache}->{realtime},
				default_expires => '70 seconds',
				lock_level      => Cache::File::LOCK_LOCAL(),
			);
			return $cache;
		}
	);

	# https://de.wikipedia.org/wiki/Liste_nach_Gemeinden_und_Regionen_benannter_IC/ICE-Fahrzeuge#Namensgebung_ICE-Triebz%C3%BCge_nach_Gemeinden
	# via https://github.com/marudor/bahn.expert/blob/main/src/server/coachSequence/TrainNames.ts
	$self->attr(
		ice_name => sub {
			state $id_to_name = {
				Travel::Status::DE::DBRIS::Formation::Group::name_to_designation(
				)
			};
			return $id_to_name;
		}
	);

	$self->attr(
		renamed_station => sub {
			state $legacy_to_new = JSON->new->utf8->decode(
				scalar read_file('share/old_station_names.json') );
			return $legacy_to_new;
		}
	);

	if ( not $self->app->config->{base_url} ) {
		$self->app->log->error(
"travelynx.conf: 'base_url' is missing. Links in maintenance/work/worker-generated E-Mails will be incorrect. This variable was introduced in travelynx 1.22; see examples/travelynx.conf for documentation."
		);
	}

	$self->helper(
		base_url_for => sub {
			my ( $self, $path ) = @_;
			if ( ( my $url = $self->url_for($path) )->base ne q{}
				or not $self->app->config->{base_url} )
			{
				return $url;
			}
			return $self->url_for($path)
			  ->base( $self->app->config->{base_url} );
		}
	);

	$self->helper(
		efa => sub {
			my ($self) = @_;
			state $efa = Travelynx::Helper::EFA->new(
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->base_url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->app->config->{version},
			);
		}
	);

	$self->helper(
		dbris => sub {
			my ($self) = @_;
			state $dbris = Travelynx::Helper::DBRIS->new(
				log            => $self->app->log,
				service_config => $self->app->config->{dbris},
				cache          => $self->app->cache_iris_rt,
				root_url       => $self->base_url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->app->config->{version},
			);
		}
	);

	$self->helper(
		hafas => sub {
			my ($self) = @_;
			state $hafas = Travelynx::Helper::HAFAS->new(
				log            => $self->app->log,
				service_config => $self->app->config->{hafas},
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->base_url_for('/')->to_abs,
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
				root_url       => $self->base_url_for('/')->to_abs,
				version        => $self->app->config->{version},
			);
		}
	);

	$self->helper(
		motis => sub {
			my ($self) = @_;
			state $motis = Travelynx::Helper::MOTIS->new(
				log        => $self->app->log,
				cache      => $self->app->cache_iris_rt,
				user_agent => $self->ua,
				root_url   => $self->base_url_for('/')->to_abs,
				version    => $self->app->config->{version},
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
				root_url   => $self->base_url_for('/')->to_abs,
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
				in_transit      => $self->in_transit,
				stats_cache     => $self->journey_stats_cache,
				renamed_station => $self->app->renamed_station,
				stations        => $self->stations,
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

			$pg->on(
				connection => sub {
					my ( $pg, $dbh ) = @_;
					$dbh->do("set time zone 'Europe/Berlin'");
				}
			);

			return $pg;
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
		stations => sub {
			my ($self) = @_;
			state $stations
			  = Travelynx::Model::Stations->new( pg => $self->pg );
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
				log            => $self->app->log,
				main_cache     => $self->app->cache_iris_main,
				realtime_cache => $self->app->cache_iris_rt,
				root_url       => $self->base_url_for('/')->to_abs,
				user_agent     => $self->ua,
				version        => $self->app->config->{version},
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
		'sprintf_km' => sub {
			my ( $self, $km ) = @_;

			if ( $km < 1 ) {
				return sprintf( '%.f m', $km * 1000 );
			}
			if ( $km < 10 ) {
				return sprintf( '%.1f km', $km );
			}
			return sprintf( '%.f km', $km );
		}
	);

	$self->helper(
		'efa_load_icon' => sub {
			my ( $self, $occupancy ) = @_;

			my @symbols
			  = (
				qw(help_outline person_outline people priority_high not_interested)
			  );

			if ( $occupancy eq 'MANY_SEATS' ) {
				$occupancy = 1;
			}
			elsif ( $occupancy eq 'FEW_SEATS' ) {
				$occupancy = 2;
			}
			elsif ( $occupancy eq 'STANDING_ONLY' ) {
				$occupancy = 3;
			}
			elsif ( $occupancy eq 'FULL' ) {
				$occupancy = 4;
			}

			return $symbols[$occupancy] // 'help_outline';
		}
	);

	$self->helper(
		'load_icon' => sub {
			my ( $self, $load ) = @_;
			my $first  = $load->{FIRST}  // 0;
			my $second = $load->{SECOND} // 0;

			# DBRIS
			if ( $first == 99 ) {
				$first = 4;
			}
			if ( $second == 99 ) {
				$second = 4;
			}

			my @symbols
			  = (
				qw(help_outline person_outline people priority_high not_interested)
			  );

			return ( $symbols[$first], $symbols[$second] );
		}
	);

	$self->helper(
		'visibility_icon' => sub {
			my ( $self, $visibility ) = @_;
			if ( $visibility eq 'public' ) {
				return 'language';
			}
			if ( $visibility eq 'travelynx' ) {
				return 'lock_open';
			}
			if ( $visibility eq 'followers' ) {
				return 'group';
			}
			if ( $visibility eq 'unlisted' ) {
				return 'lock_outline';
			}
			if ( $visibility eq 'private' ) {
				return 'lock';
			}
			return 'help_outline';
		}
	);

	$self->helper(
		'checkin_p' => sub {
			my ( $self, %opt ) = @_;

			my $station  = $opt{station};
			my $train_id = $opt{train_id};
			my $ts       = $opt{ts};
			my $uid      = $opt{uid} // $self->current_user->{id};
			my $db       = $opt{db}  // $self->pg->db;
			my $hafas;

			my $user = $self->get_user_status( $uid, $db );
			if ( $user->{checked_in} or $user->{cancelled} ) {
				return Mojo::Promise->reject('You are already checked in');
			}

			if ( $opt{dbris} ) {
				return $self->_checkin_dbris_p(%opt);
			}
			if ( $opt{efa} ) {
				return $self->_checkin_efa_p(%opt);
			}
			if ( $opt{hafas} ) {
				return $self->_checkin_hafas_p(%opt);
			}
			if ( $opt{motis} ) {
				return $self->_checkin_motis_p(%opt);
			}

			my $promise = Mojo::Promise->new;

			$self->iris->get_departures_p(
				station    => $station,
				lookbehind => 140,
				lookahead  => 40
			)->then(
				sub {
					my ($status) = @_;

					if ( $status->{errstr} ) {
						$promise->reject( $status->{errstr} );
						return;
					}

					my $eva   = $status->{station_eva};
					my $train = List::Util::first { $_->train_id eq $train_id }
					@{ $status->{results} };

					if ( not defined $train ) {
						$promise->reject("Train ${train_id} not found");
						return;
					}

					eval {
						$self->in_transit->add(
							uid           => $uid,
							db            => $db,
							departure_eva => $eva,
							train         => $train,
							route      => [ $self->iris->route_diff($train) ],
							backend_id =>
							  $self->stations->get_backend_id( iris => 1 ),
						);
					};
					if ($@) {
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						$promise->reject( 'INSERT failed: ' . $@ );
						return;
					}

					# mustn't be called during a transaction
					if ( not $opt{in_transaction} ) {
						$self->add_route_timestamps( $uid, $train, 1 );
						$self->add_wagonorder(
							uid          => $uid,
							train_id     => $train->train_id,
							is_departure => 1,
							eva          => $eva,
							datetime     => $train->sched_departure,
							train_type   => $train->type,
							train_no     => $train->train_no
						);
						$self->add_stationinfo( $uid, 1, $train->train_id,
							$eva );
						$self->run_hook( $uid, 'checkin' );
					}

					$promise->resolve($train);
					return;
				}
			)->catch(
				sub {
					my ( $err, $status ) = @_;
					$promise->reject( $status->{errstr} );
					return;
				}
			)->wait;

			return $promise;
		}
	);

	$self->helper(
		'_checkin_motis_p' => sub {
			my ( $self, %opt ) = @_;

			my $station  = $opt{station};
			my $train_id = $opt{train_id};
			my $ts       = $opt{ts};
			my $uid      = $opt{uid} // $self->current_user->{id};
			my $db       = $opt{db}  // $self->pg->db;
			my $hafas;

			my $promise = Mojo::Promise->new;

			$self->motis->get_trip_p(
				service => $opt{motis},
				trip_id => $train_id,
			)->then(
				sub {
					my ($trip) = @_;
					my $found_stopover;

					for my $stopover ( $trip->stopovers ) {
						if ( $stopover->stop->id eq $station ) {
							$found_stopover = $stopover;

							# Lines may serve the same stop several times.
							# Keep looking until the scheduled departure
							# matches the one passed while checking in.
							if (    $ts
								and $stopover->scheduled_departure->epoch
								== $ts )
							{
								last;
							}
						}
					}

					if ( not $found_stopover ) {
						$promise->reject(
"Did not find stopover at '$station' within trip '$train_id'"
						);
						return;
					}

					for my $stopover ( $trip->stopovers ) {
						$self->stations->add_or_update(
							stop  => $stopover->stop,
							db    => $db,
							motis => $opt{motis},
						);
					}

					$self->stations->add_or_update(
						stop  => $found_stopover->stop,
						db    => $db,
						motis => $opt{motis},
					);

					eval {
						$self->in_transit->add(
							uid        => $uid,
							db         => $db,
							journey    => $trip,
							stopover   => $found_stopover,
							data       => { trip_id => $train_id },
							backend_id => $self->stations->get_backend_id(
								motis => $opt{motis}
							),
						);
					};

					if ($@) {
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						$promise->reject( 'INSERT failed: ' . $@ );
						return;
					}

					my $polyline;
					if ( $trip->polyline ) {
						my @station_list;
						my @coordinate_list;
						for my $coordinate ( $trip->polyline ) {
							if ( $coordinate->{stop} ) {
								if ( not defined $coordinate->{stop}->{eva} ) {
									die();
								}

								push(
									@coordinate_list,
									[
										$coordinate->{lon},
										$coordinate->{lat},
										$coordinate->{stop}->{eva}
									]
								);

								push( @station_list,
									$coordinate->{stop}->name );
							}
							else {
								push( @coordinate_list,
									[ $coordinate->{lon}, $coordinate->{lat} ]
								);
							}
						}

						# equal length → polyline only consists of straight
						# lines between stops. that's not helpful.
						if ( @station_list == @coordinate_list ) {
							$self->log->debug( 'Ignoring polyline for '
								  . $trip->route_name
								  . ' as it only consists of straight lines between stops.'
							);
						}
						else {
							$polyline = {
								from_eva =>
								  ( $trip->stopovers )[0]->stop->{eva},
								to_eva => ( $trip->stopovers )[-1]->stop->{eva},
								coords => \@coordinate_list,
							};
						}
					}

					if ($polyline) {
						$self->in_transit->set_polyline(
							uid      => $uid,
							db       => $db,
							polyline => $polyline,
						);
					}

					# mustn't be called during a transaction
					if ( not $opt{in_transaction} ) {
						$self->run_hook( $uid, 'checkin' );
					}

					$promise->resolve($trip);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
					return;
				}
			)->wait;

			return $promise;
		}
	);

	$self->helper(
		'_checkin_dbris_p' => sub {
			my ( $self, %opt ) = @_;

			my $station      = $opt{station};
			my $train_id     = $opt{train_id};
			my $train_suffix = $opt{train_suffix};
			my $ts           = $opt{ts};
			my $uid          = $opt{uid} // $self->current_user->{id};
			my $db           = $opt{db}  // $self->pg->db;
			my $hafas;

			my $promise = Mojo::Promise->new;

			$self->dbris->get_journey_p(
				trip_id       => $train_id,
				with_polyline => 1
			)->then(
				sub {
					my ($journey) = @_;
					my $found;
					for my $stop ( $journey->route ) {
						if ( $stop->eva eq $station ) {
							$found = $stop;

							# Lines may serve the same stop several times.
							# Keep looking until the scheduled departure
							# matches the one passed while checking in.
							if ( $ts and $stop->sched_dep->epoch == $ts ) {
								last;
							}
						}
					}
					if ( not $found ) {
						$promise->reject(
"Did not find stop '$station' within journey '$train_id'"
						);
						return;
					}
					for my $stop ( $journey->route ) {
						$self->stations->add_or_update(
							stop  => $stop,
							db    => $db,
							dbris => 'bahn.de',
						);
					}
					eval {
						$self->in_transit->add(
							uid        => $uid,
							db         => $db,
							journey    => $journey,
							stop       => $found,
							data       => { trip_id => $train_id },
							backend_id => $self->stations->get_backend_id(
								dbris => 'bahn.de'
							),
							train_suffix => $train_suffix,
						);
					};
					if ($@) {
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						$promise->reject( 'INSERT failed: ' . $@ );
						return;
					}

					my $polyline;
					if ( $journey->polyline ) {
						my @station_list;
						my @coordinate_list;
						for my $coord ( $journey->polyline ) {
							if ( $coord->{stop} ) {
								push(
									@coordinate_list,
									[
										$coord->{lon}, $coord->{lat},
										$coord->{stop}->eva
									]
								);
								push( @station_list, $coord->{stop}->name );
							}
							else {
								push( @coordinate_list,
									[ $coord->{lon}, $coord->{lat} ] );
							}
						}

						# equal length → polyline only consists of straight
						# lines between stops. that's not helpful.
						if ( @station_list == @coordinate_list ) {
							$self->log->debug( 'Ignoring polyline for '
								  . $journey->train
								  . ' as it only consists of straight lines between stops.'
							);
						}
						else {
							$polyline = {
								from_eva => ( $journey->route )[0]->eva,
								to_eva   => ( $journey->route )[-1]->eva,
								coords   => \@coordinate_list,
							};
						}
					}

					if ($polyline) {
						$self->in_transit->set_polyline(
							uid      => $uid,
							db       => $db,
							polyline => $polyline,
						);
					}

					# mustn't be called during a transaction
					if ( not $opt{in_transaction} ) {
						$self->run_hook( $uid, 'checkin' );
						$self->add_wagonorder(
							uid          => $uid,
							train_id     => $train_id,
							is_departure => 1,
							eva          => $found->eva,
							datetime     => $found->sched_dep,
							train_type   => $journey->type,
							train_no     => $journey->train_no,
						);
						$self->add_stationinfo( $uid, 1, $train_id,
							$found->eva );
					}

					$promise->resolve($journey);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
					return;
				}
			)->wait;

			return $promise;
		}
	);

	$self->helper(
		'_checkin_efa_p' => sub {
			my ( $self, %opt ) = @_;
			my $station = $opt{station};
			my $trip_id = $opt{train_id};
			my $ts      = $opt{ts};
			my $uid     = $opt{uid} // $self->current_user->{id};
			my $db      = $opt{db}  // $self->pg->db;

			my $promise = Mojo::Promise->new;
			$self->efa->get_journey_p(
				service => $opt{efa},
				trip_id => $trip_id
			)->then(
				sub {
					my ($journey) = @_;

					my $found;
					for my $stop ( $journey->route ) {
						if ( $stop->id_num == $station ) {
							$found = $stop;

							# Lines may serve the same stop several times.
							# Keep looking until the scheduled departure
							# matches the one passed while checking in.
							if ( $ts and $stop->sched_dep->epoch == $ts ) {
								last;
							}
						}
					}
					if ( not $found ) {
						$promise->reject(
"Did not find stop '$station' within journey '$trip_id'"
						);
						return;
					}

					for my $stop ( $journey->route ) {
						$self->stations->add_or_update(
							stop => $stop,
							db   => $db,
							efa  => $opt{efa},
						);
					}

					eval {
						$self->in_transit->add(
							uid        => $uid,
							db         => $db,
							journey    => $journey,
							stop       => $found,
							trip_id    => $trip_id,
							backend_id => $self->stations->get_backend_id(
								efa => $opt{efa}
							),
						);
					};
					if ($@) {
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						$promise->reject( 'INSERT failed: ' . $@ );
						return;
					}

					my $polyline;
					if ( $journey->polyline ) {
						my @station_list;
						my @coordinate_list;
						for my $coord ( $journey->polyline ) {
							if ( $coord->{stop} ) {
								push(
									@coordinate_list,
									[
										$coord->{lon}, $coord->{lat},
										$coord->{stop}->id_num
									]
								);
								push( @station_list,
									$coord->{stop}->full_name );
							}
							else {
								push( @coordinate_list,
									[ $coord->{lon}, $coord->{lat} ] );
							}
						}

						# equal length → polyline only consists of straight
						# lines between stops. that's not helpful.
						if ( @station_list == @coordinate_list ) {
							$self->log->debug( 'Ignoring polyline for '
								  . $journey->line
								  . ' as it only consists of straight lines between stops.'
							);
						}
						else {
							$polyline = {
								from_eva => ( $journey->route )[0]->id_num,
								to_eva   => ( $journey->route )[-1]->id_num,
								coords   => \@coordinate_list,
							};
						}
					}

					if ($polyline) {
						$self->in_transit->set_polyline(
							uid      => $uid,
							db       => $db,
							polyline => $polyline,
						);
					}

					# mustn't be called during a transaction
					if ( not $opt{in_transaction} ) {
						$self->run_hook( $uid, 'checkin' );
					}

					$promise->resolve($journey);

					return;
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
					return;
				}
			)->wait;
			return $promise;
		}
	);

	$self->helper(
		'_checkin_hafas_p' => sub {
			my ( $self, %opt ) = @_;

			my $station  = $opt{station};
			my $train_id = $opt{train_id};
			my $ts       = $opt{ts};
			my $uid      = $opt{uid} // $self->current_user->{id};
			my $db       = $opt{db}  // $self->pg->db;

			my $promise = Mojo::Promise->new;

			$self->hafas->get_journey_p(
				service       => $opt{hafas},
				trip_id       => $train_id,
				with_polyline => 1
			)->then(
				sub {
					my ($journey) = @_;
					my $found;
					for my $stop ( $journey->route ) {
						if (   $stop->loc->name eq $station
							or $stop->loc->eva == $station )
						{
							$found = $stop;

							# Lines may serve the same stop several times.
							# Keep looking until the scheduled departure
							# matches the one passed while checking in.
							if ( $ts and $stop->sched_dep->epoch == $ts ) {
								last;
							}
						}
					}
					if ( not $found ) {
						$promise->reject(
"Did not find stop '$station' within journey '$train_id'"
						);
						return;
					}
					for my $stop ( $journey->route ) {
						$self->stations->add_or_update(
							stop  => $stop,
							db    => $db,
							hafas => $opt{hafas},
						);
					}
					eval {
						$self->in_transit->add(
							uid        => $uid,
							db         => $db,
							journey    => $journey,
							stop       => $found,
							data       => { trip_id => $journey->id },
							backend_id => $self->stations->get_backend_id(
								hafas => $opt{hafas}
							),
						);
					};
					if ($@) {
						$self->app->log->error(
							"Checkin($uid): INSERT failed: $@");
						$promise->reject( 'INSERT failed: ' . $@ );
						return;
					}

					my $polyline;
					if ( $journey->polyline ) {
						my @station_list;
						my @coordinate_list;
						for my $coord ( $journey->polyline ) {
							if ( $coord->{name} ) {
								push(
									@coordinate_list,
									[
										$coord->{lon}, $coord->{lat},
										$coord->{eva}
									]
								);
								push( @station_list, $coord->{name} );
							}
							else {
								push( @coordinate_list,
									[ $coord->{lon}, $coord->{lat} ] );
							}
						}

						# equal length → polyline only consists of straight
						# lines between stops. that's not helpful.
						if ( @station_list == @coordinate_list ) {
							$self->log->debug( 'Ignoring polyline for '
								  . $journey->line
								  . ' as it only consists of straight lines between stops.'
							);
						}
						else {
							$polyline = {
								from_eva => ( $journey->route )[0]->loc->eva,
								to_eva   => ( $journey->route )[-1]->loc->eva,
								coords   => \@coordinate_list,
							};
						}
					}

					if ($polyline) {
						$self->in_transit->set_polyline(
							uid      => $uid,
							db       => $db,
							polyline => $polyline,
						);
					}

					# mustn't be called during a transaction
					if ( not $opt{in_transaction} ) {
						$self->run_hook( $uid, 'checkin' );
						if ( $opt{hafas} eq 'DB' and $journey->class <= 16 ) {
							$self->add_wagonorder(
								uid          => $uid,
								train_id     => $journey->id,
								is_departure => 1,
								eva          => $found->loc->eva,
								datetime     => $found->sched_dep,
								train_type   => $journey->type,
								train_no     => $journey->number
							);
							$self->add_stationinfo( $uid, 1, $journey->id,
								$found->loc->eva );
						}
					}

					$promise->resolve($journey);
				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->reject($err);
					return;
				}
			)->wait;

			return $promise;
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

				# users may force checkouts at stations that are not part of
				# the train's scheduled (or real-time) route. re-adding those
				# to in-transit violates the assumption that each train has
				# a valid destination. Remove the target in this case.
				my $route = JSON->new->decode( $journey->{route} );
				my $found_checkout_id;
				for my $stop ( @{$route} ) {
					if ( $stop->[1] == $journey->{checkout_station_id} ) {
						$found_checkout_id = 1;
						last;
					}
				}
				if ( not $found_checkout_id ) {
					$journey->{checkout_station_id} = undef;
					$journey->{checkout_time}       = undef;
					$journey->{arr_platform}        = undef;
					$journey->{sched_arrival}       = undef;
					$journey->{real_arrival}        = undef;
				}

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
		'checkout_p' => sub {
			my ( $self, %opt ) = @_;

			my $station      = $opt{station};
			my $dep_eva      = $opt{dep_eva};
			my $arr_eva      = $opt{arr_eva};
			my $with_related = $opt{with_related} // 0;
			my $force        = $opt{force};
			my $uid          = $opt{uid} // $self->current_user->{id};
			my $db           = $opt{db}  // $self->pg->db;
			my $user         = $self->get_user_status( $uid, $db );
			my $train_id     = $user->{train_id};
			my $hafas        = $opt{hafas};

			my $promise = Mojo::Promise->new;

			if ( not $station ) {
				$self->app->log->error("Checkout($uid): station is empty");
				return $promise->resolve( 1,
					'BUG: Checkout station is empty.' );
			}

			if ( not $user->{checked_in} and not $user->{cancelled} ) {
				return $promise->resolve( 0, 'You are not checked in' );
			}

			if ( $dep_eva and $dep_eva != $user->{dep_eva} ) {
				return $promise->resolve( 0, 'race condition' );
			}
			if ( $arr_eva and $arr_eva != $user->{arr_eva} ) {
				return $promise->resolve( 0, 'race condition' );
			}

			if (   $user->{is_dbris}
				or $user->{is_efa}
				or $user->{is_hafas}
				or $user->{is_motis} )
			{
				return $self->_checkout_journey_p(%opt);
			}

			my $now     = DateTime->now( time_zone => 'Europe/Berlin' );
			my $journey = $self->in_transit->get(
				uid       => $uid,
				with_data => 1
			);

			$self->iris->get_departures_p(
				station      => $station,
				lookbehind   => 120,
				lookahead    => 180,
				with_related => $with_related,
			)->then(
				sub {
					my ($status) = @_;

					my $new_checkout_station_id = $status->{station_eva};

					# Store the intended checkout station regardless of this operation's
					# success.
					# TODO for with_related == 1, the correct EVA may be different
					# and should be fetched from $train later on
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

					# Note that a train may pass the same station several times.
					# Notable example: S41 / S42 ("Ringbahn") both starts and
					# terminates at Berlin Südkreuz
					my $train = List::Util::first {
						$_->train_id eq $train_id
						  and $_->sched_arrival
						  and $_->sched_arrival->epoch
						  > $user->{sched_departure}->epoch
					}
					@{ $status->{results} };

					$train //= List::Util::first { $_->train_id eq $train_id }
					@{ $status->{results} };

					if ( not defined $train ) {

						# Arrival time via IRIS is unknown, so the train probably
						# has not arrived yet. Fall back to HAFAS.
						# TODO support cases where $station is EVA or DS100 code
						if (
							my $station_data
							= List::Util::first { $_->[0] eq $station }
							@{ $journey->{route} }
						  )
						{
							$station_data = $station_data->[2];
							if ( $station_data->{sched_arr} ) {
								my $sched_arr
								  = epoch_to_dt( $station_data->{sched_arr} );
								my $rt_arr
								  = epoch_to_dt( $station_data->{rt_arr} );
								if ( $rt_arr->epoch == 0 ) {
									$rt_arr = $sched_arr->clone;
									if (    $station_data->{arr_delay}
										and $station_data->{arr_delay}
										=~ m{^\d+$} )
									{
										$rt_arr->add( minutes =>
											  $station_data->{arr_delay} );
									}
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
							$promise->resolve( 1, undef );
							return;
						}
					}
					my $has_arrived = 0;

					eval {

						my $tx;
						if ( not $opt{in_transaction} ) {
							$tx = $db->begin;
						}

						if (    defined $train
							and not $train->arrival
							and not $force )
						{
							my $train_no = $train->train_no;
							die("Train ${train_no} has no arrival timestamp\n");
						}
						elsif ( defined $train and $train->arrival ) {
							$self->in_transit->set_arrival(
								uid   => $uid,
								db    => $db,
								train => $train,
							);

							$has_arrived
							  = $train->arrival->epoch < $now->epoch ? 1 : 0;
							if ($has_arrived) {
								my @unknown_stations
								  = $self->stations->grep_unknown(
									$train->route );
								if (@unknown_stations) {
									$self->app->log->warn(
										sprintf(
'IRIS: Route of %s %s (%s -> %s) contains unknown stations: %s',
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
								=~ m{ ^ (?<year> \d{4} ) - (?<month> \d{2} ) }x
							  )
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
						elsif ( defined $train
							and $train->arrival_is_cancelled )
						{

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
						$promise->resolve( 1, 'Checkout error: ' . $@ );
						return;
					}

					if ( $has_arrived or $force ) {
						if ( not $opt{in_transaction} ) {
							$self->run_hook( $uid, 'checkout' );
						}
						$promise->resolve( 0, undef );
						return;
					}
					if ( not $opt{in_transaction} ) {
						$self->run_hook( $uid, 'update' );
						$self->add_route_timestamps( $uid, $train, 0, 1 );
						$self->add_wagonorder(
							uid        => $uid,
							train_id   => $train->train_id,
							is_arrival => 1,
							eva        => $new_checkout_station_id,
							datetime   => $train->sched_departure,
							train_type => $train->type,
							train_no   => $train->train_no
						);
						$self->add_stationinfo( $uid, 0, $train->train_id,
							$dep_eva, $new_checkout_station_id );
					}
					$promise->resolve( 1, undef );
					return;

				}
			)->catch(
				sub {
					my ($err) = @_;
					$promise->resolve( 1, $err );
					return;
				}
			)->wait;

			return $promise;
		}
	);

	$self->helper(
		'_checkout_journey_p' => sub {
			my ( $self, %opt ) = @_;

			my $station = $opt{station};
			my $force   = $opt{force};
			my $uid     = $opt{uid} // $self->current_user->{id};
			my $db      = $opt{db}  // $self->pg->db;

			my $promise = Mojo::Promise->new;

			my $now     = DateTime->now( time_zone => 'Europe/Berlin' );
			my $journey = $self->in_transit->get(
				uid             => $uid,
				db              => $db,
				with_data       => 1,
				with_timestamps => 1,
				with_visibility => 1,
				postprocess     => 1,
			);

			# with_visibility needed due to postprocess

			my $found;
			my $has_arrived;
			for my $stop ( @{ $journey->{route_after} } ) {
				if ( $station eq $stop->[0] or $station eq $stop->[1] ) {
					$found = $stop;
					$self->in_transit->set_arrival_eva(
						uid         => $uid,
						db          => $db,
						arrival_eva => $stop->[1],
					);
					if ( defined $journey->{checkout_station_id}
						and $journey->{checkout_station_id} != $stop->{eva} )
					{
						$self->in_transit->unset_arrival_data(
							uid => $uid,
							db  => $db
						);
					}
					$self->in_transit->set_arrival_times(
						uid           => $uid,
						db            => $db,
						sched_arrival => $stop->[2]{sched_arr},
						rt_arrival    =>
						  ( $stop->[2]{rt_arr} || $stop->[2]{sched_arr} )
					);
					if (
						$now > ( $stop->[2]{rt_arr} || $stop->[2]{sched_arr} ) )
					{
						$has_arrived = 1;
					}
					last;
				}
			}
			if ( not $found and not $force ) {
				return $promise->resolve( 1, 'station not found in route' );
			}

			eval {
				my $tx;
				if ( not $opt{in_transaction} ) {
					$tx = $db->begin;
				}

				if ( $has_arrived or $force ) {
					$journey = $self->in_transit->get(
						uid => $uid,
						db  => $db
					);
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
				elsif ( $found and $found->[2]{isCancelled} ) {
					$journey = $self->in_transit->get(
						uid => $uid,
						db  => $db
					);
					$journey->{cancelled} = 1;
					$self->journeys->add_from_in_transit(
						db      => $db,
						journey => $journey
					);
					$self->in_transit->set_cancelled_destination(
						uid                   => $uid,
						db                    => $db,
						cancelled_destination => $found->[0],
					);
				}

				if ($tx) {
					$tx->commit;
				}
			};

			if ($@) {
				$self->app->log->error("Checkout($uid): $@");
				return $promise->resolve( 1, 'Checkout error: ' . $@ );
			}

			if ( $has_arrived or $force ) {
				if ( not $opt{in_transaction} ) {
					$self->run_hook( $uid, 'checkout' );
				}
				return $promise->resolve( 0, undef );
			}
			if ( not $opt{in_transaction} ) {
				$self->run_hook( $uid, 'update' );
			}
			return $promise->resolve( 1, undef );
		}
	);

	# This helper should only be called directly when also providing a user ID.
	# If you don't have one, use current_user() instead (get_user_data will
	# delegate to it anyways).
	$self->helper(
		'get_user_data' => sub {
			my ( $self, $uid ) = @_;

			$uid //= $self->current_user->{id};

			return $self->users->get( uid => $uid );
		}
	);

	$self->helper(
		'run_hook' => sub {
			my ( $self, $uid, $reason, $callback ) = @_;

			my $hook = $self->users->get_webhook( uid => $uid );

			if ( not $hook->{enabled} or not $hook->{url} =~ m{^ https?:// }x )
			{
				if ($callback) {
					&$callback();
				}
				return;
			}

			my $status    = $self->get_user_status_json_v1( uid => $uid );
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
						$self->users->update_webhook_status(
							uid     => $uid,
							url     => $hook->{url},
							success => 0,
							text    => "HTTP $err->{code} $err->{message}"
						);
					}
					else {
						$self->users->update_webhook_status(
							uid     => $uid,
							url     => $hook->{url},
							success => 1,
							text    => $tx->result->body
						);
					}
					if ($callback) {
						&$callback();
					}
					return;
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->users->update_webhook_status(
						uid     => $uid,
						url     => $hook->{url},
						success => 0,
						text    => $err
					);
					if ($callback) {
						&$callback();
					}
					return;
				}
			)->wait;
		}
	);

	$self->helper(
		'add_wagonorder' => sub {
			my ( $self, %opt ) = @_;

			my $uid        = $opt{uid};
			my $train_id   = $opt{train_id};
			my $train_type = $opt{train_type};
			my $train_no   = $opt{train_no};
			my $eva        = $opt{eva};
			my $datetime   = $opt{datetime};

			$uid //= $self->current_user->{id};

			my $db = $self->pg->db;

			if ( $datetime and $train_no ) {
				$self->dbdb->has_wagonorder_p(%opt)->then(
					sub {
						return $self->dbdb->get_wagonorder_p(%opt);
					}
				)->then(
					sub {
						my ($wagonorder) = @_;

						my $data      = {};
						my $user_data = {};

						my $wr;
						eval {
							$wr
							  = Travel::Status::DE::DBRIS::Formation->new(
								json => $wagonorder );
						};

						if (    $opt{is_departure}
							and $wr
							and not exists $wagonorder->{error} )
						{
							my $dt
							  = $opt{datetime}->clone->set_time_zone('UTC');
							$data->{wagonorder_dep}   = $wagonorder;
							$data->{wagonorder_param} = {
								time      => $dt->rfc3339 =~ s{(?=Z)}{.000}r,
								number    => $opt{train_no},
								evaNumber => $opt{eva},
								administrationId => 80,
								date             => $dt->strftime('%Y-%m-%d'),
								category         => $opt{train_type},
							};
							$user_data->{wagongroups} = [];
							for my $group ( $wr->groups ) {
								my @wagons;
								for my $wagon ( $group->carriages ) {
									push(
										@wagons,
										{
											id     => $wagon->uic_id,
											number => $wagon->number,
											type   => $wagon->type,
										}
									);
								}
								push(
									@{ $user_data->{wagongroups} },
									{
										name        => $group->name,
										desc        => $group->desc_short,
										description => $group->description,
										designation => $group->designation,
										to          => $group->destination,
										type        => $group->train_type,
										no          => $group->train_no,
										wagons      => [@wagons],
									}
								);
								if (    $group->{name}
									and $group->{name} eq 'ICE0304' )
								{
									$data->{wagonorder_pride} = 1;
								}
							}
							$self->in_transit->update_data(
								uid      => $uid,
								db       => $db,
								data     => $data,
								train_id => $train_id,
							);
							$self->in_transit->update_user_data(
								uid       => $uid,
								db        => $db,
								user_data => $user_data,
								train_id  => $train_id,
							);
						}
						elsif ( $opt{is_arrival}
							and not exists $wagonorder->{error} )
						{
							$data->{wagonorder_arr} = $wagonorder;
							$self->in_transit->update_data(
								uid      => $uid,
								db       => $db,
								data     => $data,
								train_id => $train_id,
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
		}
	);

	# This helper is only ever called from an IRIS context.
	# HAFAS already has all relevant information.
	$self->helper(
		'add_route_timestamps' => sub {
			my ( $self, $uid, $train, $is_departure, $update_polyline ) = @_;

			$uid //= $self->current_user->{id};

			my $db = $self->pg->db;

			# TODO "with_timestamps" is misleading, there are more differences between in_transit and in_transit_str
			# Here it's only needed because of dep_eva / arr_eva names
			my $in_transit = $self->in_transit->get(
				db              => $db,
				uid             => $uid,
				with_data       => 1,
				with_timestamps => 1
			);

			if ( not $in_transit ) {
				return;
			}

			my $route    = $in_transit->{route};
			my $train_id = $train->train_id;

			my $tripid_promise;

			if ( $in_transit->{data}{trip_id} ) {
				$tripid_promise
				  = Mojo::Promise->resolve( $in_transit->{data}{trip_id} );
			}
			else {
				$tripid_promise = $self->hafas->get_tripid_p( train => $train );
			}

			$tripid_promise->then(
				sub {
					my ($trip_id) = @_;

					if ( not $in_transit->{extra_data}{trip_id} ) {
						$self->in_transit->update_data(
							uid      => $uid,
							db       => $db,
							data     => { trip_id => $trip_id },
							train_id => $train_id,
						);
					}

					return $self->hafas->get_route_p(
						train         => $train,
						trip_id       => $trip_id,
						with_polyline => (
							$update_polyline
							  or not $in_transit->{polyline}
						) ? 1 : 0,
					);
				}
			)->then(
				sub {
					my ( $new_route, $journey, $polyline ) = @_;
					my $db_route;

					for my $stop ( $journey->route ) {
						$self->stations->add_or_update(
							stop => $stop,
							db   => $db,
							iris => 1,
						);
					}

					for my $i ( 0 .. $#{$new_route} ) {
						my $old_name  = $route->[$i][0];
						my $old_eva   = $route->[$i][1];
						my $old_entry = $route->[$i][2];
						my $new_name  = $new_route->[$i]->{name};
						my $new_eva   = $new_route->[$i]->{eva};
						my $new_entry = $new_route->[$i];

						if ( defined $old_name and $old_name eq $new_name ) {
							if ( $old_entry->{rt_arr}
								and not $new_entry->{rt_arr} )
							{
								$new_entry->{rt_arr} = $old_entry->{rt_arr};
								$new_entry->{arr_delay}
								  = $old_entry->{arr_delay};
							}
							if ( $old_entry->{rt_dep}
								and not $new_entry->{rt_dep} )
							{
								$new_entry->{rt_dep} = $old_entry->{rt_dep};
								$new_entry->{dep_delay}
								  = $old_entry->{dep_delay};
							}
						}

						push(
							@{$db_route},
							[
								$new_name,
								$new_eva,
								{
									sched_arr    => $new_entry->{sched_arr},
									rt_arr       => $new_entry->{rt_arr},
									arr_delay    => $new_entry->{arr_delay},
									sched_dep    => $new_entry->{sched_dep},
									rt_dep       => $new_entry->{rt_dep},
									dep_delay    => $new_entry->{dep_delay},
									tz_offset    => $new_entry->{tz_offset},
									isAdditional => $new_entry->{isAdditional},
									isCancelled  => $new_entry->{isCancelled},
									load         => $new_entry->{load},
									lat          => $new_entry->{lat},
									lon          => $new_entry->{lon},
								}
							]
						);
					}

					my @messages;
					for my $m ( $journey->messages ) {
						if ( not $m->code ) {
							push(
								@messages,
								{
									header => $m->short,
									lead   => $m->text,
								}
							);
						}
					}

					$self->in_transit->set_route_data(
						uid            => $uid,
						db             => $db,
						route          => $db_route,
						delay_messages => [
							map { [ $_->[0]->epoch, $_->[1] ] }
							  $train->delay_messages
						],
						qos_messages => [
							map { [ $_->[0]->epoch, $_->[1] ] }
							  $train->qos_messages
						],
						him_messages => \@messages,
						train_id     => $train_id,
					);

					if ($polyline) {
						$self->in_transit->set_polyline(
							uid      => $uid,
							db       => $db,
							polyline => $polyline,
							old_id   => $in_transit->{polyline_id},
							train_id => $train_id,
						);
					}

					return;
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->app->log->debug("add_route_timestamps: $err");
					return;
				}
			)->wait;
		}
	);

	$self->helper(
		'add_stationinfo' => sub {
			my ( $self, $uid, $is_departure, $train_id, $dep_eva, $arr_eva )
			  = @_;

			$uid //= $self->current_user->{id};

			my $db = $self->pg->db;
			if ($is_departure) {
				$self->dbdb->get_stationinfo_p($dep_eva)->then(
					sub {
						my ($station_info) = @_;
						my $data = { stationinfo_dep => $station_info };

						$self->in_transit->update_data(
							uid      => $uid,
							db       => $db,
							data     => $data,
							train_id => $train_id,
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

			if ( $arr_eva and not $is_departure ) {
				$self->dbdb->get_stationinfo_p($arr_eva)->then(
					sub {
						my ($station_info) = @_;
						my $data = { stationinfo_arr => $station_info };

						$self->in_transit->update_data(
							uid      => $uid,
							db       => $db,
							data     => $data,
							train_id => $train_id,
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
		'resolve_sb_template' => sub {
			my ( $self, $template, %opt ) = @_;
			my $ret  = $template;
			my $name = $opt{name} =~ s{/}{%2F}gr;
			$ret =~ s{[{]eva[}]}{$opt{eva}}g;
			$ret =~ s{[{]name[}]}{$name}g;
			$ret =~ s{[{]tt[}]}{$opt{tt}}g;
			$ret =~ s{[{]tn[}]}{$opt{tn}}g;
			$ret =~ s{[{]id[}]}{$opt{id}}g;
			$ret =~ s{[{]dbris[}]}{$opt{dbris}}g;
			$ret =~ s{[{]hafas[}]}{$opt{hafas}}g;

			if ( $opt{id} and not $opt{is_iris} ) {
				$ret =~ s{[{]id_or_tttn[}]}{$opt{id}}g;
			}
			else {
				$ret =~ s{[{]id_or_tttn[}]}{$opt{tt}$opt{tn}}g;
			}
			return $ret;
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
					  = Travel::Status::DE::DBRIS::Formation->new(
						json => $wagonorder );
				};
				if (    $wr
					and $wr->sectors
					and defined $wr->direction )
				{
					my $section_0 = ( $wr->sectors )[0];
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

				my $sa = $station->[2]{sched_arr};
				my $ra = $station->[2]{rt_arr} || $station->[2]{sched_arr};
				my $sd = $station->[2]{sched_dep};
				my $rd = $station->[2]{rt_dep} || $station->[2]{sched_dep};

				$station_desc .= $sa ? $sa->strftime(';%s') : ';0';
				$station_desc .= $ra ? $ra->strftime(';%s') : ';0';
				$station_desc .= $sd ? $sd->strftime(';%s') : ';0';
				$station_desc .= $rd ? $rd->strftime(';%s') : ';0';

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
				with_polyline   => 1,
				with_timestamps => 1,
				with_visibility => 1,
				postprocess     => 1,
			);

			if ($in_transit) {
				my $ret = $in_transit;

				my $traewelling = $self->traewelling->get(
					uid => $uid,
					db  => $db
				);
				if ( $traewelling->{latest_run}
					>= epoch_to_dt( $in_transit->{checkin_ts} ) )
				{
					$ret->{traewelling} = $traewelling;
					if ( @{ $traewelling->{data}{log} // [] }
						and ( my $log_entry = $traewelling->{data}{log}[0] ) )
					{
						if ( $log_entry->[2] ) {
							$ret->{traewelling_status} = $log_entry->[2];
							$ret->{traewelling_url}
							  = 'https://traewelling.de/status/'
							  . $log_entry->[2];
						}
						$ret->{traewelling_log_latest} = $log_entry->[1];
					}
				}

				my $stop_after_dep
				  = scalar @{ $ret->{route_after} }
				  ? $ret->{route_after}[0][0]
				  : undef;
				my $stop_before_dest;
				for my $i ( 1 .. $#{ $ret->{route_after} } ) {
					if (    $ret->{arr_name}
						and $ret->{route_after}[$i][0] eq $ret->{arr_name} )
					{
						$stop_before_dest = $ret->{route_after}[ $i - 1 ][0];
						last;
					}
				}

				my ($dep_platform_number)
				  = ( ( $ret->{dep_platform} // 0 ) =~ m{(\d+)} );
				if ( $dep_platform_number
					and
					exists $ret->{data}{stationinfo_dep}{$dep_platform_number} )
				{
					$ret->{dep_direction} = $self->stationinfo_to_direction(
						$ret->{data}{stationinfo_dep}{$dep_platform_number},
						$ret->{data}{wagonorder_dep},
						undef, $stop_after_dep
					);
				}

				my ($arr_platform_number)
				  = ( ( $ret->{arr_platform} // 0 ) =~ m{(\d+)} );
				if ( $arr_platform_number
					and
					exists $ret->{data}{stationinfo_arr}{$arr_platform_number} )
				{
					$ret->{arr_direction} = $self->stationinfo_to_direction(
						$ret->{data}{stationinfo_arr}{$arr_platform_number},
						$ret->{data}{wagonorder_arr},
						$stop_before_dest,
						undef
					);
				}

				if (    $ret->{departure_countdown} > 0
					and $in_transit->{data}{wagonorder_dep} )
				{
					my $wr;
					eval {
						$wr
						  = Travel::Status::DE::DBRIS::Formation->new(
							json => $in_transit->{data}{wagonorder_dep} );
					};
					if (    $wr
						and $wr->carriages
						and defined $wr->direction )
					{
						$ret->{wagonorder} = $wr;
					}
				}

				return $ret;
			}

			my ( $latest, $latest_cancellation ) = $self->journeys->get_latest(
				uid => $uid,
				db  => $db,
			);

			if ( $latest_cancellation and $latest_cancellation->{cancelled} ) {
				if (
					my $station = $self->stations->get_by_eva(
						$latest_cancellation->{dep_eva},
						backend_id => $latest_cancellation->{backend_id},
					)
				  )
				{
					$latest_cancellation->{dep_ds100} = $station->{ds100};
					$latest_cancellation->{dep_name}  = $station->{name};
				}
				if (
					my $station = $self->stations->get_by_eva(
						$latest_cancellation->{arr_eva},
						backend_id => $latest_cancellation->{backend_id},
					)
				  )
				{
					$latest_cancellation->{arr_ds100} = $station->{ds100};
					$latest_cancellation->{arr_name}  = $station->{name};
				}
			}
			else {
				$latest_cancellation = undef;
			}

			if ($latest) {
				my $ts          = $latest->{checkout_ts};
				my $action_time = epoch_to_dt($ts);
				if (
					my $station = $self->stations->get_by_eva(
						$latest->{dep_eva}, backend_id => $latest->{backend_id}
					)
				  )
				{
					$latest->{dep_ds100} = $station->{ds100};
					$latest->{dep_name}  = $station->{name};
				}
				if (
					my $station = $self->stations->get_by_eva(
						$latest->{arr_eva}, backend_id => $latest->{backend_id}
					)
				  )
				{
					$latest->{arr_ds100} = $station->{ds100};
					$latest->{arr_name}  = $station->{name};
				}
				return {
					checked_in      => 0,
					cancelled       => 0,
					cancellation    => $latest_cancellation,
					backend_id      => $latest->{backend_id},
					backend_name    => $latest->{backend_name},
					is_dbris        => $latest->{is_dbris},
					is_iris         => $latest->{is_iris},
					is_hafas        => $latest->{is_hafas},
					is_motis        => $latest->{is_motis},
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
					dep_external_id => $latest->{dep_external_id},
					dep_name        => $latest->{dep_name},
					dep_lat         => $latest->{dep_lat},
					dep_lon         => $latest->{dep_lon},
					dep_platform    => $latest->{dep_platform},
					sched_arrival   => epoch_to_dt( $latest->{sched_arr_ts} ),
					real_arrival    => epoch_to_dt( $latest->{real_arr_ts} ),
					arr_ds100       => $latest->{arr_ds100},
					arr_eva         => $latest->{arr_eva},
					arr_external_id => $latest->{arr_external_id},
					arr_name        => $latest->{arr_name},
					arr_lat         => $latest->{arr_lat},
					arr_lon         => $latest->{arr_lon},
					arr_platform    => $latest->{arr_platform},
					comment         => $latest->{user_data}{comment},
					visibility      => $latest->{visibility},
					visibility_str  => $latest->{visibility_str},
					effective_visibility     => $latest->{effective_visibility},
					effective_visibility_str =>
					  $latest->{effective_visibility_str},
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
			my ( $self, %opt ) = @_;
			my $uid     = $opt{uid};
			my $privacy = $opt{privacy}
			  // $self->users->get_privacy_by( uid => $uid );
			my $status = $opt{status} // $self->get_user_status($uid);

			my $ret = {
				deprecated => \0,
				checkedIn  => (
					     $status->{checked_in}
					  or $status->{cancelled}
				) ? \1 : \0,
				comment => $status->{comment},
				backend => {
					id => $status->{backend_id},
					type => $status->{is_dbris} ? 'DBRIS'
					: $status->{is_hafas} ? 'HAFAS'
					: $status->{is_motis} ? 'MOTIS'
					: 'IRIS-TTS',
					name => $status->{backend_name},
				},
				fromStation => {
					ds100         => $status->{dep_ds100},
					name          => $status->{dep_name},
					uic           => $status->{dep_eva},
					longitude     => $status->{dep_lon},
					latitude      => $status->{dep_lat},
					platform      => $status->{dep_platform},
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
					longitude     => $status->{arr_lon},
					latitude      => $status->{arr_lat},
					platform      => $status->{arr_platform},
					scheduledTime => $status->{sched_arrival}
					? $status->{sched_arrival}->epoch
					: undef,
					realTime => $status->{real_arrival}
					? $status->{real_arrival}->epoch
					: undef,
				},
				train => {
					type    => $status->{train_type},
					line    => $status->{train_line},
					no      => $status->{train_no},
					id      => $status->{train_id},
					hafasId => $status->{extra_data}{trip_id},
				},
				intermediateStops => [],
				visibility        => {
					level => $status->{effective_visibility},
					desc  => $status->{effective_visibility_str},
				}
			};

			if ( $opt{public} ) {
				if ( not $privacy->{comments_visible} ) {
					delete $ret->{comment};
				}
			}
			else {
				$ret->{actionTime}
				  = $status->{timestamp}
				  ? $status->{timestamp}->epoch
				  : undef;
			}

			for my $stop ( @{ $status->{route_after} // [] } ) {
				if ( $status->{arr_name} and $stop->[0] eq $status->{arr_name} )
				{
					last;
				}
				push(
					@{ $ret->{intermediateStops} },
					{
						name             => $stop->[0],
						scheduledArrival => $stop->[2]{sched_arr}
						? $stop->[2]{sched_arr}->epoch
						: undef,
						realArrival => $stop->[2]{rt_arr}
						? $stop->[2]{rt_arr}->epoch
						: undef,
						scheduledDeparture => $stop->[2]{sched_dep}
						? $stop->[2]{sched_dep}->epoch
						: undef,
						realDeparture => $stop->[2]{rt_dep}
						? $stop->[2]{rt_dep}->epoch
						: undef,
					}
				);
			}

			return $ret;
		}
	);

	$self->helper(
		'traewelling_to_travelynx_p' => sub {
			my ( $self, %opt ) = @_;
			my $traewelling = $opt{traewelling};
			my $user_data   = $opt{user_data};
			my $uid         = $user_data->{user_id};

			my $promise = Mojo::Promise->new;

			if ( not $traewelling->{checkin}
				or $self->now->epoch - $traewelling->{checkin}->epoch > 900 )
			{
				$self->log->debug("... not checked in");
				return $promise->resolve;
			}
			if (    $traewelling->{status_id}
				and $user_data->{data}{latest_pull_status_id}
				and $traewelling->{status_id}
				== $user_data->{data}{latest_pull_status_id} )
			{
				$self->log->debug("... already handled");
				return $promise->resolve;
			}
			$self->log->debug(
"... checked in : $traewelling->{dep_name} $traewelling->{dep_eva} -> $traewelling->{arr_name} $traewelling->{arr_eva}"
			);
			$self->users->mark_seen( uid => $uid );
			my $user_status = $self->get_user_status($uid);
			if ( $user_status->{checked_in} ) {
				$self->log->debug(
					"... also checked in via travelynx. aborting.");
				return $promise->resolve;
			}

			my $db = $self->pg->db;
			my $tx = $db->begin;

			$self->_checkin_dbris_p(
				station        => $traewelling->{dep_eva},
				train_id       => $traewelling->{trip_id},
				uid            => $uid,
				in_transaction => 1,
				db             => $db
			)->then(
				sub {
					$self->log->debug("... handled origin");
					return $self->_checkout_journey_p(
						station        => $traewelling->{arr_eva},
						train_id       => $traewelling->{trip_id},
						uid            => $uid,
						in_transaction => 1,
						db             => $db
					);
				}
			)->then(
				sub {
					my ( undef, $err ) = @_;
					if ($err) {
						$self->log->debug("... error: $err");
						return Mojo::Promise->reject($err);
					}
					$self->log->debug("... handled destination");
					if ( $traewelling->{message} ) {
						$self->in_transit->update_user_data(
							uid       => $uid,
							db        => $db,
							user_data => { comment => $traewelling->{message} }
						);
					}
					$self->traewelling->log(
						uid     => $uid,
						db      => $db,
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
					$promise->resolve;
					return;
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->log->debug("... error: $err");
					$self->traewelling->log(
						uid     => $uid,
						message =>
"Konnte $traewelling->{line} nach $traewelling->{arr_name} nicht übernehmen: $err",
						status_id => $traewelling->{status_id},
						is_error  => 1
					);
					$promise->resolve;
					return;
				}
			)->wait;
			return $promise;
		}
	);

	$self->helper(
		'journeys_to_map_data' => sub {
			my ( $self, %opt ) = @_;

			my @journeys       = @{ $opt{journeys} // [] };
			my $route_type     = $opt{route_type} // 'polybee';
			my $include_manual = $opt{include_manual} ? 1 : 0;

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

			my @stations = uniq_by { $_->{name} } map {
				{
					name   => $_->{to_name}   // $_->{arr_name},
					latlon => $_->{to_latlon} // $_->{arr_latlon},
				},
				  {
					name   => $_->{from_name}   // $_->{dep_name},
					latlon => $_->{from_latlon} // $_->{dep_latlon}
				  }
			} @journeys;

			my @station_coordinates
			  = map { [ $_->{latlon}, $_->{name} ] } @stations;

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
				my $from_eva = $journey->{from_eva} // $journey->{dep_eva};
				my $to_eva   = $journey->{to_eva}   // $journey->{arr_eva};

				my $from_index
				  = first_index { $_->[2] and $_->[2] == $from_eva } @polyline;
				my $to_index
				  = first_index { $_->[2] and $_->[2] == $to_eva } @polyline;

				# Work around inconsistencies caused by a multiple EVA IDs mapping to the same station name
				if ( $from_index == -1 ) {
					for my $entry ( @{ $journey->{route} // [] } ) {
						if ( $entry->[0] eq $journey->{from_name} ) {
							$from_eva = $entry->[1];
							$from_index
							  = first_index { $_->[2] and $_->[2] == $from_eva }
							@polyline;
							last;
						}
					}
				}

				if ( $to_index == -1 ) {
					for my $entry ( @{ $journey->{route} // [] } ) {
						if ( $entry->[0] eq $journey->{to_name} ) {
							$to_eva = $entry->[1];
							$to_index
							  = first_index { $_->[2] and $_->[2] == $to_eva }
							@polyline;
							last;
						}
					}
				}

				if (   $from_index == -1
					or $to_index == -1 )
				{
					# Fall back to route
					push( @beeline_journeys, $journey );
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

				if ( $from_index > $to_index ) {
					( $to_index, $from_index ) = ( $from_index, $to_index );
				}
				@polyline = @polyline[ $from_index .. $to_index ];
				my @polyline_coords;
				for my $coord (@polyline) {
					push( @polyline_coords, [ $coord->[1], $coord->[0] ] );
				}
				push( @polylines, [@polyline_coords] );
			}

			for my $journey (@beeline_journeys) {

				my @route = @{ $journey->{route} };

				my $from_index = first_index {
					(         $_->[1]
						  and $_->[1]
						  == ( $journey->{from_eva} // $journey->{dep_eva} ) )
					  or $_->[0] eq
					  ( $journey->{from_name} // $journey->{dep_name} )
				}
				@route;
				my $to_index = first_index {
					(         $_->[1]
						  and $_->[1]
						  == ( $journey->{to_eva} // $journey->{arr_eva} ) )
					  or $_->[0] eq
					  ( $journey->{to_name} // $journey->{arr_name} )
				}
				@route;

				if ( $from_index == -1 ) {
					my $rename = $self->app->renamed_station;
					$from_index = first_index {
						( $rename->{ $_->[0] } // $_->[0] ) eq
						  ( $journey->{from_name} // $journey->{dep_name} )
					}
					@route;
				}
				if ( $to_index == -1 ) {
					my $rename = $self->app->renamed_station;
					$to_index = first_index {
						( $rename->{ $_->[0] }  // $_->[0] ) eq
						  ( $journey->{to_name} // $journey->{arr_name} )
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
				if (    $journey->{edited}
					and $journey->{edited} & 0x0010
					and @route <= 2
					and not $include_manual )
				{
					push( @skipped_journeys,
						[ $journey, 'Manueller Eintrag ohne Unterwegshalte' ] );
					next;
				}

				@route = @route[ $from_index .. $to_index ];

				my $key = join( '|', map { $_->[0] } @route );

				if ( $seen{$key} ) {
					next;
				}

				$seen{$key} = 1;

				# direction does not matter at the moment
				$seen{ join( '|', reverse map { $_->[0] } @route ) } = 1;

				my $prev_station = shift @route;
				for my $station (@route) {
					push( @station_pairs, [ $prev_station, $station ] );
					$prev_station = $station;
				}
			}

			@station_pairs
			  = uniq_by { $_->[0][0] . '|' . $_->[1][0] } @station_pairs;
			@station_pairs
			  = grep { defined $_->[0][2]{lat} and defined $_->[1][2]{lat} }
			  @station_pairs;
			@station_pairs = map {
				[
					[ $_->[0][2]{lat}, $_->[0][2]{lon} ],
					[ $_->[1][2]{lat}, $_->[1][2]{lon} ]
				]
			} @station_pairs;

			my $ret = {
				skipped_journeys    => \@skipped_journeys,
				station_coordinates => \@station_coordinates,
				polyline_groups     => [
					{
						polylines => $json->encode( \@station_pairs ),
						color     => '#673ab7',
						opacity   => @polylines
						? $with_polyline
						      ? 0.4
						      : 0.6
						: 0.8,
					},
					{
						polylines => $json->encode( \@polylines ),
						color     => '#673ab7',
						opacity   => 0.8,
					}
				],
			};

			if (@station_coordinates) {
				my @lats    = map { $_->[0][0] } @station_coordinates;
				my @lons    = map { $_->[0][1] } @station_coordinates;
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
	$r->get('/tos')->to('static#tos');
	$r->get('/legend')->to('static#legend');
	$r->get('/offline.html')->to('static#offline');
	$r->get('/api/v1/:user_action/:token')->to('api#get_v1');
	$r->get('/login')->to('account#login_form');
	$r->get('/recover')->to('account#request_password_reset');
	$r->get('/recover/:id/:token')->to('account#recover_password');
	$r->get('/reg/:id/:token')->to('account#verify');
	$r->get( '/status/:name' => [ format => [ 'html', 'json' ] ] )
	  ->to( 'profile#user_status', format => undef );
	$r->get( '/status/:name/:ts' => [ format => [ 'html', 'json' ] ] )
	  ->to( 'profile#user_status', format => undef );
	$r->get('/ajax/status/#name')->to('profile#status_card');
	$r->get('/ajax/status/:name/:ts')->to('profile#status_card');
	$r->get( '/p/:name' => [ format => [ 'html', 'json' ] ] )
	  ->to( 'profile#profile', format => undef );
	$r->get( '/p/:name/j/:id' => 'public_journey' )
	  ->to('profile#journey_details');
	$r->get('/.well-known/webfinger')->to('account#webfinger');
	$r->get('/dyn/:av/autocomplete.js')->to('api#autocomplete');
	$r->post('/api/v1/import')->to('api#import_v1');
	$r->post('/api/v1/travel')->to('api#travel_v1');
	$r->post('/action')->to('traveling#travel_action');
	$r->post('/geolocation')->to('traveling#geolocation');
	$r->post('/list_departures')->to('traveling#redirect_to_station');
	$r->post('/login')->to('account#do_login');
	$r->post('/recover')->to('account#request_password_reset');

	if ( $self->config->{traewelling}{oauth} ) {
		$r->get('/oauth/traewelling')->to('traewelling#oauth');
		$r->post('/oauth/traewelling')->to('traewelling#oauth');
	}

	if ( not $self->config->{registration}{disabled} ) {
		$r->get('/register')->to('account#registration_form');
		$r->post('/register')->to('account#register');
	}

	my $authed_r = $r->under(
		sub {
			my ($self) = @_;
			if ( $self->is_user_authenticated ) {
				return 1;
			}
			$self->render(
				'login',
				redirect_to => $self->req->url,
				from        => 'auth_required'
			);
			return undef;
		}
	);

	$authed_r->get('/account')->to('account#account');
	$authed_r->get('/account/privacy')->to('account#privacy');
	$authed_r->get('/account/social')->to('account#social');
	$authed_r->get('/account/social/:kind')->to('account#social_list');
	$authed_r->get('/account/profile')->to('account#profile');
	$authed_r->get('/account/hooks')->to('account#webhook');
	$authed_r->get('/account/traewelling')->to('traewelling#settings');
	$authed_r->get('/account/insight')->to('account#insight');
	$authed_r->get('/ajax/status_card.html')->to('traveling#status_card');
	$authed_r->get( '/cancelled' => [ format => [ 'html', 'json' ] ] )
	  ->to( 'traveling#cancelled', format => undef );
	$authed_r->get('/fgr')->to('passengerrights#list_candidates');
	$authed_r->get('/account/password')->to('account#password_form');
	$authed_r->get('/account/mail')->to('account#change_mail');
	$authed_r->get('/account/name')->to('account#change_name');
	$authed_r->get('/account/select_backend')->to('account#backend_form');
	$authed_r->get('/export.json')->to('account#json_export');
	$authed_r->get('/history.json')->to('traveling#json_history');
	$authed_r->get('/history.csv')->to('traveling#csv_history');
	$authed_r->get('/history')->to('traveling#history');
	$authed_r->get('/history/commute')->to('traveling#commute');
	$authed_r->get('/history/map')->to('traveling#map_history');
	$authed_r->get('/history/:year')->to('traveling#yearly_history');
	$authed_r->get('/history/:year/review')->to('traveling#year_in_review');
	$authed_r->get('/history/:year/:month')->to('traveling#monthly_history');
	$authed_r->get('/journey/add')->to('traveling#add_journey_form');
	$authed_r->get('/journey/comment')->to('traveling#comment_form');
	$authed_r->get('/journey/visibility')->to('traveling#visibility_form');
	$authed_r->get('/journey/:id')->to('traveling#journey_details');
	$authed_r->get('/s/*station')->to('traveling#station');
	$authed_r->get('/confirm_mail/:token')->to('account#confirm_mail');
	$authed_r->post('/account/privacy')->to('account#privacy');
	$authed_r->post('/account/social')->to('account#social');
	$authed_r->post('/account/profile')->to('account#profile');
	$authed_r->post('/account/hooks')->to('account#webhook');
	$authed_r->post('/account/traewelling')->to('traewelling#settings');
	$authed_r->post('/account/insight')->to('account#insight');
	$authed_r->post('/account/select_backend')->to('account#change_backend');
	$authed_r->post('/journey/add')->to('traveling#add_journey_form');
	$authed_r->post('/journey/comment')->to('traveling#comment_form');
	$authed_r->post('/journey/visibility')->to('traveling#visibility_form');
	$authed_r->post('/journey/edit')->to('traveling#edit_journey');
	$authed_r->post('/journey/passenger_rights/*filename')
	  ->to('passengerrights#generate');
	$authed_r->post('/account/password')->to('account#change_password');
	$authed_r->post('/account/mail')->to('account#change_mail');
	$authed_r->post('/account/name')->to('account#change_name');
	$authed_r->post('/social-action')->to('account#social_action');
	$authed_r->post('/delete')->to('account#delete');
	$authed_r->post('/logout')->to('account#do_logout');
	$authed_r->post('/set_token')->to('api#set_token');
	$authed_r->get('/timeline/in-transit')->to('profile#checked_in');

}

1;
