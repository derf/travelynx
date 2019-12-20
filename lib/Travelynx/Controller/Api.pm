package Travelynx::Controller::Api;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use List::Util;
use Travel::Status::DE::IRIS::Stations;
use UUID::Tiny qw(:std);

sub make_token {
	return create_uuid_as_string(UUID_V4);
}

sub sanitize {
	my ( $type, $value ) = @_;
	if ( not defined $value ) {
		return undef;
	}
	if ( $type eq '' ) {
		return '' . $value;
	}
	return 0 + $value;
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
					ds100 => $status->{arr_ds100} // $status->{dep_ds100},
					name  => $status->{arr_name}  // $status->{dep_name},
					uic   => $station_eva,
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

sub travel_v1 {
	my ($self) = @_;

	my $payload = $self->req->json;

	if ( not $payload or ref($payload) ne 'HASH' ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Malformed JSON',
			},
		);
		return;
	}

	if ( $self->app->mode ne 'development' ) {
		$self->render(
			json => {
				success => \0,
				error =>
'This feature is incomplete and only available in development mode',
			},
		);
		return;
	}

	my $api_token = $payload->{token} // '';

	if ( $api_token !~ qr{ ^ (?<id> \d+ ) - (?<token> .* ) $ }x ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Malformed token',
			},
		);
		return;
	}
	my $uid = $+{id};
	$api_token = $+{token};

	if ( $uid > 2147483647 ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Malformed token',
			},
		);
		return;
	}

	my $token = $self->get_api_token($uid);
	if ( $api_token ne $token->{'travel'} ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Invalid token',
			},
		);
		return;
	}

	if ( not exists $payload->{action}
		or $payload->{action} !~ m{^(checkin|checkout|undo)$} )
	{
		$self->render(
			json => {
				success => \0,
				error   => 'Missing or invalid action',
			},
		);
		return;
	}

	if ( $payload->{action} eq 'checkin' ) {
		my $from_station = sanitize( q{}, $payload->{fromStation} );
		my $to_station   = sanitize( q{}, $payload->{toStation} );
		my $train_id;

		if ( exists $payload->{train}{id} ) {
			$train_id = sanitize( 0, $payload->{train}{id} );
		}
		else {
			my $train_type = sanitize( q{}, $payload->{train}{type} );
			my $train_no   = sanitize( q{}, $payload->{train}{no} );
			my $status = $self->get_departures( $from_station, 140, 40, 0 );
			if ( $status->{errstr} ) {
				$self->render(
					json => {
						success => \0,
						error   => 'Fehler am Abfahrtsbahnhof: '
						  . $status->{errstr},
						status => $self->get_user_status_json_v1($uid)
					}
				);
				return;
			}
			my ($train) = List::Util::first {
				$_->type eq $train_type and $_->train_no eq $train_no
			}
			@{ $status->{results} };
			if ( not defined $train ) {
				$self->render(
					json => {
						success => \0,
						error   => 'Fehler am Abfahrtsbahnhof: '
						  . $status->{errstr},
						status => $self->get_user_status_json_v1($uid)
					}
				);
				return;
			}
			$train_id = $train->train_id;
		}

		my ( $train, $error )
		  = $self->checkin( $from_station, $train_id, $uid );
		if ( $payload->{comment} and not $error ) {
			$self->update_in_transit_comment(
				sanitize( q{}, $payload->{comment} ), $uid );
		}
		if ( $to_station and not $error ) {
			( $train, $error ) = $self->checkout( $to_station, 0, $uid );
		}
		if ($error) {
			$self->render(
				json => {
					success => \0,
					error   => $error,
					status  => $self->get_user_status_json_v1($uid)
				}
			);
		}
		else {
			$self->render(
				json => {
					success => \1,
					status  => $self->get_user_status_json_v1($uid)
				}
			);
		}
	}
	elsif ( $payload->{action} eq 'checkout' ) {
		my $to_station = sanitize( q{}, $payload->{toStation} );

		if ( $payload->{comment} ) {
			$self->update_in_transit_comment(
				sanitize( q{}, $payload->{comment} ), $uid );
		}

		my ( $train, $error )
		  = $self->checkout( $to_station, $payload->{force} ? 1 : 0, $uid );
		if ($error) {
			$self->render(
				json => {
					success => \0,
					error   => $error,
					status  => $self->get_user_status_json_v1($uid)
				}
			);
		}
		else {
			$self->render(
				json => {
					success => \1,
					status  => $self->get_user_status_json_v1($uid)
				}
			);
		}
	}
	elsif ( $payload->{action} eq 'undo' ) {
		my $error = $self->undo( 'in_transit', $uid );
		if ($error) {
			$self->render(
				json => {
					success => \0,
					error   => $error,
					status  => $self->get_user_status_json_v1($uid)
				}
			);
		}
		else {
			$self->render(
				json => {
					success => \1,
					status  => $self->get_user_status_json_v1($uid)
				}
			);
		}
	}
}

