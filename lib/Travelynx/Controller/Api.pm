package Travelynx::Controller::Api;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use List::Util;
use Mojo::JSON qw(encode_json);
use UUID::Tiny qw(:std);

# Internal Helpers

sub make_token {
	return create_uuid_as_string(UUID_V4);
}

sub sanitize {
	my ( $type, $value ) = @_;
	if ( not defined $value ) {
		return undef;
	}
	if ( not defined $type ) {
		return $value ? ( '' . $value ) : undef;
	}
	if ( $type eq '' ) {
		return '' . $value;
	}
	if ( $value =~ m{ ^ [0-9.e]+ $ }x ) {
		return 0 + $value;
	}
	return 0;
}

# Contollers

sub documentation {
	my ($self) = @_;

	if ( $self->is_user_authenticated ) {
		my $uid = $self->current_user->{id};
		$self->render(
			'api_documentation',
			uid       => $uid,
			api_token => $self->users->get_api_token( uid => $uid ),
		);
	}
	else {
		$self->render('api_documentation');
	}
}

sub get_v1 {
	my ($self) = @_;

	$self->res->headers->access_control_allow_origin(q{*});

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

	my $token = $self->users->get_api_token( uid => $uid );
	if (   not $api_token
		or not $token->{$api_action}
		or $api_token ne $token->{$api_action} )
	{
		$self->render(
			json => {
				error => 'Invalid token',
			},
		);
		return;
	}
	if ( $api_action eq 'status' ) {
		$self->render( json => $self->get_user_status_json_v1( uid => $uid ) );
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
				success    => \0,
				deprecated => \0,
				error      => 'Malformed JSON',
			},
			status => 400,
		);
		return;
	}

	my $api_token = $payload->{token} // '';

	if ( $api_token !~ qr{ ^ (?<id> \d+ ) - (?<token> .* ) $ }x ) {
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'Malformed token',
			},
			status => 400,
		);
		return;
	}
	my $uid = $+{id};
	$api_token = $+{token};

	if ( $uid > 2147483647 ) {
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'Malformed token',
			},
			status => 400,
		);
		return;
	}

	my $token = $self->users->get_api_token( uid => $uid );
	if ( not $token->{'travel'} or $api_token ne $token->{'travel'} ) {
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'Invalid token',
			},
			status => 400,
		);
		return;
	}

	if ( not exists $payload->{action}
		or $payload->{action} !~ m{^(checkin|checkout|undo)$} )
	{
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'Missing or invalid action',
				status     => $self->get_user_status_json_v1( uid => $uid )
			},
			status => 400,
		);
		return;
	}

	if ( $payload->{action} eq 'checkin' ) {
		my $from_station = sanitize( q{}, $payload->{fromStation} );
		my $to_station   = sanitize( q{}, $payload->{toStation} );
		my $train_id;
		my $dbris = sanitize( undef, $payload->{dbris} );
		my $hafas = sanitize( undef, $payload->{hafas} );

		if ( not $hafas and exists $payload->{train}{journeyID} ) {
			$dbris //= 'bahn.de';
		}

		if (
			not(
				$from_station
				and (  ( $payload->{train}{type} and $payload->{train}{no} )
					or $payload->{train}{id}
					or $payload->{train}{journeyID} )
			)
		  )
		{
			$self->render(
				json => {
					success    => \0,
					deprecated => \0,
					error      => 'Missing fromStation or train data',
					status     => $self->get_user_status_json_v1( uid => $uid )
				},
				status => 400,
			);
			return;
		}

		if (    not $hafas
			and not $dbris
			and not $self->stations->search( $from_station, backend_id => 1 ) )
		{
			$self->render(
				json => {
					success    => \0,
					deprecated => \0,
					error      => 'Unknown fromStation',
					status     => $self->get_user_status_json_v1( uid => $uid )
				},
				status => 400,
			);
			return;
		}

		if (    $to_station
			and not $hafas
			and not $dbris
			and not $self->stations->search( $to_station, backend_id => 1 ) )
		{
			$self->render(
				json => {
					success    => \0,
					deprecated => \0,
					error      => 'Unknown toStation',
					status     => $self->get_user_status_json_v1( uid => $uid )
				},
				status => 400,
			);
			return;
		}

		my $train_p;

		if ( exists $payload->{train}{journeyID} ) {
			$train_p = Mojo::Promise->resolve(
				sanitize( q{}, $payload->{train}{journeyID} ) );
		}
		elsif ( exists $payload->{train}{id} ) {
			$train_p
			  = Mojo::Promise->resolve( sanitize( 0, $payload->{train}{id} ) );
		}
		else {
			my $train_type = sanitize( q{}, $payload->{train}{type} );
			my $train_no   = sanitize( q{}, $payload->{train}{no} );

			$train_p = $self->iris->get_departures_p(
				station    => $from_station,
				lookbehind => 140,
				lookahead  => 40
			)->then(
				sub {
					my ($status) = @_;
					if ( $status->{errstr} ) {
						return Mojo::Promise->reject(
							'Error requesting departures from fromStation: '
							  . $status->{errstr} );
					}
					my ($train) = List::Util::first {
						$_->type eq $train_type and $_->train_no eq $train_no
					}
					@{ $status->{results} };
					if ( not defined $train ) {
						return Mojo::Promise->reject(
							'Train not found at fromStation');
					}
					return Mojo::Promise->resolve( $train->train_id );
				}
			);
		}

		$self->render_later;

		$train_p->then(
			sub {
				my ($train_id) = @_;
				return $self->checkin_p(
					station  => $from_station,
					train_id => $train_id,
					uid      => $uid,
					hafas    => $hafas,
					dbris    => $dbris,
				);
			}
		)->then(
			sub {
				my ($train) = @_;
				if ( $payload->{comment} ) {
					$self->in_transit->update_user_data(
						uid       => $uid,
						user_data =>
						  { comment => sanitize( q{}, $payload->{comment} ) }
					);
				}
				if ($to_station) {

					# the user may not have provided the correct to_station, so
					# request related stations for checkout.
					return $self->checkout_p(
						station      => $to_station,
						force        => 0,
						uid          => $uid,
						with_related => 1,
					);
				}
				return Mojo::Promise->resolve;
			}
		)->then(
			sub {
				my ( undef, $error ) = @_;
				if ($error) {
					return Mojo::Promise->reject($error);
				}
				$self->render(
					json => {
						success    => \1,
						deprecated => \0,
						status => $self->get_user_status_json_v1( uid => $uid )
					}
				);
			}
		)->catch(
			sub {
				my ($error) = @_;
				$self->render(
					json => {
						success    => \0,
						deprecated => \0,
						error      => 'Checkin/Checkout error: ' . $error,
						status => $self->get_user_status_json_v1( uid => $uid )
					}
				);
			}
		)->wait;
	}
	elsif ( $payload->{action} eq 'checkout' ) {
		my $to_station = sanitize( q{}, $payload->{toStation} );

		if ( not $to_station ) {
			$self->render(
				json => {
					success    => \0,
					deprecated => \0,
					error      => 'Missing toStation',
					status     => $self->get_user_status_json_v1( uid => $uid )
				},
			);
			return;
		}

		if ( $payload->{comment} ) {
			$self->in_transit->update_user_data(
				uid       => $uid,
				user_data => { comment => sanitize( q{}, $payload->{comment} ) }
			);
		}

		$self->render_later;

		# the user may not have provided the correct to_station, so
		# request related stations for checkout.
		$self->checkout_p(
			station      => $to_station,
			force        => $payload->{force} ? 1 : 0,
			uid          => $uid,
			with_related => 1,
		)->then(
			sub {
				my ( $train, $error ) = @_;
				if ($error) {
					return Mojo::Promise->reject($error);
				}
				$self->render(
					json => {
						success    => \1,
						deprecated => \0,
						status => $self->get_user_status_json_v1( uid => $uid )
					}
				);
				return;
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					json => {
						success    => \0,
						deprecated => \0,
						error      => 'Checkout error: ' . $err,
						status => $self->get_user_status_json_v1( uid => $uid )
					}
				);
			}
		)->wait;
	}
	elsif ( $payload->{action} eq 'undo' ) {
		my $error = $self->undo( 'in_transit', $uid );
		if ($error) {
			$self->render(
				json => {
					success    => \0,
					deprecated => \0,
					error      => $error,
					status     => $self->get_user_status_json_v1( uid => $uid )
				}
			);
		}
		else {
			$self->render(
				json => {
					success    => \1,
					deprecated => \0,
					status     => $self->get_user_status_json_v1( uid => $uid )
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
				success    => \0,
				deprecated => \0,
				error      => 'Malformed JSON',
			},
		);
		return;
	}

	my $api_token = $payload->{token} // '';

	if ( $api_token !~ qr{ ^ (?<id> \d+ ) - (?<token> .* ) $ }x ) {
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'Malformed token',
			},
		);
		return;
	}
	my $uid = $+{id};
	$api_token = $+{token};

	if ( $uid > 2147483647 ) {
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'Malformed token',
			},
		);
		return;
	}

	my $token = $self->users->get_api_token( uid => $uid );
	if ( not $token->{'import'} or $api_token ne $token->{'import'} ) {
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'Invalid token',
			},
		);
		return;
	}

	if (   not exists $payload->{fromStation}
		or not exists $payload->{toStation} )
	{
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => 'missing fromStation or toStation',
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
			uid             => $uid,
			train_type      => sanitize( q{}, $payload->{train}{type} ),
			train_no        => sanitize( q{}, $payload->{train}{no} ),
			train_line      => sanitize( q{}, $payload->{train}{line} ),
			cancelled       => $payload->{cancelled} ? 1 : 0,
			dep_station     => sanitize( q{}, $payload->{fromStation}{name} ),
			arr_station     => sanitize( q{}, $payload->{toStation}{name} ),
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
			comment    => sanitize( q{}, $payload->{comment} ),
			lax        => $payload->{lax} ? 1 : 0,
			backend_id => 1,
		);

		if ( $payload->{intermediateStops}
			and ref( $payload->{intermediateStops} ) eq 'ARRAY' )
		{
			$opt{route}
			  = [ map { sanitize( q{}, $_ ) }
				  @{ $payload->{intermediateStops} } ];
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
				success    => \0,
				deprecated => \0,
				error      => $first_line
			}
		);
		return;
	}

	my $db = $self->pg->db;
	my $tx = $db->begin;

	$opt{db} = $db;
	my ( $journey_id, $error ) = $self->journeys->add(%opt);
	my $journey;

	if ( not $error ) {
		eval {
			$journey = $self->journeys->get_single(
				uid        => $uid,
				db         => $db,
				journey_id => $journey_id,
				verbose    => 1
			);
			$error
			  = $self->journeys->sanity_check( $journey,
				$payload->{lax} ? 1 : 0 );
		};
		if ($@) {
			$error = $@;
		}
	}

	if ($error) {
		$self->render(
			json => {
				success    => \0,
				deprecated => \0,
				error      => $error
			}
		);
	}
	elsif ( $payload->{dryRun} ) {
		$self->render(
			json => {
				success    => \1,
				deprecated => \0,
				id         => $journey_id,
				result     => $journey
			}
		);
	}
	else {
		$self->journey_stats_cache->invalidate(
			ts  => $opt{rt_departure},
			db  => $db,
			uid => $uid
		);
		$tx->commit;
		$self->render(
			json => {
				success    => \1,
				deprecated => \0,
				id         => $journey_id,
				result     => $journey
			}
		);
	}
}

sub set_token {
	my ($self) = @_;
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}
	my $token    = make_token();
	my $token_id = $self->users->get_token_id( $self->param('token') );

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

sub autocomplete {
	my ($self) = @_;

	$self->res->headers->cache_control('max-age=86400, immutable');

	my $backend_id = $self->param('backend_id') // 1;

	my $output
	  = "document.addEventListener('DOMContentLoaded',function(){M.Autocomplete.init(document.querySelectorAll('.autocomplete'),{\n";
	$output .= 'minLength:3,limit:50,data:';
	$output
	  .= encode_json(
		$self->stations->get_for_autocomplete( backend_id => $backend_id ) );
	$output .= "\n});});\n";

	$self->render(
		format => 'js',
		data   => $output
	);
}

1;
