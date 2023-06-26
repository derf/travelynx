package Travelynx::Command::database;

# Copyright (C) 2020-2023 Birthe Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';

use DateTime;
use File::Slurp qw(read_file);
use JSON;
use Travel::Status::DE::IRIS::Stations;

has description => 'Initialize or upgrade database layout';

has usage => sub { shift->extract_usage };

sub get_schema_version {
	my ( $db, $key ) = @_;
	my $version;

	$key //= 'version';

	eval { $version = $db->select( 'schema_version', [$key] )->hash->{$key}; };
	if ($@) {

		# If it failed, the version table does not exist -> run setup first.
		return undef;
	}
	return $version;
}

sub initialize_db {
	my ($db) = @_;
	$db->query(
		qq{
			create table schema_version (
				version integer primary key
			);
			create table users (
				id serial not null primary key,
				name varchar(64) not null unique,
				status smallint not null,
				public_level smallint not null,
				email varchar(256),
				token varchar(80),
				password text,
				registered_at timestamptz not null,
				last_login timestamptz not null,
				deletion_requested timestamptz
			);
			create table stations (
				id serial not null primary key,
				ds100 varchar(16) not null unique,
				name varchar(64) not null unique
			);
			create table user_actions (
				id serial not null primary key,
				user_id integer not null references users (id),
				action_id smallint not null,
				station_id int references stations (id),
				action_time timestamptz not null,
				train_type varchar(16),
				train_line varchar(16),
				train_no varchar(16),
				train_id varchar(128),
				sched_time timestamptz,
				real_time timestamptz,
				route text,
				messages text
			);
			create table pending_mails (
				email varchar(256) not null primary key,
				num_tries smallint not null,
				last_try timestamptz not null
			);
			create table tokens (
				user_id integer not null references users (id),
				type smallint not null,
				token varchar(80) not null,
				primary key (user_id, type)
			);
			insert into schema_version values (0);
		}
	);
}

