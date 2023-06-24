package Travelynx::Helper::Traewelling;

# Copyright (C) 2020-2023 Birthe Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;
use utf8;

use DateTime;
use DateTime::Format::Strptime;
use Mojo::Promise;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header} = {
		'User-Agent' =>
"travelynx/${version} on $opt{root_url} +https://finalrewind.org/projects/travelynx",
		'Accept' => 'application/json',
	};
	$opt{strp1} = DateTime::Format::Strptime->new(
		pattern   => '%Y-%m-%dT%H:%M:%S.000000Z',
		time_zone => 'UTC',
	);
	$opt{strp2} = DateTime::Format::Strptime->new(
		pattern   => '%Y-%m-%d %H:%M:%S',
		time_zone => 'Europe/Berlin',
	);
	$opt{strp3} = DateTime::Format::Strptime->new(
		pattern   => '%Y-%m-%dT%H:%M:%S%z',
		time_zone => 'Europe/Berlin',
	);

	return bless( \%opt, $class );
}

sub epoch_to_dt_or_undef {
	my ($epoch) = @_;

	if ( not $epoch ) {
		return undef;
	}

	return DateTime->from_epoch(
		epoch     => $epoch,
		time_zone => 'Europe/Berlin',
		locale    => 'de-DE',
	);
}

sub parse_datetime {
	my ( $self, $dt ) = @_;

	return $self->{strp1}->parse_datetime($dt)
	  // $self->{strp2}->parse_datetime($dt)
	  // $self->{strp3}->parse_datetime($dt);
}

sub get_status_p {
	my ( $self, %opt ) = @_;

	my $username = $opt{username};
	my $token    = $opt{token};
	my $promise  = Mojo::Promise->new;

	my $header = {
		'User-Agent'    => $self->{header}{'User-Agent'},
		'Accept'        => 'application/json',
		'Authorization' => "Bearer $token",
	};

	$self->{user_agent}->request_timeout(20)
	  ->get_p(
		"https://traewelling.de/api/v1/user/${username}/statuses?limit=1" =>
		  $header )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg
				  = "v1/user/${username}/statuses: HTTP $err->{code} $err->{message}";
				$promise->reject( { http => $err->{code}, text => $err_msg } );
				return;
			}
			else {
				if ( my $status = $tx->result->json->{data}[0] ) {
					my $status_id = $status->{id};
					my $message   = $status->{body};
					my $checkin_at
					  = $self->parse_datetime( $status->{createdAt} );

					my $dep_dt = $self->parse_datetime(
						$status->{train}{origin}{departurePlanned} );
					my $arr_dt = $self->parse_datetime(
						$status->{train}{destination}{arrivalPlanned} );

					my $dep_eva
					  = $status->{train}{origin}{evaIdentifier};
					my $arr_eva
					  = $status->{train}{destination}{evaIdentifier};

					my $dep_ds100
					  = $status->{train}{origin}{rilIdentifier};
					my $arr_ds100
					  = $status->{train}{destination}{rilIdentifier};

					my $dep_name
					  = $status->{train}{origin}{name};
					my $arr_name
					  = $status->{train}{destination}{name};

					my $category = $status->{train}{category};
					my $linename = $status->{train}{lineName};
					my ( $train_type, $train_line ) = split( qr{ }, $linename );
					$promise->resolve(
						{
							http       => $tx->res->code,
							status_id  => $status_id,
							message    => $message,
							checkin    => $checkin_at,
							dep_dt     => $dep_dt,
							dep_eva    => $dep_eva,
							dep_ds100  => $dep_ds100,
							dep_name   => $dep_name,
							arr_dt     => $arr_dt,
							arr_eva    => $arr_eva,
							arr_ds100  => $arr_ds100,
							arr_name   => $arr_name,
							train_type => $train_type,
							line       => $linename,
							line_no    => $train_line,
							category   => $category,
						}
					);
					return;
				}
				else {
					$promise->reject(
						{ text => "v1/${username}/statuses: unknown error" } );
					return;
				}
			}
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject( { text => "v1/${username}/statuses: $err" } );
			return;
		}
	)->wait;

	return $promise;
}

sub get_user_p {
	my ( $self, $uid, $token ) = @_;
	my $ua = $self->{user_agent}->request_timeout(20);

	my $header = {
		'User-Agent'    => $self->{header}{'User-Agent'},
		'Accept'        => 'application/json',
		'Authorization' => "Bearer $token",
	};
	my $promise = Mojo::Promise->new;

	$ua->get_p( "https://traewelling.de/api/v1/auth/user" => $header )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg = "v1/auth/user: HTTP $err->{code} $err->{message}";
				$promise->reject($err_msg);
				return;
			}
			else {
				my $user_data = $tx->result->json->{data};
				$self->{model}->set_user(
					uid         => $uid,
					trwl_id     => $user_data->{id},
					screen_name => $user_data->{displayName},
					user_name   => $user_data->{username},
				);
				$promise->resolve;
				return;
			}
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("v1/auth/user: $err");
			return;
		}
	)->wait;

	return $promise;
}

