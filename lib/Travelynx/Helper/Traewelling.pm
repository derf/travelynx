package Travelynx::Helper::Traewelling;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

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
	  ->get_p( "https://traewelling.de/api/v0/user/${username}" => $header )
	  ->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg = "HTTP $err->{code} $err->{message}";
				$promise->reject($err_msg);
				return;
			}
			else {
				if ( my $status = $tx->result->json->{statuses}{data}[0] ) {
					my $status_id = $status->{id};
					my $message   = $status->{body};
					my $checkin_at
					  = $self->parse_datetime( $status->{created_at} );

					my $dep_dt = $self->parse_datetime(
						$status->{train_checkin}{departure} );
					my $arr_dt = $self->parse_datetime(
						$status->{train_checkin}{arrival} );

					my $dep_eva
					  = $status->{train_checkin}{origin}{ibnr};
					my $arr_eva
					  = $status->{train_checkin}{destination}{ibnr};

					my $dep_name
					  = $status->{train_checkin}{origin}{name};
					my $arr_name
					  = $status->{train_checkin}{destination}{name};

					my $category
					  = $status->{train_checkin}{hafas_trip}{category};
					my $trip_id
					  = $status->{train_checkin}{hafas_trip}{trip_id};
					my $linename
					  = $status->{train_checkin}{hafas_trip}{linename};
					my ( $train_type, $train_line ) = split( qr{ }, $linename );
					$promise->resolve(
						{
							status_id  => $status_id,
							message    => $message,
							checkin    => $checkin_at,
							dep_dt     => $dep_dt,
							dep_eva    => $dep_eva,
							dep_name   => $dep_name,
							arr_dt     => $arr_dt,
							arr_eva    => $arr_eva,
							arr_name   => $arr_name,
							trip_id    => $trip_id,
							train_type => $train_type,
							line       => $linename,
							line_no    => $train_line,
							category   => $category,
						}
					);
					return;
				}
				else {
					$promise->reject("unknown error");
					return;
				}
			}
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
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

	$ua->get_p( "https://traewelling.de/api/v0/getuser" => $header )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg
				  = "HTTP $err->{code} $err->{message} bei Abfrage der Nutzerdaten";
				$promise->reject($err_msg);
				return;
			}
			else {
				my $user_data = $tx->result->json;
				$self->{model}->set_user(
					uid         => $uid,
					trwl_id     => $user_data->{id},
					screen_name => $user_data->{name},
					user_name   => $user_data->{username},
				);
				$promise->resolve;
				return;
			}
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("$err bei Abfrage der Nutzerdaten");
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
		email    => $email,
		password => $password,
	};

	my $promise = Mojo::Promise->new;
	my $token;

	$ua->post_p(
		"https://traewelling.de/api/v0/auth/login" => $self->{header},
		json                                       => $request
	)->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg = "HTTP $err->{code} $err->{message} bei Login";
				$promise->reject($err_msg);
				return;
			}
			else {
				my $res = $tx->result->json;
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
						$promise->reject($err);
						return;
					}
				);
			}
			else {
				$promise->reject($err);
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
		"https://traewelling.de/api/v0/auth/logout" => $header => json =>
		  $request )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg = "HTTP $err->{code} $err->{message}";
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
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub checkin {
	my ( $self, %opt ) = @_;

	my $header = {
		'User-Agent'    => $self->{header}{'User-Agent'},
		'Accept'        => 'application/json',
		'Authorization' => "Bearer $opt{token}",
	};

	my $request = {
		tripID   => $opt{trip_id},
		lineName => $opt{train_type} . ' '
		  . ( $opt{train_line} // $opt{train_no} ),
		start       => q{} . $opt{dep_eva},
		destination => q{} . $opt{arr_eva},
		toot        => $opt{data}{toot} ? \1 : \0,
		tweet       => $opt{data}{tweet} ? \1 : \0,
	};

	if ( $opt{user_data}{comment} ) {
		$request->{body} = $opt{user_data}{comment};
	}

	$self->{user_agent}->request_timeout(20)
	  ->post_p( "https://traewelling.de/api/v0/trains/checkin" =>
		  $header => json => $request )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg = "HTTP $err->{code} $err->{message}";
				$self->{log}->warn("Traewelling checkin error: $err_msg");
				$self->{model}->log(
					uid => $opt{uid},
					message =>
					  "Fehler bei $opt{train_type} $opt{train_no}: $err_msg",
					is_error => 1
				);
				return;
			}
			$self->{log}->debug( "... success! " . $tx->res->body );

			# As of 2020-10-04, traewelling.de checkins do not yet return
			# "statusId". The patch is present on the develop branch and waiting
			# for a merge into master.
			$self->{model}->log(
				uid       => $opt{uid},
				message   => "Eingecheckt in $opt{train_type} $opt{train_no}",
				status_id => $tx->res->json->{statusId}
			);
			$self->{model}->set_latest_push_ts(
				uid => $opt{uid},
				ts  => $opt{checkin_ts}
			);

			# TODO store status_id in in_transit object so that it can be shown
			# on the user status page
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("... error: $err");
			$self->{model}->log(
				uid      => $opt{uid},
				message  => "Fehler bei $opt{train_type} $opt{train_no}: $err",
				is_error => 1
			);
		}
	)->wait;
}

1;
