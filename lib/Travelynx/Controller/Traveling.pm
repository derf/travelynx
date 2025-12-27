package Travelynx::Controller::Traveling;

# Copyright (C) 2020-2023 Birte Kristina Friesel
# Copyright (C) 2025 networkException <git@nwex.de>
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use GIS::Distance;
use List::Util      qw(uniq min max);
use List::UtilsBy   qw(max_by uniq_by);
use List::MoreUtils qw(first_index last_index);
use Mojo::UserAgent;
use Mojo::Promise;
use Text::CSV;
use Travel::Status::DE::IRIS::Stations;
use XML::LibXML;

# Internal Helpers

sub has_str_in_list {
	my ( $str, @strs ) = @_;
	if ( List::Util::any { $str eq $_ } @strs ) {
		return 1;
	}
	return;
}

sub compute_effective_visibility {
	my ( $self, $default_visibility, $journey_visibility ) = @_;
	if ( $journey_visibility eq 'default' ) {
		return $default_visibility;
	}
	return $journey_visibility;
}

# Controllers

sub homepage {
	my ($self) = @_;
	if ( $self->is_user_authenticated ) {
		my $user     = $self->current_user;
		my $uid      = $user->{id};
		my $status   = $self->get_user_status;
		my @timeline = $self->in_transit->get_timeline(
			uid   => $uid,
			short => 1
		);
		$self->stash( timeline => [@timeline] );
		my @recent_targets;
		if ( $status->{checked_in} ) {
			my $map_data = {};
			if ( $status->{arr_name} ) {
				$map_data = $self->journeys_to_map_data(
					journeys         => [$status],
					show_full_route  => 1,
					with_now_markers => 1,
				);
			}
			my $journey_visibility
			  = $self->compute_effective_visibility(
				$user->{default_visibility_str},
				$status->{visibility_str} );
			$self->render(
				'landingpage',
				user               => $user,
				user_status        => $status,
				journey_visibility => $journey_visibility,
				with_map           => 1,
				%{$map_data},
			);
			$self->users->mark_seen( uid => $uid );
			return;
		}
		else {
			@recent_targets = uniq_by { $_->{external_id_or_eva} }
			$self->journeys->get_latest_checkout_stations( uid => $uid );
		}
		$self->render(
			'landingpage',
			user              => $user,
			user_status       => $status,
			recent_targets    => \@recent_targets,
			with_autocomplete => 1,
			with_geolocation  => 1,
			backend_id        => $user->{backend_id},
		);
		$self->users->mark_seen( uid => $uid );
	}
	else {
		$self->render( 'landingpage', intro => 1 );
	}
}

sub status_card {
	my ($self) = @_;
	my $user   = $self->current_user;
	my $status = $self->get_user_status;
	my $uid    = $user->{id};

	delete $self->stash->{layout};

	my @timeline = $self->in_transit->get_timeline(
		uid   => $uid,
		short => 1
	);
	$self->stash( timeline => [@timeline] );

	if ( $status->{checked_in} ) {
		my $map_data = {};
		if ( $status->{arr_name} ) {
			$map_data = $self->journeys_to_map_data(
				journeys         => [$status],
				show_full_route  => 1,
				with_now_markers => 1,
			);
		}
		my $journey_visibility
		  = $self->compute_effective_visibility(
			$user->{default_visibility_str},
			$status->{visibility_str} );
		$self->render(
			'_checked_in',
			journey            => $status,
			journey_visibility => $journey_visibility,
			%{$map_data},
		);
	}
	elsif ( $status->{cancellation} ) {
		$self->render( '_cancelled_departure',
			journey => $status->{cancellation} );
	}
	else {
		$self->render( '_checked_out', journey => $status );
	}
}

sub geolocation {
	my ($self) = @_;

	my $lon        = $self->param('lon');
	my $lat        = $self->param('lat');
	my $backend_id = $self->param('backend') // 0;

	if ( not $lon or not $lat ) {
		$self->render(
			json => { error => "Invalid lon/lat (${lon}/${lat}) received" } );
		return;
	}

	if ( $backend_id !~ m{ ^ \d+ $ }x ) {
		$self->render(
			json => { error => "Invalid backend (${backend_id}) received" } );
		return;
	}

	my ( $dbris_service, $efa_service, $hafas_service, $motis_service );
	my $backend = $self->stations->get_backend( backend_id => $backend_id );
	if ( $backend->{dbris} ) {
		$dbris_service = $backend->{name};
	}
	if ( $backend->{efa} ) {
		$efa_service = $backend->{name};
	}
	elsif ( $backend->{hafas} ) {
		$hafas_service = $backend->{name};
	}
	elsif ( $backend->{motis} ) {
		$motis_service = $backend->{name};
	}

	if ($dbris_service) {
		$self->render_later;

		$self->dbris->geosearch_p(
			latitude  => $lat,
			longitude => $lon
		)->then(
			sub {
				my ($dbris) = @_;
				my @results = map {
					{
						name     => $_->name,
						eva      => $_->eva,
						distance => 0,
						dbris    => $dbris_service,
					}
				} uniq_by { $_->name } $dbris->results;
				if ( @results > 10 ) {
					@results = @results[ 0 .. 9 ];
				}
				$self->render(
					json => {
						candidates => [@results],
					}
				);
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					json => {
						candidates => [],
						error      => $err,
					},

					# The frontend JavaScript does not have an XHR error handler yet
					# (and if it did, I do not know whether it would have access to our JSON body).
					# So, for now, we do the bad thing™ and return HTTP 200 even though the request to the backend was not successful.
					# status => 502,
				);
			}
		)->wait;
		return;
	}
	elsif ($efa_service) {
		$self->render_later;

		Travel::Status::DE::EFA->new_p(
			promise    => 'Mojo::Promise',
			user_agent => Mojo::UserAgent->new,
			service    => $efa_service,
			coord      => {
				lat => $lat,
				lon => $lon
			}
		)->then(
			sub {
				my ($efa) = @_;
				my @results = map {
					{
						name     => $_->full_name,
						eva      => $_->id_code,
						distance => 0,
						efa      => $efa_service,
					}
				} $efa->results;
				if ( @results > 10 ) {
					@results = @results[ 0 .. 9 ];
				}
				$self->render(
					json => {
						candidates => [@results],
					}
				);
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					json => {
						candidates => [],
						error      => $err,
					},

					# See above
					# status => 502
				);
			}
		)->wait;
		return;
	}
	elsif ($hafas_service) {
		$self->render_later;

		my $agent = $self->ua;
		if ( my $proxy = $self->app->config->{hafas}{$hafas_service}{proxy} ) {
			$agent = Mojo::UserAgent->new;
			$agent->proxy->http($proxy);
			$agent->proxy->https($proxy);
		}

		Travel::Status::DE::HAFAS->new_p(
			promise    => 'Mojo::Promise',
			user_agent => $agent,
			service    => $hafas_service,
			geoSearch  => {
				lat => $lat,
				lon => $lon
			}
		)->then(
			sub {
				my ($hafas) = @_;
				my @hafas = map {
					{
						name     => $_->name,
						eva      => $_->eva,
						distance => $_->distance_m / 1000,
						hafas    => $hafas_service
					}
				} $hafas->results;
				if ( @hafas > 10 ) {
					@hafas = @hafas[ 0 .. 9 ];
				}
				$self->render(
					json => {
						candidates => [@hafas],
					}
				);
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					json => {
						candidates => [],
						error      => $err,
					},

					# See above
					#status => 502
				);
			}
		)->wait;

		return;
	}
	elsif ($motis_service) {
		$self->render_later;

		Travel::Status::MOTIS->new_p(
			promise    => 'Mojo::Promise',
			user_agent => $self->ua,
			time_zone  => 'Europe/Berlin',

			service             => $motis_service,
			stops_by_coordinate => {
				lat => $lat,
				lon => $lon
			}
		)->then(
			sub {
				my ($motis) = @_;
				my @motis = map {
					{
						id       => $_->id,
						name     => $_->name,
						distance => 0,
						motis    => $motis_service,
					}
				} $motis->results;

				if ( @motis > 10 ) {
					@motis = @motis[ 0 .. 9 ];
				}

				$self->render(
					json => {
						candidates => [@motis],
					}
				);
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					json => {
						candidates => [],
						error      => $err,
					},

					# See above
					#status => 502
				);
			}
		)->wait;

		return;
	}

	my @iris = map {
		{
			ds100    => $_->[0][0],
			name     => $_->[0][1],
			eva      => $_->[0][2],
			lon      => $_->[0][3],
			lat      => $_->[0][4],
			distance => $_->[1],
			hafas    => 0,
		}
	} Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
		$lat, 10 );
	@iris = uniq_by { $_->{name} } @iris;
	if ( @iris > 5 ) {
		@iris = @iris[ 0 .. 4 ];
	}
	$self->render(
		json => {
			candidates => [@iris],
		}
	);

}

