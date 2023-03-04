package Travelynx::Model::Users;

# Copyright (C) 2020-2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use JSON;

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

my @sb_templates = (
	undef,
	[ 'DBF',         'https://dbf.finalrewind.org/{name}?rt=1#{tt}{tn}' ],
	[ 'bahn.expert', 'https://bahn.expert/{name}#{id}' ],
	[ 'DBF HAFAS', 'https://dbf.finalrewind.org/{name}?rt=1&hafas=1#{tt}{tn}' ],
	[ 'bahn.expert/regional', 'https://bahn.expert/regional/{name}#{id}' ],
);

my %token_id = (
	status  => 1,
	history => 2,
	travel  => 3,
	import  => 4,
);
my @token_types = (qw(status history travel import));

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub get_token_id {
	my ( $self, $type ) = @_;

	return $token_id{$type};
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

sub get_api_token {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $token = {};
	my $res = $db->select( 'tokens', [ 'type', 'token' ], { user_id => $uid } );

	for my $entry ( $res->hashes->each ) {
		$token->{ $token_types[ $entry->{type} - 1 ] }
		  = $entry->{token};
	}

	return $token;
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
		return {
			id                 => $user->{id},
			public_level       => $user->{public_level},          # todo remove?
			default_visibility => $user->{public_level} & 0x7f,
			default_visibility_str =>
			  $visibility_itoa{ $user->{public_level} & 0x7f },
			comments_visible => $user->{public_level} & 0x80 ? 1 : 0,
			past_visible     => ( $user->{public_level} & 0x300 ) >> 8,
			past_all         => $user->{public_level} & 0x400 ? 1 : 0,
			past_status      => $user->{public_level} & 0x800 ? 1 : 0,
		};
	}
	return;
}

sub set_privacy {
	my ( $self, %opt ) = @_;
	my $db           = $opt{db} // $self->{pg}->db;
	my $uid          = $opt{uid};
	my $public_level = $opt{level};

	if ( not defined $public_level and defined $opt{default_visibility} ) {
		$public_level
		  = ( $opt{default_visibility} & 0x7f )
		  | ( $opt{comments_visible} ? 0x80 : 0x00 )
		  | ( ( ( $opt{past_visible} // 0 ) << 8 ) & 0x300 )
		  | ( $opt{past_all} ? 0x400 : 0 ) | ( $opt{past_status} ? 0x800 : 0 );
	}

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

sub get {
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
			id                     => $user->{id},
			name                   => $user->{name},
			status                 => $user->{status},
			is_public              => $user->{public_level},
			default_visibility     => $user->{public_level} & 0x7f,
			default_visibility_str =>
			  $visibility_itoa{ $user->{public_level} & 0x7f },
			comments_visible => $user->{public_level} & 0x80 ? 1 : 0,
			past_visible     => ( $user->{public_level} & 0x300 ) >> 8,
			past_all         => $user->{public_level} & 0x400 ? 1 : 0,
			past_status      => $user->{public_level} & 0x800 ? 1 : 0,
			email            => $user->{email},
			sb_name          => $user->{external_services}
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

sub add {
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
			public_level  => $visibility_atoi{unlisted},
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

sub delete {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};
	my $tx;

	if ( not $opt{in_transaction} ) {
		$tx = $db->begin;
	}

	my %res;

	$res{tokens}   = $db->delete( 'tokens',            { user_id => $uid } );
	$res{stats}    = $db->delete( 'journey_stats',     { user_id => $uid } );
	$res{journeys} = $db->delete( 'journeys',          { user_id => $uid } );
	$res{transit}  = $db->delete( 'in_transit',        { user_id => $uid } );
	$res{hooks}    = $db->delete( 'webhooks',          { user_id => $uid } );
	$res{trwl}     = $db->delete( 'traewelling',       { user_id => $uid } );
	$res{lt}       = $db->delete( 'localtransit',      { user_id => $uid } );
	$res{password} = $db->delete( 'pending_passwords', { user_id => $uid } );
	$res{users}    = $db->delete( 'users',             { id      => $uid } );

	for my $key ( keys %res ) {
		$res{$key} = $res{$key}->rows;
	}

	if ( $res{users} != 1 ) {
		die("Deleted $res{users} rows from users, expected 1. Rolling back.\n");
	}

	if ( not $opt{in_transaction} ) {
		$tx->commit;
	}

	return \%res;
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

	if ( $opt{destinations} ) {
		$db->insert(
			'localtransit',
			{
				user_id => $uid,
				data    =>
				  JSON->new->encode( { destinations => $opt{destinations} } )
			},
			{ on_conflict => \'(user_id) do update set data = EXCLUDED.data' }
		);
	}

	if ($value) {
		$db->update( 'users', { use_history => $value }, { id => $uid } );
	}
	else {
		if ( $opt{with_local_transit} ) {
			my $res = $db->select(
				'user_transit',
				[ 'use_history', 'data' ],
				{ id => $uid }
			)->expand->hash;
			return ( $res->{use_history}, $res->{data}{destinations} // [] );
		}
		else {
			return $db->select( 'users', ['use_history'], { id => $uid } )
			  ->hash->{use_history};
		}
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
