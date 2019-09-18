package Travelynx::Controller::Passengerrights;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use CAM::PDF;

sub mark_if_missed_connection {
	my ( $self, $journey, $next_journey ) = @_;

	my $possible_delay
	  = (   $next_journey->{rt_departure}->epoch
		  - $journey->{sched_arrival}->epoch ) / 60;
	my $wait_time
	  = ( $next_journey->{rt_departure}->epoch - $journey->{rt_arrival}->epoch )
	  / 60;

	# Assumption: $next_journey is a missed connection (i.e., if $journey had
	# been on time it would have been an earlier train)
	# * the wait time between arrival and departure is less than 70 minutes
	#   (up to 60 minutes to wait for the next train in an hourly connection
	#    + up to 10 minutes transfer time between platforms)
	# * the delay between scheduled arrival at the interchange station and
	#   real departure of $next_journey (which is hopefully the same as the
	#   total delay at the destination of $next_journey) is more than 120
	#   minutes (-> 50% fare reduction) or it is more than 60 minutes and the
	#   single-journey delay is less than 60 minutes (-> 25% fare reduction)
	#   This ensures that $next_journey is only referenced if the missed
	#   connection makes a difference from a passenger rights point of view --
	#   if $journey itself is already 60 .. 119 minutes delayed and the
	#   delay with the connection to $next_journey is also 60 .. 119 minutes,
	#   including it is not worth the effort. Similarly, if $journey is already
	#   ≥120 minutes delayed, looking for connections and more delay is
	#   pointless.

	if (
		$wait_time < 70
		and ( $possible_delay >= 120
			or ( $journey->{delay} < 60 and $possible_delay >= 60 ) )
	  )
	{
		$journey->{connection_missed} = 1;
		$journey->{connection}        = $next_journey;
		$journey->{possible_delay}    = $possible_delay;
		$journey->{wait_time}         = $wait_time;
		return 1;
	}
	return 0;
}

sub mark_substitute_connection {
	my ( $self, $journey ) = @_;

	my @substitute_candidates = reverse $self->get_user_travels(
		after  => $journey->{sched_departure}->clone->subtract( hours => 1 ),
		before => $journey->{sched_departure}->clone->add( hours => 12 ),
	);

	my ( $first_substitute, $last_substitute );

	for my $substitute_candidate (@substitute_candidates) {
		if ( not $first_substitute
			and $substitute_candidate->{from_name} eq $journey->{from_name} )
		{
			$first_substitute = $substitute_candidate;
		}
		if ( not $last_substitute
			and $substitute_candidate->{to_name} eq $journey->{to_name} )
		{
			$last_substitute = $substitute_candidate;
			last;
		}
	}

	if ( $first_substitute and $last_substitute ) {
		$journey->{has_substitute}  = 1;
		$journey->{from_substitute} = $first_substitute;
		$journey->{to_substitute}   = $last_substitute;
		$journey->{substitute_delay}
		  = (   $last_substitute->{rt_arrival}->epoch
			  - $journey->{sched_arrival}->epoch ) / 60;
	}
}

sub list_candidates {
	my ($self) = @_;

	my $now         = DateTime->now( time_zone => 'Europe/Berlin' );
	my $range_start = $now->clone->subtract( months => 6 );

	my @journeys = $self->get_user_travels(
		after  => $range_start,
		before => $now
	);
	@journeys = grep { $_->{sched_arrival}->epoch and $_->{rt_arrival}->epoch }
	  @journeys;

	for my $i ( 0 .. $#journeys ) {
		my $journey = $journeys[$i];

		$journey->{delay}
		  = ( $journey->{rt_arrival}->epoch - $journey->{sched_arrival}->epoch )
		  / 60;

		if ( $journey->{delay} < 3 or $journey->{delay} >= 120 ) {
			next;
		}
		if ( $i > 0 ) {
			$self->mark_if_missed_connection( $journey, $journeys[ $i - 1 ] );
		}
	}

	@journeys = grep { $_->{delay} >= 60 or $_->{connection_missed} } @journeys;

	my @cancelled = $self->get_user_travels(
		after     => $range_start,
		before    => $now,
		cancelled => 1
	);
	for my $journey (@cancelled) {

		if ( not $journey->{sched_arrival}->epoch ) {
			next;
		}

		$journey->{cancelled} = 1;
		$self->mark_substitute_connection($journey);

		if ( not $journey->{has_substitute}
			or $journey->{to_substitute}->{rt_arrival}->epoch
			- $journey->{sched_arrival}->epoch >= 3600 )
		{
			push( @journeys, $journey );
		}
	}

	@journeys
	  = sort { $b->{sched_departure}->epoch <=> $a->{sched_departure}->epoch }
	  @journeys;

	$self->respond_to(
		json => { json => [@journeys] },
		any  => {
			template => 'passengerrights',
			journeys => [@journeys]
		}
	);
}

