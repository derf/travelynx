package Travelynx::Command::database;
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Initialize or upgrade database layout';

has usage => sub { shift->extract_usage };

sub get_schema_version {
	my ($db) = @_;
	my $version;

	eval {
		$version
		  = $db->select( 'schema_version', ['version'] )->hash->{version};
	};
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
);

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

sub migrate_db {
	my ($db) = @_;
	my $tx = $db->begin;

	my $schema_version = get_schema_version($db);
	say "Found travelynx schema v${schema_version}";

	if ( $schema_version == @migrations ) {
		say "Database layout is up-to-date";
	}

	eval {
		for my $i ( $schema_version .. $#migrations ) {
			printf( "Updating to v%d ...\n", $i + 1 );
			$migrations[$i]($db);
		}
	};
	if ($@) {
		say STDERR "Migration failed: $@";
		say STDERR "Rolling back to v${schema_version}";
		exit(1);
	}

	if ( get_schema_version($db) == @migrations ) {
		$tx->commit;
	}
	else {
		printf STDERR (
			"Database schema mismatch after migrations: Expected %d, got %d\n",
			scalar @migrations,
			get_schema_version($db)
		);
		say STDERR "Rolling back to v${schema_version}";
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
		migrate_db($db);
	}
	elsif ( $command eq 'has-current-schema' ) {
		if ( get_schema_version($db) == @migrations ) {
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
  > perl index.pl migrate
  > systemctl start travelynx
