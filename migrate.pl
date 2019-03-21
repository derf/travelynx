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
				(?, ?, ?, ?, ?, ?);
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

	# v1 -> v2
	sub {
		$dbh->begin_work;
		$dbh->do(
			qq{
			update schema_version set version = 2;
		}
		);
		$dbh->do(
			qq{
			create table new_users (
				id integer primary key,
				name char(64) not null unique,
				status int not null,
				public_level int not null,
				email char(256),
				token char(80),
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

		# At this point, some "users" fields were never used -> skip those
		# during migration.
		my $add_user_query = $dbh->prepare(
			qq{
			insert into new_users
				(id, name, status, public_level, registered_at, last_login)
				values
				(?, ?, ?, ?, ?, ?);
		}
		);

		$get_users_query->execute;

		while ( my @row = $get_users_query->fetchrow_array ) {
			my (
				$id,        $name,       $status,
				$is_public, $email,      $password,
				$reg_at,    $last_login, $del_requested
			) = @row;
			$add_user_query->execute( $id, $name, $status, $is_public, $reg_at,
				$last_login );
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
		$dbh->do(
			qq{
			create table pending_mails (
				email char(256) not null primary key,
				num_tries int not null,
				last_try datetime not null
			);
		}
		);
		$dbh->commit;
	},

	# v2 -> v3
	sub {
		$dbh->begin_work;
		$dbh->do(
			qq{
			update schema_version set version = 3;
		}
		);
		$dbh->do(
			qq{
			create table tokens (
				user_id integer not null,
				type integer not null,
				token char(80) not null,
				primary key (user_id, type)
			);
		}
		);
		$dbh->commit;
	},

	# v3 -> v4
	sub {
		$dbh->begin_work;
		$dbh->do(
			qq{
			update schema_version set version = 4;
		}
		);
		$dbh->do(
			qq{
			create table monthly_stats (
				user_id integer not null,
				year int not null,
				month int not null,
				km_route int not null,
				km_beeline int not null,
				min_travel_sched int not null,
				min_travel_real int not null,
				min_change_sched int not null,
				min_change_real int not null,
				num_cancelled int not null,
				num_trains int not null,
				num_journeys int not null,
				primary key (user_id, year, month)
			);
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
