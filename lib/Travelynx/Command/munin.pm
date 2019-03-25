package Travelynx::Command::munin;
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Generate statistics for munin-node';

has usage => sub { shift->extract_usage };

sub query_to_munin {
	my ( $label, $query, @args ) = @_;

	$query->execute(@args);
	my $rows = $query->fetchall_arrayref;
	if ( @{$rows} ) {
		printf( "%s.value %d\n", $label, $rows->[0][0] );
	}
}

sub run {
	my ($self, $filename) = @_;

	my $dbh = $self->app->dbh;

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );

	my $checkin_window_query
	= $dbh->prepare(
	qq{select count(*) from user_actions where action_id = 1 and action_time > to_timestamp(?);}
	);

	query_to_munin( 'reg_user_count',
		$dbh->prepare(qq{select count(*) from users where status = 1;}) );
	query_to_munin( 'checkins_24h', $checkin_window_query,
		$now->subtract( hours => 24 )->epoch );
	query_to_munin( 'checkins_7d', $checkin_window_query,
		$now->subtract( days => 7 )->epoch );
	query_to_munin( 'checkins_30d', $checkin_window_query,
		$now->subtract( days => 30 )->epoch );

	$dbh->disconnect;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl munin

  Write statistics for munin-node to stdout