sub travel_action {
	my ($self) = @_;
	my $params = $self->req->json;

	if ( not exists $params->{action} ) {
		$params = $self->req->params->to_hash;
	}

	if ( not $self->is_user_authenticated ) {

		# We deliberately do not set the HTTP status for these replies, as it
		# confuses jquery.
		$self->render(
			json => {
				success => 0,
				error   => 'Session error, please login again',
			},
		);
		return;
	}

	if ( not $params->{action} ) {
		$self->render(
			json => {
				success => 0,
				error   => 'Missing action value',
			},
		);
		return;
	}

	my $station = $params->{station};

	if ( $params->{action} eq 'checkin' ) {

		my $status = $self->get_user_status;
		my $promise;

		if (    $status->{checked_in}
			and $status->{arr_eva}
			and $status->{arrival_countdown} <= 0 )
		{
			$promise = $self->checkout_p( station => $status->{arr_eva} );
		}
		else {
			$promise = Mojo::Promise->resolve;
		}

		$self->render_later;
		$promise->then(
			sub {
				return $self->checkin_p(
					dbris        => $params->{dbris},
					efa          => $params->{efa},
					hafas        => $params->{hafas},
					motis        => $params->{motis},
					station      => $params->{station},
					train_id     => $params->{train},
					train_suffix => $params->{suffix},
					ts           => $params->{ts},
				);
			}
		)->then(
			sub {
				my $destination = $params->{dest};
				if ( not $destination ) {
					$self->render(
						json => {
							success     => 1,
							redirect_to => '/',
						},
					);
					return;
				}

				# Silently ignore errors -- if they are permanent, the user will see
				# them when selecting the destination manually.
				return $self->checkout_p(
					station => $destination,
					force   => 0
				);
			}
		)->then(
			sub {
				my ( $still_checked_in, undef ) = @_;
				if ( my $destination = $params->{dest} ) {
					my $station_link = '/s/' . $destination;
					if ( $status->{is_dbris} ) {
						$station_link .= '?dbris=' . $status->{backend_name};
					}
					elsif ( $status->{is_efa} ) {
						$station_link .= '?efa=' . $status->{backend_name};
					}
					elsif ( $status->{is_hafas} ) {
						$station_link .= '?hafas=' . $status->{backend_name};
					}
					$self->render(
						json => {
							success     => 1,
							redirect_to => $still_checked_in
							? '/'
							: $station_link,
						},
					);
				}
				return;
			}
		)->catch(
			sub {
				my ($error) = @_;
				$self->render(
					json => {
						success => 0,
						error   => $error,
					},
				);
			}
		)->wait;
	}
	elsif ( $params->{action} eq 'checkout' ) {
		$self->render_later;
		my $status = $self->get_user_status;
		$self->checkout_p(
			station => $params->{station},
			force   => $params->{force}
		)->then(
			sub {
				my ( $still_checked_in, $error ) = @_;
				my $station_link = '/s/' . $params->{station};
				if ( $status->{is_dbris} ) {
					$station_link .= '?dbris=' . $status->{backend_name};
				}
				elsif ( $status->{is_efa} ) {
					$station_link .= '?efa=' . $status->{backend_name};
				}
				elsif ( $status->{is_hafas} ) {
					$station_link .= '?hafas=' . $status->{backend_name};
				}

				if ($error) {
					$self->render(
						json => {
							success => 0,
							error   => $error,
						},
					);
				}
				else {
					$self->render(
						json => {
							success     => 1,
							redirect_to => $still_checked_in
							? '/'
							: $station_link,
						},
					);
				}
				return;
			}
		)->catch(
			sub {
				my ($error) = @_;
				$self->render(
					json => {
						success => 0,
						error   => $error,
					},
				);
				return;
			}
		)->wait;
	}
	elsif ( $params->{action} eq 'undo' ) {
		my $status = $self->get_user_status;
		my $error  = $self->undo( $params->{undo_id} );
		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			my $redir = '/';
			if ( $status->{checked_in} or $status->{cancelled} ) {
				if ( $status->{is_dbris} ) {
					$redir
					  = '/s/'
					  . $status->{dep_eva}
					  . '?dbris='
					  . $status->{backend_name};
				}
				elsif ( $status->{is_efa} ) {
					$redir
					  = '/s/'
					  . $status->{dep_eva} . '?efa='
					  . $status->{backend_name};
				}
				elsif ( $status->{is_hafas} ) {
					$redir
					  = '/s/'
					  . $status->{dep_eva}
					  . '?hafas='
					  . $status->{backend_name};
				}
				elsif ( $status->{is_motis} ) {
					$redir
					  = '/s/'
					  . $status->{dep_external_id}
					  . '?motis='
					  . $status->{backend_name};
				}
				else {
					$redir = '/s/' . $status->{dep_ds100};
				}
			}
			$self->render(
				json => {
					success     => 1,
					redirect_to => $redir,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_from' ) {
		$self->render_later;
		$self->checkin_p(
			dbris    => $params->{dbris},
			efa      => $params->{efa},
			hafas    => $params->{hafas},
			motis    => $params->{motis},
			station  => $params->{station},
			train_id => $params->{train},
			ts       => $params->{ts},
		)->then(
			sub {
				$self->render(
					json => {
						success     => 1,
						redirect_to => '/',
					},
				);
			}
		)->catch(
			sub {
				my ($error) = @_;
				$self->render(
					json => {
						success => 0,
						error   => $error,
					},
				);
			}
		)->wait;
	}
	elsif ( $params->{action} eq 'cancelled_to' ) {
		$self->render_later;
		$self->checkout_p(
			station => $params->{station},
			force   => 1
		)->then(
			sub {
				my ( undef, $error ) = @_;
				if ($error) {
					$self->render(
						json => {
							success => 0,
							error   => $error,
						},
					);
				}
				else {
					$self->render(
						json => {
							success     => 1,
							redirect_to => '/',
						},
					);
				}
				return;
			}
		)->catch(
			sub {
				my ($error) = @_;
				$self->render(
					json => {
						success => 0,
						error   => $error,
					},
				);
				return;
			}
		)->wait;
	}
	elsif ( $params->{action} eq 'delete' ) {
		my $error = $self->journeys->delete(
			uid      => $self->current_user->{id},
			id       => $params->{id},
			checkin  => $params->{checkin},
			checkout => $params->{checkout}
		);
		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success     => 1,
					redirect_to => '/history',
				},
			);
		}
	}
	else {
		$self->render(
			json => {
				success => 0,
				error   => 'invalid action value',
			},
		);
	}
}