my @migrations = (

	# v0 -> v1
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table user_actions
					add column edited smallint;
				drop table if exists monthly_stats;
				create table journey_stats (
					user_id integer not null references users (id),
					year smallint not null,
					month smallint not null,
					data jsonb not null,
					primary key (user_id, year, month)
				);
				update schema_version set version = 1;
			}
		);
	},

	# v1 -> v2
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				update user_actions set edited = 0;
				alter table user_actions
					alter column edited set not null;
				update schema_version set version = 2;
			}
		);
	},

	# v2 -> v3
	# A bug in the journey distance calculation caused excessive distances to be
	# reported for routes covering stations without GPS coordinates. Ensure
	# all caches are rebuilt.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				truncate journey_stats;
				update schema_version set version = 3;
			}
		);
	},

	# v3 -> v4
	# Introduces "journeys", containing one row for each complete
	# journey, and "in_transit", containing the journey which is currently
	# in progress (if any). "user_actions" is no longer used, but still kept
	# as a backup for now.
	sub {
		my ($db) = @_;

		$db->query(
			qq{
				create table journeys (
					id serial not null primary key,
					user_id integer not null references users (id),
					train_type varchar(16) not null,
					train_line varchar(16),
					train_no varchar(16) not null,
					train_id varchar(128) not null,
					checkin_station_id integer not null references stations (id),
					checkin_time timestamptz not null,
					sched_departure timestamptz not null,
					real_departure timestamptz not null,
					checkout_station_id integer not null references stations (id),
					checkout_time timestamptz not null,
					sched_arrival timestamptz,
					real_arrival timestamptz,
					cancelled boolean not null,
					edited smallint not null,
					route text,
					messages text
				);
				create table in_transit (
					user_id integer not null references users (id) primary key,
					train_type varchar(16) not null,
					train_line varchar(16),
					train_no varchar(16) not null,
					train_id varchar(128) not null,
					checkin_station_id integer not null references stations (id),
					checkin_time timestamptz not null,
					sched_departure timestamptz not null,
					real_departure timestamptz not null,
					checkout_station_id int references stations (id),
					checkout_time timestamptz,
					sched_arrival timestamptz,
					real_arrival timestamptz,
					cancelled boolean not null,
					route text,
					messages text
				);
				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, edited, route, messages
					from journeys
					join stations as dep_stations on dep_stations.id = checkin_station_id
					join stations as arr_stations on arr_stations.id = checkout_station_id
					;
				create view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, route, messages
					from in_transit
					join stations as dep_stations on dep_stations.id = checkin_station_id
					left join stations as arr_stations on arr_stations.id = checkout_station_id
					;
			}
		);

		my @uids
		  = $db->select( 'users', ['id'] )->hashes->map( sub { shift->{id} } )
		  ->each;
		my $count = 0;

		for my $uid (@uids) {
			my %cache;
			my $prev_action_type = 0;
			my $actions          = $db->select(
				'user_actions', '*',
				{ user_id  => $uid },
				{ order_by => { -asc => 'id' } }
			);
			for my $action ( $actions->hashes->each ) {
				my $action_type = $action->{action_id};
				my $id          = $action->{id};

				if ( $action_type == 2 and $prev_action_type != 1 ) {
					die(
"Inconsistent data at uid ${uid} action ${id}: Illegal transition $prev_action_type -> $action_type.\n"
					);
				}

				if ( $action_type == 5 and $prev_action_type != 4 ) {
					die(
"Inconsistent data at uid ${uid} action ${id}: Illegal transition $prev_action_type -> $action_type.\n"
					);
				}

				if ( $action_type == 1 or $action_type == 4 ) {
					%cache = (
						train_type         => $action->{train_type},
						train_line         => $action->{train_line},
						train_no           => $action->{train_no},
						train_id           => $action->{train_id},
						checkin_station_id => $action->{station_id},
						checkin_time       => $action->{action_time},
						sched_departure    => $action->{sched_time},
						real_departure     => $action->{real_time},
						route              => $action->{route},
						messages           => $action->{messages},
						cancelled          => $action->{action_id} == 4 ? 1 : 0,
						edited             => $action->{edited},
					);
				}
				elsif ( $action_type == 2 or $action_type == 5 ) {
					$cache{checkout_station_id} = $action->{station_id};
					$cache{checkout_time}       = $action->{action_time};
					$cache{sched_arrival}       = $action->{sched_time};
					$cache{real_arrival}        = $action->{real_time};
					$cache{edited} |= $action->{edited} << 8;
					if ( $action->{route} ) {
						$cache{route} = $action->{route};
					}
					if ( $action->{messages} ) {
						$cache{messages} = $action->{messages};
					}

					$db->insert(
						'journeys',
						{
							user_id             => $uid,
							train_type          => $cache{train_type},
							train_line          => $cache{train_line},
							train_no            => $cache{train_no},
							train_id            => $cache{train_id},
							checkin_station_id  => $cache{checkin_station_id},
							checkin_time        => $cache{checkin_time},
							sched_departure     => $cache{sched_departure},
							real_departure      => $cache{real_departure},
							checkout_station_id => $cache{checkout_station_id},
							checkout_time       => $cache{checkout_time},
							sched_arrival       => $cache{sched_arrival},
							real_arrival        => $cache{real_arrival},
							cancelled           => $cache{cancelled},
							edited              => $cache{edited},
							route               => $cache{route},
							messages            => $cache{messages}
						}
					);

					%cache = ();

				}

				$prev_action_type = $action_type;
			}

			if (%cache) {

				# user is currently in transit
				$db->insert(
					'in_transit',
					{
						user_id            => $uid,
						train_type         => $cache{train_type},
						train_line         => $cache{train_line},
						train_no           => $cache{train_no},
						train_id           => $cache{train_id},
						checkin_station_id => $cache{checkin_station_id},
						checkin_time       => $cache{checkin_time},
						sched_departure    => $cache{sched_departure},
						real_departure     => $cache{real_departure},
						cancelled          => $cache{cancelled},
						route              => $cache{route},
						messages           => $cache{messages}
					}
				);
			}

			$count++;
			printf( "    journey storage migration: %3.0f%% complete\n",
				$count * 100 / @uids );
		}
		$db->update( 'schema_version', { version => 4 } );
	},

	# v4 -> v5
	# Handle inconsistent data (overlapping journeys) in statistics. Introduces
	# the "inconsistencies" stats key -> rebuild all stats.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				truncate journey_stats;
				update schema_version set version = 5;
			}
		);
	},

	# v5 -> v6
	# Add documentation
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				comment on table in_transit is 'Users who are currently checked into a train';
				comment on view in_transit_str is 'in_transit with station IDs resolved to name/ds100';
				comment on table journey_stats is 'Cache for yearly and monthly statistics in JSON format';
				comment on table journeys is 'Past train trips (i.e. the user has already checked out)';
				comment on view journeys_str is 'journeys with station IDs resolved to name/ds100';
				comment on table pending_mails is 'Blacklist for mail addresses used in an unsuccessful registration attempt. Helps ensure that travelynx does not spam individual mails with registration attempts.';
				comment on table stations is 'Map of station IDs to name and DS100 code';
				comment on table tokens is 'User API tokens';
				comment on column in_transit.route is 'Format: station1|station2|station3|...';
				comment on column in_transit.messages is 'Format: epoch:message1|epoch:message2|...';
				comment on column in_transit_str.route is 'Format: station1|station2|station3|...';
				comment on column in_transit_str.messages is 'Format: epoch:message1|epoch:message2|...';
				comment on column journeys.edited is 'Bit mask indicating which part has been entered manually. 0x0001 = sched departure, 0x0002 = real departure, 0x0100 = sched arrival, 0x0200 = real arrival';
				comment on column journeys.route is 'Format: station1|station2|station3|...';
				comment on column journeys.messages is 'Format: epoch:message1|epoch:message2|...';
				comment on column journeys_str.edited is 'Bit mask indicating which part has been entered manually. 0x0001 = sched departure, 0x0002 = real departure, 0x0100 = sched arrival, 0x0200 = real arrival';
				comment on column journeys_str.route is 'Format: station1|station2|station3|...';
				comment on column journeys_str.messages is 'Format: epoch:message1|epoch:message2|...';
				comment on column users.status is 'Bit mask: 0x01 = verified';
				comment on column users.public_level is 'Bit mask indicating public account parts. 0x01 = current status (checkin from/to or last checkout at)';
				comment on column users.token is 'Used for e-mail verification';
				comment on column users.deletion_requested is 'Time at which account deletion was requested';
				update schema_version set version = 6;
			}
		);
	},

	# v6 -> v7
	# Add pending_passwords table to store data about pending password resets
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				create table pending_passwords (
					user_id integer not null references users (id) primary key,
					token varchar(80) not null,
					requested_at timestamptz not null
				);
				comment on table pending_passwords is 'Password reset tokens';
				update schema_version set version = 7;
			}
		);
	},

	# v7 -> v8
	# Add pending_mails table to store data about pending mail changes
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table pending_mails rename to mail_blacklist;
				create table pending_mails (
					user_id integer not null references users (id) primary key,
					email varchar(256) not null,
					token varchar(80) not null,
					requested_at timestamptz not null
				);
				comment on table pending_mails is 'Verification tokens for mail address changes';
				update schema_version set version = 8;
			}
		);
	},

	# v8 -> v9
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table users rename column last_login to last_seen;
				drop table user_actions;
				update schema_version set version = 9;
			}
		);
	},

	# v9 -> v10
	# Add pending_registrations table. The users.token column is no longer
	# needed.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				create table pending_registrations (
					user_id integer not null references users (id) primary key,
					token varchar(80) not null
				);
				comment on table pending_registrations is 'Verification tokens for newly registered accounts';
				update schema_version set version = 10;
			}
		);
		my $res = $db->select( 'users', [ 'id', 'token' ], { status => 0 } );
		for my $user ( $res->hashes->each ) {
			$db->insert(
				'pending_registrations',
				{
					user_id => $user->{id},
					token   => $user->{token}
				}
			);
		}
		$db->query(
			qq{
				alter table users drop column token;
			}
		);
	},

	# v10 -> v11
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				create table webhooks (
					user_id integer not null references users (id) primary key,
					enabled boolean not null,
					url varchar(1000) not null,
					token varchar(250),
					errored boolean,
					latest_run timestamptz,
					output text
				);
				comment on table webhooks is 'URLs and bearer tokens for push events';
				create view webhooks_str as select
					user_id, enabled, url, token, errored, output,
					extract(epoch from latest_run) as latest_run_ts
					from webhooks
				;
				update schema_version set version = 11;
			}
		);
	},

	# v11 -> v12
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table journeys
					add column dep_platform varchar(16),
					add column arr_platform varchar(16);
				alter table in_transit
					add column dep_platform varchar(16),
					add column arr_platform varchar(16);
				create or replace view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, edited, route, messages,
					dep_platform, arr_platform
					from journeys
					join stations as dep_stations on dep_stations.id = checkin_station_id
					join stations as arr_stations on arr_stations.id = checkout_station_id
					;
				create or replace view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, route, messages,
					dep_platform, arr_platform
					from in_transit
					join stations as dep_stations on dep_stations.id = checkin_station_id
					left join stations as arr_stations on arr_stations.id = checkout_station_id
					;
				update schema_version set version = 12;
			}
		);
	},

	# v12 -> v13
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table users add column use_history smallint default 255;
				update schema_version set version = 13;
			}
		);
	},

	# v13 -> v14
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table journeys add column route_new jsonb,
					add column messages_new jsonb;
				alter table in_transit add column route_new jsonb,
					add column messages_new jsonb;
			}
		);
		my $res  = $db->select( 'journeys', [ 'id', 'messages', 'route' ] );
		my $json = JSON->new;

		for my $journey ( $res->hashes->each ) {
			my $id = $journey->{id};
			my @messages;
			for my $message ( split( qr{[|]}, $journey->{messages} // '' ) ) {
				my ( $ts, $msg ) = split( qr{:}, $message );
				push( @messages, [ $ts, $msg ] );
			}
			my @route = map { [$_] }
			  split( qr{[|]}, $journey->{route} // '' );

			$db->update(
				'journeys',
				{
					messages_new => $json->encode( [@messages] ),
					route_new    => $json->encode( [@route] ),
				},
				{ id => $id }
			);
		}

		$res = $db->select( 'in_transit', [ 'user_id', 'messages', 'route' ] );
		for my $journey ( $res->hashes->each ) {
			my $id = $journey->{user_id};
			my @messages;
			for my $message ( split( qr{[|]}, $journey->{messages} // '' ) ) {
				my ( $ts, $msg ) = split( qr{:}, $message );
				push( @messages, [ $ts, $msg ] );
			}
			my @route = map { [$_] }
			  split( qr{[|]}, $journey->{route} // '' );

			$db->update(
				'in_transit',
				{
					messages_new => $json->encode( [@messages] ),
					route_new    => $json->encode( [@route] ),
				},
				{ user_id => $id }
			);
		}

		$db->query(
			qq{
				drop view journeys_str;
				alter table journeys drop column messages;
				alter table journeys drop column route;
				alter table journeys rename column messages_new to messages;
				alter table journeys rename column route_new to route;

				drop view in_transit_str;
				alter table in_transit drop column messages;
				alter table in_transit drop column route;
				alter table in_transit rename column messages_new to messages;
				alter table in_transit rename column route_new to route;

				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, edited, route, messages,
					dep_platform, arr_platform
					from journeys
					join stations as dep_stations on dep_stations.id = checkin_station_id
					join stations as arr_stations on arr_stations.id = checkout_station_id
					;
				create view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, route, messages,
					dep_platform, arr_platform
					from in_transit
					join stations as dep_stations on dep_stations.id = checkin_station_id
					left join stations as arr_stations on arr_stations.id = checkout_station_id
					;

				update schema_version set version = 14;
			}
		);
	},

	# v14 -> v15
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table in_transit add column data jsonb;
				create or replace view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, route, messages,
					dep_platform, arr_platform, data
					from in_transit
					join stations as dep_stations on dep_stations.id = checkin_station_id
					left join stations as arr_stations on arr_stations.id = checkout_station_id
					;
				update schema_version set version = 15;
			}
		);
	},

	# v15 -> v16
	# Beeline distance calculation now also works when departure or arrival
	# station do not have geo-coordinates (by resorting to the first/last
	# station in the route which does have geo-coordinates). Previously,
	# beeline distances were reported as zero in this case. Clear caches
	# to recalculate total distances per year / month.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				truncate journey_stats;
				update schema_version set version = 16;
			}
		);
	},

	# v16 -> v17
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				drop view journeys_str;
				drop view in_transit_str;
				alter table journeys add column user_data jsonb;
				alter table in_transit add column user_data jsonb;
				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, edited, route, messages, user_data,
					dep_platform, arr_platform
					from journeys
					join stations as dep_stations on dep_stations.id = checkin_station_id
					join stations as arr_stations on arr_stations.id = checkout_station_id
					;
				create view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform
					from in_transit
					join stations as dep_stations on dep_stations.id = checkin_station_id
					left join stations as arr_stations on arr_stations.id = checkout_station_id
					;
			}
		);
		for my $journey ( $db->select( 'journeys', [ 'id', 'messages' ] )
			->expand->hashes->each )
		{
			if (    $journey->{messages}
				and @{ $journey->{messages} }
				and $journey->{messages}[0][0] == 0 )
			{
				my $comment = $journey->{messages}[0][1];
				$db->update(
					'journeys',
					{
						user_data =>
						  JSON->new->encode( { comment => $comment } ),
						messages => undef
					},
					{ id => $journey->{id} }
				);
			}
		}
		$db->query(
			qq{
				update schema_version set version = 17;
			}
		);
	},

	# v17 -> v18
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				create or replace view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					dep_stations.ds100 as dep_ds100,
					dep_stations.name as dep_name,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					arr_stations.ds100 as arr_ds100,
					arr_stations.name as arr_name,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform, data
					from in_transit
					join stations as dep_stations on dep_stations.id = checkin_station_id
					left join stations as arr_stations on arr_stations.id = checkout_station_id
					;
				update schema_version set version = 18;
			}
		);
	},

	# v18 -> v19
	sub {
		my ($db) = @_;
		say
'Transitioning from travelynx station ID to EVA IDs, this may take a while ...';
		$db->query(
			qq{
				alter table in_transit drop constraint in_transit_checkin_station_id_fkey;
				alter table in_transit drop constraint in_transit_checkout_station_id_fkey;
				alter table journeys drop constraint journeys_checkin_station_id_fkey;
				alter table journeys drop constraint journeys_checkout_station_id_fkey;
			}
		);
		for my $journey ( $db->select( 'in_transit_str', '*' )->hashes->each ) {
			my ($s_dep)
			  = Travel::Status::DE::IRIS::Stations::get_station(
				$journey->{dep_ds100} );
			if ( $s_dep->[1] ne $journey->{dep_name} ) {
				die(
"$s_dep->[0] name mismatch: $s_dep->[1] vs. $journey->{dep_name}"
				);
			}
			my $rows = $db->update(
				'in_transit',
				{ checkin_station_id => $s_dep->[2] },
				{ user_id            => $journey->{user_id} }
			)->rows;
			if ( $rows != 1 ) {
				die(
"Update error at in_transit checkin_station_id UID $journey->{user_id}\n"
				);
			}
			if ( $journey->{arr_ds100} ) {
				my ($s_arr)
				  = Travel::Status::DE::IRIS::Stations::get_station(
					$journey->{arr_ds100} );
				if ( $s_arr->[1] ne $journey->{arr_name} ) {
					die(
"$s_arr->[0] name mismatch: $s_arr->[1] vs. $journey->{arr_name}"
					);
				}
				my $rows = $db->update(
					'in_transit',
					{ checkout_station_id => $s_arr->[2] },
					{ user_id             => $journey->{user_id} }
				)->rows;
				if ( $rows != 1 ) {
					die(
"Update error at in_transit checkout_station_id UID $journey->{user_id}\n"
					);
				}
			}
		}
		for my $journey ( $db->select( 'journeys_str', '*' )->hashes->each ) {
			my ($s_dep)
			  = Travel::Status::DE::IRIS::Stations::get_station(
				$journey->{dep_ds100} );
			my ($s_arr)
			  = Travel::Status::DE::IRIS::Stations::get_station(
				$journey->{arr_ds100} );
			if ( $s_dep->[1] ne $journey->{dep_name} ) {
				die(
"$s_dep->[0] name mismatch: $s_dep->[1] vs. $journey->{dep_name}"
				);
			}
			my $rows = $db->update(
				'journeys',
				{ checkin_station_id => $s_dep->[2] },
				{ id                 => $journey->{journey_id} }
			)->rows;
			if ( $rows != 1 ) {
				die(
"While updating journeys#checkin_station_id for journey $journey->{id}: got $rows rows, expected 1\n"
				);
			}
			if ( $s_arr->[1] ne $journey->{arr_name} ) {
				die(
"$s_arr->[0] name mismatch: $s_arr->[1] vs. $journey->{arr_name}"
				);
			}
			$rows = $db->update(
				'journeys',
				{ checkout_station_id => $s_arr->[2] },
				{ id                  => $journey->{journey_id} }
			)->rows;
			if ( $rows != 1 ) {
				die(
"While updating journeys#checkout_station_id for journey $journey->{id}: got $rows rows, expected 1\n"
				);
			}
		}
		$db->query(
			qq{
				drop view journeys_str;
				drop view in_transit_str;
				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					cancelled, edited, route, messages, user_data,
					dep_platform, arr_platform
					from journeys
					;
				create or replace view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform, data
					from in_transit
					;
				drop table stations;
				update schema_version set version = 19;
			}
		);
	},

	# v19 -> v20
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				create table polylines (
					id serial not null primary key,
					origin_eva integer not null,
					destination_eva integer not null,
					polyline jsonb not null
				);
				alter table journeys
					add column polyline_id integer references polylines (id);
				alter table in_transit
					add column polyline_id integer references polylines (id);
				drop view journeys_str;
				drop view in_transit_str;
				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					polylines.polyline as polyline,
					cancelled, edited, route, messages, user_data,
					dep_platform, arr_platform
					from journeys
					left join polylines on polylines.id = polyline_id
					;
				create or replace view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					polylines.polyline as polyline,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform, data
					from in_transit
					left join polylines on polylines.id = polyline_id
					;
				update schema_version set version = 20;
			}
		);
	},

	# v20 -> v21
	# After introducing polyline support, journey distance calculation diverged:
	# the detail view (individual train) used the polyline, whereas monthly and
	# yearly statistics were still based on beeline between intermediate stops.
	# Release 1.16.0 fixes this -> ensure all caches are rebuilt.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				truncate journey_stats;
				update schema_version set version = 21;
			}
		);
	},

	# v21 -> v22
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				create table traewelling (
					user_id integer not null references users (id) primary key,
					email varchar(256) not null,
					push_sync boolean not null,
					pull_sync boolean not null,
					errored boolean,
					token text,
					data jsonb,
					latest_run timestamptz
				);
				comment on table traewelling is 'Token and Status for Traewelling';
				create view traewelling_str as select
					user_id, email, push_sync, pull_sync, errored, token, data,
					extract(epoch from latest_run) as latest_run_ts
					from traewelling
				;
				update schema_version set version = 22;
			}
		);
	},

	# v22 -> v23
	# 1.18.1 fixes handling of negative cumulative arrival/departure delays
	# and introduces additional statistics entries with pre-formatted duration
	# strings while at it. Old cache entries lack those.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				truncate journey_stats;
				update schema_version set version = 23;
			}
		);
	},

	# v23 -> v24
	# travelynx 1.22 warns about upcoming account deletion due to inactivity
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table users add column deletion_notified timestamptz;
				comment on column users.deletion_notified is 'Time at which warning about upcoming account deletion due to inactivity was sent';
				update schema_version set version = 24;
			}
		);
	},

	# v24 -> v25
	# travelynx 1.23 adds optional links to external services, e.g.
	# DBF or bahn.expert departure boards
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table users add column external_services smallint;
				comment on column users.external_services is 'Which external service to use for stationboard or routing links';
				update schema_version set version = 25;
			}
		);
	},

	# v25 -> v26
	# travelynx 1.24 adds local transit connections and needs to know targets
	# for that to work, as local transit does not support checkins yet.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				create table localtransit (
					user_id integer not null references users (id) primary key,
					data jsonb
				);
				create view user_transit as select
					id,
					use_history,
					localtransit.data as data
					from users
					left join localtransit on localtransit.user_id = id
				;
				update schema_version set version = 26;
			}
		);
	},

	# v26 -> v27
	# add list of stations that are not (or no longer) present in T-S-DE-IRIS
	# (in this case, stations that were removed up to 1.74)
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table schema_version
					add column iris varchar(12);
				create table stations (
					eva int not null primary key,
					ds100 varchar(16) not null,
					name varchar(64) not null,
					lat real not null,
					lon real not null,
					source smallint not null,
					archived bool not null
				);
				update schema_version set version = 27;
				update schema_version set iris = '0';
			}
		);
	},

