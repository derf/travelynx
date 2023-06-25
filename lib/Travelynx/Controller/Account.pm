package Travelynx::Controller::Account;

# Copyright (C) 2020-2023 Birthe Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use JSON;
use Mojo::Util qw(xml_escape);
use Text::Markdown;
use UUID::Tiny qw(:std);

my %visibility_itoa = (
	100 => 'public',
	80  => 'travelynx',
	60  => 'followers',
	30  => 'unlisted',
	10  => 'private',
);

my %visibility_atoi = (
	public    => 100,
	travelynx => 80,
	followers => 60,
	unlisted  => 30,
	private   => 10,
);

# Internal Helpers

sub hash_password {
	my ($password) = @_;
	my @salt_bytes = map { int( rand(255) ) + 1 } ( 1 .. 16 );
	my $salt       = en_base64( pack( 'C[16]', @salt_bytes ) );

	return bcrypt( substr( $password, 0, 10000 ), '$2a$12$' . $salt );
}

sub make_token {
	return create_uuid_as_string(UUID_V4);
}

sub send_registration_mail {
	my ( $self, %opt ) = @_;

	my $email   = $opt{email};
	my $token   = $opt{token};
	my $user    = $opt{user};
	my $user_id = $opt{user_id};
	my $ip      = $opt{ip};
	my $date    = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->strftime('%d.%m.%Y %H:%M:%S %z');

	my $ua          = $self->req->headers->user_agent;
	my $reg_url     = $self->url_for('reg')->to_abs->scheme('https');
	my $imprint_url = $self->url_for('impressum')->to_abs->scheme('https');

	my $body = "Hallo, ${user}!\n\n";
	$body .= "Mit deiner E-Mail-Adresse (${email}) wurde ein Account bei\n";
	$body .= "travelynx angelegt.\n\n";
	$body
	  .= "Falls die Registrierung von dir ausging, kannst du den Account unter\n";
	$body .= "${reg_url}/${user_id}/${token}\n";
	$body .= "freischalten.\n\n";
	$body
	  .= "Falls nicht, ignoriere diese Mail bitte. Nach etwa 48 Stunden wird deine\n";
	$body
	  .= "Mail-Adresse erneut zur Registrierung freigeschaltet. Falls auch diese fehlschlägt,\n";
	$body
	  .= "werden wir sie dauerhaft sperren und keine Mails mehr dorthin schicken.\n\n";
	$body .= "Daten zur Registrierung:\n";
	$body .= " * Datum: ${date}\n";
	$body .= " * Client: ${ip}\n";
	$body .= " * UserAgent: ${ua}\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	return $self->sendmail->custom( $email, 'Registrierung bei travelynx',
		$body );
}

sub send_address_confirmation_mail {
	my ( $self, $email, $token ) = @_;

	my $name = $self->current_user->{name};
	my $ip   = $self->req->headers->header('X-Forwarded-For');
	my $ua   = $self->req->headers->user_agent;
	my $date = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->strftime('%d.%m.%Y %H:%M:%S %z');

	# In case Mojolicious is not running behind a reverse proxy
	$ip
	  //= sprintf( '%s:%s', $self->tx->remote_address, $self->tx->remote_port );
	my $confirm_url = $self->url_for('confirm_mail')->to_abs->scheme('https');
	my $imprint_url = $self->url_for('impressum')->to_abs->scheme('https');

	my $body = "Hallo ${name},\n\n";
	$body .= "Bitte bestätige unter <${confirm_url}/${token}>,\n";
	$body .= "dass du mit dieser Adresse E-Mail empfangen kannst.\n\n";
	$body
	  .= "Du erhältst diese Mail, da eine Änderung der deinem travelynx-Account\n";
	$body .= "zugeordneten Mail-Adresse beantragt wurde.\n\n";
	$body .= "Daten zur Anfrage:\n";
	$body .= " * Datum: ${date}\n";
	$body .= " * Client: ${ip}\n";
	$body .= " * UserAgent: ${ua}\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	return $self->sendmail->custom( $email,
		'travelynx: Mail-Adresse bestätigen', $body );
}

