package Travelynx::Controller::Traveling;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use Travel::Status::DE::IRIS::Stations;

sub homepage {
	my ($self) = @_;
	if ( $self->is_user_authenticated ) {
		$self->render( 'landingpage', with_geolocation => 1 );
	}
	else {
		$self->render( 'landingpage', intro => 1 );
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
			$lat, 5 );
		$self->render(
			json => {
				candidates => [@candidates],
			}
		);
	}
}

sub log_action {
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

		my ( $train, $error )
		  = $self->checkin( $params->{station}, $params->{train} );

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
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'checkout' ) {
		my $error = $self->checkout( $params->{station}, $params->{force} );

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
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'undo' ) {
		my $error = $self->undo( $params->{undo_id} );
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
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_from' ) {
		my ( undef, $error )
		  = $self->checkin( $params->{station}, $params->{train},
			$self->app->action_type->{cancelled_from} );

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
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_to' ) {
		my $error = $self->checkout( $params->{station}, 1,
			$self->app->action_type->{cancelled_to} );

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
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'delete' ) {
		my ( $from, $to ) = split( qr{,}, $params->{ids} );
		my $error = $self->delete_journey( $from, $to, $params->{checkin},
			$params->{checkout} );
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
					success => 1,
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

	my $status = $self->get_departures($station);

	if ( $status->{errstr} ) {
		$self->render(
			'landingpage',
			with_geolocation => 1,
			error            => $status->{errstr}
		);
	}
	else {
		# You can't check into a train which terminates here
		my @results = grep { $_->departure } @{ $status->{results} };

		@results = map { $_->[0] }
		  sort { $b->[1] <=> $a->[1] }
		  map { [ $_, $_->departure->epoch // $_->sched_departure->epoch ] }
		  @results;

		if ($train) {
			@results
			  = grep { $_->type . ' ' . $_->train_no eq $train } @results;
		}

		$self->render(
			'departures',
			ds100   => $status->{station_ds100},
			results => \@results,
			station => $status->{station_name},
			title   => "travelynx: $status->{station_name}",
		);
	}
}

sub redirect_to_station {
	my ($self) = @_;
	my $station = $self->param('station');

	$self->redirect_to("/s/${station}");
}

sub history {
	my ($self) = @_;
	my $cancelled = $self->param('cancelled') ? 1 : 0;

	my @journeys = $self->get_user_travels( cancelled => $cancelled );

	$self->respond_to(
		json => { json => [@journeys] },
		any  => {
			template => 'history',
			journeys => [@journeys]
		}
	);
}

sub json_history {
	my ($self) = @_;
	my $cancelled = $self->param('cancelled') ? 1 : 0;

	$self->render(
		json => [ $self->get_user_travels( cancelled => $cancelled ) ] );
}

sub monthly_history {
	my ($self) = @_;
	my $year   = $self->stash('year');
	my $month  = $self->stash('month');
	my $cancelled = $self->param('cancelled') ? 1 : 0;
	my @journeys;
	my $stats;
	my @months
	  = (
		qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
	  );

	if ( not( $year =~ m{ ^ [0-9]{4} $ }x and $month =~ m{ ^ [0-9]{1,2} $ }x ) )
	{
		@journeys = $self->get_user_travels( cancelled => $cancelled );
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
		@journeys = $self->get_user_travels(
			cancelled => $cancelled,
			verbose   => 1,
			after     => $interval_start,
			before    => $interval_end
		);
		$stats = $self->compute_journey_stats(@journeys);
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history',
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
	my ( $uid, $checkout_id ) = split( qr{-}, $self->stash('id') );

	if ( not( $uid == $self->current_user->{id} and $checkout_id ) ) {
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my @journeys = $self->get_user_travels(
		uid         => $uid,
		checkout_id => $checkout_id,
		verbose     => 1,
	);
	if (   @journeys == 0
		or not $journeys[0]{completed}
		or $journeys[0]{ids}[1] != $checkout_id )
	{
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	$self->render(
		'journey',
		error   => undef,
		journey => $journeys[0]
	);
}

1;
