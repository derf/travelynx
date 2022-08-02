package Travelynx::Controller::Traveling;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use JSON;
use List::Util qw(uniq min max);
use List::UtilsBy qw(max_by uniq_by);
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

	my $uid         = $opt{uid} //= $self->current_user->{id};
	my $use_history = $self->users->use_history( uid => $uid );

	my ( $eva, $exclude_via, $exclude_train_id, $exclude_before );
	my $now = $self->now->epoch;
	my ( $stationinfo, $arr_epoch, $arr_platform );

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

	if ( not @destinations ) {
		return $promise->reject;
	}

	$self->iris->get_departures_p(
		station      => $eva,
		lookbehind   => 10,
		lookahead    => 40,
		with_related => 1
	)->then(
		sub {
			my ($stationboard) = @_;
			if ( $stationboard->{errstr} ) {
				$promise->reject( $stationboard->{errstr} );
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

			$promise->resolve( @results, @cancellations );
		}
	)->catch(
		sub {
			$promise->reject(@_);
			return;
		}
	)->wait;
	return $promise;
}

# Controllers

sub homepage {
	my ($self) = @_;
	if ( $self->is_user_authenticated ) {
		my $status = $self->get_user_status;
		if ( $status->{checked_in} ) {
			if ( defined $status->{arrival_countdown}
				and $status->{arrival_countdown} < ( 20 * 60 ) )
			{
				$self->render_later;
				$self->get_connecting_trains_p->then(
					sub {
						my @connecting_trains = @_;
						$self->render(
							'landingpage',
							version => $self->app->config->{version}
							  // 'UNKNOWN',
							status            => $status,
							connections       => \@connecting_trains,
							with_autocomplete => 1,
							with_geolocation  => 1
						);
						$self->users->mark_seen(
							uid => $self->current_user->{id} );
					}
				)->catch(
					sub {
						$self->render(
							'landingpage',
							version => $self->app->config->{version}
							  // 'UNKNOWN',
							status            => $status,
							with_autocomplete => 1,
							with_geolocation  => 1
						);
						$self->users->mark_seen(
							uid => $self->current_user->{id} );
					}
				)->wait;
				return;
			}
		}
		$self->render(
			'landingpage',
			version           => $self->app->config->{version} // 'UNKNOWN',
			status            => $status,
			with_autocomplete => 1,
			with_geolocation  => 1
		);
		$self->users->mark_seen( uid => $self->current_user->{id} );
	}
	else {
		$self->render(
			'landingpage',
			version => $self->app->config->{version} // 'UNKNOWN',
			intro   => 1
		);
	}
}