sub send_name_notification_mail {
	my ( $self, $old_name, $new_name ) = @_;

	my $ip   = $self->req->headers->header('X-Forwarded-For');
	my $ua   = $self->req->headers->user_agent;
	my $date = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->strftime('%d.%m.%Y %H:%M:%S %z');

	# In case Mojolicious is not running behind a reverse proxy
	$ip
	  //= sprintf( '%s:%s', $self->tx->remote_address, $self->tx->remote_port );
	my $confirm_url = $self->url_for('confirm_mail')->to_abs->scheme('https');
	my $imprint_url = $self->url_for('impressum')->to_abs->scheme('https');

	my $body = "Hallo ${new_name},\n\n";
	$body .= "Der Name deines Travelynx-Accounts wurde erfolgreich geändert.\n";
	$body
	  .= "Bitte beachte, dass du dich ab sofort nur mit dem neuen Namen anmelden kannst.\n\n";
	$body .= "Alter Name: ${old_name}\n\n";
	$body .= "Neue Name: ${new_name}\n\n";
	$body .= "Daten zur Anfrage:\n";
	$body .= " * Datum: ${date}\n";
	$body .= " * Client: ${ip}\n";
	$body .= " * UserAgent: ${ua}\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	return $self->sendmail->custom( $self->current_user->{email},
		'travelynx: Name geändert', $body );
}

sub send_password_notification_mail {
	my ($self) = @_;
	my $user   = $self->current_user->{name};
	my $email  = $self->current_user->{email};
	my $ip     = $self->req->headers->header('X-Forwarded-For');
	my $ua     = $self->req->headers->user_agent;
	my $date   = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->strftime('%d.%m.%Y %H:%M:%S %z');

	# In case Mojolicious is not running behind a reverse proxy
	$ip
	  //= sprintf( '%s:%s', $self->tx->remote_address, $self->tx->remote_port );
	my $imprint_url = $self->url_for('impressum')->to_abs->scheme('https');

	my $body = "Hallo ${user},\n\n";
	$body
	  .= "Das Passwort deines travelynx-Accounts wurde soeben geändert.\n\n";
	$body .= "Daten zur Änderung:\n";
	$body .= " * Datum: ${date}\n";
	$body .= " * Client: ${ip}\n";
	$body .= " * UserAgent: ${ua}\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	$self->sendmail->custom( $email, 'travelynx: Passwort geändert', $body );
}

sub send_lostpassword_confirmation_mail {
	my ( $self, %opt ) = @_;
	my $email = $opt{email};
	my $name  = $opt{name};
	my $uid   = $opt{uid};
	my $token = $opt{token};

	my $ip   = $self->req->headers->header('X-Forwarded-For');
	my $ua   = $self->req->headers->user_agent;
	my $date = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->strftime('%d.%m.%Y %H:%M:%S %z');

	# In case Mojolicious is not running behind a reverse proxy
	$ip
	  //= sprintf( '%s:%s', $self->tx->remote_address, $self->tx->remote_port );
	my $recover_url = $self->url_for('recover')->to_abs->scheme('https');
	my $imprint_url = $self->url_for('impressum')->to_abs->scheme('https');

	my $body = "Hallo ${name},\n\n";
	$body .= "Unter ${recover_url}/${uid}/${token}\n";
	$body
	  .= "kannst du ein neues Passwort für deinen travelynx-Account vergeben.\n\n";
	$body
	  .= "Du erhältst diese Mail, da mit deinem Accountnamen und deiner Mail-Adresse\n";
	$body
	  .= "ein Passwort-Reset angefordert wurde. Falls diese Anfrage nicht von dir\n";
	$body .= "ausging, kannst du sie ignorieren.\n\n";
	$body .= "Daten zur Anfrage:\n";
	$body .= " * Datum: ${date}\n";
	$body .= " * Client: ${ip}\n";
	$body .= " * UserAgent: ${ua}\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	my $success
	  = $self->sendmail->custom( $email, 'travelynx: Neues Passwort', $body );
}