sub station {
	my ($self)    = @_;
	my $station   = $self->stash('station');
	my $train     = $self->param('train');
	my $trip_id   = $self->param('trip_id');
	my $timestamp = $self->param('timestamp');
	my $user      = $self->current_user;
	my $uid       = $user->{id};

	my @timeline = $self->in_transit->get_timeline(
		uid   => $uid,
		short => 1
	);
	my %checkin_by_train;
	for my $checkin (@timeline) {
		push( @{ $checkin_by_train{ $checkin->{train_id} } }, $checkin );
	}
	$self->stash( checkin_by_train => \%checkin_by_train );

	$self->render_later;

	if ( $timestamp and $timestamp =~ m{ ^ \d+ $ }x ) {
		$timestamp = DateTime->from_epoch(
			epoch     => $timestamp,
			time_zone => 'Europe/Berlin'
		);
	}
	else {
		$timestamp = DateTime->now( time_zone => 'Europe/Berlin' );
	}

	my ( $dbris_service, $efa_service, $hafas_service, $motis_service );

	if ( $self->param('dbris') ) {
		$dbris_service = $self->param('dbris');
	}
	elsif ( $self->param('efa') ) {
		$efa_service = $self->param('efa');
	}
	elsif ( $self->param('hafas') ) {
		$hafas_service = $self->param('hafas');
	}
	elsif ( $self->param('motis') ) {
		$motis_service = $self->param('motis');
	}
	else {
		if ( $user->{backend_dbris} ) {
			$dbris_service = $user->{backend_name};
		}
		elsif ( $user->{backend_efa} ) {
			$efa_service = $user->{backend_name};
		}
		elsif ( $user->{backend_hafas} ) {
			$hafas_service = $user->{backend_name};
		}
		elsif ( $user->{backend_motis} ) {
			$motis_service = $user->{backend_name};
		}
	}

	my @suggestions;

	my $promise;
	if ($dbris_service) {
		if ( $station !~ m{ [@] L = \d+ }x ) {
			$self->render_later;
			$self->dbris->get_station_id_p($station)->then(
				sub {
					my ($dbris_station) = @_;
					$self->redirect_to( '/s/' . $dbris_station->{id} );
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->redirect_to('/');
				}
			)->wait;
			return;
		}
		$promise = $self->dbris->get_departures_p(
			station    => $station,
			timestamp  => $timestamp,
			lookbehind => 30,
		);
	}
	elsif ($efa_service) {
		$promise = $self->efa->get_departures_p(
			service    => $efa_service,
			name       => $station,
			timestamp  => $timestamp,
			lookbehind => 10,
			lookahead  => 50,
		);
	}
	elsif ($hafas_service) {
		$promise = $self->hafas->get_departures_p(
			service    => $hafas_service,
			eva        => $station,
			timestamp  => $timestamp,
			lookbehind => 30,
			lookahead  => 30,
		);
	}
	elsif ($motis_service) {
		if ( $station !~ m/.*_.*/ ) {
			$self->render_later;
			$self->motis->get_station_by_query_p(
				service => $motis_service,
				query   => $station,
			)->then(
				sub {
					my ($motis_station) = @_;
					$self->redirect_to( '/s/' . $motis_station->{id} );
				}
			)->catch(
				sub {
					my ($err) = @_;
					say "$err";

					$self->redirect_to('/');
				}
			)->wait;
			return;
		}
		$promise = $self->motis->get_departures_p(
			service    => $motis_service,
			station_id => $station,
			timestamp  => $timestamp,
			lookbehind => 30,
			lookahead  => 30,
		);
	}
	else {
		$promise = $self->iris->get_departures_p(
			station      => $station,
			lookbehind   => 120,
			lookahead    => 30,
			with_related => 1,
		);
	}
	$promise->then(
		sub {
			my ($status) = @_;
			my @results;

			my $now = $self->now->epoch;
			my $now_within_range
			  = abs( $timestamp->epoch - $now ) < 1800 ? 1 : 0;

			if ($dbris_service) {

				@results = map { $_->[0] }
				  sort { $b->[1] <=> $a->[1] }
				  map { [ $_, $_->dep->epoch ] } $status->results;

				$status = {
					station_eva      => $station,
					related_stations => [],
				};

				if ( $station =~ m{ [@] O = (?<name> [^@]+ ) [@] }x ) {
					$status->{station_name} = $+{name};
				}

				my ($eva) = ( $station =~ m{ [@] L = (\d+) }x );
				my $backend_id
				  = $self->stations->get_backend_id( dbris => $dbris_service );
				my @destinations = $self->journeys->get_connection_targets(
					uid        => $uid,
					backend_id => $backend_id,
					eva        => $eva
				);

				for my $dep (@results) {
					destination: for my $dest (@destinations) {
						if (    $dep->destination
							and $dep->destination eq $dest->{name} )
						{
							push( @suggestions, [ $dep, $dest ] );
							next destination;
						}
						for my $via_name ( $dep->via ) {
							if ( $via_name eq $dest->{name} ) {
								push( @suggestions, [ $dep, $dest ] );
								next destination;
							}
						}
					}
				}

				@suggestions = map { $_->[0] }
				  sort { $a->[1] <=> $b->[1] }
				  grep { $_->[1] >= $now - 300 }
				  map  { [ $_, $_->[0]->dep->epoch ] } @suggestions;
			}
			elsif ($hafas_service) {

				@results = map { $_->[0] }
				  sort { $b->[1] <=> $a->[1] }
				  map { [ $_, $_->datetime->epoch ] } $status->results;
				if ( $status->station->{eva} ) {
					$self->stations->add_meta(
						eva   => $status->station->{eva},
						meta  => $status->station->{evas} // [],
						hafas => $hafas_service,
					);
				}
				$status = {
					station_eva  => $status->station->{eva},
					station_name => (
						List::Util::reduce { length($a) < length($b) ? $a : $b }
						@{ $status->station->{names} }
					),
					related_stations => [],
				};
			}
			elsif ($efa_service) {
				@results = map { $_->[0] }
				  sort { $b->[1] <=> $a->[1] }
				  map { [ $_, $_->datetime->epoch ] } $status->results;
				my $backend_id
				  = $self->stations->get_backend_id( efa => $efa_service );
				my @destinations = $self->journeys->get_connection_targets(
					uid        => $uid,
					backend_id => $backend_id,
					eva        => $status->stop->id_num,
				);
				@suggestions = $self->efa->grep_suggestions(
					status       => $status,
					destinations => \@destinations
				);
				@suggestions = sort { $a->[0]{sort_ts} <=> $b->[0]{sort_ts} }
				  grep {
					      $_->[0]{sort_ts} >= $now - 300
					  and $_->[0]{sort_ts} <= $now + 1800
				  } @suggestions;

				$status = {
					station_eva      => $status->stop->id_num,
					station_name     => $status->stop->full_name,
					related_stations => [],
				};
			}
			elsif ($motis_service) {
				@results = map { $_->[0] }
				  sort { $b->[1] <=> $a->[1] }
				  map  { [ $_, $_->stopover->departure->epoch ] }
				  $status->results;

				$status = {
					station_eva  => $station,
					station_name =>
					  $status->{results}->[0]->stopover->stop->name,
					related_stations => [],
				};
			}
			else {

				# You can't check into a train which terminates here
				@results = grep { $_->departure } @{ $status->{results} };

				@results = map { $_->[0] }
				  sort { $b->[1] <=> $a->[1] }
				  map {
					[ $_, $_->departure->epoch // $_->sched_departure->epoch ]
				  } @results;

				my @destinations = $self->journeys->get_connection_targets(
					uid        => $uid,
					backend_id => 0,
					eva        => $status->{station_eva},
				);

				for my $dep (@results) {
					destination: for my $dest (@destinations) {
						for my $via_name ( $dep->route_post ) {
							if ( $via_name eq $dest->{name} ) {
								push( @suggestions, [ $dep, $dest ] );
								next destination;
							}
						}
					}
				}

				@suggestions = map { $_->[0] }
				  sort { $a->[1] <=> $b->[1] }
				  grep { $_->[1] >= $now - 300 }
				  map  { [ $_, $_->[0]->departure->epoch ] } @suggestions;
			}

			my $user_status = $self->get_user_status;

			my $can_check_out = 0;
			my ($eva) = ( $station =~ m{ [@] L = (\d+) }x );
			$eva //= $status->{station_eva};
			if ( $user_status->{checked_in} ) {
				for my $stop ( @{ $user_status->{route_after} } ) {
					if (
						$stop->[1] eq $eva
						or List::Util::any { $stop->[1] eq $_->{uic} }
						@{ $status->{related_stations} }
					  )
					{
						$can_check_out = 1;
						last;
					}
				}
			}

			if ( $trip_id and ( $dbris_service or $hafas_service ) ) {
				@results = grep { $_->id eq $trip_id } @results;
			}
			elsif ( $train and not $hafas_service ) {
				@results
				  = grep { $_->type . ' ' . $_->train_no eq $train } @results;
			}

			$self->render(
				'departures',
				user             => $user,
				dbris            => $dbris_service,
				efa              => $efa_service,
				hafas            => $hafas_service,
				motis            => $motis_service,
				eva              => $status->{station_eva},
				datetime         => $timestamp,
				now_in_range     => $now_within_range,
				results          => \@results,
				station          => $status->{station_name},
				related_stations => $status->{related_stations},
				user_status      => $user_status,
				can_check_out    => $can_check_out,
				suggestions      => \@suggestions,
				title            => "travelynx: $status->{station_name}",
			);
		}
	)->catch(
		sub {
			my ( $err, $status ) = @_;
			if ( $status and $status->{suggestions} ) {
				$self->render(
					'disambiguation',
					suggestions => $status->{suggestions},
					status      => 300,
				);
			}
			elsif ( $efa_service
				and $status
				and scalar $status->name_candidates )
			{
				$self->render(
					'disambiguation',
					suggestions => [
						map { { name => $_->name, eva => $_->id_num } }
						  $status->name_candidates
					],
					status => 300,
				);
			}
			elsif ( $hafas_service
				and $status
				and $status->errcode eq 'LOCATION' )
			{
				$self->hafas->search_location_p(
					service => $hafas_service,
					query   => $station
				)->then(
					sub {
						my ($hafas2) = @_;
						my @suggestions = $hafas2->results;
						if ( @suggestions == 1 ) {
							$self->redirect_to( '/s/'
								  . $suggestions[0]->eva
								  . '?hafas='
								  . $hafas_service );
						}
						else {
							$self->render(
								'disambiguation',
								suggestions => [
									map { { name => $_->name, eva => $_->eva } }
									  @suggestions
								],
								status => 300,
							);
						}
					}
				)->catch(
					sub {
						my ($err2) = @_;
						$self->render(
							'exception',
							exception =>
"locationSearch threw '$err2' when handling '$err'",
							status => 502
						);
					}
				)->wait;
			}
			elsif ( $err
				=~ m{svcRes|connection close|Service Temporarily Unavailable|Forbidden|HTTP 500 Internal Server Error|HTTP 429 Too Many Requests}
			  )
			{
				$self->render(
					'bad_gateway',
					message            => $err,
					status             => 502,
					select_new_backend => 1,
				);
			}
			elsif ( $err =~ m{timeout}i ) {
				$self->render(
					'gateway_timeout',
					message            => $err,
					status             => 504,
					select_new_backend => 1,
				);
			}
			else {
				$self->render(
					'exception',
					exception => $err,
					status    => 500
				);
			}
		}
	)->wait;
	$self->users->mark_seen( uid => $uid );
}

sub redirect_to_station {
	my ($self) = @_;
	my $station = $self->param('station');

	if ( $self->param('backend_dbris') ) {
		$self->render_later;
		$self->dbris->get_station_id_p($station)->then(
			sub {
				my ($dbris_station) = @_;
				$self->redirect_to( '/s/' . $dbris_station->{id} );
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->redirect_to('/');
			}
		)->wait;
	}
	elsif ( $self->param('backend_motis') ) {
		$self->render_later;
		$self->motis->get_station_by_query(
			service => $self->param('backend_motis'),
			query   => $station,
		)->then(
			sub {
				my ($motis_station) = @_;
				$self->redirect_to( '/s/' . $motis_station->{id} );
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->redirect_to('/');
			}
		)->wait;
	}
	else {
		$self->redirect_to("/s/${station}");
	}
}

sub cancelled {
	my ($self) = @_;
	my @journeys = $self->journeys->get(
		uid                 => $self->current_user->{id},
		cancelled           => 1,
		with_datetime       => 1,
		with_route_datetime => 1
	);

	$self->respond_to(
		json => { json => [@journeys] },
		any  => {
			template => 'cancelled',
			journeys => [@journeys]
		}
	);
}

sub history {
	my ($self) = @_;

	$self->render(
		template => 'history',
		title    => 'travelynx: History'
	);
}

sub commute {
	my ($self) = @_;

	my $year        = $self->param('year');
	my $filter_type = $self->param('filter_type') || 'exact';
	my $station     = $self->param('station');

	# DateTime is very slow when looking far into the future due to DST changes
	# -> Limit time range to avoid accidental DoS.
	if (
		not(    $year
			and $year =~ m{ ^ [0-9]{4} $ }x
			and $year > 1990
			and $year < 2100 )
	  )
	{
		$year = DateTime->now( time_zone => 'Europe/Berlin' )->year - 1;
	}
	my $interval_start = DateTime->new(
		time_zone => 'Europe/Berlin',
		year      => $year,
		month     => 1,
		day       => 1,
		hour      => 0,
		minute    => 0,
		second    => 0,
	);
	my $interval_end = $interval_start->clone->add( years => 1 );

	my @journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $interval_start,
		before        => $interval_end,
		with_datetime => 1,
	);

	if ( not $station ) {
		my %candidate_count;
		for my $journey (@journeys) {
			my $dep = $journey->{rt_departure};
			my $arr = $journey->{rt_arrival};
			if ( $arr->dow <= 5 and $arr->hour <= 12 ) {
				$candidate_count{ $journey->{to_name} }++;
			}
			elsif ( $dep->dow <= 5 and $dep->hour > 12 ) {
				$candidate_count{ $journey->{from_name} }++;
			}
			else {
				# Avoid selecting an intermediate station for multi-leg commutes.
				# Assumption: The intermediate station is also used for private
				# travels -> penalize stations which are used on weekends or at
				# unexpected times.
				$candidate_count{ $journey->{from_name} }--;
				$candidate_count{ $journey->{to_name} }--;
			}
		}
		$station = max_by { $candidate_count{$_} } keys %candidate_count;
	}

	my %journeys_by_month;
	my %count_by_month;
	my $total = 0;

	my $prev_doy = 0;
	for my $journey ( reverse @journeys ) {
		my $month = $journey->{rt_departure}->month;
		if (
			(
				$filter_type eq 'exact' and ( $journey->{to_name} eq $station
					or $journey->{from_name} eq $station )
			)
			or (
				$filter_type eq 'substring'
				and (  $journey->{to_name} =~ m{\Q$station\E}
					or $journey->{from_name} =~ m{\Q$station\E} )
			)
			or (
				$filter_type eq 'regex'
				and (  $journey->{to_name} =~ m{$station}
					or $journey->{from_name} =~ m{$station} )
			)
		  )
		{
			push( @{ $journeys_by_month{$month} }, $journey );

			my $doy = $journey->{rt_departure}->day_of_year;
			if ( $doy != $prev_doy ) {
				$count_by_month{$month}++;
				$total++;
			}

			$prev_doy = $doy;
		}
	}

	$self->param( year        => $year );
	$self->param( filter_type => $filter_type );
	$self->param( station     => $station );

	$self->render(
		template          => 'commute',
		with_autocomplete => 1,
		journeys_by_month => \%journeys_by_month,
		count_by_month    => \%count_by_month,
		total_journeys    => $total,
		title             => 'travelynx: Reisen nach Station',
		months            => [
			qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
		],
	);
}