sub generate {
	my ($self) = @_;
	my $journey_id = $self->param('id');

	my $uid = $self->current_user->{id};

	if ( not($journey_id) ) {
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->get_journey(
		uid        => $uid,
		journey_id => $journey_id,
		verbose    => 1,
	);

	if ( not $journey ) {
		$self->render(
			'journey',
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	$journey->{delay}
	  = ( $journey->{rt_arrival}->epoch - $journey->{sched_arrival}->epoch )
	  / 60;

	if ( $journey->{cancelled} ) {
		$self->mark_substitute_connection($journey);
	}
	elsif ( $journey->{delay} < 120 ) {
		my @connections = $self->get_user_travels(
			uid    => $uid,
			after  => $journey->{rt_arrival},
			before => $journey->{rt_arrival}->clone->add( hours => 2 )
		);
		if (@connections) {
			$self->mark_if_missed_connection( $journey, $connections[-1] );
		}
	}

	my $pdf = CAM::PDF->new('public/static/pdf/fahrgastrechteformular.pdf');

	# from station
	$pdf->fillFormFields( 'S1F4', $journey->{from_name} );

	if ( $journey->{connection} ) {

		# to station
		$pdf->fillFormFields( 'S1F7', $journey->{connection}{to_name} );

		# missed connection in:
		$pdf->fillFormFields( 'S1F22', $journey->{to_name} );

		# last change in:
		$pdf->fillFormFields( 'S1F24', $journey->{to_name} );
	}
	else {
		# to station
		$pdf->fillFormFields( 'S1F7', $journey->{to_name} );
	}

	if ( $journey->{has_substitute} ) {

		# arived with: TRAIN NO
		$pdf->fillFormFields( 'S1F13', $journey->{to_substitute}{type} );
		$pdf->fillFormFields( 'S1F14', $journey->{to_substitute}{no} );

		# arrival YYMMDD
		$pdf->fillFormFields( 'S1F10',
			$journey->{to_substitute}{rt_arrival}->strftime('%d') );
		$pdf->fillFormFields( 'S1F11',
			$journey->{to_substitute}{rt_arrival}->strftime('%m') );
		$pdf->fillFormFields( 'S1F12',
			$journey->{to_substitute}{rt_arrival}->strftime('%y') );

		# arrival HHMM
		$pdf->fillFormFields( 'S1F15',
			$journey->{to_substitute}{rt_arrival}->strftime('%H') );
		$pdf->fillFormFields( 'S1F16',
			$journey->{to_substitute}{rt_arrival}->strftime('%M') );

		if ( $journey->{from_substitute} != $journey->{to_substitute} ) {

			# last change in:
			$pdf->fillFormFields( 'S1F24',
				$journey->{to_substitute}{from_name} );
		}
	}
	elsif ( not $journey->{cancelled} ) {

		# arived with: TRAIN NO
		if ( $journey->{connection} ) {
			$pdf->fillFormFields( 'S1F13', $journey->{connection}{type} );
			$pdf->fillFormFields( 'S1F14', $journey->{connection}{no} );
		}
		else {
			$pdf->fillFormFields( 'S1F13', $journey->{type} );
			$pdf->fillFormFields( 'S1F14', $journey->{no} );
		}
	}

	# first delayed train: TRAIN NO
	$pdf->fillFormFields( 'S1F17', $journey->{type} );
	$pdf->fillFormFields( 'S1F18', $journey->{no} );

	if ( $journey->{sched_departure}->epoch ) {

		# journey YYMMDD
		$pdf->fillFormFields( 'S1F1',
			$journey->{sched_departure}->strftime('%d') );
		$pdf->fillFormFields( 'S1F2',
			$journey->{sched_departure}->strftime('%m') );
		$pdf->fillFormFields( 'S1F3',
			$journey->{sched_departure}->strftime('%y') );

		# sched departure HHMM
		$pdf->fillFormFields( 'S1F5',
			$journey->{sched_departure}->strftime('%H') );
		$pdf->fillFormFields( 'S1F6',
			$journey->{sched_departure}->strftime('%M') );

		# first delayed train: sched departure HHMM
		$pdf->fillFormFields( 'S1F19',
			$journey->{sched_departure}->strftime('%H') );
		$pdf->fillFormFields( 'S1F20',
			$journey->{sched_departure}->strftime('%M') );
	}
	if ( $journey->{sched_arrival}->epoch ) {

		# sched arrival HHMM
		if ( $journey->{connection} ) {

			# TODO (needs plan data for non-journey trains)
		}
		else {
			$pdf->fillFormFields( 'S1F8',
				$journey->{sched_arrival}->strftime('%H') );
			$pdf->fillFormFields( 'S1F9',
				$journey->{sched_arrival}->strftime('%M') );
		}
	}
	if ( $journey->{rt_arrival}->epoch and not $journey->{cancelled} ) {

		if ( $journey->{connection} ) {

			# arrival YYMMDD
			$pdf->fillFormFields( 'S1F10',
				$journey->{connection}{rt_arrival}->strftime('%d') );
			$pdf->fillFormFields( 'S1F11',
				$journey->{connection}{rt_arrival}->strftime('%m') );
			$pdf->fillFormFields( 'S1F12',
				$journey->{connection}{rt_arrival}->strftime('%y') );

			# arrival HHMM
			$pdf->fillFormFields( 'S1F15',
				$journey->{connection}{rt_arrival}->strftime('%H') );
			$pdf->fillFormFields( 'S1F16',
				$journey->{connection}{rt_arrival}->strftime('%M') );
		}
		else {
			# arrival YYMMDD
			$pdf->fillFormFields( 'S1F10',
				$journey->{rt_arrival}->strftime('%d') );
			$pdf->fillFormFields( 'S1F11',
				$journey->{rt_arrival}->strftime('%m') );
			$pdf->fillFormFields( 'S1F12',
				$journey->{rt_arrival}->strftime('%y') );

			# arrival HHMM
			$pdf->fillFormFields( 'S1F15',
				$journey->{rt_arrival}->strftime('%H') );
			$pdf->fillFormFields( 'S1F16',
				$journey->{rt_arrival}->strftime('%M') );
		}
	}

	$self->res->headers->content_type('application/pdf');
	$self->res->body( $pdf->toPDF() );
	$self->rendered(200);

}

1;