sub send_lostpassword_notification_mail {
	my ( $self, $account ) = @_;
	my $user  = $account->{name};
	my $email = $account->{email};
	my $ip    = $self->req->headers->header('X-Forwarded-For');
	my $ua    = $self->req->headers->user_agent;
	my $date  = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->strftime('%d.%m.%Y %H:%M:%S %z');

	# In case Mojolicious is not running behind a reverse proxy
	$ip
	  //= sprintf( '%s:%s', $self->tx->remote_address, $self->tx->remote_port );
	my $imprint_url = $self->url_for('impressum')->to_abs->scheme('https');

	my $body = "Hallo ${user},\n\n";
	$body .= "Das Passwort deines travelynx-Accounts wurde soeben über die";
	$body .= " 'Passwort vergessen'-Funktion geändert.\n\n";
	$body .= "Daten zur Änderung:\n";
	$body .= " * Datum: ${date}\n";
	$body .= " * Client: ${ip}\n";
	$body .= " * UserAgent: ${ua}\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	return $self->sendmail->custom( $email, 'travelynx: Passwort geändert',
		$body );
}

# Controllers

sub login_form {
	my ($self) = @_;
	$self->render('login');
}

sub do_login {
	my ($self)   = @_;
	my $user     = $self->req->param('user');
	my $password = $self->req->param('password');

	# Keep cookies for 6 months
	$self->session( expiration => 60 * 60 * 24 * 180 );

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
	}
	else {
		if ( $self->authenticate( $user, $password ) ) {
			$self->redirect_to( $self->req->param('redirect_to') // '/' );
			$self->users->mark_seen( uid => $self->current_user->{id} );
		}
		else {
			my $data = $self->users->get_login_data( name => $user );
			if ( $data and $data->{status} == 0 ) {
				$self->render(
					'login',
					status  => 400,
					invalid => 'confirmation'
				);
			}
			else {
				$self->render(
					'login',
					status  => 400,
					invalid => 'credentials'
				);
			}
		}
	}
}

sub registration_form {
	my ($self) = @_;
	$self->render('register');
}

sub register {
	my ($self)    = @_;
	my $dt        = $self->req->param('dt');
	my $user      = $self->req->param('user');
	my $email     = $self->req->param('email');
	my $password  = $self->req->param('password');
	my $password2 = $self->req->param('password2');
	my $ip        = $self->req->headers->header('X-Forwarded-For');

	# In case Mojolicious is not running behind a reverse proxy
	$ip
	  //= sprintf( '%s:%s', $self->tx->remote_address, $self->tx->remote_port );

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}

	if ( my $registration_denylist
		= $self->app->config->{registration}->{denylist} )
	{
		if ( open( my $fh, "<", $registration_denylist ) ) {
			while ( my $line = <$fh> ) {
				chomp $line;
				if ( $ip eq $line ) {
					close($fh);
					$self->render( 'register', invalid => "denylist" );
					return;
				}
			}
			close($fh);
		}
		else {
			$self->log->error("Cannot open($registration_denylist): $!");
			die("Cannot verify registration: $!");
		}
	}

	if ( my $error = $self->users->is_name_invalid( name => $user ) ) {
		$self->render( 'register', invalid => $error );
		return;
	}

	if ( not length($email) ) {
		$self->render( 'register', invalid => 'mail_empty' );
		return;
	}

	if ( $self->users->mail_is_blacklisted( email => $email ) ) {
		$self->render( 'register', invalid => 'mail_blacklisted' );
		return;
	}

	if ( $password ne $password2 ) {
		$self->render( 'register', invalid => 'password_notequal' );
		return;
	}

	if ( length($password) < 8 ) {
		$self->render( 'register', invalid => 'password_short' );
		return;
	}

	if ( not $dt
		or DateTime->now( time_zone => 'Europe/Berlin' )->epoch - $dt < 6 )
	{
		# a human user should take at least five seconds to fill out the form.
		# Throw a CSRF error at presumed spammers.
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}

	my $token   = make_token();
	my $pw_hash = hash_password($password);
	my $db      = $self->pg->db;
	my $tx      = $db->begin;
	my $user_id = $self->users->add(
		db            => $db,
		name          => $user,
		email         => $email,
		token         => $token,
		password_hash => $pw_hash
	);

	my $success = $self->send_registration_mail(
		email   => $email,
		token   => $token,
		ip      => $ip,
		user    => $user,
		user_id => $user_id
	);
	if ($success) {
		$tx->commit;
		$self->render( 'login', from => 'register' );
	}
	else {
		$self->render( 'register', invalid => 'sendmail' );
	}
}

