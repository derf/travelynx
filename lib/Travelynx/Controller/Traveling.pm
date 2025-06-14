package Travelynx::Controller::Traveling;

# Copyright (C) 2020-2023 Birte Kristina Friesel
# Copyright (C) 2025 networkException <git@nwex.de>
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use List::Util      qw(uniq min max);
use List::UtilsBy   qw(max_by uniq_by);
use List::MoreUtils qw(first_index);
use Mojo::UserAgent;
use Mojo::Promise;
use Text::CSV;
use Travel::Status::DE::IRIS::Stations;

# Internal Helpers

sub has_str_in_list {
	my ( $str, @strs ) = @_;
	if ( List::Util::any { $str eq $_ } @strs ) {
		return 1;
	}
	return;
}

# when called with "eva" provided: look up connections from eva, either
# for provided backend_id / hafas or (if not provided) for user backend id.
# When calld without "eva": look up connections from current/latest arrival
# eva, using the checkin's backend id.
sub get_connecting_trains_p {
	my ( $self, %opt ) = @_;

	my $user        = $self->current_user;
	my $uid         = $opt{uid} //= $user->{id};
	my $use_history = $self->users->use_history( uid => $uid );

	my ( $eva, $exclude_via, $exclude_train_id, $exclude_before );
	my $now = $self->now->epoch;
	my ( $stationinfo, $arr_epoch, $arr_platform, $arr_countdown );

	my $promise = Mojo::Promise->new;

	if ( $user->{backend_dbris} ) {

		# We do get a little bit of via information, so this might work in some
		# cases. But not reliably. Probably best to leave it out entirely then.
		return $promise->reject;
	}
	if ( $user->{backend_motis} ) {

		# FIXME: The following code can't handle external_ids currently
		return $promise->reject;
	}

	if ( $opt{eva} ) {
		if ( $use_history & 0x01 ) {
			$eva = $opt{eva};
		}
		elsif ( $opt{destination_name} ) {
			$eva = $opt{eva};
		}
		if ( not defined $opt{backend_id} ) {
			if ( $opt{hafas} ) {
				$opt{backend_id}
				  = $self->stations->get_backend_id( hafas => $opt{hafas} );
			}
			else {
				$opt{backend_id} = $user->{backend_id};
			}
		}
	}
	else {
		if ( $use_history & 0x02 ) {
			my $status = $self->get_user_status;
			$opt{backend_id}  = $status->{backend_id};
			$eva              = $status->{arr_eva};
			$exclude_via      = $status->{dep_name};
			$exclude_train_id = $status->{train_id};
			$arr_platform     = $status->{arr_platform};
			$stationinfo      = $status->{extra_data}{stationinfo_arr};
			if ( $status->{real_arrival} ) {
				$exclude_before = $arr_epoch = $status->{real_arrival}->epoch;
				$arr_countdown  = $status->{arrival_countdown};
			}
		}
	}

	$exclude_before //= $now - 300;

	if ( not $eva ) {
		return $promise->reject;
	}

	$self->log->debug(
		"get_connecting_trains_p(backend_id => $opt{backend_id}, eva => $eva)");

	my @destinations = $self->journeys->get_connection_targets(%opt);

	@destinations = uniq_by { $_->{name} } @destinations;

	if ($exclude_via) {
		@destinations = grep { $_->{name} ne $exclude_via } @destinations;
	}

	if ( not @destinations ) {
		return $promise->reject;
	}

	$self->log->debug( 'get_connection_targets returned '
		  . join( q{, }, map { $_->{name} } @destinations ) );

	my $can_check_in = not $arr_epoch || ( $arr_countdown // 1 ) < 0;
	my $lookahead
	  = $can_check_in ? 40 : ( ( ${arr_countdown} // 0 ) / 60 + 40 );

	my $iris_promise = Mojo::Promise->new;
	my %via_count    = map { $_->{name} => 0 } @destinations;

	my $backend
	  = $self->stations->get_backend( backend_id => $opt{backend_id} );
	if ( $opt{backend_id} == 0 ) {
		$self->iris->get_departures_p(
			station      => $eva,
			lookbehind   => 10,
			lookahead    => $lookahead,
			with_related => 1
		)->then(
			sub {
				my ($stationboard) = @_;
				if ( $stationboard->{errstr} ) {
					$promise->resolve( [], [] );
					return;
				}

				@{ $stationboard->{results} } = map { $_->[0] }
				  sort { $a->[1] <=> $b->[1] }
				  map  { [ $_, $_->departure ? $_->departure->epoch : 0 ] }
				  @{ $stationboard->{results} };
				my @results;
				my @cancellations;
				my $excluded_train;
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
						$excluded_train = $train;
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
						my @via = (
							$train->sched_route_post, $train->sched_route_end
						);
						for my $dest (@destinations) {
							if ( has_str_in_list( $dest->{name}, @via ) ) {
								push( @cancellations, [ $train, $dest ] );
								next;
							}
						}
					}
					else {
						my @via = ( $train->route_post, $train->route_end );
						for my $dest (@destinations) {
							if ( $via_count{ $dest->{name} } < 2
								and has_str_in_list( $dest->{name}, @via ) )
							{
								push( @results, [ $train, $dest ] );

								# Show all past and up to two future departures per destination
								if ( not $train->departure
									or $train->departure->epoch >= $now )
								{
									$via_count{ $dest->{name} }++;
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
						$_->[0]->departure->epoch
						  // $_->[0]->sched_departure->epoch
					]
				  } @results;
				@cancellations = map { $_->[0] }
				  sort { $a->[1] <=> $b->[1] }
				  map  { [ $_, $_->[0]->sched_departure->epoch ] }
				  @cancellations;

				# remove trains whose route matches the excluded one's
				if ($excluded_train) {
					my $route_pre
					  = join( '|', reverse $excluded_train->route_pre );
					@results
					  = grep { join( '|', $_->[0]->route_post ) ne $route_pre }
					  @results;
					my $route_post = join( '|', $excluded_train->route_post );
					@results
					  = grep { join( '|', $_->[0]->route_post ) ne $route_post }
					  @results;
				}

				# add message IDs and 'transfer short' hints
				for my $result (@results) {
					my $train = $result->[0];
					my @message_ids
					  = List::Util::uniq map { $_->[1] } $train->raw_messages;
					$train->{message_id} = { map { $_ => 1 } @message_ids };
					my $interchange_duration;
					if ( exists $stationinfo->{i} ) {
						if (    defined $arr_platform
							and defined $train->platform )
						{
							$interchange_duration
							  = $stationinfo->{i}{$arr_platform}
							  { $train->platform };
						}
						$interchange_duration //= $stationinfo->{i}{"*"};
					}
					if ( defined $interchange_duration ) {
						my $interchange_time
						  = ( $train->departure->epoch - $arr_epoch ) / 60;
						if ( $interchange_time < $interchange_duration ) {
							$train->{interchange_text} = 'Anschluss knapp';
							$train->{interchange_icon} = 'directions_run';
						}
						elsif ( $interchange_time == $interchange_duration ) {
							$train->{interchange_text}
							  = 'Anschluss könnte knapp werden';
							$train->{interchange_icon} = 'directions_run';
						}
					}
				}

				$promise->resolve( [ @results, @cancellations ], [] );
				return;
			}
		)->catch(
			sub {
				$promise->resolve( [], [] );
				return;
			}
		)->wait;
	}
	elsif ( $backend->{dbris} ) {
		return $promise->reject;
	}
	elsif ( $backend->{hafas} ) {
		my $hafas_service = $backend->{name};
		$self->hafas->get_departures_p(
			service    => $hafas_service,
			eva        => $eva,
			lookbehind => 10,
			lookahead  => $lookahead
		)->then(
			sub {
				my ($status) = @_;
				my @hafas_trains;
				my @all_hafas_trains = $status->results;
				for my $hafas_train (@all_hafas_trains) {
					for my $stop ( $hafas_train->route ) {
						for my $dest (@destinations) {
							if (    $stop->loc->name
								and $stop->loc->name eq $dest->{name}
								and $via_count{ $dest->{name} } < 2
								and $hafas_train->datetime )
							{
								my $departure = $hafas_train->datetime;
								my $arrival   = $stop->arr;
								my $delay     = $hafas_train->delay;
								if (    $delay
									and $stop->arr == $stop->sched_arr )
								{
									$arrival->add( minutes => $delay );
								}
								if ( $departure->epoch >= $exclude_before ) {
									$via_count{ $dest->{name} }++;
									push(
										@hafas_trains,
										[
											$hafas_train, $dest,
											$arrival,     $hafas_service
										]
									);
								}
							}
						}
					}
				}
				$promise->resolve( [], \@hafas_trains );
				return;
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->log->debug("get_connection_trains: hafas: $err");
				$promise->resolve( [], [] );
				return;
			}
		)->wait;
	}

	return $promise;
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
					journeys => [$status],
				);
			}
			my $journey_visibility
			  = $self->compute_effective_visibility(
				$user->{default_visibility_str},
				$status->{visibility_str} );
			if ( defined $status->{arrival_countdown}
				and $status->{arrival_countdown} < ( 40 * 60 ) )
			{
				$self->render_later;
				$self->get_connecting_trains_p->then(
					sub {
						my ( $connections_iris, $connections_hafas ) = @_;
						$self->render(
							'landingpage',
							user               => $user,
							user_status        => $status,
							journey_visibility => $journey_visibility,
							connections_iris   => $connections_iris,
							connections_hafas  => $connections_hafas,
							with_map           => 1,
							%{$map_data},
						);
						$self->users->mark_seen( uid => $uid );
					}
				)->catch(
					sub {
						$self->render(
							'landingpage',
							user               => $user,
							user_status        => $status,
							journey_visibility => $journey_visibility,
							with_map           => 1,
							%{$map_data},
						);
						$self->users->mark_seen( uid => $uid );
					}
				)->wait;
				return;
			}
			else {
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
	my $status = $self->get_user_status;

	delete $self->stash->{layout};

	my @timeline = $self->in_transit->get_timeline(
		uid   => $self->current_user->{id},
		short => 1
	);
	$self->stash( timeline => [@timeline] );

	if ( $status->{checked_in} ) {
		my $map_data = {};
		if ( $status->{arr_name} ) {
			$map_data = $self->journeys_to_map_data(
				journeys => [$status],
			);
		}
		my $journey_visibility
		  = $self->compute_effective_visibility(
			$self->current_user->{default_visibility_str},
			$status->{visibility_str} );
		if ( defined $status->{arrival_countdown}
			and $status->{arrival_countdown} < ( 40 * 60 ) )
		{
			$self->render_later;
			$self->get_connecting_trains_p->then(
				sub {
					my ( $connections_iris, $connections_hafas ) = @_;
					$self->render(
						'_checked_in',
						journey            => $status,
						journey_visibility => $journey_visibility,
						connections_iris   => $connections_iris,
						connections_hafas  => $connections_hafas,
						%{$map_data},
					);
				}
			)->catch(
				sub {
					$self->render(
						'_checked_in',
						journey            => $status,
						journey_visibility => $journey_visibility,
						%{$map_data},
					);
				}
			)->wait;
			return;
		}
		$self->render(
			'_checked_in',
			journey            => $status,
			journey_visibility => $journey_visibility,
			%{$map_data},
		);
	}
	elsif ( $status->{cancellation} ) {
		$self->render_later;
		$self->get_connecting_trains_p(
			backend_id       => $status->{backend_id},
			eva              => $status->{cancellation}{dep_eva},
			destination_name => $status->{cancellation}{arr_name}
		)->then(
			sub {
				my ($connecting_trains) = @_;
				$self->render(
					'_cancelled_departure',
					journey          => $status->{cancellation},
					connections_iris => $connecting_trains
				);
			}
		)->catch(
			sub {
				$self->render( '_cancelled_departure',
					journey => $status->{cancellation} );
			}
		)->wait;
		return;
	}
	else {
		my @connecting_trains;
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		if ( $now->epoch - $status->{timestamp}->epoch < ( 30 * 60 ) ) {
			$self->render_later;
			$self->get_connecting_trains_p->then(
				sub {
					my ( $connections_iris, $connections_hafas ) = @_;
					$self->render(
						'_checked_out',
						journey           => $status,
						connections_iris  => $connections_iris,
						connections_hafas => $connections_hafas,
					);
				}
			)->catch(
				sub {
					$self->render( '_checked_out', journey => $status );
				}
			)->wait;
			return;
		}
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

	my ( $dbris_service, $hafas_service, $motis_service );
	my $backend = $self->stations->get_backend( backend_id => $backend_id );
	if ( $backend->{dbris} ) {
		$dbris_service = $backend->{name};
	}
	elsif ( $backend->{hafas} ) {
		$hafas_service = $backend->{name};
	}
	elsif ( $backend->{motis} ) {
		$motis_service = $backend->{name};
	}

	if ($dbris_service) {
		$self->render_later;

		Travel::Status::DE::DBRIS->new_p(
			promise    => 'Mojo::Promise',
			user_agent => Mojo::UserAgent->new,
			geoSearch  => {
				latitude  => $lat,
				longitude => $lon
			}
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
				} $dbris->results;
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
						warning    => $err,
					}
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
						warning    => $err,
					}
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
						warning    => $err,
					}
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
			dbris    => 0,
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

	my $dbris_service = $self->param('dbris')
	  // ( $user->{backend_dbris} ? $user->{backend_name} : undef );
	my $efa_service = $self->param('efa')
	  // ( $user->{backend_efa} ? $user->{backend_name} : undef );
	my $hafas_service = $self->param('hafas')
	  // ( $user->{backend_hafas} ? $user->{backend_name} : undef );
	my $motis_service = $self->param('motis')
	  // ( $user->{backend_motis} ? $user->{backend_name} : undef );
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
	elsif ($hafas_service) {
		$promise = $self->hafas->get_departures_p(
			service    => $hafas_service,
			eva        => $station,
			timestamp  => $timestamp,
			lookbehind => 30,
			lookahead  => 30,
		);
	}
	elsif ($efa_service) {
		$promise = $self->efa->get_departures_p(
			service    => $efa_service,
			name       => $station,
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
			}

			my $user_status = $self->get_user_status;

			my $can_check_out = 0;
			if ( $user_status->{checked_in} ) {
				for my $stop ( @{ $user_status->{route_after} } ) {
					if (
						$stop->[1] eq $status->{station_eva}
						or List::Util::any { $stop->[1] eq $_->{uic} }
						@{ $status->{related_stations} }
					  )
					{
						$can_check_out = 1;
						last;
					}
				}
			}

			my $connections_p;
			if ( $trip_id and $hafas_service ) {
				@results = grep { $_->id eq $trip_id } @results;
			}
			elsif ( $train and not $hafas_service ) {
				@results
				  = grep { $_->type . ' ' . $_->train_no eq $train } @results;
			}
			else {
				if (    $user_status->{cancellation}
					and $status->{station_eva} eq
					$user_status->{cancellation}{dep_eva} )
				{
					$connections_p = $self->get_connecting_trains_p(
						eva => $user_status->{cancellation}{dep_eva},
						destination_name =>
						  $user_status->{cancellation}{arr_name},
						efa   => $efa_service,
						hafas => $hafas_service,
					);
				}
				else {
					$connections_p = $self->get_connecting_trains_p(
						eva   => $status->{station_eva},
						efa   => $efa_service,
						hafas => $hafas_service
					);
				}
			}

			if ($connections_p) {
				$connections_p->then(
					sub {
						my ( $connections_iris, $connections_hafas ) = @_;
						$self->render(
							'departures',
							user              => $user,
							dbris             => $dbris_service,
							efa              => $efa_service,
							hafas             => $hafas_service,
							motis             => $motis_service,
							eva               => $status->{station_eva},
							datetime          => $timestamp,
							now_in_range      => $now_within_range,
							results           => \@results,
							station           => $status->{station_name},
							related_stations  => $status->{related_stations},
							user_status       => $user_status,
							can_check_out     => $can_check_out,
							connections_iris  => $connections_iris,
							connections_hafas => $connections_hafas,
							title => "travelynx: $status->{station_name}",
						);
					}
				)->catch(
					sub {
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
							title => "travelynx: $status->{station_name}",
						);
					}
				)->wait;
			}
			else {
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
					title            => "travelynx: $status->{station_name}",
				);
			}
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
				=~ m{svcRes|connection close|Service Temporarily Unavailable|Forbidden}
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
		pattern   => '%d.%m.%Y',
		locale    => 'de_DE',
		time_zone => 'Europe/Berlin'
	);

	if (    $filter_from
		and $filter_from =~ m{ ^ (\d+) [.] (\d+) [.] (\d+) $ }x )
	{
		$filter_from = $parser->parse_datetime($filter_from);
	}
	else {
		$filter_from = undef;
	}

	if (    $filter_until
		and $filter_until =~ m{ ^ (\d+) [.] (\d+) [.] (\d+) $ }x )
	{
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
		qw(Zugtyp Linie Nummer Start Ziel),
		'Start (DS100)',
		'Ziel (DS100)',
		'Abfahrt (soll)',
		'Abfahrt (ist)',
		'Ankunft (soll)',
		'Ankunft (ist)',
		'Kommentar',
		'ID'
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
				$journey->{to_name},
				$journey->{from_ds100},
				$journey->{to_ds100},
				$journey->{sched_departure}->strftime('%Y-%m-%d %H:%M'),
				$journey->{rt_departure}->strftime('%Y-%m-%d %H:%M'),
				$journey->{sched_arrival}->strftime('%Y-%m-%d %H:%M'),
				$journey->{rt_arrival}->strftime('%Y-%m-%d %H:%M'),
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
		$self->render(
			'journey',
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
		with_polyline       => 1,
		with_visibility     => 1,
	);

	if ($journey) {
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

		$self->render(
			'journey',
			title => sprintf(
				'travelynx: Fahrt %s %s %s am %s',
				$journey->{type}, $journey->{line} // '',
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
		);
	}
	else {
		$self->render(
			'journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
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
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);

		my $db = $self->pg->db;
		my $tx = $db->begin;

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			my $datetime = $parser->parse_datetime( $self->param($key) );
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
					$key => $self->param($key)
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
			$self->param(
				$key => $journey->{$key}->strftime('%d.%m.%Y %H:%M') );
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
		error             => $error,
		journey           => $journey
	);
}

sub add_journey_form {
	my ($self) = @_;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
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
'Zug muss als „Typ Nummer“ oder „Typ Linie Nummer“ eingegeben werden.'
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
		$opt{backend_id} = 1;

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

1;
