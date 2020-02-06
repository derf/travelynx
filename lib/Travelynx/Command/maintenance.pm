package Travelynx::Command::maintenance;
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Prune unverified users, incomplete checkins etc';

has usage => sub { shift->extract_usage };

sub run {
	my ( $self, $filename ) = @_;

	my $now                   = DateTime->now( time_zone => 'Europe/Berlin' );
	my $checkin_deadline      = $now->clone->subtract( hours => 48 );
	my $verification_deadline = $now->clone->subtract( hours => 48 );
	my $deletion_deadline     = $now->clone->subtract( hours => 72 );
	my $old_deadline          = $now->clone->subtract( years => 1 );

	my $db = $self->app->pg->db;
	my $tx = $db->begin;

	my $res = $db->delete( 'in_transit',
		{ checkin_time => { '<', $checkin_deadline } } );

	if ( my $rows = $res->rows ) {
		printf( "Removed %d incomplete checkins\n", $rows );
	}

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

	$res = $db->delete( 'pending_passwords',
		{ requested_at => { '<', $verification_deadline } } );

	if ( my $rows = $res->rows ) {
		printf( "Pruned %d pending password reset(s)\n", $rows );
	}

	$res = $db->delete( 'pending_mails',
		{ requested_at => { '<', $verification_deadline } } );

	if ( my $rows = $res->rows ) {
		printf( "Pruned %d pending mail change(s)\n", $rows );
	}

	my $to_delete = $db->select( 'users', ['id'],
		{ deletion_requested => { '<', $deletion_deadline } } );
	my @uids_to_delete = $to_delete->arrays->map( sub { shift->[0] } )->each;

	$to_delete
	  = $db->select( 'users', ['id'], { last_seen => { '<', $old_deadline } } );

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