sub verify {
	my ($self) = @_;

	my $id    = $self->stash('id');
	my $token = $self->stash('token');

	if ( not $id =~ m{ ^ \d+ $ }x or $id > 2147483647 ) {
		$self->render( 'register', invalid => 'token' );
		return;
	}

	if (
		not $self->users->verify_registration_token(
			uid   => $id,
			token => $token
		)
	  )
	{
		$self->render( 'register', invalid => 'token' );
		return;
	}

	$self->render( 'login', from => 'verification' );
}

sub delete {
	my ($self) = @_;
	my $uid = $self->current_user->{id};
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}

	if ( $self->param('action') eq 'delete' ) {
		if (
			not $self->authenticate(
				$self->current_user->{name},
				$self->param('password')
			)
		  )
		{
			$self->flash( invalid => 'deletion password' );
			$self->redirect_to('account');
			return;
		}
		$self->users->flag_deletion( uid => $uid );
	}
	else {
		$self->users->unflag_deletion( uid => $uid );
	}
	$self->redirect_to('account');
}

sub do_logout {
	my ($self) = @_;
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}
	$self->logout;
	$self->redirect_to('/login');
}

sub privacy {
	my ($self) = @_;

	my $user = $self->current_user;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my %opt;
		my $default_visibility
		  = $visibility_atoi{ $self->param('status_level') };
		if ( defined $default_visibility ) {
			$opt{default_visibility} = $default_visibility;
		}

		my $past_visibility = $visibility_atoi{ $self->param('history_level') };
		if ( defined $past_visibility ) {
			$opt{past_visibility} = $past_visibility;
		}

		$opt{comments_visible} = $self->param('public_comment') ? 1 : 0;

		$opt{past_all}    = $self->param('history_age') eq 'infinite' ? 1 : 0;
		$opt{past_status} = $self->param('past_status')               ? 1 : 0;

		$self->users->set_privacy(
			uid => $user->{id},
			%opt
		);

		$self->flash( success => 'privacy' );
		$self->redirect_to('account');
	}
	else {
		$self->param(
			status_level => $visibility_itoa{ $user->{default_visibility} } );
		$self->param( public_comment => $user->{comments_visible} );
		$self->param(
			history_level => $visibility_itoa{ $user->{past_visibility} } );
		$self->param( history_age => $user->{past_all} ? 'infinite' : 'month' );
		$self->param( past_status => $user->{past_status} );
		$self->render( 'privacy', name => $user->{name} );
	}
}

sub social {
	my ($self) = @_;

	my $user = $self->current_user;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'bad_request',
				csrf   => 1,
				status => 400
			);
			return;
		}

		my %opt;
		my $accept_follow = $self->param('accept_follow');

		if ( $accept_follow eq 'yes' ) {
			$opt{accept_follows} = 1;
		}
		elsif ( $accept_follow eq 'request' ) {
			$opt{accept_follow_requests} = 1;
		}

		$self->users->set_social(
			uid => $user->{id},
			%opt
		);

		$self->flash( success => 'social' );
		$self->redirect_to('account');
	}
	else {
		if ( $user->{accept_follows} ) {
			$self->param( accept_follow => 'yes' );
		}
		elsif ( $user->{accept_follow_requests} ) {
			$self->param( accept_follow => 'request' );
		}
		else {
			$self->param( accept_follow => 'no' );
		}
		$self->render( 'social', name => $user->{name} );
	}
}

sub social_list {
	my ($self) = @_;

	my $kind = $self->stash('kind');
	my $user = $self->current_user;

	if ( $kind eq 'follow-requests' ) {
		my @follow_reqs
		  = $self->users->get_follow_requests( uid => $user->{id} );
		$self->render(
			'social_list',
			type          => 'follow-requests',
			entries       => [@follow_reqs],
			notifications => $user->{notifications},
		);
	}
	elsif ( $kind eq 'followers' ) {
		my @followers = $self->users->get_followers( uid => $user->{id} );
		$self->render(
			'social_list',
			type          => 'followers',
			entries       => [@followers],
			notifications => $user->{notifications},
		);
	}
	elsif ( $kind eq 'follows' ) {
		my @following = $self->users->get_followees( uid => $user->{id} );
		$self->render(
			'social_list',
			type          => 'follows',
			entries       => [@following],
			notifications => $user->{notifications},
		);
	}
	elsif ( $kind eq 'blocks' ) {
		my @blocked = $self->users->get_blocked_users( uid => $user->{id} );
		$self->render(
			'social_list',
			type          => 'blocks',
			entries       => [@blocked],
			notifications => $user->{notifications},
		);
	}
	else {
		$self->render( 'not_found', status => 404 );
	}
}

