package Travelynx::Model::Users;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;

my @sb_templates = (
	undef,
	[ 'DBF', 'https://dbf.finalrewind.org/{name}?rt=1#{tt}{tn}' ],
	[ 'marudor.de', 'https://bahn.expert/{name}#{id}' ],
	[ 'NVM',        'https://nvm.finalrewind.org/board/{eva}#{tt}{tn}' ],
	[ 'marudor.de/regional', 'https://bahn.expert/regional/{name}#{id}' ],
);

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub mark_seen {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	$db->update(
		'users',
		{
			last_seen         => DateTime->now( time_zone => 'Europe/Berlin' ),
			deletion_notified => undef
		},
		{ id => $uid }
	);
}

sub mark_deletion_notified {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	$db->update(
		'users',
		{
			deletion_notified => DateTime->now( time_zone => 'Europe/Berlin' ),
		},
		{ id => $uid }
	);
}

sub verify_registration_token {
	my ( $self, %opt ) = @_;
	my $uid   = $opt{uid};
	my $token = $opt{token};
	my $db    = $opt{db} // $self->{pg}->db;

	my $tx;

	if ( not $opt{in_transaction} ) {
		$tx = $db->begin;
	}

	my $res = $db->select(
		'pending_registrations',
		'count(*) as count',
		{
			user_id => $uid,
			token   => $token
		}
	);

	if ( $res->hash->{count} ) {
		$db->update( 'users', { status => 1 }, { id => $uid } );
		$db->delete( 'pending_registrations', { user_id => $uid } );
		if ( not $opt{in_transaction} ) {
			$tx->commit;
		}
		return 1;
	}
	return;
}

sub get_uid_by_name_and_mail {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $name  = $opt{name};
	my $email = $opt{email};

	my $res = $db->select(
		'users',
		['id'],
		{
			name   => $name,
			email  => $email,
			status => 1
		}
	);

	if ( my $user = $res->hash ) {
		return $user->{id};
	}
	return;
}

sub get_privacy_by_name {
	my ( $self, %opt ) = @_;
	my $db   = $opt{db} // $self->{pg}->db;
	my $name = $opt{name};

	my $res = $db->select(
		'users',
		[ 'id', 'public_level' ],
		{
			name   => $name,
			status => 1
		}
	);

	if ( my $user = $res->hash ) {
		return $user;
	}
	return;
}

sub set_privacy {
	my ( $self, %opt ) = @_;
	my $db           = $opt{db} // $self->{pg}->db;
	my $uid          = $opt{uid};
	my $public_level = $opt{level};

	$db->update( 'users', { public_level => $public_level }, { id => $uid } );
}

sub mark_for_password_reset {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $token = $opt{token};

	my $res = $db->select(
		'pending_passwords',
		'count(*) as count',
		{ user_id => $uid }
	);
	if ( $res->hash->{count} ) {
		return 'in progress';
	}

	$db->insert(
		'pending_passwords',
		{
			user_id      => $uid,
			token        => $token,
			requested_at => DateTime->now( time_zone => 'Europe/Berlin' )
		}
	);

	return undef;
}

sub verify_password_token {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $token = $opt{token};

	my $res = $db->select(
		'pending_passwords',
		'count(*) as count',
		{
			user_id => $uid,
			token   => $token
		}
	);

	if ( $res->hash->{count} ) {
		return 1;
	}
	return;
}

sub mark_for_mail_change {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $email = $opt{email};
	my $token = $opt{token};

	$db->insert(
		'pending_mails',
		{
			user_id      => $uid,
			email        => $email,
			token        => $token,
			requested_at => DateTime->now( time_zone => 'Europe/Berlin' )
		},
		{
			on_conflict => \
'(user_id) do update set email = EXCLUDED.email, token = EXCLUDED.token, requested_at = EXCLUDED.requested_at'
		},
	);
}

sub change_mail_with_token {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $token = $opt{token};

	my $tx = $db->begin;

	my $res_h = $db->select(
		'pending_mails',
		['email'],
		{
			user_id => $uid,
			token   => $token
		}
	)->hash;

	if ($res_h) {
		$db->update( 'users', { email => $res_h->{email} }, { id => $uid } );
		$db->delete( 'pending_mails', { user_id => $uid } );
		$tx->commit;
		return 1;
	}
	return;
}

sub is_name_invalid {
	my ( $self, %opt ) = @_;
	my $db   = $opt{db} // $self->{pg}->db;
	my $name = $opt{name};

	if ( not length($name) ) {
		return 'user_empty';
	}

	if ( $name !~ m{ ^ [0-9a-zA-Z_-]+ $ }x ) {
		return 'user_format';
	}

	if (
		$self->user_name_exists(
			db   => $db,
			name => $name
		)
	  )
	{
		return 'user_collision';
	}

	return;
}

sub change_name {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	eval { $db->update( 'users', { name => $opt{name} }, { id => $uid } ); };

	if ($@) {
		return 0;
	}

	return 1;
}

sub remove_password_token {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $token = $opt{token};

	$db->delete(
		'pending_passwords',
		{
			user_id => $uid,
			token   => $token
		}
	);
}