sub map_history {
	my ($self) = @_;

	if ( not $self->param('route_type') ) {
		$self->param( route_type => 'polybee' );
	}

	my $route_type    = $self->param('route_type');
	my $filter_from   = $self->param('filter_from');
	my $filter_until  = $self->param('filter_to');
	my $filter_type   = $self->param('filter_type');
	my $with_polyline = $route_type eq 'beeline' ? 0 : 1;

	my $parser = DateTime::Format::Strptime->new(
		pattern   => '%F',
		locale    => 'de_DE',
		time_zone => 'Europe/Berlin'
	);

	if ($filter_from) {
		$filter_from = $parser->parse_datetime($filter_from);
	}
	else {
		$filter_from = undef;
	}

	if ($filter_until) {
		$filter_until = $parser->parse_datetime($filter_until)->set(
			hour   => 23,
			minute => 59,
			second => 58
		);
	}
	else {
		$filter_until = undef;
	}

	my $year;
	if (    $filter_from
		and $filter_from->day == 1
		and $filter_from->month == 1
		and $filter_until
		and $filter_until->day == 31
		and $filter_until->month == 12
		and $filter_from->year == $filter_until->year )
	{
		$year = $filter_from->year;
	}

	my @journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		with_polyline => $with_polyline,
		after         => $filter_from,
		before        => $filter_until,
	);

	if ($filter_type) {
		my @filter = split( qr{, *}, $filter_type );
		@journeys
		  = grep { has_str_in_list( $_->{type}, @filter ) } @journeys;
	}

	if ( not @journeys ) {
		$self->render(
			template            => 'history_map',
			with_map            => 1,
			skipped_journeys    => [],
			station_coordinates => [],
			polyline_groups     => [],
		);
		return;
	}

	my $include_manual = $self->param('include_manual') ? 1 : 0;

	my $res = $self->journeys_to_map_data(
		journeys       => \@journeys,
		route_type     => $route_type,
		include_manual => $include_manual
	);

	$self->render(
		template => 'history_map',
		year     => $year,
		with_map => 1,
		title    => 'travelynx: Karte',
		%{$res}
	);
}