sub social_action {
	my ($self) = @_;

	my $user        = $self->current_user;
	my $action      = $self->param('action');
	my $target_ids  = $self->param('target');
	my $redirect_to = $self->param('redirect_to');

	for my $key (
		qw(follow request_follow follow_or_request unfollow remove_follower cancel_follow_request accept_follow_request reject_follow_request block unblock)
	  )
	{
		if ( $self->param($key) ) {
			$action     = $key;
			$target_ids = $self->param($key);
		}
	}

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->redirect_to('/');
		return;
	}

	if ( $action and $action eq 'clear_notifications' ) {
		$self->users->update_notifications(
			db                  => $self->pg->db,
			uid                 => $user->{id},
			has_follow_requests => 0
		);
		$self->flash( success => 'clear_notifications' );
		$self->redirect_to('account');
		return;
	}

	if ( not( $action and $target_ids and $redirect_to ) ) {
		$self->redirect_to('/');
		return;
	}

	for my $target_id ( split( qr{,}, $target_ids ) ) {
		my $target = $self->users->get_privacy_by( uid => $target_id );

		if ( not $target ) {
			next;
		}

		if ( $action eq 'follow' and $target->{accept_follows} ) {
			$self->users->follow(
				uid    => $user->{id},
				target => $target->{id}
			);
		}
		elsif ( $action eq 'request_follow'
			and $target->{accept_follow_requests} )
		{
			$self->users->request_follow(
				uid    => $user->{id},
				target => $target->{id}
			);
		}
		elsif ( $action eq 'follow_or_request' ) {
			if ( $target->{accept_follows} ) {
				$self->users->follow(
					uid    => $user->{id},
					target => $target->{id}
				);
			}
			elsif ( $target->{accept_follow_requests} ) {
				$self->users->request_follow(
					uid    => $user->{id},
					target => $target->{id}
				);
			}
		}
		elsif ( $action eq 'unfollow' ) {
			$self->users->unfollow(
				uid    => $user->{id},
				target => $target->{id}
			);
		}
		elsif ( $action eq 'remove_follower' ) {
			$self->users->remove_follower(
				uid      => $user->{id},
				follower => $target->{id}
			);
		}
		elsif ( $action eq 'cancel_follow_request' ) {
			$self->users->cancel_follow_request(
				uid    => $user->{id},
				target => $target->{id}
			);
		}
		elsif ( $action eq 'accept_follow_request' ) {
			$self->users->accept_follow_request(
				uid       => $user->{id},
				applicant => $target->{id}
			);
		}
		elsif ( $action eq 'reject_follow_request' ) {
			$self->users->reject_follow_request(
				uid       => $user->{id},
				applicant => $target->{id}
			);
		}
		elsif ( $action eq 'block' ) {
			$self->users->block(
				uid    => $user->{id},
				target => $target->{id}
			);
		}
		elsif ( $action eq 'unblock' ) {
			$self->users->unblock(
				uid    => $user->{id},
				target => $target->{id}
			);
		}

		if ( $redirect_to eq 'profile' ) {

			# profile links do not perform bulk actions
			$self->redirect_to( '/p/' . $target->{name} );
			return;
		}
	}

	$self->redirect_to($redirect_to);
}

sub profile {
	my ($self) = @_;
	my $user = $self->current_user;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'bad_request',
				csrf   => 1,
				status => 400
			);
			return;
		}
		my $md  = Text::Markdown->new;
		my $bio = $self->param('bio');

		if ( length($bio) > 2000 ) {
			$bio = substr( $bio, 0, 2000 ) . '…';
		}

		my $profile = {
			bio => {
				markdown => $bio,
				html     => $md->markdown( xml_escape($bio) ),
			},
			metadata => [],
		};
		for my $i ( 0 .. 20 ) {
			my $key   = $self->param("key_$i");
			my $value = $self->param("value_$i");
			if ($key) {
				if ( length($value) > 500 ) {
					$value = substr( $value, 0, 500 ) . '…';
				}
				my $html_value
				  = ( $value
					  =~ s{ \[ ([^]]+) \]\( ([^)]+) \) }{'<a href="' . xml_escape($2) . '" rel="me">' . xml_escape($1) .'</a>' }egrx
				  );
				$profile->{metadata}[$i] = {
					key   => $key,
					value => {
						markdown => $value,
						html     => $html_value,
					},
				};
			}
			else {
				last;
			}
		}
		$self->users->set_profile(
			uid     => $user->{id},
			profile => $profile
		);
		$self->redirect_to( '/p/' . $user->{name} );
	}

	my $profile = $self->users->get_profile( uid => $user->{id} );
	$self->param( bio => $profile->{bio}{markdown} );
	for my $i ( 0 .. $#{ $profile->{metadata} } ) {
		$self->param( "key_$i"   => $profile->{metadata}[$i]{key} );
		$self->param( "value_$i" => $profile->{metadata}[$i]{value}{markdown} );
	}

	$self->render( 'edit_profile', name => $user->{name} );
}