# v27 -> v28
# add ds100, name, and lat/lon from stations table to journeys_str / in_transit_str
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				drop view journeys_str;
				drop view in_transit_str;
				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					dep_station.ds100 as dep_ds100,
					dep_station.name as dep_name,
					dep_station.lat as dep_lat,
					dep_station.lon as dep_lon,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					arr_station.ds100 as arr_ds100,
					arr_station.name as arr_name,
					arr_station.lat as arr_lat,
					arr_station.lon as arr_lon,
					polylines.polyline as polyline,
					cancelled, edited, route, messages, user_data,
					dep_platform, arr_platform
					from journeys
					left join polylines on polylines.id = polyline_id
					left join stations as dep_station on checkin_station_id = dep_station.eva
					left join stations as arr_station on checkout_station_id = arr_station.eva
					;
				create view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					dep_station.ds100 as dep_ds100,
					dep_station.name as dep_name,
					dep_station.lat as dep_lat,
					dep_station.lon as dep_lon,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					arr_station.ds100 as arr_ds100,
					arr_station.name as arr_name,
					arr_station.lat as arr_lat,
					arr_station.lon as arr_lon,
					polylines.polyline as polyline,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform, data
					from in_transit
					left join polylines on polylines.id = polyline_id
					left join stations as dep_station on checkin_station_id = dep_station.eva
					left join stations as arr_station on checkout_station_id = arr_station.eva
					;
				update schema_version set version = 28;
			}
		);
	},

	# v28 -> v29
	# add pre-migration travelynx version. This way, a failed migration can
	# print a helpful "git checkout" command.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table schema_version
					add column travelynx varchar(64);
				update schema_version set version = 29;
			}
		);
	},