sub user_status {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $ts   = $self->stash('ts') // 0;
	my $user = $self->users->get_privacy_by_name( name => $name );

	if ( not $user or not $user->{public_level} & 0x03 ) {
		$self->render('not_found');
		return;
	}

	if ( $user->{public_level} & 0x01 and not $self->is_user_authenticated ) {
		$self->render( 'login', redirect_to => $self->req->url );
		return;
	}

	my $status = $self->get_user_status( $user->{id} );
	my $journey;

	if (
		$ts
		and ( not $status->{checked_in}
			or $status->{sched_departure}->epoch != $ts )
		and (
			$user->{public_level} & 0x20
			or ( $user->{public_level} & 0x10 and $self->is_user_authenticated )
		)
	  )
	{
		for my $candidate (
			$self->journeys->get(
				uid   => $user->{id},
				limit => 10,
			)
		  )
		{
			if ( $candidate->{sched_dep_ts} eq $ts ) {
				$journey = $self->journeys->get_single(
					uid           => $user->{id},
					journey_id    => $candidate->{id},
					verbose       => 1,
					with_datetime => 1,
					with_polyline => 1,
				);
			}
		}
	}

	my %tw_data = (
		card  => 'summary',
		site  => '@derfnull',
		image => $self->url_for('/static/icons/icon-512x512.png')
		  ->to_abs->scheme('https'),
	);
	my %og_data = (
		type      => 'article',
		image     => $tw_data{image},
		url       => $self->url_for("/status/${name}")->to_abs->scheme('https'),
		site_name => 'travelynx',
	);

	if ($journey) {
		$og_data{title} = $tw_data{title} = sprintf( 'Fahrt von %s nach %s',
			$journey->{from_name}, $journey->{to_name} );
		$og_data{description} = $tw_data{description}
		  = $journey->{rt_arrival}->strftime('Ankunft am %d.%m.%Y um %H:%M');
		$og_data{url} .= "/${ts}";
	}
	elsif (
		$ts
		and ( not $status->{checked_in}
			or $status->{sched_departure}->epoch != $ts )
	  )
	{
		$og_data{title}       = $tw_data{title} = "Bahnfahrt beendet";
		$og_data{description} = $tw_data{description}
		  = "${name} hat das Ziel erreicht";
	}
	elsif ( $status->{checked_in} ) {
		$og_data{url} .= '/' . $status->{sched_departure}->epoch;
		$og_data{title}       = $tw_data{title}       = "${name} ist unterwegs";
		$og_data{description} = $tw_data{description} = sprintf(
			'%s %s von %s nach %s',
			$status->{train_type}, $status->{train_line} // $status->{train_no},
			$status->{dep_name},   $status->{arr_name}   // 'irgendwo'
		);
		if ( $status->{real_arrival}->epoch ) {
			$tw_data{description} .= $status->{real_arrival}
			  ->strftime(' – Ankunft gegen %H:%M Uhr');
			$og_data{description} .= $status->{real_arrival}
			  ->strftime(' – Ankunft gegen %H:%M Uhr');
		}
	}
	else {
		$og_data{title} = $tw_data{title}
		  = "${name} ist gerade nicht eingecheckt";
		$og_data{description} = $tw_data{description}
		  = "Letztes Fahrtziel: $status->{arr_name}";
	}

	if ($journey) {
		if ( not $user->{public_level} & 0x04 ) {
			delete $journey->{user_data}{comment};
		}
		my $map_data = $self->journeys_to_map_data(
			journeys       => [$journey],
			include_manual => 1,
		);
		$self->render(
			'journey',
			error     => undef,
			with_map  => 1,
			readonly  => 1,
			journey   => $journey,
			twitter   => \%tw_data,
			opengraph => \%og_data,
			%{$map_data},
		);
	}
	else {
		$self->render(
			'user_status',
			name         => $name,
			public_level => $user->{public_level},
			journey      => $status,
			twitter      => \%tw_data,
			opengraph    => \%og_data,
		);
	}
}

sub public_profile {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $user = $self->users->get_privacy_by_name( name => $name );

	if (
		$user
		and (
			$user->{public_level} & 0x22
			or ( $user->{public_level} & 0x11 and $self->is_user_authenticated )
		)
	  )
	{
		my $status = $self->get_user_status( $user->{id} );
		my @journeys;
		if ( $user->{public_level} & 0x40 ) {
			@journeys = $self->journeys->get(
				uid           => $user->{id},
				limit         => 10,
				with_datetime => 1
			);
		}
		else {
			my $now       = DateTime->now( time_zone => 'Europe/Berlin' );
			my $month_ago = $now->clone->subtract( weeks => 4 );
			@journeys = $self->journeys->get(
				uid           => $user->{id},
				limit         => 10,
				with_datetime => 1,
				after         => $month_ago,
				before        => $now
			);
		}
		$self->render(
			'profile',
			name         => $name,
			uid          => $user->{id},
			public_level => $user->{public_level},
			journey      => $status,
			journeys     => [@journeys],
			version      => $self->app->config->{version} // 'UNKNOWN',
		);
	}
	else {
		$self->render('not_found');
	}
}