sub import_v1 {
	my ($self) = @_;

	my $payload = $self->req->json;

	if ( not $payload or ref($payload) ne 'HASH' ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Malformed JSON',
			},
		);
		return;
	}

	if ( $self->app->mode ne 'development' ) {
		$self->render(
			json => {
				success => \0,
				error =>
'This feature is incomplete and only available in development mode',
			},
		);
		return;
	}

	my $api_token = $payload->{token} // '';

	if ( $api_token !~ qr{ ^ (?<id> \d+ ) - (?<token> .* ) $ }x ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Malformed token',
			},
		);
		return;
	}
	my $uid = $+{id};
	$api_token = $+{token};

	if ( $uid > 2147483647 ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Malformed token',
			},
		);
		return;
	}

	my $token = $self->get_api_token($uid);
	if ( $api_token ne $token->{'import'} ) {
		$self->render(
			json => {
				success => \0,
				error   => 'Invalid token',
			},
		);
		return;
	}

	if (   not exists $payload->{fromStation}
		or not exists $payload->{toStation} )
	{
		$self->render(
			json => {
				success => \0,
				error   => 'missing fromStation or toStation',
			},
		);
		return;
	}

	my %opt;

	eval {

		if (   not $payload->{fromStation}{name}
			or not $payload->{toStation}{name} )
		{
			die("Missing fromStation/toStation name\n");
		}
		if ( not $payload->{train}{type} or not $payload->{train}{no} ) {
			die("Missing train data\n");
		}
		if (   not $payload->{fromStation}{scheduledTime}
			or not $payload->{toStation}{scheduledTime} )
		{
			die("Missing fromStation/toStation scheduledTime\n");
		}

		%opt = (
			uid         => $uid,
			train_type  => sanitize( q{}, $payload->{train}{type} ),
			train_no    => sanitize( q{}, $payload->{train}{no} ),
			train_line  => sanitize( q{}, $payload->{train}{line} ),
			cancelled   => $payload->{cancelled} ? 1 : 0,
			dep_station => sanitize( q{}, $payload->{fromStation}{name} ),
			arr_station => sanitize( q{}, $payload->{toStation}{name} ),
			sched_departure =>
			  sanitize( 0, $payload->{fromStation}{scheduledTime} ),
			rt_departure => sanitize(
				0,
				$payload->{fromStation}{realTime}
				  // $payload->{fromStation}{scheduledTime}
			),
			sched_arrival =>
			  sanitize( 0, $payload->{toStation}{scheduledTime} ),
			rt_arrival => sanitize(
				0,
				$payload->{toStation}{realTime}
				  // $payload->{toStation}{scheduledTime}
			),
			comment => sanitize( q{}, $payload->{comment} ),
			lax     => $payload->{lax} ? 1 : 0,
		);

		if ( $payload->{route} and ref( $payload->{route} ) eq 'ARRAY' ) {
			$opt{route}
			  = [ map { sanitize( q{}, $_ ) } @{ $payload->{route} } ];
		}

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			$opt{$key} = DateTime->from_epoch(
				time_zone => 'Europe/Berlin',
				epoch     => $opt{$key}
			);
		}
	};
	if ($@) {
		my ($first_line) = split( qr{\n}, $@ );
		$self->render(
			json => {
				success => \0,
				error   => $first_line
			}
		);
		return;
	}

	my $db = $self->pg->db;
	my $tx = $db->begin;

	$opt{db} = $db;
	my ( $journey_id, $error ) = $self->add_journey(%opt);
	my $journey;

	if ( not $error ) {
		$journey = $self->get_journey(
			uid        => $uid,
			db         => $db,
			journey_id => $journey_id,
			verbose    => 1
		);
		$error
		  = $self->journey_sanity_check( $journey, $payload->{lax} ? 1 : 0 );
	}

	if ($error) {
		$self->render(
			json => {
				success => \0,
				error   => $error
			}
		);
	}
	elsif ( $payload->{dryRun} ) {
		$self->render(
			json => {
				success => \1,
				id      => $journey_id,
				result  => $journey
			}
		);
	}
	else {
		$tx->commit;
		$self->render(
			json => {
				success => \1,
				id      => $journey_id,
				result  => $journey
			}
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
