package Travelynx::Controller::Passengerrights;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use List::Util;
use POSIX;
use CAM::PDF;

# Internal Helpers

sub mark_if_missed_connection {
	my ( $self, $journey, $next_journey ) = @_;

	my $possible_delay
	  = (   $next_journey->{rt_departure}->epoch
		  - $journey->{sched_arrival}->epoch )
	  / 60;
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

	my @substitute_candidates = reverse $self->journeys->get(
		uid    => $self->current_user->{id},
		after  => $journey->{sched_departure}->clone->subtract( hours => 1 ),
		before => $journey->{sched_departure}->clone->add( hours => 12 ),
		with_datetime => 1,
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
		  = ( $last_substitute->{rt_arr_ts} - $journey->{sched_arr_ts} ) / 60;
	}
}

# Controllers

sub list_candidates {
	my ($self) = @_;

	my $now         = DateTime->now( time_zone => 'Europe/Berlin' );
	my $range_start = $now->clone->subtract( months => 6 );

	my @journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $range_start,
		before        => $now,
		with_datetime => 1,
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

	my @abo_journeys
	  = grep { $_->{delay} >= 20 and $_->{delay} < 60 } @journeys;
	@journeys = grep { $_->{delay} >= 60 or $_->{connection_missed} } @journeys;

	my @cancelled = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $range_start,
		before        => $now,
		cancelled     => 1,
		with_datetime => 1,
	);
	for my $journey (@cancelled) {

		if ( not $journey->{sched_arrival}->epoch ) {
			next;
		}

		$journey->{cancelled} = 1;
		$self->mark_substitute_connection($journey);

		if (    $journey->{has_substitute}
			and $journey->{to_substitute}->{rt_arr_ts}
			- $journey->{sched_arr_ts} >= 3600 )
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
			template     => 'passengerrights',
			journeys     => [@journeys],
			abo_journeys => [@abo_journeys]
		}
	);
}

sub list_cumulative_delays {
	my ($self) = @_;
	my $parser = DateTime::Format::Strptime->new(
		pattern   => '%Y-%m-%d',
		locale    => 'de_DE',
		time_zone => 'Europe/Berlin'
	);
	my @fv_types = qw(IC ICE EC ECE RJ RJX D IR NJ TGV WB FLX);
	my @not_train_types = qw(Bus STR STB U);
	my $ticket_value = $self->param('ticket_value') // 150;

	my $start = $self->param('start') ?
		$parser->parse_datetime($self->param('start')) :
		$self->now->truncate(to=>'month');

	my $end = $self->param('end') ?
		$parser->parse_datetime($self->param('end')) :
		$self->now->truncate(to=>'month')->add(months=>1)->subtract(days=>1);

	my @journeys = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $start->clone,
		before        => $end->clone->add(days=>1),
		with_datetime => 1,
	);
	# filter for realtime data
	@journeys = grep { $_->{sched_arrival}->epoch and $_->{rt_arrival}->epoch }
		@journeys;

	# look for substitute connections after cancellation
	# start by finding all canceled trains during ticket validity
	my @cancelled = $self->journeys->get(
		uid           => $self->current_user->{id},
		after         => $start->clone,
		before        => $end->clone->add(days=>1),
		cancelled     => 1,
		with_datetime => 1,
	);
	for my $journey (@cancelled) {
		# filter out non-train transports not covered by FGR
		if (List::Util::any {$journey->{type} eq $_} @not_train_types) {
			next;
		}
		if ( not $journey->{sched_arrival}->epoch ) {
			next;
		}

		# try to find a substitute connection for the canceled train
		$journey->{cancelled} = 1;
		$self->mark_substitute_connection($journey);
		# if we have a substitute connection with real-time data, add the
		# train to the eligible list
		if ($journey->{has_substitute} and
		$journey->{to_substitute}->{rt_arr_ts}) {
			push( @journeys, $journey );
		}
	}

	# sum up delays
	my $cumulative_delay = 0;
	for my $i ( 0 .. $#journeys ) {
		my $journey = $journeys[$i];
		# filter out non-train transports not covered by FGR
		if (List::Util::any {$journey->{type} eq $_} @not_train_types) {
			next;
		}
		# if we're using a regional ticket, filter out all long-distance trains
		if ($ticket_value < 500 and List::Util::any {$journey->{type} eq $_} @fv_types) {
			next;
		}

		$journey->{delay} = $journey->{substitute_delay} //
			( $journey->{rt_arrival}->epoch - $journey->{sched_arrival}->epoch ) / 60;

		# find candidates for missed connections - if we arrive with a delay and
		# later check into a train again from the same station
		# note that we can't assign a delay to potential missed connections
		# because we don't know the planned arrival of the train we missed
		if ( $i > 0 and $journey->{delay} >= 3) {
			$self->mark_if_missed_connection( $journey, $journeys[ $i - 1 ] );
		}

		if ($journey->{delay} >= 20) {
			# add up to 60 minutes of delay per journey
			# not entirely clear if you could in theory get compensation
			# for a single 180-minute-delayed journey, so let's play it safe
			$cumulative_delay += ($journey->{delay} < 60) ? $journey->{delay} : 60;
			$journey->{generate_fgr_target} = sprintf(
				'/journey/passenger_rights/FGR %s %s %s.pdf',
				$journey->{sched_departure}->ymd, $journey->{type}, $journey->{no}
			);
		} elsif ($journey->{connection_missed}) {
			$journey->{generate_fgr_target} = sprintf(
				'/journey/passenger_rights/FGR %s %s %s.pdf',
				$journey->{sched_departure}->ymd, $journey->{type}, $journey->{no}
			);
		}
	}
	# filter out journeys with delay below +20
	@journeys = grep { ($_->{delay} // 0) >= 20 or $_->{connection_missed} } @journeys;
	# sort by departure - we did add all the substitute trains to the very back
	@journeys = sort {$b->{rt_departure} cmp $a->{rt_departure}} @journeys;


	my $compensation_amount = floor($cumulative_delay / 60) * $ticket_value;

	my $min_delay_for_compensation = ceil(400/$ticket_value) * 60;
	my $bar_fill = int( ($cumulative_delay/$min_delay_for_compensation) * 100);
	$bar_fill = $bar_fill > 100 ? 100 : $bar_fill;

	$self->render(
		'passengerrights_cumulative',
		title=>'travelynx: Fahrgastrechte Zeitkarten',
		start=>$start,
		end=>$end,
		journeys=>[@journeys],
		num_journeys=>scalar @journeys,
		cumulative_delay=>$cumulative_delay,
		compensation_amount=>$compensation_amount,
		min_delay_for_compensation=>$min_delay_for_compensation,
		bar_fill=>$bar_fill,
		ticket_value=>$ticket_value,
		did_miss_connections=>List::Util::any { $_->{connection_missed} } @journeys
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

	my $journey = $self->journeys->get_single(
		uid           => $uid,
		journey_id    => $journey_id,
		verbose       => 1,
		with_datetime => 1,
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
		my @connections = $self->journeys->get(
			uid           => $uid,
			after         => $journey->{rt_arrival},
			before        => $journey->{rt_arrival}->clone->add( hours => 2 ),
			with_datetime => 1,
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
