package Travelynx::Controller::Traveling;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use List::Util      qw(uniq min max);
use List::UtilsBy   qw(max_by uniq_by);
use List::MoreUtils qw(first_index);
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

sub get_connecting_trains_p {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid} //= $self->current_user->{id};
	my ( $use_history, $lt_stops ) = $self->users->use_history(
		uid                => $uid,
		with_local_transit => 1
	);

	my ( $eva, $exclude_via, $exclude_train_id, $exclude_before );
	my $now = $self->now->epoch;
	my ( $stationinfo, $arr_epoch, $arr_platform, $arr_countdown );

	my $promise = Mojo::Promise->new;

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
				$exclude_before = $arr_epoch = $status->{real_arrival}->epoch;
				$arr_countdown  = $status->{arrival_countdown};
			}
		}
	}

	$exclude_before //= $now - 300;

	if ( not $eva ) {
		return $promise->reject;
	}

	my @destinations = $self->journeys->get_connection_targets(%opt);

	if ($exclude_via) {
		@destinations = grep { $_ ne $exclude_via } @destinations;
	}

	if ( not( @destinations or $use_history & 0x04 and @{$lt_stops} ) ) {
		return $promise->reject;
	}

	my $can_check_in = not $arr_epoch || ( $arr_countdown // 1 ) < 0;
	my $lookahead
	  = $can_check_in ? 40 : ( ( ${arr_countdown} // 0 ) / 60 + 40 );

	my $iris_promise = Mojo::Promise->new;

	if (@destinations) {
		$self->iris->get_departures_p(
			station      => $eva,
			lookbehind   => 10,
			lookahead    => $lookahead,
			with_related => 1
		)->then(
			sub {
				my ($stationboard) = @_;
				if ( $stationboard->{errstr} ) {
					$iris_promise->reject( $stationboard->{errstr} );
					return;
				}

				@{ $stationboard->{results} } = map { $_->[0] }
				  sort { $a->[1] <=> $b->[1] }
				  map  { [ $_, $_->departure ? $_->departure->epoch : 0 ] }
				  @{ $stationboard->{results} };
				my @results;
				my @cancellations;
				my $excluded_train;
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
							if ( has_str_in_list( $dest, @via ) ) {
								push( @cancellations, [ $train, $dest ] );
								next;
							}
						}
					}
					else {
						my @via = ( $train->route_post, $train->route_end );
						for my $dest (@destinations) {
							if ( $via_count{$dest} < 2
								and has_str_in_list( $dest, @via ) )
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

				$iris_promise->resolve( [ @results, @cancellations ] );
				return;
			}
		)->catch(
			sub {
				$iris_promise->reject(@_);
				return;
			}
		)->wait;
	}
	else {
		$iris_promise->resolve( [] );
	}

	my $hafas_promise = Mojo::Promise->new;
	$self->hafas->get_departures_p(
		eva        => $eva,
		lookbehind => 10,
		lookahead  => $lookahead
	)->then(
		sub {
			my ($status) = @_;
			$hafas_promise->resolve( [ $status->results ] );
			return;
		}
	)->catch(
		sub {
			# HAFAS data is optional.
			# Errors are logged by get_json_p and can be silently ignored here.
			$hafas_promise->resolve( [] );
			return;
		}
	)->wait;

	Mojo::Promise->all( $iris_promise, $hafas_promise )->then(
		sub {
			my ( $iris, $hafas ) = @_;
			my @iris_trains  = @{ $iris->[0] };
			my @hafas_trains = @{ $hafas->[0] };
			my @transit_fyi;

			# We've already got a list of connecting trains; this function
			# only adds further information to them. We ignore errors, as
			# partial data is better than no data.
			eval {
				for my $iris_train (@iris_trains) {
					if ( $iris_train->[0]->departure_is_cancelled ) {
						next;
					}
					for my $hafas_train (@hafas_trains) {
						if (    $hafas_train->number
							and $hafas_train->number
							== $iris_train->[0]->train_no )
						{
							if (    $hafas_train->load
								and $hafas_train->load->{SECOND} )
							{
								$iris_train->[3] = $hafas_train->load;
							}
							for my $stop ( $hafas_train->route ) {
								if (    $stop->{name}
									and $stop->{name} eq $iris_train->[1]
									and $stop->{arr} )
								{
									$iris_train->[2] = $stop->{arr};
									if ( $iris_train->[0]->departure_delay
										and not $stop->{arr_delay} )
									{
										$iris_train->[2]
										  ->add( minutes => $iris_train->[0]
											  ->departure_delay );
									}
									last;
								}
							}
							last;
						}
					}
				}
				if ( $use_history & 0x04 and @{$lt_stops} ) {
					my %via_count = map { $_ => 0 } @{$lt_stops};
					for my $hafas_train (@hafas_trains) {
						for my $stop ( $hafas_train->route ) {
							for my $dest ( @{$lt_stops} ) {
								if (    $stop->{name}
									and $stop->{name} eq $dest
									and $via_count{$dest} < 2
									and $hafas_train->datetime )
								{
									my $departure = $hafas_train->datetime;
									my $arrival   = $stop->{arr};
									my $delay     = $hafas_train->delay;
									if (    $delay
										and $stop->{arr} == $stop->{sched_arr} )
									{
										$arrival->add( minutes => $delay );
									}
									if ( $departure->epoch >= $exclude_before )
									{
										$via_count{$dest}++;
										push(
											@transit_fyi,
											[
												{
													line => $hafas_train->line,
													departure => $departure,
													departure_delay => $delay
												},
												$dest, $arrival
											]
										);
									}
								}
							}
						}
					}
				}
			};
			if ($@) {
				$self->app->log->error(
					"get_connecting_trains_p($uid): IRIS/HAFAS merge failed: $@"
				);
			}

			$promise->resolve( \@iris_trains, \@transit_fyi );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;

			# TODO logging. HAFAS errors should never happen, IRIS errors are noteworthy too.
			$promise->reject($err);
			return;
		}
	)->wait;

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
		my $uid      = $self->current_user->{id};
		my $status   = $self->get_user_status;
		my @timeline = $self->in_transit->get_timeline(
			uid   => $uid,
			short => 1
		);
		$self->stash( timeline => [@timeline] );
		my @recent_targets;
		if ( $status->{checked_in} ) {
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
						my ( $connecting_trains, $transit_fyi ) = @_;
						$self->render(
							'landingpage',
							user_status        => $status,
							journey_visibility => $journey_visibility,
							connections        => $connecting_trains,
							transit_fyi        => $transit_fyi,
						);
						$self->users->mark_seen( uid => $uid );
					}
				)->catch(
					sub {
						$self->render(
							'landingpage',
							user_status        => $status,
							journey_visibility => $journey_visibility,
						);
						$self->users->mark_seen( uid => $uid );
					}
				)->wait;
				return;
			}
			else {
				$self->render(
					'landingpage',
					user_status        => $status,
					journey_visibility => $journey_visibility,
				);
				$self->users->mark_seen( uid => $uid );
				return;
			}
		}
		else {
			@recent_targets = uniq_by { $_->{eva} }
			$self->journeys->get_latest_checkout_stations( uid => $uid );
		}
		$self->render(
			'landingpage',
			user_status       => $status,
			recent_targets    => \@recent_targets,
			with_autocomplete => 1,
			with_geolocation  => 1
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
					my ( $connecting_trains, $transit_fyi ) = @_;
					$self->render(
						'_checked_in',
						journey            => $status,
						journey_visibility => $journey_visibility,
						connections        => $connecting_trains,
						transit_fyi        => $transit_fyi
					);
				}
			)->catch(
				sub {
					$self->render(
						'_checked_in',
						journey            => $status,
						journey_visibility => $journey_visibility,
					);
				}
			)->wait;
			return;
		}
		$self->render(
			'_checked_in',
			journey            => $status,
			journey_visibility => $journey_visibility,
		);
	}
	elsif ( $status->{cancellation} ) {
		$self->render_later;
		$self->get_connecting_trains_p(
			eva              => $status->{cancellation}{dep_eva},
			destination_name => $status->{cancellation}{arr_name}
		)->then(
			sub {
				my ($connecting_trains) = @_;
				$self->render(
					'_cancelled_departure',
					journey     => $status->{cancellation},
					connections => $connecting_trains
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
					my ($connecting_trains) = @_;
					$self->render(
						'_checked_out',
						journey     => $status,
						connections => $connecting_trains
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

	my $lon = $self->param('lon');
	my $lat = $self->param('lat');

	if ( not $lon or not $lat ) {
		$self->render( json => { error => 'Invalid lon/lat received' } );
	}
	else {
		my @candidates = map {
			{
				ds100    => $_->[0][0],
				name     => $_->[0][1],
				eva      => $_->[0][2],
				lon      => $_->[0][3],
				lat      => $_->[0][4],
				distance => $_->[1],
			}
		} Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
			$lat, 10 );
		@candidates = uniq_by { $_->{name} } @candidates;
		if ( @candidates > 5 ) {
			$self->render(
				json => {
					candidates => [ @candidates[ 0 .. 4 ] ],
				}
			);
		}
		else {
			$self->render(
				json => {
					candidates => [@candidates],
				}
			);
		}
	}
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

		$self->render_later;
		$self->checkin_p(
			station  => $params->{station},
			train_id => $params->{train}
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
				my ( $still_checked_in, undef ) = $self->checkout(
					station => $destination,
					force   => 0
				);
				my $station_link = '/s/' . $destination;
				$self->render(
					json => {
						success     => 1,
						redirect_to => $still_checked_in ? '/' : $station_link,
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
	elsif ( $params->{action} eq 'checkout' ) {
		my ( $still_checked_in, $error ) = $self->checkout(
			station => $params->{station},
			force   => $params->{force}
		);
		my $station_link = '/s/' . $params->{station};

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
					redirect_to => $still_checked_in ? '/' : $station_link,
				},
			);
		}
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
				$redir = '/s/' . $status->{dep_ds100};
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
			station  => $params->{station},
			train_id => $params->{train}
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
		my ( undef, $error ) = $self->checkout(
			station => $params->{station},
			force   => 1
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
					redirect_to => '/',
				},
			);
		}
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
	my ($self)  = @_;
	my $station = $self->stash('station');
	my $train   = $self->param('train');

	$self->render_later;

	my $use_hafas = $self->param('hafas');
	my $promise;
	if ($use_hafas) {
		$promise = $self->hafas->get_departures_p(
			eva        => $station,
			lookbehind => 120,
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
			if ($use_hafas) {
				my $now = $self->now->epoch;
				@results = map { $_->[0] }
				  sort { $b->[1] <=> $a->[1] }
				  map  { [ $_, $_->datetime->epoch ] }
				  grep {
					( $_->datetime // $_->sched_datetime )->epoch
					  < $now + 30 * 60
				  } $status->results;
				$status = {
					station_eva  => $status->station->{eva},
					station_name => (
						List::Util::reduce { length($a) < length($b) ? $a : $b }
						@{ $status->station->{names} }
					),
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
			if ($train) {
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
						  $user_status->{cancellation}{arr_name}
					);
				}
				else {
					$connections_p = $self->get_connecting_trains_p(
						eva => $status->{station_eva} );
				}
			}

			if ($connections_p) {
				$connections_p->then(
					sub {
						my ($connecting_trains) = @_;
						$self->render(
							'departures',
							eva              => $status->{station_eva},
							results          => \@results,
							hafas            => $use_hafas,
							station          => $status->{station_name},
							related_stations => $status->{related_stations},
							user_status      => $user_status,
							can_check_out    => $can_check_out,
							connections      => $connecting_trains,
							title => "travelynx: $status->{station_name}",
						);
					}
				)->catch(
					sub {
						$self->render(
							'departures',
							eva              => $status->{station_eva},
							results          => \@results,
							hafas            => $use_hafas,
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
					eva              => $status->{station_eva},
					results          => \@results,
					hafas            => $use_hafas,
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
			if ($status) {
				$self->render(
					'landingpage',
					with_autocomplete => 1,
					with_geolocation  => 1,
					error             => $status->{errstr},
					status            => 400,
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

	$self->redirect_to("/s/${station}");
}

sub cancelled {
	my ($self) = @_;
	my @journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		cancelled     => 1,
		with_datetime => 1
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

	$self->render( template => 'history' );
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
		months            => [
			qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
		],
	);
}

sub map_history {
	my ($self) = @_;

	my $location = $self->app->coordinates_by_station;

	if ( not $self->param('route_type') ) {
		$self->param( route_type => 'polybee' );
	}

	my $route_type    = $self->param('route_type');
	my $filter_from   = $self->param('filter_after');
	my $filter_until  = $self->param('filter_before');
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
		$filter_until = $parser->parse_datetime($filter_until);
	}
	else {
		$filter_until = undef;
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
		with_map => 1,
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
			message => 'Keine Zugfahrten im angefragten Jahr gefunden.',
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
		title  => "travelynx Jahresrückblick $year",
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
			message => 'Keine Zugfahrten im angefragten Jahr gefunden.'
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
			message => 'Keine Zugfahrten im angefragten Monat gefunden.',
			status  => 404
		);
		return;
	}

	my $stats = $self->journeys->get_stats(
		uid   => $self->current_user->{id},
		year  => $year,
		month => $month
	);

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_month',
			journeys   => [@journeys],
			year       => $year,
			month      => $month,
			month_name => $months[ $month - 1 ],
			statistics => $stats
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
		uid             => $uid,
		journey_id      => $journey_id,
		verbose         => 1,
		with_datetime   => 1,
		with_polyline   => 1,
		with_visibility => 1,
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
		uid           => $uid,
		journey_id    => $journey_id,
		verbose       => 1,
		with_datetime => 1,
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
				uid           => $uid,
				db            => $db,
				journey_id    => $journey_id,
				verbose       => 1,
				with_datetime => 1,
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

		$opt{db}  = $db;
		$opt{uid} = $self->current_user->{id};

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