sub insight {
	my ($self) = @_;

	my $user = $self->current_user;
	my ( $use_history, $destinations ) = $self->users->use_history(
		uid                => $user->{id},
		with_local_transit => 1
	);

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		if ( $self->param('on_departure') ) {
			$use_history |= 0x01;
		}
		else {
			$use_history &= ~0x01;
		}

		if ( $self->param('on_arrival') ) {
			$use_history |= 0x02;
		}
		else {
			$use_history &= ~0x02;
		}

		if ( $self->param('local_transit') ) {
			$use_history |= 0x04;
		}
		else {
			$use_history &= ~0x04;
		}

		if ( $self->param('destinations') ) {
			$destinations
			  = [ split( qr{\r?\n\r?}, $self->param('destinations') ) ];
		}

		$self->users->use_history(
			uid          => $user->{id},
			set          => $use_history,
			destinations => $destinations
		);
		$self->flash( success => 'use_history' );
		$self->redirect_to('account');
	}

	$self->param( on_departure  => $use_history & 0x01 ? 1 : 0 );
	$self->param( on_arrival    => $use_history & 0x02 ? 1 : 0 );
	$self->param( local_transit => $use_history & 0x04 ? 1 : 0 );
	$self->param( destinations  => join( "\n", @{$destinations} ) );
	$self->render('use_history');

}

sub services {
	my ($self) = @_;
	my $user = $self->current_user;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $sb    = $self->param('stationboard');
		my $value = 0;
		if ( $sb =~ m{ ^ \d+ $ }x and $sb >= 0 and $sb <= 4 ) {
			$value = int($sb);
		}
		$self->users->use_external_services(
			uid => $user->{id},
			set => $value
		);
		$self->flash( success => 'external' );
		$self->redirect_to('account');
	}

	$self->param( stationboard =>
		  $self->users->use_external_services( uid => $user->{id} ) );
	$self->render('use_external_links');
}

sub webhook {
	my ($self) = @_;

	my $uid = $self->current_user->{id};

	my $hook = $self->users->get_webhook( uid => $uid );

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		$hook->{url}     = $self->param('url');
		$hook->{token}   = $self->param('token');
		$hook->{enabled} = $self->param('enabled') // 0;
		$self->users->set_webhook(
			uid     => $uid,
			url     => $hook->{url},
			token   => $hook->{token},
			enabled => $hook->{enabled}
		);
		$self->run_hook(
			$self->current_user->{id},
			'ping',
			sub {
				$self->render(
					'webhooks',
					hook     => $self->users->get_webhook( uid => $uid ),
					new_hook => 1
				);
			}
		);
		return;
	}
	else {
		$self->param( url     => $hook->{url} );
		$self->param( token   => $hook->{token} );
		$self->param( enabled => $hook->{enabled} );
	}

	$self->render( 'webhooks', hook => $hook );
}

sub change_mail {
	my ($self) = @_;

	my $action   = $self->req->param('action');
	my $password = $self->req->param('password');
	my $email    = $self->req->param('email');

	if ( $action and $action eq 'update_mail' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'bad_request',
				csrf   => 1,
				status => 400
			);
			return;
		}

		if ( not length($email) ) {
			$self->render( 'change_mail', invalid => 'mail_empty' );
			return;
		}

		if (
			not $self->authenticate(
				$self->current_user->{name},
				$self->param('password')
			)
		  )
		{
			$self->render( 'change_mail', invalid => 'password' );
			return;
		}

		my $token = make_token();
		my $db    = $self->pg->db;
		my $tx    = $db->begin;

		$self->users->mark_for_mail_change(
			db    => $db,
			uid   => $self->current_user->{id},
			email => $email,
			token => $token
		);

		my $success = $self->send_address_confirmation_mail( $email, $token );

		if ($success) {
			$tx->commit;
			$self->render( 'change_mail', success => 1 );
		}
		else {
			$self->render( 'change_mail', invalid => 'sendmail' );
		}
	}
	else {
		$self->render('change_mail');
	}
}

