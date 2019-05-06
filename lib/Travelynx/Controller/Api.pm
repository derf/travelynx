package Travelynx::Controller::Api;
use Mojo::Base 'Mojolicious::Controller';

use Travel::Status::DE::IRIS::Stations;
use UUID::Tiny qw(:std);

sub make_token {
	return create_uuid_as_string(UUID_V4);
}

sub documentation {
	my ($self) = @_;

	$self->render('api_documentation');
}

sub get_v0 {
	my ($self) = @_;

	my $api_action = $self->stash('user_action');
	my $api_token  = $self->stash('token');
	if ( $api_action !~ qr{ ^ (?: status | history | action ) $ }x ) {
		$self->render(
			json => {
				error => 'Invalid action',
			},
		);
		return;
	}
	if ( $api_token !~ qr{ ^ (?<id> \d+ ) - (?<token> .* ) $ }x ) {
		$self->render(
			json => {
				error => 'Malformed token',
			},
		);
		return;
	}
	my $uid = $+{id};
	$api_token = $+{token};
	my $token = $self->get_api_token($uid);
	if ( $api_token ne $token->{$api_action} ) {
		$self->render(
			json => {
				error => 'Invalid token',
			},
		);
		return;
	}
	if ( $api_action eq 'status' ) {
		my $status = $self->get_user_status($uid);

		my @station_descriptions;
		my $station_eva = undef;
		my $station_lon = undef;
		my $station_lat = undef;

		if ( $status->{arr_ds100} // $status->{dep_ds100} ) {
			@station_descriptions
			  = Travel::Status::DE::IRIS::Stations::get_station(
				$status->{arr_ds100} // $status->{dep_ds100} );
		}
		if ( @station_descriptions == 1 ) {
			( undef, undef, $station_eva, $station_lon, $station_lat )
			  = @{ $station_descriptions[0] };
		}
		$self->render(
			json => {
				deprecated => \1,
				checked_in => (
					     $status->{checked_in}
					  or $status->{cancelled}
				) ? \1 : \0,
				station => {
					ds100     => $status->{arr_ds100} // $status->{dep_ds100},
					name      => $status->{arr_name} // $status->{dep_name},
					uic       => $station_eva,
					longitude => $station_lon,
					latitude  => $station_lat,
				},
				train => {
					type => $status->{train_type},
					line => $status->{train_line},
					no   => $status->{train_no},
				},
				actionTime    => $status->{timestamp}->epoch,
				scheduledTime => $status->{sched_arrival}->epoch
				  || $status->{sched_departure}->epoch,
				realTime => $status->{real_arrival}->epoch
				  || $status->{real_departure}->epoch,
			},
		);
	}
	else {
		$self->render(
			json => {
				error => 'not implemented',
			},
		);
	}
}

sub get_v1 {
	my ($self) = @_;

	my $api_action = $self->stash('user_action');
	my $api_token  = $self->stash('token');
	if ( $api_action !~ qr{ ^ (?: status | history | action ) $ }x ) {
		$self->render(
			json => {
				error => 'Invalid action',
			},
		);
		return;
	}
	if ( $api_token !~ qr{ ^ (?<id> \d+ ) - (?<token> .* ) $ }x ) {
		$self->render(
			json => {
				error => 'Malformed token',
			},
		);
		return;
	}
	my $uid = $+{id};
	$api_token = $+{token};

	if ( $uid > 2147483647 ) {
		$self->render(
			json => {
				error => 'Malformed token',
			},
		);
		return;
	}

	my $token = $self->get_api_token($uid);
	if ( $api_token ne $token->{$api_action} ) {
		$self->render(
			json => {
				error => 'Invalid token',
			},
		);
		return;
	}
	if ( $api_action eq 'status' ) {
		$self->render( json => $self->get_user_status_json_v1($uid) );
	}
	else {
		$self->render(
			json => {
				error => 'not implemented',
			},
		);
	}
}

sub set_token {
	my ($self) = @_;
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render( 'account', invalid => 'csrf' );
		return;
	}
	my $token    = make_token();
	my $token_id = $self->app->token_type->{ $self->param('token') };

	if ( not $token_id ) {
		$self->redirect_to('account');
		return;
	}

	if ( $self->param('action') eq 'delete' ) {
		$self->pg->db->delete(
			'tokens',
			{
				user_id => $self->current_user->{id},
				type    => $token_id
			}
		);
	}
	else {
		$self->pg->db->insert(
			'tokens',
			{
				user_id => $self->current_user->{id},
				type    => $token_id,
				token   => $token
			},
			{
				on_conflict => \
				  '(user_id, type) do update set token = EXCLUDED.token'
			},
		);
	}
	$self->redirect_to('account');
}

1;