sub login_p {
	my ( $self, %opt ) = @_;

	my $uid      = $opt{uid};
	my $email    = $opt{email};
	my $password = $opt{password};

	my $ua = $self->{user_agent}->request_timeout(20);

	my $request = {
		login    => $email,
		password => $password,
	};

	my $promise = Mojo::Promise->new;
	my $token;

	$ua->post_p(
		"https://traewelling.de/api/v1/auth/login" => $self->{header},
		json                                       => $request
	)->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg
				  = "v1/auth/login: HTTP $err->{code} $err->{message}";
				$promise->reject($err_msg);
				return;
			}
			else {
				my $res = $tx->result->json->{data};
				$token = $res->{token};
				my $expiry_dt = $self->parse_datetime( $res->{expires_at} );

				# Fall back to one year expiry
				$expiry_dt //= DateTime->now( time_zone => 'Europe/Berlin' )
				  ->add( years => 1 );
				$self->{model}->link(
					uid     => $uid,
					email   => $email,
					token   => $token,
					expires => $expiry_dt
				);
				return $self->get_user_p( $uid, $token );
			}
		}
	)->then(
		sub {
			$promise->resolve;
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			if ($token) {

				# We have a token, but couldn't complete the login. For now, we
				# solve this by logging out and invalidating the token.
				$self->logout_p(
					uid   => $uid,
					token => $token
				)->finally(
					sub {
						$promise->reject("v1/auth/login: $err");
						return;
					}
				);
			}
			else {
				$promise->reject("v1/auth/login: $err");
			}
			return;
		}
	)->wait;

	return $promise;
}

sub logout_p {
	my ( $self, %opt ) = @_;

	my $uid   = $opt{uid};
	my $token = $opt{token};

	my $ua = $self->{user_agent}->request_timeout(20);

	my $header = {
		'User-Agent'    => $self->{header}{'User-Agent'},
		'Accept'        => 'application/json',
		'Authorization' => "Bearer $token",
	};
	my $request = {};

	$self->{model}->unlink( uid => $uid );

	my $promise = Mojo::Promise->new;

	$ua->post_p(
		"https://traewelling.de/api/v1/auth/logout" => $header => json =>
		  $request )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg
				  = "v1/auth/logout: HTTP $err->{code} $err->{message}";
				$promise->reject($err_msg);
				return;
			}
			else {
				$promise->resolve;
				return;
			}
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("v1/auth/logout: $err");
			return;
		}
	)->wait;

	return $promise;
}

sub checkin_p {
	my ( $self, %opt ) = @_;

	my $header = {
		'User-Agent'    => $self->{header}{'User-Agent'},
		'Accept'        => 'application/json',
		'Authorization' => "Bearer $opt{token}",
	};

	my $departure_ts = epoch_to_dt_or_undef( $opt{dep_ts} );
	my $arrival_ts   = epoch_to_dt_or_undef( $opt{arr_ts} );

	if ($departure_ts) {
		$departure_ts = $departure_ts->rfc3339;
	}
	if ($arrival_ts) {
		$arrival_ts = $arrival_ts->rfc3339;
	}

	my $request = {
		tripId   => $opt{trip_id},
		lineName => $opt{train_type} . ' '
		  . ( $opt{train_line} // $opt{train_no} ),
		ibnr        => \1,
		start       => q{} . $opt{dep_eva},
		destination => q{} . $opt{arr_eva},
		departure   => $departure_ts,
		arrival     => $arrival_ts,
		toot        => $opt{data}{toot}  ? \1 : \0,
		tweet       => $opt{data}{tweet} ? \1 : \0,
	};

	if ( $opt{user_data}{comment} ) {
		$request->{body} = $opt{user_data}{comment};
	}

	my $debug_prefix
	  = "v1/trains/checkin('$request->{lineName}' $request->{tripId} $request->{start} -> $request->{destination})";

	my $promise = Mojo::Promise->new;

	$self->{user_agent}->request_timeout(20)
	  ->post_p(
		"https://traewelling.de/api/v1/trains/checkin" => $header => json =>
		  $request )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg = "HTTP $err->{code} $err->{message}";
				if ( $tx->res->body ) {
					if ( $err->{code} == 409 ) {
						my $j = $tx->res->json;
						$err_msg .= sprintf(
': Bereits in %s eingecheckt: https://traewelling.de/status/%d',
							$j->{message}{lineName},
							$j->{message}{status_id}
						);
					}
					else {
						$err_msg .= ' ' . $tx->res->body;
					}
				}
				$self->{log}
				  ->debug("Traewelling $debug_prefix error: $err_msg");
				$self->{model}->log(
					uid     => $opt{uid},
					message =>
"Konnte $opt{train_type} $opt{train_no} nicht übertragen: $debug_prefix returned $err_msg",
					is_error => 1
				);
				$promise->reject( { http => $err->{code} } );
				return;
			}
			$self->{log}->debug( "... success! " . $tx->res->body );

			$self->{model}->log(
				uid       => $opt{uid},
				message   => "Eingecheckt in $opt{train_type} $opt{train_no}",
				status_id => $tx->res->json->{statusId}
			);
			$self->{model}->set_latest_push_ts(
				uid => $opt{uid},
				ts  => $opt{checkin_ts}
			);
			$promise->resolve( { http => $tx->res->code } );

			# TODO store status_id in in_transit object so that it can be shown
			# on the user status page
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("... $debug_prefix error: $err");
			$self->{model}->log(
				uid     => $opt{uid},
				message =>
"Konnte $opt{train_type} $opt{train_no} nicht übertragen: $debug_prefix returned $err",
				is_error => 1
			);
			$promise->reject( { connection => $err } );
			return;
		}
	)->wait;

	return $promise;
}

1;
