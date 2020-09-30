package Travelynx::Helper::Traewelling;

use strict;
use warnings;
use 5.020;

use Mojo::Promise;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"travelynx/${version} on $opt{root_url} +https://finalrewind.org/projects/travelynx"
	  };

	return bless( \%opt, $class );
}

sub get_status_p {
	my ( $self, %opt ) = @_;

	my $username = $opt{username};
	my $token    = $opt{token};
	my $promise  = Mojo::Promise->new;

	my $header = {
		'User-Agent'    => $self->{header}{'User-Agent'},
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
					my $strp = DateTime::Format::Strptime->new(
						pattern   => '%Y-%m-%dT%H:%M:%S.000000Z',
						time_zone => 'UTC',
					);
					my $status_id = $status->{id};
					my $message   = $status->{body};
					my $checkin_at
					  = $strp->parse_datetime( $status->{created_at} );

					my $dep_dt = $strp->parse_datetime(
						$status->{train_checkin}{departure} );
					my $arr_dt = $strp->parse_datetime(
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
		"https://traewelling.de/api/v0/auth/login" => $self->{header} =>
		  json                                     => $request )->then(
		sub {
			my ($tx) = @_;
			if ( my $err = $tx->error ) {
				my $err_msg = "HTTP $err->{code} $err->{message} bei Login";
				$promise->reject($err_msg);
				return;
			}
			else {
				$token = $tx->result->json->{token};
				$self->{model}->link(
					uid   => $uid,
					email => $email,
					token => $token
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
	my ( $self, $uid ) = @_;
	if ( my $token = $self->get_traewelling_push_token($uid) ) {
		my $user = $self->get_user_status;

# TODO delete previous traewelling status if the train's destination has been changed
# TODO delete traewelling status when undoing a travelynx checkin
		if ( $user->{checked_in} and $user->{extra_data}{trip_id} ) {
			my $traewelling = $self->{model}->get($uid);
			if ( $traewelling->{data}{trip_id} eq $user->{extra_data}{trip_id} )
			{
				return;
			}
			my $header = {
				'User-Agent'    => 'travelynx/' . $self->{version},
				'Authorization' => "Bearer $token",
			};

			my $request = {
				tripID      => $user->{extra_data}{trip_id},
				start       => q{} . $user->{dep_eva},
				destination => q{} . $user->{arr_eva},
			};
			my $trip_req = sprintf(
				"tripID=%s&lineName=%s%%20%s&start=%s",
				$user->{extra_data}{trip_id}, $user->{train_type},
				$user->{train_line} // $user->{train_no}, $user->{dep_eva}
			);
			$self->{user_agent}->request_timeout(20)
			  ->get_p(
				"https://traewelling.de/api/v0/trains/trip?$trip_req" =>
				  $header )->then(
				sub {
					return $self->{user_agent}->request_timeout(20)
					  ->post_p(
						"https://traewelling.de/api/v0/trains/checkin" =>
						  $header => json => $request );
				}
			)->then(
				sub {
					my ($tx) = @_;
					if ( my $err = $tx->error ) {
						my $err_msg = "HTTP $err->{code} $err->{message}";
						$self->mark_trwl_checkin_error( $uid, $user, $err_msg );
					}
					else {
  # TODO check for traewelling error ("error" key in response)
  # TODO store ID of resulting status (request /user/{name} and store status ID)
						$self->mark_trwl_checkin_success( $uid, $user );

                      # mark success: checked into (trip_id, start, destination)
					}
				}
			)->catch(
				sub {
					my ($err) = @_;
					$self->mark_trwl_checkin_error( $uid, $user, $err );
				}
			)->wait;
		}
	}
}

1;