# v29 -> v30
# change layout of stops in in_transit and journeys "route" lists.
# Old layout: A mixture of [name, {data}, undef/"additional"/"cancelled"], [name, timestamp, timestamp], and [name]
# New layout: [name, eva, {data including isAdditional/isCancelled}]
# Combined with a maintenance task that adds eva IDs to past stops, this will allow for more resilience against station name changes.
# It will also help increase the performance of distance and map calculation
	sub {
		my ($db) = @_;
		my $json = JSON->new;

		say 'Adjusting route schema, this may take a while ...';

		my $res = $db->select( 'in_transit_str', [ 'route', 'user_id' ] );
		while ( my $row = $res->expand->hash ) {
			my @new_route;
			for my $stop ( @{ $row->{route} } ) {
				push( @new_route, [ $stop->[0], undef, {} ] );
			}
			$db->update(
				'in_transit',
				{ route   => $json->encode( \@new_route ) },
				{ user_id => $row->{user_id} }
			);
		}

		my $total
		  = $db->select( 'journeys', 'count(*) as count' )->hash->{count};
		my $count = 0;

		$res = $db->select( 'journeys_str', [ 'route', 'journey_id' ] );
		while ( my $row = $res->expand->hash ) {
			my @new_route;

			for my $stop ( @{ $row->{route} } ) {
				if ( @{$stop} == 1 ) {
					push( @new_route, [ $stop->[0], undef, {} ] );
				}
				elsif (
					( not defined $stop->[1] or $stop->[1] =~ m{ ^ \d+ $ }x )
					and
					( not defined $stop->[2] or $stop->[2] =~ m{ ^ \d+ $ }x )
				  )
				{
					push( @new_route, [ $stop->[0], undef, {} ] );
				}
				else {
					my $attr = $stop->[1] // {};
					if ( $stop->[2] and $stop->[2] eq 'additional' ) {
						$attr->{isAdditional} = 1;
					}
					elsif ( $stop->[2] and $stop->[2] eq 'cancelled' ) {
						$attr->{isCancelled} = 1;
					}
					push( @new_route, [ $stop->[0], undef, $attr ] );
				}
			}

			$db->update(
				'journeys',
				{ route => $json->encode( \@new_route ) },
				{ id    => $row->{journey_id} }
			);

			if ( $count++ % 10000 == 0 ) {
				printf( "    %2.0f%% complete\n", $count * 100 / $total );
			}
		}
		say '    done';
		$db->query(
			qq{
				update schema_version set version = 30;
			}
		);
	},

	# v30 -> v31
	# travelynx v1.29.17 introduces links to conflicting journeys.
	# These require changes to statistics data.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				truncate journey_stats;
				update schema_version set version = 31;
			}
		);
	},

	# v31 -> v32
	# travelynx v1.29.18 improves above-mentioned conflict links.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				truncate journey_stats;
				update schema_version set version = 32;
			}
		);
	},

	# v32 -> v33
	# add optional per-status visibility that overrides global visibility
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table journeys add column visibility smallint;
				alter table in_transit add column visibility smallint;
				drop view journeys_str;
				drop view in_transit_str;
				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					dep_station.ds100 as dep_ds100,
					dep_station.name as dep_name,
					dep_station.lat as dep_lat,
					dep_station.lon as dep_lon,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					arr_station.ds100 as arr_ds100,
					arr_station.name as arr_name,
					arr_station.lat as arr_lat,
					arr_station.lon as arr_lon,
					polylines.polyline as polyline,
					visibility,
					cancelled, edited, route, messages, user_data,
					dep_platform, arr_platform
					from journeys
					left join polylines on polylines.id = polyline_id
					left join stations as dep_station on checkin_station_id = dep_station.eva
					left join stations as arr_station on checkout_station_id = arr_station.eva
					;
				create view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					dep_station.ds100 as dep_ds100,
					dep_station.name as dep_name,
					dep_station.lat as dep_lat,
					dep_station.lon as dep_lon,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					arr_station.ds100 as arr_ds100,
					arr_station.name as arr_name,
					arr_station.lat as arr_lat,
					arr_station.lon as arr_lon,
					polylines.polyline as polyline,
					visibility,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform, data
					from in_transit
					left join polylines on polylines.id = polyline_id
					left join stations as dep_station on checkin_station_id = dep_station.eva
					left join stations as arr_station on checkout_station_id = arr_station.eva
					;
			}
		);
		my $res = $db->select( 'users', [ 'id', 'public_level' ] );
		while ( my $row = $res->hash ) {
			my $old_level = $row->{public_level};

			# status default: unlisted
			my $new_level = 30;
			if ( $old_level & 0x01 ) {

				# status: account required
				$new_level = 80;
			}
			if ( $old_level & 0x02 ) {

				# status: public
				$new_level = 100;
			}
			if ( $old_level & 0x04 ) {

				# comment public
				$new_level |= 0x80;
			}
			if ( $old_level & 0x10 ) {

				# past: account required
				$new_level |= 0x100;
			}
			if ( $old_level & 0x20 ) {

				# past: public
				$new_level |= 0x200;
			}
			if ( $old_level & 0x40 ) {

				# past: infinite (default is 4 weeks)
				$new_level |= 0x400;
			}
			my $r = $db->update(
				'users',
				{ public_level => $new_level },
				{ id           => $row->{id} }
			)->rows;
			if ( $r != 1 ) {
				die("oh no");
			}
		}
		$db->update( 'schema_version', { version => 33 } );
	},

	# v33 -> v34
	# add polyline_id to in_transit_str
	# (https://github.com/derf/travelynx/issues/66)
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				drop view in_transit_str;
				create view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					dep_station.ds100 as dep_ds100,
					dep_station.name as dep_name,
					dep_station.lat as dep_lat,
					dep_station.lon as dep_lon,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					arr_station.ds100 as arr_ds100,
					arr_station.name as arr_name,
					arr_station.lat as arr_lat,
					arr_station.lon as arr_lon,
					polyline_id,
					polylines.polyline as polyline,
					visibility,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform, data
					from in_transit
					left join polylines on polylines.id = polyline_id
					left join stations as dep_station on checkin_station_id = dep_station.eva
					left join stations as arr_station on checkout_station_id = arr_station.eva
					;
				update schema_version set version = 34;
			}
		);
	},

	# v34 -> v35
	sub {
		my ($db) = @_;

		# 1 : follows
		# 2 : follow requested
		# 3 : is blocked by
		$db->query(
			qq{
				create table relations (
					subject_id integer not null references users (id),
					predicate smallint not null,
					object_id integer not null references users (id),
					primary key (subject_id, object_id)
				);
				create view followers as select
					relations.object_id as self_id,
					users.id as id,
					users.name as name
					from relations
					join users on relations.subject_id = users.id
					where predicate = 1;
				create view followees as select
					relations.subject_id as self_id,
					users.id as id,
					users.name as name
					from relations
					join users on relations.object_id = users.id
					where predicate = 1;
				create view follow_requests as select
					relations.object_id as self_id,
					users.id as id,
					users.name as name
					from relations
					join users on relations.subject_id = users.id
					where predicate = 2;
				create view blocked_users as select
					relations.object_id as self_id,
					users.id as id,
					users.name as name
					from relations
					join users on relations.subject_id = users.id
					where predicate = 3;
				update schema_version set version = 35;
			}
		);
	},

	# v35 -> v36
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table relations
					add column ts timestamptz not null;
				alter table users
					add column accept_follows smallint default 0;
				update schema_version set version = 36;
			}
		);
	},

	# v36 -> v37
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table users
					add column notifications smallint default 0,
					add column profile jsonb;
				update schema_version set version = 37;
			}
		);
	},

	# v37 -> v38
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				drop view followers;
				create view followers as select
					relations.object_id as self_id,
					users.id as id,
					users.name as name,
					users.accept_follows as accept_follows,
					r2.predicate as inverse_predicate
					from relations
					join users on relations.subject_id = users.id
					left join relations as r2 on relations.subject_id = r2.object_id
					where relations.predicate = 1;
				update schema_version set version = 38;
			}
		);
	},

	# v38 -> v39
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				drop view followers;
				create view followers as select
					relations.object_id as self_id,
					users.id as id,
					users.name as name,
					users.accept_follows as accept_follows,
					r2.predicate as inverse_predicate
					from relations
					join users on relations.subject_id = users.id
					left join relations as r2
					on relations.subject_id = r2.object_id
					and relations.object_id = r2.subject_id
					where relations.predicate = 1;
				update schema_version set version = 39;
			}
		);
	},

	# v39 -> v40
	# distinguish between public / travelynx / followers / private visibility
	# for the history page, just like status visibility.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				alter table users alter public_level type integer;
			}
		);
		my $res = $db->select( 'users', [ 'id', 'public_level' ] );
		while ( my $row = $res->hash ) {
			my $old_level = $row->{public_level};

			# checkin and comment visibility remain unchanged
			my $new_level = $old_level & 0x00ff;

			# past: account required
			if ( $old_level & 0x100 ) {
				$new_level |= 80 << 8;
			}

			# past: public
			elsif ( $old_level & 0x200 ) {
				$new_level |= 100 << 8;
			}

			# past: private
			else {
				$new_level |= 10 << 8;
			}

			# past: infinite (default is 4 weeks)
			if ( $old_level & 0x400 ) {
				$new_level |= 0x10000;
			}

			# show past journey on status page
			if ( $old_level & 0x800 ) {
				$new_level |= 0x8000;
			}

			my $r = $db->update(
				'users',
				{ public_level => $new_level },
				{ id           => $row->{id} }
			)->rows;
			if ( $r != 1 ) {
				die("oh no");
			}
		}
		$db->update( 'schema_version', { version => 40 } );
	},

	# v40 -> v41
	# Compute effective visibility in in_transit_str and journeys_str.
	sub {
		my ($db) = @_;
		$db->query(
			qq{
				drop view in_transit_str;
				drop view journeys_str;
				create view in_transit_str as select
					user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					dep_station.ds100 as dep_ds100,
					dep_station.name as dep_name,
					dep_station.lat as dep_lat,
					dep_station.lon as dep_lon,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					arr_station.ds100 as arr_ds100,
					arr_station.name as arr_name,
					arr_station.lat as arr_lat,
					arr_station.lon as arr_lon,
					polyline_id,
					polylines.polyline as polyline,
					visibility,
					coalesce(visibility, users.public_level & 127) as effective_visibility,
					cancelled, route, messages, user_data,
					dep_platform, arr_platform, data
					from in_transit
					left join polylines on polylines.id = polyline_id
					left join users on users.id = user_id
					left join stations as dep_station on checkin_station_id = dep_station.eva
					left join stations as arr_station on checkout_station_id = arr_station.eva
					;
				create view journeys_str as select
					journeys.id as journey_id, user_id,
					train_type, train_line, train_no, train_id,
					extract(epoch from checkin_time) as checkin_ts,
					extract(epoch from sched_departure) as sched_dep_ts,
					extract(epoch from real_departure) as real_dep_ts,
					checkin_station_id as dep_eva,
					dep_station.ds100 as dep_ds100,
					dep_station.name as dep_name,
					dep_station.lat as dep_lat,
					dep_station.lon as dep_lon,
					extract(epoch from checkout_time) as checkout_ts,
					extract(epoch from sched_arrival) as sched_arr_ts,
					extract(epoch from real_arrival) as real_arr_ts,
					checkout_station_id as arr_eva,
					arr_station.ds100 as arr_ds100,
					arr_station.name as arr_name,
					arr_station.lat as arr_lat,
					arr_station.lon as arr_lon,
					polylines.polyline as polyline,
					visibility,
					coalesce(visibility, users.public_level & 127) as effective_visibility,
					cancelled, edited, route, messages, user_data,
					dep_platform, arr_platform
					from journeys
					left join polylines on polylines.id = polyline_id
					left join users on users.id = user_id
					left join stations as dep_station on checkin_station_id = dep_station.eva
					left join stations as arr_station on checkout_station_id = arr_station.eva
					;
				update schema_version set version = 41;
			}
		);
	},
);

