#!/usr/bin/env perl

use strict;
use warnings;
use 5.020;

use DateTime;
use DBI;

my $dbname = $ENV{TRAVELYNX_DB_FILE} // 'travelynx.sqlite';
my $dbh = DBI->connect( "dbi:SQLite:dbname=${dbname}", q{}, q{} );

my $has_version_query = $dbh->prepare(
	qq{
	select name from sqlite_master
	where type = 'table' and name = 'schema_version';
}
);

sub get_schema_version {
	$has_version_query->execute();
	my $rows = $has_version_query->fetchall_arrayref;
	if ( @{$rows} == 1 ) {
		my $get_version_query = $dbh->prepare(
			qq{
			select version from schema_version;
		}
		);
		$get_version_query->execute();
		my $rows = $get_version_query->fetchall_arrayref;
		if ( @{$rows} == 0 ) {
			return -1;
		}
		return $rows->[0][0];
	}
	return 0;
}

my @migrations = (

	# v0 -> v1
	sub {
		$dbh->begin_work;
		$dbh->do(
			qq{
			create table schema_version (
				version integer primary key
			);
		}
		);
		$dbh->do(
			qq{
			insert into schema_version (version) values (1);
		}
		);
		$dbh->do(
			qq{
			create table new_users (
				id integer primary key,
				name char(64) not null unique,
				status int not null,
				is_public bool not null,
				email char(256),
				password text,
				registered_at datetime not null,
				last_login datetime not null,
				deletion_requested datetime
			);
		}
		);
		my $get_users_query = $dbh->prepare(
			qq{
			select * from users;
		}
		);
		my $add_user_query = $dbh->prepare(
			qq{
			insert into new_users
				(id, name, status, is_public, registered_at, last_login)
				values
				(?, ?, ?, ?, ?, ?)
		}
		);
		$get_users_query->execute;

		while ( my @row = $get_users_query->fetchrow_array ) {
			my ( $id, $name ) = @row;
			my $now = DateTime->now( time_zone => 'Europe/Berlin' )->epoch;
			$add_user_query->execute( $id, $name, 0, 0, $now, $now );
		}
		$dbh->do(
			qq{
			drop table users;
		}
		);
		$dbh->do(
			qq{
			alter table new_users rename to users;
		}
		);
		$dbh->commit;
	},
);

my $schema_version = get_schema_version();

say "Found travelynx schema v${schema_version}";

if ( $schema_version == @migrations ) {
	say "Database schema is up-to-date";
}

for my $i ( $schema_version .. $#migrations ) {
	printf( "Updating to v%d\n", $i + 1 );
	$migrations[$i]();
}

$dbh->disconnect;
