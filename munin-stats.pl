#!/usr/bin/env perl

use strict;
use warnings;
use 5.020;

use DateTime;
use DBI;

sub query_to_munin {
	my ( $label, $query, @args ) = @_;

	$query->execute(@args);
	my $rows = $query->fetchall_arrayref;
	if ( @{$rows} ) {
		printf( "%s.value %d\n", $label, $rows->[0][0] );
	}
}

my $dbname = $ENV{TRAVELYNX_DB_FILE} // 'travelynx.sqlite';
my $dbh = DBI->connect( "dbi:SQLite:dbname=${dbname}", q{}, q{} );

my $now = DateTime->now( time_zone => 'Europe/Berlin' );

my $checkin_window_query
  = $dbh->prepare(
qq{select count(*) from user_actions where action_id = 1 and action_time > ?;}
  );

query_to_munin( 'reg_user_count',
	$dbh->prepare(qq{select count(*) from users where status = 1;}) );
query_to_munin( 'checkins_24h', $checkin_window_query,
	$now->subtract( hours => 24 )->epoch );
query_to_munin( 'checkins_7d', $checkin_window_query,
	$now->subtract( days => 7 )->epoch );

$dbh->disconnect;