sub change_name {
	my ($self) = @_;

	my $action   = $self->req->param('action');
	my $password = $self->req->param('password');
	my $old_name = $self->current_user->{name};
	my $new_name = $self->req->param('name');

	if ( $action and $action eq 'update_name' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'bad_request',
				csrf   => 1,
				status => 400
			);
			return;
		}

		if ( my $error = $self->users->is_name_invalid( name => $new_name ) ) {
			$self->render(
				'change_name',
				name    => $old_name,
				invalid => $error
			);
			return;
		}

		if ( not $self->authenticate( $old_name, $self->param('password') ) ) {
			$self->render(
				'change_name',
				name    => $old_name,
				invalid => 'password'
			);
			return;
		}

       # The users table has a unique constraint on the "name" column, so having
       # two users with the same name is not possible. The race condition
       # between the user_name_exists check in is_name_invalid and this
       # change_name call is harmless.
		my $success = $self->users->change_name(
			uid  => $self->current_user->{id},
			name => $new_name
		);

		if ( not $success ) {
			$self->render(
				'change_name',
				name    => $old_name,
				invalid => 'user_collision'
			);
			return;
		}

		$self->flash( success => 'name' );
		$self->redirect_to('account');

		$self->send_name_notification_mail( $old_name, $new_name );
	}
	else {
		$self->render( 'change_name', name => $old_name );
	}
}

sub password_form {
	my ($self) = @_;

	$self->render('change_password');
}

sub change_password {
	my ($self)       = @_;
	my $old_password = $self->req->param('oldpw');
	my $password     = $self->req->param('newpw');
	my $password2    = $self->req->param('newpw2');

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}

	if ( $password ne $password2 ) {
		$self->render( 'change_password', invalid => 'password_notequal' );
		return;
	}

	if ( length($password) < 8 ) {
		$self->render( 'change_password', invalid => 'password_short' );
		return;
	}

	if (
		not $self->authenticate(
			$self->current_user->{name},
			$self->param('oldpw')
		)
	  )
	{
		$self->render( 'change_password', invalid => 'password' );
		return;
	}

	my $pw_hash = hash_password($password);
	$self->users->set_password_hash(
		uid           => $self->current_user->{id},
		password_hash => $pw_hash
	);

	$self->flash( success => 'password' );
	$self->redirect_to('account');
	$self->send_password_notification_mail();
}

sub request_password_reset {
	my ($self) = @_;

	if ( $self->param('action') and $self->param('action') eq 'initiate' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'bad_request',
				csrf   => 1,
				status => 400
			);
			return;
		}

		my $name  = $self->param('user');
		my $email = $self->param('email');

		my $uid = $self->users->get_uid_by_name_and_mail(
			name  => $name,
			email => $email
		);

		if ( not $uid ) {
			$self->render( 'recover_password',
				invalid => 'recovery credentials' );
			return;
		}

		my $token = make_token();
		my $db    = $self->pg->db;
		my $tx    = $db->begin;

		my $error = $self->users->mark_for_password_reset(
			db    => $db,
			uid   => $uid,
			token => $token
		);

		if ($error) {
			$self->render( 'recover_password', invalid => $error );
			return;
		}

		my $success = $self->send_lostpassword_confirmation_mail(
			email => $email,
			name  => $name,
			uid   => $uid,
			token => $token
		);

		if ($success) {
			$tx->commit;
			$self->render( 'recover_password', success => 1 );
		}
		else {
			$self->render( 'recover_password', invalid => 'sendmail' );
		}
	}
	elsif ( $self->param('action')
		and $self->param('action') eq 'set_password' )
	{
		my $id        = $self->param('id');
		my $token     = $self->param('token');
		my $password  = $self->param('newpw');
		my $password2 = $self->param('newpw2');

		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'bad_request',
				csrf   => 1,
				status => 400
			);
			return;
		}
		if (
			not $self->users->verify_password_token(
				uid   => $id,
				token => $token
			)
		  )
		{
			$self->render( 'recover_password', invalid => 'change token' );
			return;
		}
		if ( $password ne $password2 ) {
			$self->render( 'set_password', invalid => 'password_notequal' );
			return;
		}

		if ( length($password) < 8 ) {
			$self->render( 'set_password', invalid => 'password_short' );
			return;
		}

		my $pw_hash = hash_password($password);
		$self->users->set_password_hash(
			uid           => $id,
			password_hash => $pw_hash
		);

		my $account = $self->get_user_data($id);

		if ( not $self->authenticate( $account->{name}, $password ) ) {
			$self->render( 'set_password',
				invalid => 'Authentication failure – WTF?' );
		}

		$self->flash( success => 'password' );
		$self->redirect_to('account');

		$self->users->remove_password_token(
			uid   => $id,
			token => $token
		);

		$self->send_lostpassword_notification_mail($account);
	}
	else {
		$self->render('recover_password');
	}
}

