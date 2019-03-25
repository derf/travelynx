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

	my $get_unverified_query
	  = $dbh->prepare(
qq{select email, extract(epoch from registered_at) from users where status = 0 and registered_at < to_timestamp(?);}
	  );
	my $get_pending_query
	  = $dbh->prepare(qq{select num_tries from pending_mails where email = ?;});
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

	$dbh->disconnect;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl maintenance

  Prunes unverified users.
