package Travelynx::Command::maintenance;
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Prune unverified users etc';

has usage => sub { shift->extract_usage };

sub run {
	my ( $self, $filename ) = @_;

	my $dbh = $self->app->dbh;

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );
	my $verification_deadline = $now->subtract( hours => 48 )->epoch;
	my $deletion_deadline     = $now->subtract( hours => 72 )->epoch;

	my $get_unverified_query
	  = $dbh->prepare(
qq{select email, extract(epoch from registered_at) from users where status = 0 and registered_at < to_timestamp(?);}
	  );
	my $get_pending_query
	  = $dbh->prepare(qq{select num_tries from pending_mails where email = ?;});
	my $get_deleted_query = $dbh->prepare(
		qq{select id from users where deletion_requested < to_timestamp(?);});
	my $set_pending_query
	  = $dbh->prepare(
qq{update pending_mails set num_tries = ?, last_try = to_timestamp(?) where email = ?;}
	  );
	my $add_pending_query
	  = $dbh->prepare(
qq{insert into pending_mails (email, num_tries, last_try) values (?, ?, to_timestamp(?));}
	  );
	my $drop_unverified_query
	  = $dbh->prepare(
qq{delete from users where status = 0 and registered_at < to_timestamp(?);}
	  );
	my $drop_tokens_query
	  = $dbh->prepare(qq{delete from tokens where user_id = ?;});
	my $drop_stats_query
	  = $dbh->prepare(qq{delete from journey_stats where user_id = ?;});
	my $drop_actions_query
	  = $dbh->prepare(qq{delete from user_actions where user_id = ?;});
	my $drop_user_query = $dbh->prepare(qq{delete from users where id = ?;});

	$dbh->begin_work;
	$get_unverified_query->execute($verification_deadline);
	while ( my @row = $get_unverified_query->fetchrow_array ) {
		my ( $mail, $reg_date ) = @row;

		if ($mail) {
			$get_pending_query->execute($mail);
			my $rows = $get_pending_query->fetchall_arrayref;

			if ( @{$rows} ) {
				my $num_tries = $rows->[0][0];
				$set_pending_query->execute( $num_tries + 1, $reg_date, $mail );
			}
			else {
				$add_pending_query->execute( $mail, 1, $reg_date );
			}
		}
	}
	$drop_unverified_query->execute($verification_deadline);
	printf( "Pruned %d unverified accounts from database\n",
		$drop_unverified_query->rows );
	$dbh->commit;

	$dbh->begin_work;
	$get_deleted_query->execute($deletion_deadline);
	my @uids_to_delete
	  = map { $_->[0] } @{ $get_deleted_query->fetchall_arrayref };

	if ( @uids_to_delete < 10 ) {
		for my $uid (@uids_to_delete) {
			say "Deleting uid ${uid}...";
			$drop_tokens_query->execute($uid);
			$drop_stats_query->execute($uid);
			$drop_actions_query->execute($uid);
			$drop_user_query->execute($uid);
			printf( "    %d tokens, %d monthly stats, %d actions\n",
				$drop_tokens_query->rows, $drop_stats_query->rows,
				$drop_actions_query->rows );
		}
	}
	else {
		printf(
			"Unusually high number of deletion requests (%d accounts)"
			  . " -- skipping automatic deletion, please investigate\n",
			scalar @uids_to_delete
		);
	}
	$dbh->commit;

	$dbh->disconnect;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl maintenance

  Prunes unverified users.
