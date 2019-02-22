#!/usr/bin/env perl

use strict;
use warnings;
use 5.020;

use DBI;

my $dbname = $ENV{TRAVELYNX_DB_FILE} // 'travelynx.sqlite';
my $dbh = DBI->connect( "dbi:SQLite:dbname=${dbname}", q{}, q{} );

my $has_version_query = $dbh->prepare(qq{
	select name from sqlite_master
	where type = 'table' and name = 'schema_version';
});

sub get_schema_version {
	$has_version_query->execute();
	my $rows = $has_version_query->fetchall_arrayref;
	if (@{$rows} == 1) {
		my $get_version_query = $dbh->prepare(qq{
			select version from schema_version;
		});
		$get_version_query->execute();
		my $rows = $get_version_query->fetchall_arrayref;
		if (@{$rows} == 0) {
			return -1;
		}
		return $rows->[0][0];
	}
	return 0;
}

my @migrations = (
	# v0 -> v1
	sub {
		$dbh->do(qq{
			begin transaction;
		});
		$dbh->do(qq{
			create table schema_version (
				version integer primary key
			);
		});
		$dbh->do(qq{
			insert into schema_version (version) values (1);
		});
		$dbh->do(qq{
			create table new_users (
				id integer primary key,
				name char(64) not null unique,
				status int not null,
				email char(256),
				password text,
				registered_at datetime,
				last_login datetime
			);
		});
		my $get_users_query = $dbh->prepare(qq{
			select * from users;
		});
		$dbh->do(qq{
			commit;
		});
	},
);

my $schema_version = get_schema_version();

say "Found travelynx schema v${schema_version}";

if ($schema_version == @migrations) {
	say "Database schema is up-to-date";
}

for my $i ($schema_version .. $#migrations) {
	printf("Updating to v%d\n", $i + 1);
	$migrations[$i]();
}