sub json_history {
	my ($self) = @_;

	$self->render(
		json => [ $self->journeys->get( uid => $self->current_user->{id} ) ] );
}

sub csv_history {
	my ($self) = @_;

	my $csv = Text::CSV->new( { eol => "\r\n" } );
	my $buf = q{};

	$csv->combine(
		qw(type line number),
		'departure stop name',
		'departure stop id',
		'arrival stop name',
		'arrival stop id',
		'scheduled departure',
		'real-time departure',
		'scheduled arrival',
		'real-time arrival',
		'operator',
		'carriage type',
		'comment',
		'id'
	);
	$buf .= $csv->string;

	for my $journey (
		$self->journeys->get(
			uid           => $self->current_user->{id},
			with_datetime => 1
		)
	  )
	{
		if (
			$csv->combine(
				$journey->{type},
				$journey->{line},
				$journey->{no},
				$journey->{from_name},
				$journey->{from_eva},
				$journey->{to_name},
				$journey->{to_eva},
				$journey->{sched_departure}->strftime('%Y-%m-%d %H:%M:%S'),
				$journey->{rt_departure}->strftime('%Y-%m-%d %H:%M:%S'),
				$journey->{sched_arrival}->strftime('%Y-%m-%d %H:%M:%S'),
				$journey->{rt_arrival}->strftime('%Y-%m-%d %H:%M:%S'),
				$journey->{user_data}{operator} // q{},
				join( q{ + },
					map { $_->{desc} // $_->{name} }
					  @{ $journey->{user_data}{wagongroups} // [] } ),
				$journey->{user_data}{comment} // q{},
				$journey->{id}
			)
		  )
		{
			$buf .= $csv->string;
		}
	}

	$self->render(
		text   => $buf,
		format => 'csv'
	);
}

sub year_in_review {
	my ($self) = @_;
	my $year = $self->stash('year');
	my @journeys;

	# DateTime is very slow when looking far into the future due to DST changes
	# -> Limit time range to avoid accidental DoS.
	if ( not( $year =~ m{ ^ [0-9]{4} $ }x and $year > 1990 and $year < 2100 ) )
	{
		$self->render( 'not_found', status => 404 );
		return;
	}

	my $interval_start = DateTime->new(
		time_zone => 'Europe/Berlin',
		year      => $year,
		month     => 1,
		day       => 1,
		hour      => 0,
		minute    => 0,
		second    => 0,
	);
	my $interval_end = $interval_start->clone->add( years => 1 );
	@journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $interval_start,
		before        => $interval_end,
		with_datetime => 1
	);

	if ( not @journeys ) {
		$self->render(
			'not_found',
			message => 'Keine Fahrten im angefragten Jahr gefunden.',
			status  => 404
		);
		return;
	}

	my $now = $self->now;
	if (
		not( $year < $now->year or ( $now->month == 12 and $now->day == 31 ) ) )
	{
		$self->render(
			'not_found',
			message =>
'Der aktuelle Jahresrückblick wird erst zum Jahresende (am 31.12.) freigeschaltet',
			status => 404
		);
		return;
	}

	my ( $stats, $review ) = $self->journeys->get_stats(
		uid    => $self->current_user->{id},
		year   => $year,
		review => 1
	);

	$self->render(
		'year_in_review',
		title  => "travelynx: Jahresrückblick $year",
		year   => $year,
		stats  => $stats,
		review => $review,
	);

}

sub yearly_history {
	my ($self) = @_;
	my $year   = $self->stash('year');
	my $filter = $self->param('filter');
	my @journeys;

	# DateTime is very slow when looking far into the future due to DST changes
	# -> Limit time range to avoid accidental DoS.
	if ( not( $year =~ m{ ^ [0-9]{4} $ }x and $year > 1990 and $year < 2100 ) )
	{
		$self->render( 'not_found', status => 404 );
		return;
	}
	my $interval_start = DateTime->new(
		time_zone => 'Europe/Berlin',
		year      => $year,
		month     => 1,
		day       => 1,
		hour      => 0,
		minute    => 0,
		second    => 0,
	);
	my $interval_end = $interval_start->clone->add( years => 1 );
	@journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $interval_start,
		before        => $interval_end,
		with_datetime => 1
	);

	if ( $filter and $filter eq 'single' ) {
		@journeys = $self->journeys->grep_single(@journeys);
	}

	if ( not @journeys ) {
		$self->render(
			'not_found',
			status  => 404,
			message => 'Keine Fahrten im angefragten Jahr gefunden.'
		);
		return;
	}

	my $stats = $self->journeys->get_stats(
		uid  => $self->current_user->{id},
		year => $year
	);

	my $with_review;
	my $now = $self->now;
	if ( $year < $now->year or ( $now->month == 12 and $now->day == 31 ) ) {
		$with_review = 1;
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template    => 'history_by_year',
			title       => "travelynx: $year",
			journeys    => [@journeys],
			year        => $year,
			have_review => $with_review,
			statistics  => $stats
		}
	);

}

sub monthly_history {
	my ($self) = @_;
	my $year   = $self->stash('year');
	my $month  = $self->stash('month');
	my @journeys;
	my @months
	  = (
		qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
	  );

	if (
		not(    $year =~ m{ ^ [0-9]{4} $ }x
			and $year > 1990
			and $year < 2100
			and $month =~ m{ ^ [0-9]{1,2} $ }x
			and $month > 0
			and $month < 13 )
	  )
	{
		$self->render( 'not_found', status => 404 );
		return;
	}
	my $interval_start = DateTime->new(
		time_zone => 'Europe/Berlin',
		year      => $year,
		month     => $month,
		day       => 1,
		hour      => 0,
		minute    => 0,
		second    => 0,
	);
	my $interval_end = $interval_start->clone->add( months => 1 );
	@journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $interval_start,
		before        => $interval_end,
		with_datetime => 1
	);

	if ( not @journeys ) {
		$self->render(
			'not_found',
			message => 'Keine Fahrten im angefragten Monat gefunden.',
			status  => 404
		);
		return;
	}

	my $stats = $self->journeys->get_stats(
		uid   => $self->current_user->{id},
		year  => $year,
		month => $month
	);

	my $month_name = $months[ $month - 1 ];

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template    => 'history_by_month',
			title       => "travelynx: $month_name $year",
			journeys    => [@journeys],
			year        => $year,
			month       => $month,
			month_name  => $month_name,
			filter_from => $interval_start,
			filter_to   => $interval_end->clone->subtract( days => 1 ),
			statistics  => $stats
		}
	);

}