sub get_data {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $user = $db->select(
		'users',
		'id, name, status, public_level, email, external_services, '
		  . 'extract(epoch from registered_at) as registered_at_ts, '
		  . 'extract(epoch from last_seen) as last_seen_ts, '
		  . 'extract(epoch from deletion_requested) as deletion_requested_ts',
		{ id => $uid }
	)->hash;
	if ($user) {
		return {
			id        => $user->{id},
			name      => $user->{name},
			status    => $user->{status},
			is_public => $user->{public_level},
			email     => $user->{email},
			sb_name   => $user->{external_services}
			? $sb_templates[ $user->{external_services} & 0x07 ][0]
			: undef,
			sb_template => $user->{external_services}
			? $sb_templates[ $user->{external_services} & 0x07 ][1]
			: undef,
			registered_at => DateTime->from_epoch(
				epoch     => $user->{registered_at_ts},
				time_zone => 'Europe/Berlin'
			),
			last_seen => DateTime->from_epoch(
				epoch     => $user->{last_seen_ts},
				time_zone => 'Europe/Berlin'
			),
			deletion_requested => $user->{deletion_requested_ts}
			? DateTime->from_epoch(
				epoch     => $user->{deletion_requested_ts},
				time_zone => 'Europe/Berlin'
			  )
			: undef,
		};
	}
	return undef;
}

sub get_login_data {
	my ( $self, %opt ) = @_;
	my $db   = $opt{db} // $self->{pg}->db;
	my $name = $opt{name};

	my $res_h = $db->select(
		'users',
		'id, name, status, password as password_hash',
		{ name => $name }
	)->hash;

	return $res_h;
}

sub add_user {
	my ( $self, %opt ) = @_;
	my $db        = $opt{db} // $self->{pg}->db;
	my $user_name = $opt{name};
	my $email     = $opt{email};
	my $token     = $opt{token};
	my $password  = $opt{password_hash};

	# This helper must be called during a transaction, as user creation
	# may fail even after the database entry has been generated, e.g.  if
	# the registration mail cannot be sent. We therefore use $db (the
	# database handle performing the transaction) instead of $self->pg->db
	# (which may be a new handle not belonging to the transaction).

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );

	my $res = $db->insert(
		'users',
		{
			name          => $user_name,
			status        => 0,
			public_level  => 0,
			email         => $email,
			password      => $password,
			registered_at => $now,
			last_seen     => $now,
		},
		{ returning => 'id' }
	);
	my $uid = $res->hash->{id};

	$db->insert(
		'pending_registrations',
		{
			user_id => $uid,
			token   => $token
		}
	);

	return $uid;
}

sub flag_deletion {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );

	$db->update(
		'users',
		{ deletion_requested => $now },
		{
			id => $uid,
		}
	);
}

sub unflag_deletion {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	$db->update(
		'users',
		{
			deletion_requested => undef,
		},
		{
			id => $uid,
		}
	);
}

sub set_password_hash {
	my ( $self, %opt ) = @_;
	my $db       = $opt{db} // $self->{pg}->db;
	my $uid      = $opt{uid};
	my $password = $opt{password_hash};

	$db->update( 'users', { password => $password }, { id => $uid } );
}

sub user_name_exists {
	my ( $self, %opt ) = @_;
	my $db        = $opt{db} // $self->{pg}->db;
	my $user_name = $opt{name};

	my $count
	  = $db->select( 'users', 'count(*) as count', { name => $user_name } )
	  ->hash->{count};

	if ($count) {
		return 1;
	}
	return 0;
}

sub mail_is_blacklisted {
	my ( $self, %opt ) = @_;
	my $db   = $opt{db} // $self->{pg}->db;
	my $mail = $opt{email};

	my $count = $db->select(
		'users',
		'count(*) as count',
		{
			email  => $mail,
			status => 0,
		}
	)->hash->{count};

	if ($count) {
		return 1;
	}

	$count = $db->select(
		'mail_blacklist',
		'count(*) as count',
		{
			email     => $mail,
			num_tries => { '>', 1 },
		}
	)->hash->{count};

	if ($count) {
		return 1;
	}
	return 0;
}

sub use_history {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $value = $opt{set};

	if ($value) {
		$db->update( 'users', { use_history => $value }, { id => $uid } );
	}
	else {
		return $db->select( 'users', ['use_history'], { id => $uid } )
		  ->hash->{use_history};
	}
}

sub use_external_services {
	my ( $self, %opt ) = @_;
	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $value = $opt{set};

	if ( defined $value ) {
		if ( $value < 0 or $value > 4 ) {
			$value = 0;
		}
		$db->update( 'users', { external_services => $value }, { id => $uid } );
	}
	else {
		return $db->select( 'users', ['external_services'], { id => $uid } )
		  ->hash->{external_services};
	}
}

sub get_webhook {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $res_h = $db->select( 'webhooks_str', '*', { user_id => $uid } )->hash;

	$res_h->{latest_run} = DateTime->from_epoch(
		epoch     => $res_h->{latest_run_ts} // 0,
		time_zone => 'Europe/Berlin',
		locale    => 'de-DE',
	);

	return $res_h;
}

sub set_webhook {
	my ( $self, %opt ) = @_;
	my $db = $opt{db} // $self->{pg}->db;

	if ( $opt{token} ) {
		$opt{token} =~ tr{\r\n}{}d;
	}

	my $res = $db->insert(
		'webhooks',
		{
			user_id => $opt{uid},
			enabled => $opt{enabled},
			url     => $opt{url},
			token   => $opt{token}
		},
		{
			on_conflict => \
'(user_id) do update set enabled = EXCLUDED.enabled, url = EXCLUDED.url, token = EXCLUDED.token, errored = null, latest_run = null, output = null'
		}
	);
}

sub update_webhook_status {
	my ( $self, %opt ) = @_;

	my $db      = $opt{db} // $self->{pg}->db;
	my $uid     = $opt{uid};
	my $url     = $opt{url};
	my $success = $opt{success};
	my $text    = $opt{text};

	if ( length($text) > 1000 ) {
		$text = substr( $text, 0, 1000 ) . '…';
	}

	$db->update(
		'webhooks',
		{
			errored    => $success ? 0 : 1,
			latest_run => DateTime->now( time_zone => 'Europe/Berlin' ),
			output     => $text,
		},
		{
			user_id => $uid,
			url     => $url
		}
	);
}

1;
