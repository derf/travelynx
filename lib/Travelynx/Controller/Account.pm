package Travelynx::Controller::Account;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use UUID::Tiny qw(:std);

sub hash_password {
	my ($password) = @_;
	my @salt_bytes = map { int( rand(255) ) + 1 } ( 1 .. 16 );
	my $salt       = en_base64( pack( 'C[16]', @salt_bytes ) );

	return bcrypt( $password, '$2a$12$' . $salt );
}

sub make_token {
	return create_uuid_as_string(UUID_V4);
}

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
			'login',
			invalid => 'csrf',
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
				$self->render( 'login', invalid => 'confirmation' );
			}
			else {
				$self->render( 'login', invalid => 'credentials' );
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
			'register',
			invalid => 'csrf',
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
			'register',
			invalid => 'csrf',
		);
		return;
	}

	my $token   = make_token();
	my $pw_hash = hash_password($password);
	my $db      = $self->pg->db;
	my $tx      = $db->begin;
	my $user_id = $self->users->add_user(
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
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render( 'account', invalid => 'csrf' );
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
			$self->render( 'account', invalid => 'deletion password' );
			return;
		}
		$self->users->flag_deletion( uid => $self->current_user->{id} );
	}
	else {
		$self->users->unflag_deletion( uid => $self->current_user->{id} );
	}
	$self->redirect_to('account');
}

sub do_logout {
	my ($self) = @_;
	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render( 'login', invalid => 'csrf' );
		return;
	}
	$self->logout;
	$self->redirect_to('/login');
}

sub privacy {
	my ($self) = @_;

	my $user         = $self->current_user;
	my $public_level = $user->{is_public};

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		if ( $self->param('status_level') eq 'intern' ) {
			$public_level |= 0x01;
			$public_level &= ~0x02;
		}
		elsif ( $self->param('status_level') eq 'extern' ) {
			$public_level |= 0x02;
			$public_level &= ~0x01;
		}
		else {
			$public_level &= ~0x03;
		}

		# public comment with non-public status does not make sense
		if (    $self->param('public_comment')
			and $self->param('status_level') ne 'private' )
		{
			$public_level |= 0x04;
		}
		else {
			$public_level &= ~0x04;
		}

		if ( $self->param('history_level') eq 'intern' ) {
			$public_level |= 0x10;
			$public_level &= ~0x20;
		}
		elsif ( $self->param('history_level') eq 'extern' ) {
			$public_level |= 0x20;
			$public_level &= ~0x10;
		}
		else {
			$public_level &= ~0x30;
		}

		if ( $self->param('history_age') eq 'infinite' ) {
			$public_level |= 0x40;
		}
		else {
			$public_level &= ~0x40;
		}

		$self->users->set_privacy(
			uid   => $user->{id},
			level => $public_level
		);

		$self->flash( success => 'privacy' );
		$self->redirect_to('account');
	}
	else {
		$self->param(
			  status_level => $public_level & 0x01 ? 'intern'
			: $public_level & 0x02 ? 'extern'
			:                        'private'
		);
		$self->param( public_comment => $public_level & 0x04 ? 1 : 0 );
		$self->param(
			  history_level => $public_level & 0x10 ? 'intern'
			: $public_level & 0x20 ? 'extern'
			:                        'private'
		);
		$self->param(
			history_age => $public_level & 0x40 ? 'infinite' : 'month' );
		$self->render( 'privacy', name => $user->{name} );
	}
}

sub insight {
	my ($self) = @_;

	my $user        = $self->current_user;
	my $use_history = $self->users->use_history( uid => $user->{id} );

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

		$self->users->use_history(
			uid => $user->{id},
			set => $use_history
		);
		$self->flash( success => 'use_history' );
		$self->redirect_to('account');
	}

	$self->param( on_departure => $use_history & 0x01 ? 1 : 0 );
	$self->param( on_arrival   => $use_history & 0x02 ? 1 : 0 );
	$self->render('use_history');

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
				'change_mail',
				invalid => 'csrf',
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

sub change_name {
	my ($self) = @_;

	my $action   = $self->req->param('action');
	my $password = $self->req->param('password');
	my $old_name = $self->current_user->{name};
	my $new_name = $self->req->param('name');

	if ( $action and $action eq 'update_name' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render(
				'change_name',
				name    => $old_name,
				invalid => 'csrf',
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
		$self->render( 'change_password', invalid => 'csrf' );
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

sub request_password_reset {
	my ($self) = @_;

	if ( $self->param('action') and $self->param('action') eq 'initiate' ) {
		if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
			$self->render( 'recover_password', invalid => 'csrf' );
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
			$self->render( 'set_password', invalid => 'csrf' );
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
	my ($self) = @_;

	$self->render('account');
	$self->users->mark_seen( uid => $self->current_user->{id} );
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

1;