sub journey_details {
	my ($self) = @_;
	my $journey_id = $self->stash('id');

	my $user = $self->current_user;
	my $uid  = $user->{id};

	$self->param( journey_id => $journey_id );

	if ( not( $journey_id and $journey_id =~ m{ ^ \d+ $ }x ) ) {
		$self->respond_to(
			json => {
				json   => { error => 'not found' },
				status => 404
			},
			any => {
				template => 'journey',
				status   => 404,
				error    => 'notfound',
				journey  => {}
			}
		);
		return;
	}

	my $journey = $self->journeys->get_single(
		uid                 => $uid,
		journey_id          => $journey_id,
		verbose             => 1,
		with_datetime       => 1,
		with_route_datetime => 1,
		with_polyline       => 1,
		with_visibility     => 1,
	);

	if ($journey) {

		if ( $self->stash('polyline_export') ) {

			if ( not( $journey->{polyline} and @{ $journey->{polyline} } ) ) {
				$journey->{polyline}
				  = [ map { [ $_->[2]{lon}, $_->[2]{lat}, $_->[1] ] }
					  @{ $journey->{route} } ];
			}

			delete $self->stash->{layout};

			my $xml = $self->render_to_string(
				template => 'polyline',
				name     => sprintf( '%s %s: %s → %s',
					$journey->{type},      $journey->{no},
					$journey->{from_name}, $journey->{to_name} ),
				polyline => $journey->{polyline}
			);
			$self->respond_to(
				gpx => {
					text   => $xml,
					format => 'gpx'
				},
				json => {
					json => [
						map {
							$_->[2] ? [ $_->[0], $_->[1], int( $_->[2] ) ] : $_
						} @{ $journey->{polyline} }
					]
				},
			);
			return;
		}

		my $map_data = $self->journeys_to_map_data(
			journeys       => [$journey],
			include_manual => 1,
		);
		my $with_share;
		my $share_text;

		my $visibility
		  = $self->compute_effective_visibility(
			$user->{default_visibility_str},
			$journey->{visibility_str} );

		if (   $visibility eq 'public'
			or $visibility eq 'travelynx'
			or $visibility eq 'followers'
			or $visibility eq 'unlisted' )
		{
			my $delay = 'pünktlich ';
			if ( $journey->{rt_arrival} != $journey->{sched_arrival} ) {
				$delay = sprintf(
					'mit %+d ',
					(
						    $journey->{rt_arrival}->epoch
						  - $journey->{sched_arrival}->epoch
					) / 60
				);
			}
			$with_share = 1;
			$share_text
			  = $journey->{km_route}
			  ? sprintf( '%.0f km', $journey->{km_route} )
			  : 'Fahrt';
			$share_text .= sprintf( ' mit %s %s – Ankunft %sum %s',
				$journey->{type}, $journey->{no},
				$delay,           $journey->{rt_arrival}->strftime('%H:%M') );
		}

		$self->respond_to(
			json => { json => $journey },
			any  => {
				template => 'journey',
				title    => sprintf(
					'travelynx: Fahrt %s %s %s am %s',
					$journey->{type},
					$journey->{line} // '',
					$journey->{no},
					$journey->{sched_departure}->strftime('%d.%m.%Y um %H:%M')
				),
				error              => undef,
				journey            => $journey,
				journey_visibility => $visibility,
				with_map           => 1,
				with_share         => $with_share,
				share_text         => $share_text,
				%{$map_data},
			}
		);
	}
	else {
		$self->respond_to(
			json => {
				json   => { error => 'not found' },
				status => 404
			},
			any => {
				template => 'journey',
				status   => 404,
				error    => 'notfound',
				journey  => {}
			}
		);
	}

}

sub visibility_form {
	my ($self)     = @_;
	my $dep_ts     = $self->param('dep_ts');
	my $journey_id = $self->param('id');
	my $action     = $self->param('action') // 'none';
	my $user       = $self->current_user;
	my $user_level = $user->{default_visibility_str};
	my $uid        = $user->{id};
	my $status     = $self->get_user_status;
	my $visibility = $status->{visibility_str};
	my $journey;

	if ($journey_id) {
		$journey = $self->journeys->get_single(
			uid             => $uid,
			journey_id      => $journey_id,
			with_datetime   => 1,
			with_visibility => 1,
		);
		$visibility = $journey->{visibility_str};
	}

	if ( $action eq 'save' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'bad_request',
				csrf   => 1,
				status => 400
			);
		}
		elsif ( $dep_ts and $dep_ts != $status->{sched_departure}->epoch ) {
			$self->render(
				'edit_visibility',
				error      => 'old',
				user_level => $user_level,
				journey    => {}
			);
		}
		else {
			if ($dep_ts) {
				$self->in_transit->update_visibility(
					uid        => $uid,
					visibility => $self->param('status_level'),
				);
				$self->redirect_to('/');
				$self->run_hook( $uid, 'update' );
			}
			elsif ($journey_id) {
				$self->journeys->update_visibility(
					uid        => $uid,
					id         => $journey_id,
					visibility => $self->param('status_level'),
				);
				$self->redirect_to( '/journey/' . $journey_id );
			}
		}
		return;
	}

	$self->param( status_level => $visibility );

	if ($journey_id) {
		$self->render(
			'edit_visibility',
			error      => undef,
			user_level => $user_level,
			journey    => $journey
		);
	}
	elsif ( $status->{checked_in} ) {
		$self->param( dep_ts => $status->{sched_departure}->epoch );
		$self->render(
			'edit_visibility',
			error      => undef,
			user_level => $user_level,
			journey    => $status
		);
	}
	else {
		$self->render(
			'edit_visibility',
			error      => 'notfound',
			user_level => $user_level,
			journey    => {}
		);
	}
}

sub comment_form {
	my ($self) = @_;
	my $dep_ts = $self->param('dep_ts');
	my $status = $self->get_user_status;

	if ( not $status->{checked_in} ) {
		$self->render(
			'edit_comment',
			error   => 'notfound',
			journey => {}
		);
	}
	elsif ( not $dep_ts ) {
		$self->param( dep_ts  => $status->{sched_departure}->epoch );
		$self->param( comment => $status->{comment} );
		$self->render(
			'edit_comment',
			error   => undef,
			journey => $status
		);
	}
	elsif ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'edit_comment',
			error   => undef,
			journey => $status
		);
	}
	elsif ( $dep_ts != $status->{sched_departure}->epoch ) {

		# TODO find and update appropriate past journey (if it exists)
		$self->param( comment => $status->{comment} );
		$self->render(
			'edit_comment',
			error   => undef,
			journey => $status
		);
	}
	else {
		$self->app->log->debug("set comment");
		my $uid = $self->current_user->{id};
		$self->in_transit->update_user_data(
			uid       => $uid,
			user_data => { comment => $self->param('comment') }
		);
		$self->redirect_to('/');
		$self->run_hook( $uid, 'update' );
	}
}

sub edit_journey {
	my ($self)     = @_;
	my $journey_id = $self->param('journey_id');
	my $uid        = $self->current_user->{id};

	if ( not( $journey_id =~ m{ ^ \d+ $ }x ) ) {
		$self->render(
			'edit_journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->journeys->get_single(
		uid                 => $uid,
		journey_id          => $journey_id,
		verbose             => 1,
		with_datetime       => 1,
		with_route_datetime => 1,
	);

	if ( not $journey ) {
		$self->render(
			'edit_journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $error = undef;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser_sec = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M:%S',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);
		my $parser_min = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);

		my $db = $self->pg->db;
		my $tx = $db->begin;

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			my $datetime = $parser_sec->parse_datetime( $self->param($key) )
			  // $parser_min->parse_datetime( $self->param($key) );
			if ( $datetime and $datetime->epoch ne $journey->{$key}->epoch ) {
				$error = $self->journeys->update(
					uid  => $uid,
					db   => $db,
					id   => $journey->{id},
					$key => $datetime
				);
				if ($error) {
					last;
				}
			}
		}
		for my $key (qw(from_name to_name)) {
			if ( defined $self->param($key)
				and $self->param($key) ne $journey->{$key} )
			{
				$error = $self->journeys->update(
					uid  => $uid,
					db   => $db,
					id   => $journey->{id},
					$key => $self->param($key),
				);
				if ($error) {
					last;
				}
			}
		}
		for my $key (qw(comment)) {
			if (
				defined $self->param($key)
				and ( not $journey->{user_data}
					or $journey->{user_data}{$key} ne $self->param($key) )
			  )
			{
				$error = $self->journeys->update(
					uid  => $uid,
					db   => $db,
					id   => $journey->{id},
					$key => $self->param($key)
				);
				if ($error) {
					last;
				}
			}
		}
		if ( defined $self->param('route') ) {
			my @route_old = map { $_->[0] } @{ $journey->{route} };
			my @route_new = split( qr{\r?\n\r?}, $self->param('route') );
			@route_new = grep { $_ ne '' } @route_new;
			if ( join( '|', @route_old ) ne join( '|', @route_new ) ) {
				$error = $self->journeys->update(
					uid   => $uid,
					db    => $db,
					id    => $journey->{id},
					route => [@route_new]
				);
			}
		}
		{
			my $cancelled_old = $journey->{cancelled}     // 0;
			my $cancelled_new = $self->param('cancelled') // 0;
			if ( $cancelled_old != $cancelled_new ) {
				$error = $self->journeys->update(
					uid       => $uid,
					db        => $db,
					id        => $journey->{id},
					cancelled => $cancelled_new
				);
			}
		}

		if ( not $error ) {
			$journey = $self->journeys->get_single(
				uid                 => $uid,
				db                  => $db,
				journey_id          => $journey_id,
				verbose             => 1,
				with_datetime       => 1,
				with_route_datetime => 1,
			);
			$error = $self->journeys->sanity_check($journey);
		}
		if ( not $error ) {
			$tx->commit;
			$self->redirect_to("/journey/${journey_id}");
			return;
		}
	}

	for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival)) {
		if ( $journey->{$key} and $journey->{$key}->epoch ) {
			if ( $journey->{$key}->second ) {
				$self->param(
					$key => $journey->{$key}->strftime('%d.%m.%Y %H:%M:%S') );
			}
			else {
				$self->param(
					$key => $journey->{$key}->strftime('%d.%m.%Y %H:%M') );
			}
		}
	}

	$self->param(
		route => join( "\n", map { $_->[0] } @{ $journey->{route} } ) );

	$self->param( cancelled => $journey->{cancelled} ? 1 : 0 );
	$self->param( from_name => $journey->{from_name} );
	$self->param( to_name   => $journey->{to_name} );

	for my $key (qw(comment)) {
		if ( $journey->{user_data} and $journey->{user_data}{$key} ) {
			$self->param( $key => $journey->{user_data}{$key} );
		}
	}

	$self->render(
		'edit_journey',
		with_autocomplete => 1,
		backend_id        => $journey->{backend_id},
		error             => $error,
		journey           => $journey
	);
}