sub public_journey_details {
	my ($self)     = @_;
	my $name       = $self->stash('name');
	my $journey_id = $self->stash('id');
	my $user       = $self->users->get_privacy_by_name( name => $name );

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

	if (
		$user
		and (
			$user->{public_level} & 0x20
			or ( $user->{public_level} & 0x10 and $self->is_user_authenticated )
		)
	  )
	{
		my $journey = $self->journeys->get_single(
			uid           => $user->{id},
			journey_id    => $journey_id,
			verbose       => 1,
			with_datetime => 1,
			with_polyline => 1,
		);

		if ( not( $user->{public_level} & 0x40 ) ) {
			my $month_ago = DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( weeks => 4 )->epoch;
			if ( $journey and $journey->{rt_dep_ts} < $month_ago ) {
				$journey = undef;
			}
		}

		if ($journey) {
			my $title = sprintf( 'Fahrt von %s nach %s am %s',
				$journey->{from_name}, $journey->{to_name},
				$journey->{rt_arrival}->strftime('%d.%m.%Y') );
			my $description = sprintf( 'Ankunft mit %s %s %s',
				$journey->{type}, $journey->{no},
				$journey->{rt_arrival}->strftime('um %H:%M') );
			my %tw_data = (
				card  => 'summary',
				site  => '@derfnull',
				image => $self->url_for('/static/icons/icon-512x512.png')
				  ->to_abs->scheme('https'),
				title       => $title,
				description => $description,
			);
			my %og_data = (
				type        => 'article',
				image       => $tw_data{image},
				url         => $self->url_for->to_abs,
				site_name   => 'travelynx',
				title       => $title,
				description => $description,
			);

			my $map_data = $self->journeys_to_map_data(
				journeys       => [$journey],
				include_manual => 1,
			);
			if ( $journey->{user_data}{comment}
				and not $user->{public_level} & 0x04 )
			{
				delete $journey->{user_data}{comment};
			}
			$self->render(
				'journey',
				error     => undef,
				journey   => $journey,
				with_map  => 1,
				username  => $name,
				readonly  => 1,
				twitter   => \%tw_data,
				opengraph => \%og_data,
				%{$map_data},
			);
		}
		else {
			$self->render('not_found');
		}
	}
	else {
		$self->render('not_found');
	}
}

sub public_status_card {
	my ($self) = @_;

	my $name = $self->stash('name');
	$name =~ s{[.]html$}{};
	my $user = $self->users->get_privacy_by_name( name => $name );

	delete $self->stash->{layout};

	if (
		$user
		and (
			$user->{public_level} & 0x02
			or ( $user->{public_level} & 0x01 and $self->is_user_authenticated )
		)
	  )
	{
		my $status = $self->get_user_status( $user->{id} );
		$self->render(
			'_public_status_card',
			name         => $name,
			public_level => $user->{public_level},
			journey      => $status
		);
	}
	else {
		$self->render('not_found');
	}
}