# TODO add 'hafas' column to in_transit (and maybe journeys? undo/redo needs something to work with...)

sub sync_stations {
	my ( $db, $iris_version ) = @_;

	$db->update( 'schema_version',
		{ iris => $Travel::Status::DE::IRIS::Stations::VERSION } );

	say 'Updating stations table, this may take a while ...';
	my $total = scalar Travel::Status::DE::IRIS::Stations::get_stations();
	my $count = 0;
	for my $s ( Travel::Status::DE::IRIS::Stations::get_stations() ) {
		my ( $ds100, $name, $eva, $lon, $lat ) = @{$s};
		if ( $ENV{__TRAVELYNX_TEST_MINI_IRIS}
			and ( $eva < 8000000 or $eva > 8000100 ) )
		{
			next;
		}
		$db->insert(
			'stations',
			{
				eva      => $eva,
				ds100    => $ds100,
				name     => $name,
				lat      => $lat,
				lon      => $lon,
				source   => 0,
				archived => 0
			},
			{
				on_conflict => \
'(eva) do update set archived = false, source = 0, ds100 = EXCLUDED.ds100, name=EXCLUDED.name, lat=EXCLUDED.lat, lon=EXCLUDED.lon'
			}
		);
		if ( $count++ % 1000 == 0 ) {
			printf( "    %2.0f%% complete\n", $count * 100 / $total );
		}
	}
	say '    done';

	my $res1 = $db->query(
		qq{
			select checkin_station_id
			from journeys
			left join stations on journeys.checkin_station_id = stations.eva
			where stations.eva is null
			limit 1;
		}
	)->hash;

	my $res2 = $db->query(
		qq{
			select checkout_station_id
			from journeys
			left join stations on journeys.checkout_station_id = stations.eva
			where stations.eva is null
			limit 1;
		}
	)->hash;

	if ( $res1 or $res2 ) {
		say 'Dropping stats cache for archived stations ...';
		$db->query('truncate journey_stats;');
	}

	say 'Updating archived stations ...';
	my $old_stations
	  = JSON->new->utf8->decode( scalar read_file('share/old_stations.json') );
	if ( $ENV{__TRAVELYNX_TEST_MINI_IRIS} ) {
		$old_stations = [];
	}
	for my $s ( @{$old_stations} ) {
		$db->insert(
			'stations',
			{
				eva      => $s->{eva},
				ds100    => $s->{ds100},
				name     => $s->{name},
				lat      => $s->{latlong}[0],
				lon      => $s->{latlong}[1],
				source   => 0,
				archived => 1
			},
			{ on_conflict => undef }
		);
	}

	if ( $iris_version == 0 ) {
		say 'Applying EVA ID changes ...';
		for my $change (
			[ 721394, 301002, 'RKBP: Kronenplatz (U), Karlsruhe' ],
			[
				721356, 901012,
				'RKME: Ettlinger Tor/Staatstheater (U), Karlsruhe'
			],
		  )
		{
			my ( $old, $new, $desc ) = @{$change};
			my $rows = $db->update(
				'journeys',
				{ checkout_station_id => $new },
				{ checkout_station_id => $old }
			)->rows;
			$rows += $db->update(
				'journeys',
				{ checkin_station_id => $new },
				{ checkin_station_id => $old }
			)->rows;
			if ($rows) {
				say "$desc ($old -> $new) : $rows rows";
			}
		}
	}

	say 'Checking for unknown EVA IDs ...';
	my $found = 0;

	$res1 = $db->query(
		qq{
			select checkin_station_id
			from journeys
			left join stations on journeys.checkin_station_id = stations.eva
			where stations.eva is null;
		}
	);

	$res2 = $db->query(
		qq{
			select checkout_station_id
			from journeys
			left join stations on journeys.checkout_station_id = stations.eva
			where stations.eva is null;
		}
	);

	my %notified;
	while ( my $row = $res1->hash ) {
		my $eva = $row->{checkin_station_id};
		if ( not $found ) {
			$found = 1;
			say '';
			say '------------8<----------';
			say 'Travel::Status::DE::IRIS v'
			  . $Travel::Status::DE::IRIS::Stations::VERSION;
		}
		if ( not $notified{$eva} ) {
			say $eva;
			$notified{$eva} = 1;
		}
	}

	while ( my $row = $res2->hash ) {
		my $eva = $row->{checkout_station_id};
		if ( not $found ) {
			$found = 1;
			say '';
			say '------------8<----------';
			say 'Travel::Status::DE::IRIS v'
			  . $Travel::Status::DE::IRIS::Stations::VERSION;
		}
		if ( not $notified{$eva} ) {
			say $eva;
			$notified{$eva} = 1;
		}
	}

	if ($found) {
		say '------------8<----------';
		say '';
		say
'Due to a conceptual flaw in past travelynx releases, your database contains unknown EVA IDs.';
		say
'Please file a bug report titled "Missing EVA IDs after DB migration" at https://github.com/derf/travelynx/issues';
		say 'and include the list shown above in the bug report.';
		say
'If you do not have a GitHub account, please send an E-Mail to derf+travelynx@finalrewind.org instead.';
		say '';
		say 'This issue does not affect usability or long-term data integrity,';
		say 'and handling it is not time-critical.';
		say
'Past journeys referencing unknown EVA IDs may have inaccurate distance statistics,';
		say
'but this will be resolved once a future release handles those EVA IDs.';
		say 'Note that this issue was already present in previous releases.';
	}
	else {
		say 'None found.';
	}
}