# Taken from Travel::Status::DE::EFA::Trip#polyline
sub polyline_add_stops {
	my ( $self, %opt ) = @_;

	my $polyline = $opt{polyline};
	my $route    = $opt{route};

	my $distance = GIS::Distance->new;

	my %min_dist;
	my $route_i = 0;
	for my $stop ( @{$route} ) {
		for my $polyline_index ( 0 .. $#{$polyline} ) {
			my $pl = $polyline->[$polyline_index];
			if ( not( defined $stop->[2]{lat} and defined $stop->[2]{lon} ) ) {
				my $err
				  = sprintf(
"Cannot match uploaded polyline with the  journey's route: route stop %s (ID %s) has no lat/lon\n",
					$stop->[0], $stop->[1] // 'unknown' );
				die($err);
			}
			my $dist
			  = $distance->distance_metal( $stop->[2]{lat}, $stop->[2]{lon},
				$pl->[1], $pl->[0] );
			my $key = $route_i . ';' . $stop->[1];
			if ( not $min_dist{$key}
				or $min_dist{$key}{dist} > $dist )
			{
				$min_dist{$key} = {
					dist  => $dist,
					index => $polyline_index,
				};
			}
		}
		$route_i += 1;
	}
	$route_i = 0;
	for my $stop ( @{$route} ) {
		my $key = $route_i . ';' . $stop->[1];
		if ( $min_dist{$key} ) {
			if ( defined $polyline->[ $min_dist{$key}{index} ][2] ) {
				return sprintf(
'Error: Route stops %d and %d both map to polyline lon/lat %f/%f. '
					  . 'The uploaded polyline must cover the following route stops: %s',
					$polyline->[ $min_dist{$key}{index} ][2],
					$stop->[1],
					$polyline->[ $min_dist{$key}{index} ][0],
					$polyline->[ $min_dist{$key}{index} ][1],
					join(
						q{ · },
						map {
							sprintf(
								'%s (ID %s) @ %f/%f',
								$_->[0],      $_->[1] // 'unknown',
								$_->[2]{lon}, $_->[2]{lat}
							)
						} @{$route}
					),
				);
			}
			$polyline->[ $min_dist{$key}{index} ][2]
			  = $stop->[1];
		}
		$route_i += 1;
	}
	return;
}

sub set_polyline {
	my ($self) = @_;

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}

	my $journey_id = $self->param('id');
	my $uid        = $self->current_user->{id};

	# Ensure that the journey exists and belongs to the user
	my $journey = $self->journeys->get_single(
		uid        => $uid,
		journey_id => $journey_id,
	);

	if ( not $journey ) {
		$self->render(
			'bad_request',
			message => 'Invalid journey ID',
			status  => 400,
		);
		return;
	}

	if ( my $upload = $self->req->upload('file') ) {
		my $root;
		eval {
			$root = XML::LibXML->load_xml( string => $upload->asset->slurp );
		};

		if ($@) {
			$self->render(
				'bad_request',
				message => "Invalid GPX file: Invalid XML: $@",
				status  => 400,
			);
			return;
		}

		my $context = XML::LibXML::XPathContext->new($root);
		$context->registerNs( 'gpx', 'http://www.topografix.com/GPX/1/1' );

		my @polyline;
		for my $point (
			$context->findnodes('/gpx:gpx/gpx:trk/gpx:trkseg/gpx:trkpt') )
		{
			push(
				@polyline,
				[
					0.0 + $point->getAttribute('lon'),
					0.0 + $point->getAttribute('lat')
				]
			);
		}

		if ( not @polyline ) {
			$self->render(
				'bad_request',
				message => 'Invalid GPX file: found no track points',
				status  => 400,
			);
			return;
		}

		my @route = @{ $journey->{route} };

		if ( $self->param('upload-partial') ) {
			my $route_start = first_index {
				(
					(
						     $_->[1] and $_->[1] == $journey->{from_eva}
						  or $_->[0] eq $journey->{from_name}
					)
					  and (
						not(   defined $_->[2]{sched_dep}
							or defined $_->[2]{rt_dep} )
						or ( $_->[2]{sched_dep} // $_->[2]{rt_dep} )
						== $journey->{sched_dep_ts}
					  )
				)
			}
			@route;

			my $route_end = last_index {
				(
					(
						     $_->[1] and $_->[1] == $journey->{to_eva}
						  or $_->[0] eq $journey->{to_name}
					)
					  and (
						not(   defined $_->[2]{sched_arr}
							or defined $_->[2]{rt_arr} )
						or ( $_->[2]{sched_arr} // $_->[2]{rt_arr} )
						== $journey->{sched_arr_ts}
					  )
				)
			}
			@route;

			if ( $route_start > -1 and $route_end > -1 ) {
				@route = @route[ $route_start .. $route_end ];
			}
		}

		my $err = $self->polyline_add_stops(
			polyline => \@polyline,
			route    => \@route,
		);

		if ($err) {
			$self->render(
				'bad_request',
				message => $err,
				status  => 400,
			);
			return;
		}

		$self->journeys->set_polyline(
			uid        => $uid,
			journey_id => $journey_id,
			edited     => $journey->{edited},
			polyline   => \@polyline,
			from_eva   => $route[0][1],
			to_eva     => $route[-1][1],
			stats_ts   => $journey->{rt_dep_ts},
		);
	}

	$self->redirect_to("/journey/${journey_id}");
}

sub add_journey_form {
	my ($self) = @_;

	$self->stash( backend_id => $self->current_user->{backend_id} );

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%FT%H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);
		my %opt;

		my @parts = split( qr{\s+}, $self->param('train') );

		if ( @parts == 2 ) {
			@opt{ 'train_type', 'train_no' } = @parts;
		}
		elsif ( @parts == 3 ) {
			@opt{ 'train_type', 'train_line', 'train_no' } = @parts;
		}
		else {
			$self->render(
				'add_journey',
				with_autocomplete => 1,
				status            => 400,
				error             =>
'Fahrt muss als „Typ Nummer“ oder „Typ Linie Nummer“ eingegeben werden.'
			);
			return;
		}

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			if ( $self->param($key) ) {
				my $datetime = $parser->parse_datetime( $self->param($key) );
				if ( not $datetime ) {
					$self->render(
						'add_journey',
						with_autocomplete => 1,
						status            => 400,
						error => "${key}: Ungültiges Datums-/Zeitformat"
					);
					return;
				}
				$opt{$key} = $datetime;
			}
		}

		$opt{rt_departure} //= $opt{sched_departure};
		$opt{rt_arrival}   //= $opt{sched_arrival};

		for my $key (qw(dep_station arr_station route cancelled comment)) {
			$opt{$key} = $self->param($key);
		}

		if ( $opt{route} ) {
			$opt{route} = [ split( qr{\r?\n\r?}, $opt{route} ) ];
		}

		my $db = $self->pg->db;
		my $tx = $db->begin;

		$opt{db}         = $db;
		$opt{uid}        = $self->current_user->{id};
		$opt{backend_id} = $self->current_user->{backend_id};

		my ( $journey_id, $error ) = $self->journeys->add(%opt);

		if ( not $error ) {
			my $journey = $self->journeys->get_single(
				uid        => $self->current_user->{id},
				db         => $db,
				journey_id => $journey_id,
				verbose    => 1
			);
			$error = $self->journeys->sanity_check($journey);
		}

		if ($error) {
			$self->render(
				'add_journey',
				with_autocomplete => 1,
				status            => 400,
				error             => $error,
			);
		}
		else {
			$tx->commit;
			$self->redirect_to("/journey/${journey_id}");
		}
	}
	else {
		$self->render(
			'add_journey',
			with_autocomplete => 1,
			error             => undef
		);
	}
}

