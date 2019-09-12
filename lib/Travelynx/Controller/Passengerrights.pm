package Travelynx::Controller::Passengerrights;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use CAM::PDF;

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

	my $pdf = CAM::PDF->new('public/static/pdf/fahrgastrechteformular.pdf');

	$pdf->fillFormFields( 'S1F4', $journey->{from_name} );
	$pdf->fillFormFields( 'S1F7', $journey->{to_name} );
	if ( not $journey->{cancelled} ) {
		$pdf->fillFormFields( 'S1F13', $journey->{type} );
		$pdf->fillFormFields( 'S1F14', $journey->{no} );
	}
	$pdf->fillFormFields( 'S1F17', $journey->{type} );
	$pdf->fillFormFields( 'S1F18', $journey->{no} );
	if ( $journey->{sched_departure}->epoch ) {
		$pdf->fillFormFields( 'S1F1',
			$journey->{sched_departure}->strftime('%d') );
		$pdf->fillFormFields( 'S1F2',
			$journey->{sched_departure}->strftime('%m') );
		$pdf->fillFormFields( 'S1F3',
			$journey->{sched_departure}->strftime('%y') );
		$pdf->fillFormFields( 'S1F5',
			$journey->{sched_departure}->strftime('%H') );
		$pdf->fillFormFields( 'S1F6',
			$journey->{sched_departure}->strftime('%M') );
		$pdf->fillFormFields( 'S1F19',
			$journey->{sched_departure}->strftime('%H') );
		$pdf->fillFormFields( 'S1F20',
			$journey->{sched_departure}->strftime('%M') );
	}
	if ( $journey->{sched_arrival}->epoch ) {
		$pdf->fillFormFields( 'S1F8',
			$journey->{sched_arrival}->strftime('%H') );
		$pdf->fillFormFields( 'S1F9',
			$journey->{sched_arrival}->strftime('%M') );
	}
	if ( $journey->{rt_arrival}->epoch and not $journey->{cancelled} ) {
		$pdf->fillFormFields( 'S1F10', $journey->{rt_arrival}->strftime('%d') );
		$pdf->fillFormFields( 'S1F11', $journey->{rt_arrival}->strftime('%m') );
		$pdf->fillFormFields( 'S1F12', $journey->{rt_arrival}->strftime('%y') );
		$pdf->fillFormFields( 'S1F15', $journey->{rt_arrival}->strftime('%H') );
		$pdf->fillFormFields( 'S1F16', $journey->{rt_arrival}->strftime('%M') );
	}

	$self->res->headers->content_type('application/pdf');
	$self->res->body( $pdf->toPDF() );
	$self->rendered(200);

}

1;
