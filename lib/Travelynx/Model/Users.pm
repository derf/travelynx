package Travelynx::Model::Users;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
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

my %predicate_itoa = (
	1 => 'follows',
	2 => 'requests_follow',
	3 => 'is_blocked_by',
);

my %predicate_atoi = (
	follows         => 1,
	requests_follow => 2,
	is_blocked_by   => 3,
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

sub hash_password {
	my ( $self, $password ) = @_;
	my @salt_bytes = map { int( rand(255) ) + 1 } ( 1 .. 16 );
	my $salt       = en_base64( pack( 'C[16]', @salt_bytes ) );

	return bcrypt( substr( $password, 0, 10000 ), '$2a$12$' . $salt );
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
		if ($tx) {
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

sub get_privacy_by {
	my ( $self, %opt ) = @_;
	my $db = $opt{db} // $self->{pg}->db;

	my %where;

	if ( $opt{name} ) {
		$where{name} = $opt{name};
	}
	else {
		$where{id} = $opt{uid};
	}

	my $res = $db->select(
		'users',
		[ 'id', 'name', 'public_level', 'accept_follows' ],
		{ %where, status => 1 }
	);

	if ( my $user = $res->hash ) {
		return {
			id                     => $user->{id},
			name                   => $user->{name},
			default_visibility     => $user->{public_level} & 0x7f,
			default_visibility_str =>
			  $visibility_itoa{ $user->{public_level} & 0x7f },
			comments_visible    => $user->{public_level} & 0x80 ? 1 : 0,
			past_visibility     => ( $user->{public_level} & 0x7f00 ) >> 8,
			past_visibility_str =>
			  $visibility_itoa{ ( $user->{public_level} & 0x7f00 ) >> 8 },
			past_status            => $user->{public_level} & 0x08000 ? 1 : 0,
			past_all               => $user->{public_level} & 0x10000 ? 1 : 0,
			accept_follows         => $user->{accept_follows} == 2    ? 1 : 0,
			accept_follow_requests => $user->{accept_follows} == 1    ? 1 : 0,
		};
	}
	return;
}

sub set_backend {
	my ( $self, %opt ) = @_;
	$opt{db} //= $self->{pg}->db;

	$opt{db}->update(
		'users',
		{ backend_id => $opt{backend_id} },
		{ id         => $opt{uid} }
	);
}

sub set_privacy {
	my ( $self, %opt ) = @_;
	my $db           = $opt{db} // $self->{pg}->db;
	my $uid          = $opt{uid};
	my $public_level = $opt{level};

	if ( not defined $public_level and defined $opt{default_visibility} ) {
		$public_level
		  = ( $opt{default_visibility} & 0x7f )
		  | ( $opt{comments_visible} ? 0x80 : 0 )
		  | ( ( $opt{past_visibility} & 0x7f ) << 8 )
		  | ( $opt{past_status} ? 0x08000 : 0 )
		  | ( $opt{past_all}    ? 0x10000 : 0 );
	}

	$db->update( 'users', { public_level => $public_level }, { id => $uid } );
}

sub set_social {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $accept_follows = 0;

	if ( $opt{accept_follows} ) {
		$accept_follows = 2;
	}
	elsif ( $opt{accept_follow_requests} ) {
		$accept_follows = 1;
	}

	$db->update(
		'users',
		{ accept_follows => $accept_follows },
		{ id             => $uid }
	);
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
		'users_with_backend',
		'id, name, status, public_level, email, '
		  . 'accept_follows, notifications, '
		  . 'extract(epoch from registered_at) as registered_at_ts, '
		  . 'extract(epoch from last_seen) as last_seen_ts, '
		  . 'extract(epoch from deletion_requested) as deletion_requested_ts, '
		  . 'backend_id, backend_name, efa, hafas',
		{ id => $uid }
	)->hash;
	if ($user) {
		return {
			id                     => $user->{id},
			name                   => $user->{name},
			status                 => $user->{status},
			notifications          => $user->{notifications},
			accept_follows         => $user->{accept_follows} == 2 ? 1 : 0,
			accept_follow_requests => $user->{accept_follows} == 1 ? 1 : 0,
			default_visibility     => $user->{public_level} & 0x7f,
			default_visibility_str =>
			  $visibility_itoa{ $user->{public_level} & 0x7f },
			comments_visible    => $user->{public_level} & 0x80 ? 1 : 0,
			past_visibility     => ( $user->{public_level} & 0x7f00 ) >> 8,
			past_visibility_str =>
			  $visibility_itoa{ ( $user->{public_level} & 0x7f00 ) >> 8 },
			past_status => $user->{public_level} & 0x08000 ? 1 : 0,
			past_all    => $user->{public_level} & 0x10000 ? 1 : 0,
			email       => $user->{email},
			sb_template =>
			  'https://dbf.finalrewind.org/{name}?rt=1&hafas={hafas}#{tt}{tn}',
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
			backend_id    => $user->{backend_id},
			backend_name  => $user->{backend_name},
			backend_efa   => $user->{efa},
			backend_hafas => $user->{hafas},
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
	my $password  = $self->hash_password( $opt{password} );

	# This helper must be called during a transaction, as user creation
	# may fail even after the database entry has been generated, e.g.  if
	# the registration mail cannot be sent. We therefore use $db (the
	# database handle performing the transaction) instead of $self->pg->db
	# (which may be a new handle not belonging to the transaction).

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );

	my $res = $db->insert(
		'users',
		{
			name         => $user_name,
			status       => 0,
			public_level => $visibility_atoi{unlisted}
			  | ( $visibility_atoi{unlisted} << 8 ),
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

	$res{tokens}    = $db->delete( 'tokens',            { user_id => $uid } );
	$res{stats}     = $db->delete( 'journey_stats',     { user_id => $uid } );
	$res{journeys}  = $db->delete( 'journeys',          { user_id => $uid } );
	$res{transit}   = $db->delete( 'in_transit',        { user_id => $uid } );
	$res{hooks}     = $db->delete( 'webhooks',          { user_id => $uid } );
	$res{trwl}      = $db->delete( 'traewelling',       { user_id => $uid } );
	$res{password}  = $db->delete( 'pending_passwords', { user_id => $uid } );
	$res{relations} = $db->delete( 'relations',
		[ { subject_id => $uid }, { object_id => $uid } ] );
	$res{users} = $db->delete( 'users', { id => $uid } );

	for my $key ( keys %res ) {
		$res{$key} = $res{$key}->rows;
	}

	if ( $res{users} != 1 ) {
		die("Deleted $res{users} rows from users, expected 1. Rolling back.\n");
	}

	if ($tx) {
		$tx->commit;
	}

	return \%res;
}

sub set_password {
	my ( $self, %opt ) = @_;
	my $db       = $opt{db} // $self->{pg}->db;
	my $uid      = $opt{uid};
	my $password = $self->hash_password( $opt{password} );

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

sub set_profile {
	my ( $self, %opt ) = @_;

	my $db      = $opt{db} // $self->{pg}->db;
	my $uid     = $opt{uid};
	my $profile = $opt{profile};

	$db->update(
		'users',
		{ profile => JSON->new->encode($profile) },
		{ id      => $uid }
	);
}

sub get_profile {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	return $db->select( 'users', ['profile'], { id => $uid } )
	  ->expand->hash->{profile};
}

sub get_relation {
	my ( $self, %opt ) = @_;

	my $db      = $opt{db} // $self->{pg}->db;
	my $subject = $opt{subject};
	my $object  = $opt{object};

	my $res_h = $db->select(
		'relations',
		['predicate'],
		{
			subject_id => $subject,
			object_id  => $object,
		}
	)->hash;

	if ($res_h) {
		return $predicate_itoa{ $res_h->{predicate} };
	}
	return;

	#my $res_h = $db->select( 'relations', ['subject_id', 'predicate'],
	#	{ subject_id => [$uid, $target], object_id => [$target, $target] } )->hash;
}

sub update_notifications {
	my ( $self, %opt ) = @_;

	# must be called inside a transaction, so $opt{db} is mandatory.
	my $db  = $opt{db};
	my $uid = $opt{uid};

	my $has_follow_requests = $opt{has_follow_requests}
	  // $self->has_follow_requests(
		db  => $db,
		uid => $uid
	  );

	my $notifications
	  = $db->select( 'users', ['notifications'], { id => $uid } )
	  ->hash->{notifications};
	if ($has_follow_requests) {
		$notifications |= 0x01;
	}
	else {
		$notifications &= ~0x01;
	}
	$db->update( 'users', { notifications => $notifications }, { id => $uid } );
}

sub follow {
	my ( $self, %opt ) = @_;

	my $db     = $opt{db} // $self->{pg}->db;
	my $uid    = $opt{uid};
	my $target = $opt{target};

	$db->insert(
		'relations',
		{
			subject_id => $uid,
			predicate  => $predicate_atoi{follows},
			object_id  => $target,
			ts         => DateTime->now( time_zone => 'Europe/Berlin' ),
		}
	);
}

sub request_follow {
	my ( $self, %opt ) = @_;

	my $db     = $opt{db} // $self->{pg}->db;
	my $uid    = $opt{uid};
	my $target = $opt{target};

	my $tx;
	if ( not $opt{in_transaction} ) {
		$tx = $db->begin;
	}

	$db->insert(
		'relations',
		{
			subject_id => $uid,
			predicate  => $predicate_atoi{requests_follow},
			object_id  => $target,
			ts         => DateTime->now( time_zone => 'Europe/Berlin' ),
		}
	);
	$self->update_notifications(
		db                  => $db,
		uid                 => $target,
		has_follow_requests => 1,
	);

	if ($tx) {
		$tx->commit;
	}
}

sub accept_follow_request {
	my ( $self, %opt ) = @_;

	my $db        = $opt{db} // $self->{pg}->db;
	my $uid       = $opt{uid};
	my $applicant = $opt{applicant};

	my $tx;
	if ( not $opt{in_transaction} ) {
		$tx = $db->begin;
	}

	$db->update(
		'relations',
		{
			predicate => $predicate_atoi{follows},
			ts        => DateTime->now( time_zone => 'Europe/Berlin' ),
		},
		{
			subject_id => $applicant,
			predicate  => $predicate_atoi{requests_follow},
			object_id  => $uid
		}
	);
	$self->update_notifications(
		db  => $db,
		uid => $uid
	);

	if ($tx) {
		$tx->commit;
	}
}

sub reject_follow_request {
	my ( $self, %opt ) = @_;

	my $db        = $opt{db} // $self->{pg}->db;
	my $uid       = $opt{uid};
	my $applicant = $opt{applicant};

	my $tx;
	if ( not $opt{in_transaction} ) {
		$tx = $db->begin;
	}

	$db->delete(
		'relations',
		{
			subject_id => $applicant,
			predicate  => $predicate_atoi{requests_follow},
			object_id  => $uid
		}
	);
	$self->update_notifications(
		db  => $db,
		uid => $uid
	);

	if ($tx) {
		$tx->commit;
	}
}

sub cancel_follow_request {
	my ( $self, %opt ) = @_;

	$self->reject_follow_request(
		db        => $opt{db},
		uid       => $opt{target},
		applicant => $opt{uid},
	);
}

sub unfollow {
	my ( $self, %opt ) = @_;

	my $db     = $opt{db} // $self->{pg}->db;
	my $uid    = $opt{uid};
	my $target = $opt{target};

	$db->delete(
		'relations',
		{
			subject_id => $uid,
			predicate  => $predicate_atoi{follows},
			object_id  => $target
		}
	);
}

sub remove_follower {
	my ( $self, %opt ) = @_;

	$self->unfollow(
		db     => $opt{db},
		uid    => $opt{follower},
		target => $opt{uid},
	);
}

sub block {
	my ( $self, %opt ) = @_;

	my $db     = $opt{db} // $self->{pg}->db;
	my $uid    = $opt{uid};
	my $target = $opt{target};

	my $tx;
	if ( not $opt{in_transaction} ) {
		$tx = $db->begin;
	}

	$db->insert(
		'relations',
		{
			subject_id => $target,
			predicate  => $predicate_atoi{is_blocked_by},
			object_id  => $uid,
			ts         => DateTime->now( time_zone => 'Europe/Berlin' ),
		},
		{
			on_conflict => \
'(subject_id, object_id) do update set predicate = EXCLUDED.predicate'
		},
	);
	$self->update_notifications(
		db  => $db,
		uid => $uid
	);

	if ($tx) {
		$tx->commit;
	}
}

sub unblock {
	my ( $self, %opt ) = @_;

	my $db     = $opt{db} // $self->{pg}->db;
	my $uid    = $opt{uid};
	my $target = $opt{target};

	$db->delete(
		'relations',
		{
			subject_id => $target,
			predicate  => $predicate_atoi{is_blocked_by},
			object_id  => $uid
		},
	);
}

sub get_followers {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $res = $db->select(
		'followers',
		[ 'id', 'name', 'accept_follows', 'inverse_predicate' ],
		{ self_id => $uid }
	);

	my @ret;
	while ( my $row = $res->hash ) {
		push(
			@ret,
			{
				id             => $row->{id},
				name           => $row->{name},
				following_back => (
					      $row->{inverse_predicate}
					  and $row->{inverse_predicate} == $predicate_atoi{follows}
				) ? 1 : 0,
				followback_requested => (
					      $row->{inverse_predicate}
					  and $row->{inverse_predicate}
					  == $predicate_atoi{requests_follow}
				) ? 1 : 0,
				can_follow_back => (
					not $row->{inverse_predicate}
					  and $row->{accept_follows} == 2
				) ? 1 : 0,
				can_request_follow_back => (
					not $row->{inverse_predicate}
					  and $row->{accept_follows} == 1
				) ? 1 : 0,
			}
		);
	}
	return @ret;
}

sub has_followers {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	return $db->select( 'followers', 'count(*) as count', { self_id => $uid } )
	  ->hash->{count};
}

sub get_follow_requests {
	my ( $self, %opt ) = @_;

	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $table = $opt{sent} ? 'tx_follow_requests' : 'rx_follow_requests';

	my $res
	  = $db->select( $table, [ 'id', 'name' ], { self_id => $uid } );

	return $res->hashes->each;
}

sub has_follow_requests {
	my ( $self, %opt ) = @_;

	my $db    = $opt{db} // $self->{pg}->db;
	my $uid   = $opt{uid};
	my $table = $opt{sent} ? 'tx_follow_requests' : 'rx_follow_requests';

	return $db->select( $table, 'count(*) as count', { self_id => $uid } )
	  ->hash->{count};
}

sub get_followees {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $res = $db->select(
		'followees',
		[ 'id', 'name', 'inverse_predicate' ],
		{ self_id => $uid }
	);

	my @ret;
	while ( my $row = $res->hash ) {
		push(
			@ret,
			{
				id             => $row->{id},
				name           => $row->{name},
				following_back => (
					      $row->{inverse_predicate}
					  and $row->{inverse_predicate} == $predicate_atoi{follows}
				) ? 1 : 0,
			}
		);
	}
	return @ret;
}

sub has_followees {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	return $db->select( 'followees', 'count(*) as count', { self_id => $uid } )
	  ->hash->{count};
}

sub get_blocked_users {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	my $res
	  = $db->select( 'blocked_users', [ 'id', 'name' ], { self_id => $uid } );

	return $res->hashes->each;
}

sub has_blocked_users {
	my ( $self, %opt ) = @_;

	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	return $db->select( 'blocked_users', 'count(*) as count',
		{ self_id => $uid } )->hash->{count};
}

1;