sub add_intransit_form {
	my ($self) = @_;

	$self->stash( backend_id => $self->current_user->{backend_id} );

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%FT%H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);
		my $time_parser = DateTime::Format::Strptime->new(
			pattern   => '%H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);
		my %opt;
		my %trip;

		my @parts = split( qr{\s+}, $self->param('train') );

		if ( @parts == 2 ) {
			@trip{ 'train_type', 'train_no' } = @parts;
		}
		elsif ( @parts == 3 ) {
			@trip{ 'train_type', 'train_line', 'train_no' } = @parts;
		}
		else {
			$self->render(
				'add_intransit',
				with_autocomplete => 1,
				status            => 400,
				error             =>
'Fahrt muss als „Typ Nummer“ oder „Typ Linie Nummer“ eingegeben werden.'
			);
			return;
		}

		for my $key (qw(sched_departure sched_arrival)) {
			if ( $self->param($key) ) {
				my $datetime = $parser->parse_datetime( $self->param($key) );
				if ( not $datetime ) {
					$self->render(
						'add_intransit',
						with_autocomplete => 1,
						status            => 400,
						error => "${key}: Ungültiges Datums-/Zeitformat"
					);
					return;
				}
				$trip{$key} = $datetime;
			}
		}

		for my $key (qw(dep_station arr_station route comment)) {
			$trip{$key} = $self->param($key);
		}

		$opt{backend_id} = $self->current_user->{backend_id};

		my $dep_stop = $self->stations->search( $trip{dep_station},
			backend_id => $opt{backend_id} );
		my $arr_stop = $self->stations->search( $trip{arr_station},
			backend_id => $opt{backend_id} );

		if ( defined $trip{route} ) {
			$trip{route} = [ split( qr{\r?\n\r?}, $trip{route} ) ];
		}

		my $route_has_start = 0;
		my $route_has_stop  = 0;

		for my $station ( @{ $trip{route} || [] } ) {
			if (   $station eq $dep_stop->{name}
				or $station eq $dep_stop->{eva} )
			{
				$route_has_start = 1;
			}
			if (   $station eq $arr_stop->{name}
				or $station eq $arr_stop->{eva} )
			{
				$route_has_stop = 1;
			}
		}

		my @route;

		if ( not $route_has_start ) {
			push(
				@route,
				[
					$dep_stop->{name},
					$dep_stop->{eva},
					{
						lat => $dep_stop->{lat},
						lon => $dep_stop->{lon},
					}
				]
			);
		}

		if ( $trip{route} ) {
			my @unknown_stations;
			my $prev_ts = $trip{sched_departure};
			for my $station ( @{ $trip{route} } ) {
				my $ts;
				my %station_data;
				if ( $station
					=~ m{ ^ (?<stop> [^@]+? ) \s* [@] \s* (?<timestamp> .+ ) $ }x
				  )
				{
					$station = $+{stop};

					# attempt to parse "07:08" short timestamp first
					$ts = $time_parser->parse_datetime( $+{timestamp} );
					if ($ts) {

						# fill in last stop's (or at the first stop, our departure's)
						# date to complete the datetime
						$ts = $ts->set(
							year  => $prev_ts->year,
							month => $prev_ts->month,
							day   => $prev_ts->day
						);

						# if we go back in time with this, assume we went
						# over midnight and add a day, e.g. in case of a stop
						# at 23:00 followed by one at 01:30
						if ( $ts < $prev_ts ) {
							$ts = $ts->add( days => 1 );
						}
					}
					else {
						# do a full datetime parse
						$ts = $parser->parse_datetime( $+{timestamp} );
					}
					if ( $ts and $ts >= $prev_ts ) {
						$station_data{sched_arr} = $ts->epoch;
						$station_data{sched_dep} = $ts->epoch;
						$prev_ts                 = $ts;
					}
					else {
						$self->render(
							'add_intransit',
							with_autocomplete => 1,
							status            => 400,
							error => "Ungültige Zeitangabe: $+{timestamp}"
						);
						return;
					}
				}
				my $station_info = $self->stations->search( $station,
					backend_id => $opt{backend_id} );
				if ($station_info) {
					$station_data{lat} = $station_info->{lat};
					$station_data{lon} = $station_info->{lon};
					push(
						@route,
						[
							$station_info->{name}, $station_info->{eva},
							\%station_data,
						]
					);
				}
				else {
					push( @route,            [ $station, undef, {} ] );
					push( @unknown_stations, $station );
				}
			}

			if ( @unknown_stations == 1 ) {
				$self->render(
					'add_intransit',
					with_autocomplete => 1,
					status            => 400,
					error => "Unbekannter Unterwegshalt: $unknown_stations[0]"
				);
				return;
			}
			elsif (@unknown_stations) {
				$self->render(
					'add_intransit',
					with_autocomplete => 1,
					status            => 400,
					error             => 'Unbekannte Unterwegshalte: '
					  . join( ', ', @unknown_stations )
				);
				return;
			}
		}

		if ( not $route_has_stop ) {
			push(
				@route,
				[
					$arr_stop->{name},
					$arr_stop->{eva},
					{
						lat => $arr_stop->{lat},
						lon => $arr_stop->{lon},
					}
				]
			);
		}

		for my $station (@route) {
			if (   $station->[0] eq $dep_stop->{name}
				or $station->[1] eq $dep_stop->{eva} )
			{
				$station->[2]{sched_dep} = $trip{sched_departure}->epoch;
			}
			if (   $station->[0] eq $arr_stop->{name}
				or $station->[1] eq $arr_stop->{eva} )
			{
				$station->[2]{sched_arr} = $trip{sched_arrival}->epoch;
			}
		}

		my $error;
		my $db = $self->pg->db;
		my $tx = $db->begin;

		$trip{dep_id} = $dep_stop->{eva};
		$trip{arr_id} = $arr_stop->{eva};
		$trip{route}  = \@route;

		$opt{db}     = $db;
		$opt{manual} = \%trip;
		$opt{uid}    = $self->current_user->{id};

		if ( not defined $trip{dep_id} ) {
			$error = "Unknown departure stop '$trip{dep_station}'";
		}
		elsif ( not defined $trip{arr_id} ) {
			$error = "Unknown arrival stop '$trip{arr_station}'";
		}
		elsif ( $trip{sched_arrival} <= $trip{sched_departure} ) {
			$error = 'Ankunftszeit muss nach Abfahrtszeit liegen';
		}
		else {
			$error = $self->in_transit->add(%opt);
		}

		if ($error) {
			$self->render(
				'add_intransit',
				with_autocomplete => 1,
				status            => 400,
				error             => $error,
			);
		}
		else {
			$tx->commit;
			$self->redirect_to('/');
		}
	}
	else {
		$self->render(
			'add_intransit',
			with_autocomplete => 1,
			error             => undef
		);
	}
}

1;
