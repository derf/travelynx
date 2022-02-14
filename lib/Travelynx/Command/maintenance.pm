package Travelynx::Command::maintenance;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Prune unverified users, incomplete checkins etc';

has usage => sub { shift->extract_usage };

sub run {
	my ( $self, $filename ) = @_;

	my $now                   = DateTime->now( time_zone => 'Europe/Berlin' );
	my $verification_deadline = $now->clone->subtract( hours => 48 );
	my $deletion_deadline     = $now->clone->subtract( hours => 72 );
	my $old_deadline          = $now->clone->subtract( years => 1 );
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
		say STDERR 'Aborting maintenance. Please investigate.';
		exit(1);
	}

	for my $uid (@uids_to_delete) {
		say "Deleting uid ${uid}...";
		my $tokens_res   = $db->delete( 'tokens',        { user_id => $uid } );
		my $stats_res    = $db->delete( 'journey_stats', { user_id => $uid } );
		my $journeys_res = $db->delete( 'journeys',      { user_id => $uid } );
		my $transit_res  = $db->delete( 'in_transit',    { user_id => $uid } );
		my $hooks_res    = $db->delete( 'webhooks',      { user_id => $uid } );
		my $trwl_res     = $db->delete( 'traewelling',   { user_id => $uid } );

		# TODO + traewelling, webhooks
		my $password_res
		  = $db->delete( 'pending_passwords', { user_id => $uid } );
		my $user_res = $db->delete( 'users', { id => $uid } );

		printf( "    %d tokens, %d monthly stats, %d journeys\n",
			$tokens_res->rows, $stats_res->rows, $journeys_res->rows );

		if ( $user_res->rows != 1 ) {
			printf STDERR (
				"Deleted %d rows from users, expected 1. Rollback and abort.\n",
				$user_res->rows
			);
			exit(1);
		}
	}

	$tx->commit;

	# Computing stats may take a while, but we've got all time in the
	# world here. This means users won't have to wait when loading their
	# own journey log.
	say 'Generating missing stats ...';
	for
	  my $user ( $db->select( 'users', ['id'], { status => 1 } )->hashes->each )
	{
		$tx = $db->begin;
		$self->app->journeys->generate_missing_stats( uid => $user->{id} );
		$self->app->journeys->get_stats(
			uid  => $user->{id},
			year => $now->year
		);
		$tx->commit;
	}

	# Add estimated polylines to journeys logged before 2020-01-28

	$tx = $db->begin;

	say 'Adding polylines to journeys logged before 2020-01-28';
	my $no_polyline
	  = $db->select( 'journeys', 'count(*) as count', { polyline_id => undef } )
	  ->hash;
	say "Checking $no_polyline->{count} journeys ...";

	for my $journey (
		$db->select( 'journeys', [ 'id', 'route' ], { polyline_id => undef } )
		->hashes->each )
	{

		# prior to v1.9.4, routes were stored as [["stop1"], ["stop2"], ...].
		# Nowadays, the common format is [["stop1", {}, null], ...].
		# entry[1] is non-empty only while checked in, entry[2] is non-null only
		# if the stop is unscheduled or has been cancelled.
		#
		# Here, we pretend to use the new format, as we're looking for
		# matching routes in more recent journeys.
		#
		# Note that journey->{route} is serialized JSON (i.e., a string).
		# It is not deserialized for performance reasons.
		$journey->{route}
		  =~ s/ (?<! additional ) (?<! cancelled ) "] /", {}, null]/gx;

		my $ref = $db->select(
			'journeys',
			[ 'id', 'polyline_id' ],
			{
				route       => $journey->{route},
				polyline_id => { '!=', undef },
				edited      => 0,
			},
			{ limit => 1 }
		)->hash;
		if ($ref) {
			my $rows = $db->update(
				'journeys',
				{ polyline_id => $ref->{polyline_id} },
				{ id          => $journey->{id} }
			)->rows;
			if ( $rows != 1 ) {
				say STDERR
"Database update returned $rows rows, expected 1. Rollback and abort.";
				exit(1);
			}
		}
		else {
			while ( my ( $old_name, $new_name )
				= each %{ $self->app->renamed_station } )
			{
				$journey->{route} =~ s{"\Q$old_name\E"}{"$new_name"};
			}
			my $ref = $db->select(
				'journeys',
				[ 'id', 'polyline_id' ],
				{
					route       => $journey->{route},
					polyline_id => { '!=', undef },
					edited      => 0,
				},
				{ limit => 1 }
			)->hash;
			if ($ref) {
				my $rows = $db->update(
					'journeys',
					{ polyline_id => $ref->{polyline_id} },
					{ id          => $journey->{id} }
				)->rows;
				if ( $rows != 1 ) {
					say STDERR
"Database update returned $rows rows, expected 1. Rollback and abort.";
					exit(1);
				}
			}
		}
	}

	my $remaining
	  = $db->select( 'journeys', 'count(*) as count', { polyline_id => undef } )
	  ->hash;
	say "Done! Remaining journeys without polyline: " . $remaining->{count};

	$tx->commit;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl maintenance

  Prunes unverified users.
