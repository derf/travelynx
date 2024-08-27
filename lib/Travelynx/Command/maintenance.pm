package Travelynx::Command::maintenance;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Prune unverified users, incomplete checkins etc';

has usage => sub { shift->extract_usage };

sub run {
	my ( $self, $filename ) = @_;

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );
	my $verification_deadline     = $now->clone->subtract( hours => 48 );
	my $deletion_deadline         = $now->clone->subtract( hours => 72 );
	my $old_deadline              = $now->clone->subtract( years => 1 );
	my $old_notification_deadline = $now->clone->subtract( weeks => 4 );

	my $db = $self->app->pg->db;
	my $tx = $db->begin;

	my $unverified = $db->select(
		'users',
		'id, email, extract(epoch from registered_at) as registered_ts',
		{
			status        => 0,
			registered_at => { '<', $verification_deadline }
		}
	);

	for my $user ( $unverified->hashes->each ) {
		my $mail     = $user->{email};
		my $reg_date = DateTime->from_epoch(
			epoch     => $user->{registered_ts},
			time_zone => 'Europe/Berlin'
		);

		my $pending
		  = $db->select( 'mail_blacklist', ['num_tries'], { email => $mail } );
		my $pending_h = $pending->hash;

		if ($pending_h) {
			my $num_tries = $pending_h->{num_tries} + 1;
			$db->update(
				'mail_blacklist',
				{
					num_tries => $num_tries,
					last_try  => $reg_date
				},
				{ email => $mail }
			);
		}
		else {
			$db->insert(
				'mail_blacklist',
				{
					email     => $mail,
					num_tries => 1,
					last_try  => $reg_date
				}
			);
		}
		$db->delete( 'pending_registrations', { user_id => $user->{id} } );
		$db->delete( 'users',                 { id      => $user->{id} } );
		printf( "Pruned unverified user %d\n", $user->{id} );
	}

	my $res = $db->delete( 'pending_passwords',
		{ requested_at => { '<', $verification_deadline } } );

	if ( my $rows = $res->rows ) {
		printf( "Pruned %d pending password reset(s)\n", $rows );
	}

	$res = $db->delete( 'pending_mails',
		{ requested_at => { '<', $verification_deadline } } );

	if ( my $rows = $res->rows ) {
		printf( "Pruned %d pending mail change(s)\n", $rows );
	}

	my $to_notify = $db->select(
		'users',
		[ 'id', 'name', 'email', 'last_seen' ],
		{
			last_seen         => { '<', $old_deadline },
			deletion_notified => undef
		}
	);

	for my $user ( $to_notify->hashes->each ) {
		say "Sending account deletion notification to uid $user->{id}...";
		$self->app->sendmail->age_deletion_notification(
			name        => $user->{name},
			email       => $user->{email},
			last_seen   => $user->{last_seen},
			login_url   => $self->app->base_url_for('login')->to_abs,
			account_url => $self->app->base_url_for('account')->to_abs,
			imprint_url => $self->app->base_url_for('impressum')->to_abs,
		);
		$self->app->users->mark_deletion_notified( uid => $user->{id} );
	}

	my $to_delete = $db->select( 'users', ['id'],
		{ deletion_requested => { '<', $deletion_deadline } } );
	my @uids_to_delete = $to_delete->arrays->map( sub { shift->[0] } )->each;

	$to_delete = $db->select(
		'users',
		['id'],
		{
			last_seen         => { '<', $old_deadline },
			deletion_notified => { '<', $old_notification_deadline }
		}
	);

	push( @uids_to_delete,
		$to_delete->arrays->map( sub { shift->[0] } )->each );

	if ( @uids_to_delete > 10 ) {
		printf STDERR (
			"About to delete %d accounts, which is quite a lot.\n",
			scalar @uids_to_delete
		);
		for my $uid (@uids_to_delete) {
			my $journeys_res = $db->select(
				'journeys',
				'count(*) as count',
				{ user_id => $uid }
			)->hash;
			printf STDERR (
				" - UID %5d (%4d journeys)\n",
				$uid, $journeys_res->{count}
			);
		}
		say STDERR 'Aborting maintenance. Please investigate.';
		exit(1);
	}

	for my $uid (@uids_to_delete) {
		say "Deleting uid ${uid}...";
		my $count = $self->app->users->delete(
			uid            => $uid,
			db             => $db,
			in_transaction => 1
		);
		printf( "    %d tokens, %d monthly stats, %d journeys\n",
			$count->{tokens}, $count->{stats}, $count->{journeys} );
	}

	$tx->commit;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl maintenance

  Prunes unverified users.
