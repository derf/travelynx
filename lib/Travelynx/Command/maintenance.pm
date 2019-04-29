package Travelynx::Command::maintenance;
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Prune unverified users etc';

has usage => sub { shift->extract_usage };

sub run {
	my ( $self, $filename ) = @_;

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );
	my $verification_deadline = $now->clone->subtract( hours => 48 );
	my $deletion_deadline     = $now->clone->subtract( hours => 72 );

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
		  = $db->select( 'pending_mails', ['num_tries'], { email => $mail } );
		my $pending_h = $pending->hash;

		if ($pending_h) {
			my $num_tries = $pending_h->{num_tries} + 1;
			$db->update(
				'pending_mails',
				{
					num_tries => $num_tries,
					last_try  => $reg_date
				},
				{ email => $mail }
			);
		}
		else {
			$db->insert(
				'pending_mails',
				{
					email     => $mail,
					num_tries => 1,
					last_try  => $reg_date
				}
			);
		}
		$db->delete( 'users', { id => $user->{id} } );
		printf( "Pruned unverified user %d\n", $user->{id} );
	}

	my $res = $db->delete( 'pending_passwords',
		{ requested_at => { '<', $verification_deadline } } );

	if ( my $rows = $res->rows ) {
		printf( "Pruned %d pending password reset(s)\n", $rows );
	}

	my $to_delete = $db->select( 'users', ['id'],
		{ deletion_requested => { '<', $deletion_deadline } } );
	my @uids_to_delete = $to_delete->arrays->map( sub { shift->[0] } )->each;

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
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl maintenance

  Prunes unverified users.