sub recover_password {
	my ($self) = @_;

	my $id    = $self->stash('id');
	my $token = $self->stash('token');

	if ( not $id =~ m{ ^ \d+ $ }x or $id > 2147483647 ) {
		$self->render( 'recover_password', invalid => 'recovery token' );
		return;
	}

	if (
		$self->users->verify_password_token(
			uid   => $id,
			token => $token
		)
	  )
	{
		$self->render('set_password');
	}
	else {
		$self->render( 'recover_password', invalid => 'recovery token' );
	}
}

sub confirm_mail {
	my ($self) = @_;
	my $id     = $self->current_user->{id};
	my $token  = $self->stash('token');

	if (
		$self->users->change_mail_with_token(
			uid   => $id,
			token => $token
		)
	  )
	{
		$self->flash( success => 'mail' );
		$self->redirect_to('account');
	}
	else {
		$self->render( 'change_mail', invalid => 'change token' );
	}
}

sub account {
	my ($self)          = @_;
	my $uid             = $self->current_user->{id};
	my $follow_requests = $self->users->has_follow_requests( uid => $uid );
	my $followers       = $self->users->has_followers( uid => $uid );
	my $following       = $self->users->has_followees( uid => $uid );
	my $blocked         = $self->users->has_blocked_users( uid => $uid );

	$self->render(
		'account',
		api_token           => $self->users->get_api_token( uid => $uid ),
		num_follow_requests => $follow_requests,
		num_followers       => $followers,
		num_following       => $following,
		num_blocked         => $blocked,
	);
	$self->users->mark_seen( uid => $uid );
}

sub json_export {
	my ($self) = @_;
	my $uid = $self->current_user->{id};

	my $db = $self->pg->db;

	$self->render(
		json => {
			account    => $db->select( 'users', '*', { id => $uid } )->hash,
			in_transit => [
				$db->select( 'in_transit_str', '*', { user_id => $uid } )
				  ->hashes->each
			],
			journeys => [
				$db->select( 'journeys_str', '*', { user_id => $uid } )
				  ->hashes->each
			],
		}
	);
}

sub webfinger {
	my ($self) = @_;

	my $resource = $self->param('resource');

	if ( not $resource ) {
		$self->render( 'not_found', status => 404 );
		return;
	}

	my $root_url = $self->base_url_for('/')->to_abs->host;

	if (   not $root_url
		or not $resource
		=~ m{ ^ acct: [@]? (?<name> [^@]+ ) [@] $root_url $ }x )
	{
		$self->render( 'not_found', status => 404 );
		return;
	}

	my $name = $+{name};
	my $user = $self->users->get_privacy_by( name => $name );

	if ( not $user ) {
		$self->render( 'not_found', status => 404 );
		return;
	}

	my $profile_url
	  = $self->base_url_for("/p/${name}")->to_abs->scheme('https')->to_string;

	$self->render(
		text => JSON->new->encode(
			{
				subject => $resource,
				aliases => [ $profile_url, ],
				links   => [
					{
						rel  => 'http://webfinger.net/rel/profile-page',
						type => 'text/html',
						href => $profile_url,
					},
				],
			}
		),
		format => 'json',
	);
}

1;