sub setup_db {
	my ($db) = @_;
	my $tx = $db->begin;
	eval {
		initialize_db($db);
		$tx->commit;
	};
	if ($@) {
		say "Database initialization failed: $@";
		exit(1);
	}
}

sub failure_hints {
	my ($old_version) = @_;
	say STDERR 'This travelynx instance has reached an undefined state:';
	say STDERR
'The source code is expecting a different schema version than present in the database.';
	say STDERR
'Please file a detailed bug report at <https://github.com/derf/travelynx/issues>';
	say STDERR 'or send an e-mail to derf+travelynx@finalrewind.org.';
	if ($old_version) {
		say STDERR '';
		say STDERR
		  "The last migration was performed with travelynx v${old_version}.";
		say STDERR
'You may be able to return to a working state with the following command:';
		say STDERR "git checkout ${old_version}";
		say STDERR '';
		say STDERR 'We apologize for any inconvenience.';
	}
}

sub migrate_db {
	my ( $self, $db ) = @_;
	my $tx = $db->begin;

	my $schema_version = get_schema_version($db);
	say "Found travelynx schema v${schema_version}";

	my $old_version;

	if ( $schema_version >= 29 ) {
		$old_version = get_schema_version( $db, 'travelynx' );
	}

	if ( $schema_version == @migrations ) {
		say 'Database layout is up-to-date';
	}
	else {
		eval {
			for my $i ( $schema_version .. $#migrations ) {
				printf( "Updating to v%d ...\n", $i + 1 );
				$migrations[$i]($db);
			}
			say 'Update complete.';
		};
		if ($@) {
			say STDERR "Migration failed: $@";
			say STDERR "Rolling back to v${schema_version}";
			failure_hints($old_version);
			exit(1);
		}
	}

	my $iris_version = get_schema_version( $db, 'iris' );
	say "Found IRIS station database v${iris_version}";
	if ( $iris_version eq $Travel::Status::DE::IRIS::Stations::VERSION ) {
		say 'Station database is up-to-date';
	}
	else {
		eval {
			say
"Synchronizing with Travel::Status::DE::IRIS $Travel::Status::DE::IRIS::Stations::VERSION";
			sync_stations( $db, $iris_version );
			say 'Synchronization complete.';
		};
		if ($@) {
			say STDERR "Synchronization failed: $@";
			if ( $schema_version != @migrations ) {
				say STDERR "Rolling back to v${schema_version}";
				failure_hints($old_version);
			}
			exit(1);
		}
	}

	$db->update( 'schema_version',
		{ travelynx => $self->app->config->{version} } );

	if ( get_schema_version($db) == @migrations ) {
		$tx->commit;
		say 'Changes committed to database. Have a nice day.';
	}
	else {
		printf STDERR (
			"Database schema mismatch after migrations: Expected %d, got %d\n",
			scalar @migrations,
			get_schema_version($db)
		);
		say STDERR "Rolling back to v${schema_version}";
		say STDERR "";
		failure_hints($old_version);
		exit(1);
	}
}

sub run {
	my ( $self, $command ) = @_;

	my $db = $self->app->pg->db;

	#if ( not defined $dbh ) {
	#	printf( "Can't connect to the database: %s\n", $DBI::errstr );
	#	exit(1);
	#}

	if ( $command eq 'migrate' ) {
		if ( not defined get_schema_version($db) ) {
			setup_db($db);
		}
		$self->migrate_db($db);
	}
	elsif ( $command eq 'has-current-schema' ) {
		if (    get_schema_version($db) == @migrations
			and get_schema_version( $db, 'iris' ) eq
			$Travel::Status::DE::IRIS::Stations::VERSION )
		{
			say "yes";
		}
		else {
			say "no";
			exit(1);
		}
	}
	else {
		$self->help;
	}
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl database <migrate|has-current-schema>

  Upgrades the database layout to the latest schema.

  Recommended workflow:
  > systemctl stop travelynx
  > perl index.pl database migrate
  > systemctl start travelynx