sub status_card {
	my ($self) = @_;
	my $status = $self->get_user_status;

	delete $self->stash->{layout};

	if ( $status->{checked_in} ) {
		if ( defined $status->{arrival_countdown}
			and $status->{arrival_countdown} < ( 20 * 60 ) )
		{
			$self->render_later;
			$self->get_connecting_trains_p->then(
				sub {
					my @connecting_trains = @_;
					$self->render(
						'_checked_in',
						journey     => $status,
						connections => \@connecting_trains
					);
				}
			)->catch(
				sub {
					$self->render( '_checked_in', journey => $status );
				}
			)->wait;
			return;
		}
		$self->render( '_checked_in', journey => $status );
	}
	elsif ( $status->{cancellation} ) {
		$self->render_later;
		$self->get_connecting_trains_p(
			eva              => $status->{cancellation}{dep_eva},
			destination_name => $status->{cancellation}{arr_name}
		)->then(
			sub {
				my (@connecting_trains) = @_;
				$self->render(
					'_cancelled_departure',
					journey     => $status->{cancellation},
					connections => \@connecting_trains
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
					my @connecting_trains = @_;
					$self->render(
						'_checked_out',
						journey     => $status,
						connections => \@connecting_trains
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

		my ( $train, $error ) = $self->checkin(
			station  => $params->{station},
			train_id => $params->{train}
		);
		my $destination = $params->{dest};

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		elsif ( not $destination ) {
			$self->render(
				json => {
					success     => 1,
					redirect_to => '/',
				},
			);
		}
		else {
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
		my ( undef, $error ) = $self->checkin(
			station  => $params->{station},
			train_id => $params->{train}
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
	$self->iris->get_departures_p(
		station      => $station,
		lookbehind   => 120,
		lookahead    => 30,
		with_related => 1
	)->then(
		sub {
			my ($status) = @_;

			# You can't check into a train which terminates here
			my @results = grep { $_->departure } @{ $status->{results} };

			@results = map { $_->[0] }
			  sort { $b->[1] <=> $a->[1] }
			  map { [ $_, $_->departure->epoch // $_->sched_departure->epoch ] }
			  @results;

			my $connections_p;
			if ($train) {
				@results
				  = grep { $_->type . ' ' . $_->train_no eq $train } @results;
			}
			else {
				my $user = $self->get_user_status;
				if (    $user->{cancellation}
					and $status->{station_eva} eq
					$user->{cancellation}{dep_eva} )
				{
					$connections_p = $self->get_connecting_trains_p(
						eva              => $user->{cancellation}{dep_eva},
						destination_name => $user->{cancellation}{arr_name}
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
						my @connecting_trains = @_;
						$self->render(
							'departures',
							eva              => $status->{station_eva},
							results          => \@results,
							station          => $status->{station_name},
							related_stations => $status->{related_stations},
							connections      => \@connecting_trains,
							title => "travelynx: $status->{station_name}",
						);
					}
				)->catch(
					sub {
						$self->render(
							'departures',
							eva              => $status->{station_eva},
							results          => \@results,
							station          => $status->{station_name},
							related_stations => $status->{related_stations},
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
					station          => $status->{station_name},
					related_stations => $status->{related_stations},
					title            => "travelynx: $status->{station_name}",
				);
			}
		}
	)->catch(
		sub {
			my ($status) = @_;
			if ( $status->{errstr} ) {
				$self->render(
					'landingpage',
					version => $self->app->config->{version} // 'UNKNOWN',
					with_autocomplete => 1,
					with_geolocation  => 1,
					error             => $status->{errstr}
				);
			}
			else {
				$self->render( 'exception', exception => $status );
			}
		}
	)->wait;
	$self->users->mark_seen( uid => $self->current_user->{id} );
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

	if ( $filter_from and $filter_from =~ m{ ^ (\d+) [.] (\d+) [.] (\d+) $ }x )
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
		@journeys = grep { has_str_in_list( $_->{type}, @filter ) } @journeys;
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

sub yearly_history {
	my ($self) = @_;
	my $year = $self->stash('year');
	my @journeys;
	my $stats;

	# DateTime is very slow when looking far into the future due to DST changes
	# -> Limit time range to avoid accidental DoS.
	if ( not( $year =~ m{ ^ [0-9]{4} $ }x and $year > 1990 and $year < 2100 ) )
	{
		@journeys = $self->journeys->get(
			uid           => $self->current_user->{id},
			with_datetime => 1
		);
	}
	else {
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
		$stats = $self->journeys->get_stats(
			uid  => $self->current_user->{id},
			year => $year
		);
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_year',
			journeys   => [@journeys],
			year       => $year,
			statistics => $stats
		}
	);

}

sub monthly_history {
	my ($self) = @_;
	my $year   = $self->stash('year');
	my $month  = $self->stash('month');
	my @journeys;
	my $stats;
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
		@journeys = $self->journeys->get(
			uid           => $self->current_user->{id},
			with_datetime => 1
		);
	}
	else {
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
		$stats = $self->journeys->get_stats(
			uid   => $self->current_user->{id},
			year  => $year,
			month => $month
		);
	}

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

	my $uid = $self->current_user->{id};

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
		uid           => $uid,
		journey_id    => $journey_id,
		verbose       => 1,
		with_datetime => 1,
		with_polyline => 1,
	);

	if ($journey) {
		my $map_data = $self->journeys_to_map_data(
			journeys       => [$journey],
			include_manual => 1,
		);
		$self->render(
			'journey',
			error    => undef,
			journey  => $journey,
			with_map => 1,
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
		$self->in_transit->update_user_data(
			uid       => $self->current_user->{id},
			user_data => { comment => $self->param('comment') }
		);
		$self->redirect_to('/');
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
