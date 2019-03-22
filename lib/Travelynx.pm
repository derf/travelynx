package Travelynx;
use Mojo::Base 'Mojolicious';

use Mojolicious::Plugin::Authentication;
use Cache::File;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use DateTime;
use DBI;
use Encode qw(decode encode);
use Geo::Distance;
use List::Util qw(first);
use List::MoreUtils qw(after_incl before_incl);
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;

our $VERSION = qx{git describe --dirty} || 'experimental';

my $cache_iris_main = Cache::File->new(
	cache_root      => $ENV{TRAVELYNX_IRIS_CACHE} // '/tmp/dbf-iris-main',
	default_expires => '6 hours',
	lock_level      => Cache::File::LOCK_LOCAL(),
);

my $cache_iris_rt = Cache::File->new(
	cache_root      => $ENV{TRAVELYNX_IRISRT_CACHE} // '/tmp/dbf-iris-realtime',
	default_expires => '70 seconds',
	lock_level      => Cache::File::LOCK_LOCAL(),
);

sub hash_password {
	my ($password) = @_;
	my @salt_bytes = map { int( rand(255) ) + 1 } ( 1 .. 16 );
	my $salt = en_base64( pack( 'C[16]', @salt_bytes ) );

	return bcrypt( $password, '$2a$12$' . $salt );
}

sub check_password {
	my ( $password, $hash ) = @_;

	if ( bcrypt( $password, $hash ) eq $hash ) {
		return 1;
	}
	return 0;
}

sub epoch_to_dt {
	my ($epoch) = @_;

	# Bugs (and user errors) may lead to undefined timestamps. Set them to
	# 1970-01-01 to avoid crashing and show obviously wrong data instead.
	$epoch //= 0;

	return DateTime->from_epoch(
		epoch     => $epoch,
		time_zone => 'Europe/Berlin'
	);
}

sub get_station {
	my ($station_name) = @_;

	my @candidates
	  = Travel::Status::DE::IRIS::Stations::get_station($station_name);

	if ( @candidates == 1 ) {
		return $candidates[0];
	}
	return undef;
}

sub startup {
	my ($self) = @_;

	if ( $ENV{TRAVELYNX_SECRETS} ) {
		$self->secrets( [ split( qr{:}, $ENV{TRAVELYNX_SECRETS} ) ] );
	}

	push( @{ $self->commands->namespaces }, 'Travelynx::Command' );

	$self->defaults( layout => 'default' );

	$self->config(
		hypnotoad => {
			accepts  => 40,
			listen   => [ $ENV{TRAVELYNX_LISTEN} // 'http://*:8093' ],
			pid_file => '/tmp/travelynx.pid',
			workers  => $ENV{TRAVELYNX_WORKERS} // 2,
		},
	);

	$self->types->type( json => 'application/json; charset=utf-8' );

	$self->plugin(
		authentication => {
			autoload_user => 1,
			fail_render   => { template => 'login' },
			load_user     => sub {
				my ( $self, $uid ) = @_;
				return $self->get_user_data($uid);
			},
			validate_user => sub {
				my ( $self, $username, $password, $extradata ) = @_;
				my $user_info = $self->get_user_password($username);
				if ( not $user_info ) {
					return undef;
				}
				if ( $user_info->{status} != 1 ) {
					return undef;
				}
				if ( check_password( $password, $user_info->{password_hash} ) )
				{
					return $user_info->{id};
				}
				return undef;
			},
		}
	);
	$self->sessions->default_expiration( 60 * 60 * 24 * 180 );

	$self->defaults( layout => 'default' );

	$self->attr(
		action_type => sub {
			return {
				checkin        => 1,
				checkout       => 2,
				undo           => 3,
				cancelled_from => 4,
				cancelled_to   => 5,
			};
		}
	);
	$self->attr(
		action_types => sub {
			return [qw(checkin checkout undo cancelled_from cancelled_to)];
		}
	);
	$self->attr(
		token_type => sub {
			return {
				status  => 1,
				history => 2,
				action  => 3,
			};
		}
	);
	$self->attr(
		token_types => sub {
			return [qw(status history action)];
		}
	);

	$self->attr(
		add_station_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			insert into stations (ds100, name) values (?, ?)
		}
			);
		}
	);
	$self->attr(
		add_user_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			insert into users (
				name, status, public_level, email, token, password,
				registered_at, last_login
			) values (?, 0, 0, ?, ?, ?, ?, ?);
		}
			);
		}
	);
	$self->attr(
		set_email_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
				update users set email = ?, token = ? where id = ?;
			}
			);
		}
	);
	$self->attr(
		set_password_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
				update users set password = ? where id = ?;
			}
			);
		}
	);
	$self->attr(
		add_mail_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
				insert into pending_mails (
					email, num_tries, last_try
				) values (?, ?, ?);
			}
			);
		}
	);
	$self->attr(
		set_status_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
				update users set status = ? where id = ?;
			}
			);
		}
	);
	$self->attr(
		mark_for_deletion_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
				update users set deletion_requested = ? where id = ?;
			}
			);
		}
	);
	$self->attr(
		action_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			insert into user_actions (
				user_id, action_id, station_id, action_time,
				train_type, train_line, train_no, train_id,
				sched_time, real_time,
				route, messages
			) values (
				?, ?, ?, ?,
				?, ?, ?, ?,
				?, ?,
				?, ?
			)
		}
			);
		},
	);
	$self->attr(
		dbh => sub {
			my ($self) = @_;

			my $dbname = $ENV{TRAVELYNX_DB_FILE} // 'travelynx.sqlite';

			return DBI->connect( "dbi:SQLite:dbname=${dbname}", q{}, q{} );
		}
	);
	$self->attr(
		get_all_actions_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select action_id, action_time, stations.ds100, stations.name,
			train_type, train_line, train_no, train_id,
			sched_time, real_time,
			route, messages
			from user_actions
			left outer join stations on station_id = stations.id
			where user_id = ?
			order by action_time desc
		}
			);
		}
	);
	$self->attr(
		get_last_actions_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select action_id, action_time, stations.ds100, stations.name,
			train_type, train_line, train_no, train_id,
			sched_time, real_time,
			route, messages
			from user_actions
			left outer join stations on station_id = stations.id
			where user_id = ?
			order by action_time desc
			limit 10
		}
			);
		}
	);
	$self->attr(
		get_journey_actions_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select action_id, action_time, stations.ds100, stations.name,
			train_type, train_line, train_no, train_id,
			sched_time, real_time,
			route, messages
			from user_actions
			left outer join stations on station_id = stations.id
			where user_id = ?
			and (action_time = ? or action_time = ?)
			order by action_time desc
			limit 2
		}
			);
		}
	);
	$self->attr(
		get_userid_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{select id from users where name = ?});
		}
	);
	$self->attr(
		get_pending_mails_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{select id from users where email = ? and status = 0;});
		}
	);
	$self->attr(
		get_listed_mails_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
qq{select * from pending_mails where email = ? and num_tries > 1;}
			);
		}
	);
	$self->attr(
		get_user_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select
				id, name, status, public_level, email,
				registered_at, last_login, deletion_requested
			from users where id = ?
		}
			);
		}
	);
	$self->attr(
		get_api_tokens_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select
				type, token
			from tokens where user_id = ?
		}
			);
		}
	);
	$self->attr(
		get_api_token_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select
				token
			from tokens where user_id = ? and type = ?
		}
			);
		}
	);
	$self->attr(
		drop_api_token_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			delete from tokens where user_id = ? and type = ?
		}
			);
		}
	);
	$self->attr(
		set_api_token_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			insert or replace into tokens
				(user_id, type, token)
			values
				(?, ?, ?)
		}
			);
		}
	);
	$self->attr(
		get_password_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select
				id, name, status, password
			from users where name = ?
		}
			);
		}
	);
	$self->attr(
		get_token_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			select
				name, status, token
			from users where id = ?
		}
			);
		}
	);
	$self->attr(
		get_stationid_by_ds100_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{select id from stations where ds100 = ?});
		}
	);
	$self->attr(
		get_stationid_by_name_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{select id from stations where name = ?});
		}
	);
	$self->attr(
		undo_query => sub {
			my ($self) = @_;

			return $self->app->dbh->prepare(
				qq{
			insert into user_actions (
				user_id, action_id, action_time
			) values (
				?, $self->app->action_type->{undo}, ?
			)
		}
			);
		},
	);

	$self->helper(
		'get_departures' => sub {
			my ( $self, $station, $lookbehind ) = @_;

			$lookbehind //= 180;

			my @station_matches
			  = Travel::Status::DE::IRIS::Stations::get_station($station);

			if ( @station_matches == 1 ) {
				$station = $station_matches[0][0];
				my $status = Travel::Status::DE::IRIS->new(
					station        => $station,
					main_cache     => $cache_iris_main,
					realtime_cache => $cache_iris_rt,
					lookbehind     => 20,
					datetime => DateTime->now( time_zone => 'Europe/Berlin' )
					  ->subtract( minutes => $lookbehind ),
					lookahead => $lookbehind + 10,
				);
				return {
					results       => [ $status->results ],
					errstr        => $status->errstr,
					station_ds100 => (
						$status->station ? $status->station->{ds100} : 'undef'
					),
					station_name =>
					  ( $status->station ? $status->station->{name} : 'undef' ),
				};
			}
			elsif ( @station_matches > 1 ) {
				return {
					results => [],
					errstr  => 'Ambiguous station name',
				};
			}
			else {
				return {
					results => [],
					errstr  => 'Unknown station name',
				};
			}
		}
	);

	$self->helper(
		'checkin' => sub {
			my ( $self, $station, $train_id, $action_id ) = @_;

			$action_id //= $self->app->action_type->{checkin};

			my $status = $self->get_departures($station);
			if ( $status->{errstr} ) {
				return ( undef, $status->{errstr} );
			}
			else {
				my ($train)
				  = first { $_->train_id eq $train_id } @{ $status->{results} };
				if ( not defined $train ) {
					return ( undef, "Train ${train_id} not found" );
				}
				else {

					my $user = $self->get_user_status;
					if ( $user->{checked_in} ) {

              # If a user is already checked in, we assume that they forgot to
              # check out and do it for them.
              # XXX this is an ugly workaround for the UNIQUE constraint on
              # (user id, action timestamp): Ensure that checkout and re-checkin
              # work even if the previous checkin was less than a second ago.
						sleep(1);
						$self->checkout( $station, 1 );

             # XXX same workaround: We can't checkin immediately after checkout.
						sleep(1);
					}
					elsif ( $user->{cancelled} ) {

						# Same
						sleep(1);
						$self->cancelled_to($station);
						sleep(1);
					}

					my $success = $self->app->action_query->execute(
						$self->current_user->{id},
						$action_id,
						$self->get_station_id(
							ds100 => $status->{station_ds100},
							name  => $status->{station_name}
						),
						DateTime->now( time_zone => 'Europe/Berlin' )->epoch,
						$train->type,
						$train->line_no,
						$train->train_no,
						$train->train_id,
						$train->sched_departure->epoch,
						$train->departure->epoch,
						join( '|', $train->route ),
						join(
							'|',
							map {
								( $_->[0] ? $_->[0]->epoch : q{} ) . ':'
								  . $_->[1]
							} $train->messages
						)
					);
					if ( defined $success ) {
						return ( $train, undef );
					}
					else {
						return ( undef, 'INSERT failed' );
					}
				}
			}
		}
	);

	$self->helper(
		'undo' => sub {
			my ($self) = @_;

			my $uid = $self->current_user->{id};
			$self->app->get_last_actions_query->execute($uid);
			my $rows = $self->app->get_last_actions_query->fetchall_arrayref;

			if ( @{$rows} and $rows->[0][0] == $self->app->action_type->{undo} )
			{
				return 'Nested undo (undoing an undo) is not supported';
			}

			if ( @{$rows} > 1
				and $rows->[1][0] == $self->app->action_type->{undo} )
			{
				return 'Repeated undo is not supported';
			}

			my $success = $self->app->undo_query->execute(
				$self->current_user->{id},
				DateTime->now( time_zone => 'Europe/Berlin' )->epoch,
			);

			if ( defined $success ) {
				return;
			}
			else {
				return 'INSERT failed';
			}
		}
	);

	$self->helper(
		'checkout' => sub {
			my ( $self, $station, $force, $action_id ) = @_;

			$action_id //= $self->app->action_type->{checkout};

			my $status   = $self->get_departures( $station, 180 );
			my $user     = $self->get_user_status;
			my $train_id = $user->{train_id};

			if ( not $user->{checked_in} and not $user->{cancelled} ) {
				return 'You are not checked into any train';
			}
			if ( $status->{errstr} and not $force ) {
				return $status->{errstr};
			}

			my ($train)
			  = first { $_->train_id eq $train_id } @{ $status->{results} };
			if ( not defined $train ) {
				if ($force) {
					my $success = $self->app->action_query->execute(
						$self->current_user->{id},
						$action_id,
						$self->get_station_id(
							ds100 => $status->{station_ds100},
							name  => $status->{station_name}
						),
						DateTime->now( time_zone => 'Europe/Berlin' )->epoch,
						undef, undef, undef, undef, undef,
						undef, undef, undef
					);
					if ( defined $success ) {
						return;
					}
					else {
						return 'INSERT failed';
					}
				}
				else {
					return "Train ${train_id} not found";
				}
			}
			else {
				my $success = $self->app->action_query->execute(
					$self->current_user->{id},
					$self->app->action_type->{checkout},
					$self->get_station_id(
						ds100 => $status->{station_ds100},
						name  => $status->{station_name}
					),
					DateTime->now( time_zone => 'Europe/Berlin' )->epoch,
					$train->type,
					$train->line_no,
					$train->train_no,
					$train->train_id,
					$train->sched_arrival
					? $train->sched_arrival->epoch
					: undef,
					$train->arrival ? $train->arrival->epoch : undef,
					join( '|', $train->route ),
					join(
						'|',
						map {
							( $_->[0] ? $_->[0]->epoch : q{} ) . ':'
							  . $_->[1]
						} $train->messages
					)
				);
				if ( defined $success ) {
					return;
				}
				else {
					return 'INSERT failed';
				}
			}
		}
	);

	$self->helper(
		'get_station_id' => sub {
			my ( $self, %opt ) = @_;

			$self->app->get_stationid_by_ds100_query->execute( $opt{ds100} );
			my $rows
			  = $self->app->get_stationid_by_ds100_query->fetchall_arrayref;
			if ( @{$rows} ) {
				return $rows->[0][0];
			}
			else {
				$self->app->add_station_query->execute( $opt{ds100},
					$opt{name} );
				$self->app->get_stationid_by_ds100_query->execute(
					$opt{ds100} );
				my $rows
				  = $self->app->get_stationid_by_ds100_query->fetchall_arrayref;
				return $rows->[0][0];
			}
		}
	);

	$self->helper(
		'get_user_token' => sub {
			my ( $self, $uid ) = @_;

			my $query = $self->app->get_token_query;
			$query->execute($uid);
			my $rows = $query->fetchall_arrayref;
			if ( @{$rows} ) {
				return @{ $rows->[0] };
			}
			return;
		}
	);

	# This helper should only be called directly when also providing a user ID.
	# If you don't have one, use current_user() instead (get_user_data will
	# delegate to it anyways).
	$self->helper(
		'get_user_data' => sub {
			my ( $self, $uid ) = @_;

			$uid //= $self->current_user->{id};
			my $query = $self->app->get_user_query;
			$query->execute($uid);
			my $rows = $query->fetchall_arrayref;
			if ( @{$rows} ) {
				my @row = @{ $rows->[0] };
				return {
					id            => $row[0],
					name          => $row[1],
					status        => $row[2],
					is_public     => $row[3],
					email         => $row[4],
					registered_at => DateTime->from_epoch(
						epoch     => $row[5],
						time_zone => 'Europe/Berlin'
					),
					last_seen => DateTime->from_epoch(
						epoch     => $row[6],
						time_zone => 'Europe/Berlin'
					),
					deletion_requested => $row[7]
					? DateTime->from_epoch(
						epoch     => $row[7],
						time_zone => 'Europe/Berlin'
					  )
					: undef,
				};
			}
			return undef;
		}
	);

	$self->helper(
		'get_api_token' => sub {
			my ( $self, $uid ) = @_;
			$uid //= $self->current_user->{id};
			$self->app->get_api_tokens_query->execute($uid);
			my $rows  = $self->app->get_api_tokens_query->fetchall_arrayref;
			my $token = {};
			for my $row ( @{$rows} ) {
				$token->{ $self->app->token_types->[ $row->[0] - 1 ] }
				  = $row->[1];
			}
			return $token;
		}
	);

	$self->helper(
		'get_user_password' => sub {
			my ( $self, $name ) = @_;
			my $query = $self->app->get_password_query;
			$query->execute($name);
			my $rows = $query->fetchall_arrayref;
			if ( @{$rows} ) {
				my @row = @{ $rows->[0] };
				return {
					id            => $row[0],
					name          => $row[1],
					status        => $row[2],
					password_hash => $row[3],
				};
			}
			return;
		}
	);

	$self->helper(
		'add_user' => sub {
			my ( $self, $user_name, $email, $token, $password ) = @_;

			$self->app->get_userid_query->execute($user_name);
			my $rows = $self->app->get_userid_query->fetchall_arrayref;

			if ( @{$rows} ) {
				my $id = $rows->[0][0];

				# transition code for closed beta account -> normal account
				if ($email) {
					$self->app->set_email_query->execute( $email, $token, $id );
				}
				if ($password) {
					$self->app->set_password_query->execute( $password, $id );
				}
				return $id;
			}
			else {
				my $now = DateTime->now( time_zone => 'Europe/Berlin' )->epoch;
				$self->app->add_user_query->execute( $user_name, $email, $token,
					$password, $now, $now );
				$self->app->get_userid_query->execute($user_name);
				$rows = $self->app->get_userid_query->fetchall_arrayref;
				return $rows->[0][0];
			}
		}
	);

	$self->helper(
		'check_if_user_name_exists' => sub {
			my ( $self, $user_name ) = @_;

			$self->app->get_userid_query->execute($user_name);
			my $rows = $self->app->get_userid_query->fetchall_arrayref;

			if ( @{$rows} ) {
				return 1;
			}
			return 0;
		}
	);

	$self->helper(
		'check_if_mail_is_blacklisted' => sub {
			my ( $self, $mail ) = @_;

			$self->app->get_pending_mails_query->execute($mail);
			if ( @{ $self->app->get_pending_mails_query->fetchall_arrayref } ) {
				return 1;
			}
			$self->app->get_listed_mails_query->execute($mail);
			if ( @{ $self->app->get_listed_mails_query->fetchall_arrayref } ) {
				return 1;
			}
			return 0;
		}
	);

	$self->helper(
		'get_user_travels' => sub {
			my ( $self, %opt ) = @_;

			my $uid   = $self->current_user->{id};
			my $query = $self->app->get_all_actions_query;
			if ( $opt{limit} ) {
				$query = $self->app->get_last_actions_query;
			}

			if ( $opt{uid} and $opt{checkin_epoch} and $opt{checkout_epoch} ) {
				$query = $self->app->get_journey_actions_query;
				$query->execute( $opt{uid}, $opt{checkin_epoch},
					$opt{checkout_epoch} );
			}
			else {
				$query->execute($uid);
			}
			my @match_actions = (
				$self->app->action_type->{checkout},
				$self->app->action_type->{checkin}
			);
			if ( $opt{cancelled} ) {
				@match_actions = (
					$self->app->action_type->{cancelled_to},
					$self->app->action_type->{cancelled_from}
				);
			}

			my @travels;
			my $prev_action = 0;

			while ( my @row = $query->fetchrow_array ) {
				my (
					$action,      $raw_ts,     $ds100,
					$name,        $train_type, $train_line,
					$train_no,    $train_id,   $raw_sched_ts,
					$raw_real_ts, $raw_route,  $raw_messages
				) = @row;

				$name         = decode( 'UTF-8', $name );
				$raw_route    = decode( 'UTF-8', $raw_route );
				$raw_messages = decode( 'UTF-8', $raw_messages );

				if (
					$action == $match_actions[0]
					or
					( $opt{checkout_epoch} and $raw_ts == $opt{checkout_epoch} )
				  )
				{
					push(
						@travels,
						{
							to_name       => $name,
							sched_arrival => epoch_to_dt($raw_sched_ts),
							rt_arrival    => epoch_to_dt($raw_real_ts),
							checkout      => epoch_to_dt($raw_ts),
							type          => $train_type,
							line          => $train_line,
							no            => $train_no,
							messages      => $raw_messages
							? [ split( qr{[|]}, $raw_messages ) ]
							: undef,
							route => $raw_route
							? [ split( qr{[|]}, $raw_route ) ]
							: undef,
							completed => 0,
						}
					);
				}
				elsif (
					(
						    $action == $match_actions[1]
						and $prev_action == $match_actions[0]
					)
					or
					( $opt{checkin_epoch} and $raw_ts == $opt{checkin_epoch} )
				  )
				{
					my $ref = $travels[-1];
					$ref->{from_name}       = $name;
					$ref->{completed}       = 1;
					$ref->{sched_departure} = epoch_to_dt($raw_sched_ts);
					$ref->{rt_departure}    = epoch_to_dt($raw_real_ts);
					$ref->{checkin}         = epoch_to_dt($raw_ts);
					$ref->{type}     //= $train_type;
					$ref->{line}     //= $train_line;
					$ref->{no}       //= $train_no;
					$ref->{messages} //= [ split( qr{[|]}, $raw_messages ) ];
					$ref->{route}    //= [ split( qr{[|]}, $raw_route ) ];

					if ( $opt{verbose} ) {
						my @parsed_messages;
						for my $message ( @{ $ref->{messages} // [] } ) {
							my ( $ts, $msg ) = split( qr{:}, $message );
							push( @parsed_messages,
								[ epoch_to_dt($ts), $msg ] );
						}
						$ref->{messages} = [ reverse @parsed_messages ];
						$ref->{sched_duration}
						  = $ref->{sched_arrival}
						  ? $ref->{sched_arrival}->epoch
						  - $ref->{sched_departure}->epoch
						  : undef;
						$ref->{rt_duration}
						  = $ref->{rt_arrival}
						  ? $ref->{rt_arrival}->epoch
						  - $ref->{rt_departure}->epoch
						  : undef;
						$ref->{km_route}
						  = $self->get_travel_distance( $ref->{from_name},
							$ref->{to_name}, $ref->{route} );
						$ref->{km_beeline}
						  = $self->get_travel_distance( $ref->{from_name},
							$ref->{to_name},
							[ $ref->{from_name}, $ref->{to_name} ] );
						$ref->{kmh_route} = $ref->{km_route} / (
							(
								$ref->{rt_duration} // $ref->{sched_duration}
								  // 999999
							) / 3600
						);
						$ref->{kmh_beeline} = $ref->{km_beeline} / (
							(
								$ref->{rt_duration} // $ref->{sched_duration}
								  // 999999
							) / 3600
						);
					}
					if (    $opt{checkin_epoch}
						and $action
						== $self->app->action_type->{cancelled_from} )
					{
						$ref->{cancelled} = 1;
					}
				}
				$prev_action = $action;
			}

			return @travels;
		}
	);

	$self->helper(
		'get_user_status' => sub {
			my ( $self, $uid ) = @_;

			$uid //= $self->current_user->{id};
			$self->app->get_last_actions_query->execute($uid);
			my $rows = $self->app->get_last_actions_query->fetchall_arrayref;

			if ( @{$rows} ) {
				my $now = DateTime->now( time_zone => 'Europe/Berlin' );

				my @cols = @{ $rows->[0] };
				if ( @{$rows} > 2
					and $rows->[0][0] == $self->app->action_type->{undo} )
				{
					@cols = @{ $rows->[2] };
				}

				my $action_ts            = epoch_to_dt( $cols[1] );
				my $sched_ts             = epoch_to_dt( $cols[8] );
				my $real_ts              = epoch_to_dt( $cols[9] );
				my $checkin_station_name = decode( 'UTF-8', $cols[3] );
				my @route
				  = split( qr{[|]}, decode( 'UTF-8', $cols[10] // q{} ) );
				my @route_after;
				my $is_after = 0;
				for my $station (@route) {

					if ( $station eq $checkin_station_name ) {
						$is_after = 1;
					}
					if ($is_after) {
						push( @route_after, $station );
					}
				}
				return {
					checked_in =>
					  ( $cols[0] == $self->app->action_type->{checkin} ),
					cancelled =>
					  ( $cols[0] == $self->app->action_type->{cancelled_from} ),
					timestamp       => $action_ts,
					timestamp_delta => $now->epoch - $action_ts->epoch,
					sched_ts        => $sched_ts,
					real_ts         => $real_ts,
					station_ds100   => $cols[2],
					station_name    => $checkin_station_name,
					train_type      => $cols[4],
					train_line      => $cols[5],
					train_no        => $cols[6],
					train_id        => $cols[7],
					route           => \@route,
					route_after     => \@route_after,
				};
			}
			return {
				checked_in => 0,
				timestamp  => epoch_to_dt(0),
				sched_ts   => epoch_to_dt(0),
				real_ts    => epoch_to_dt(0),
			};
		}
	);

	$self->helper(
		'get_travel_distance' => sub {
			my ( $self, $from, $to, $route_ref ) = @_;

			my $distance = 0;
			my $geo      = Geo::Distance->new();
			my @route    = after_incl { $_ eq $from } @{$route_ref};
			@route = before_incl { $_ eq $to } @route;

			if ( @route < 2 ) {

				# I AM ERROR
				return 0;
			}

			my $prev_station = get_station( shift @route );
			if ( not $prev_station ) {
				return 0;
			}

			for my $station_name (@route) {
				if ( my $station = get_station($station_name) ) {
					$distance
					  += $geo->distance( 'kilometer', $prev_station->[3],
						$prev_station->[4], $station->[3], $station->[4] );
					$prev_station = $station;
				}
			}

			return $distance;
		}
	);

	$self->helper(
		'navbar_class' => sub {
			my ( $self, $path ) = @_;

			if ( $self->req->url eq $self->url_for($path) ) {
				return 'active';
			}
			return q{};
		}
	);

	my $r = $self->routes;

	$r->get('/')->to('traveling#homepage');
	$r->get('/about')->to('static#about');
	$r->get('/impressum')->to('static#imprint');
	$r->get('/imprint')->to('static#imprint');
	$r->get('/api/v0/:user_action/:token')->to('api#get_v0');
	$r->get('/login')->to('account#login_form');
	$r->get('/register')->to('account#registration_form');
	$r->get('/reg/:id/:token')->to('account#verify');
	$r->post('/action')->to('traveling#log_action');
	$r->post('/geolocation')->to('traveling#geolocation');
	$r->post('/list_departures')->to('traveling#redirect_to_station');
	$r->post('/login')->to('account#do_login');
	$r->post('/register')->to('account#register');

	my $authed_r = $r->under(
		sub {
			my ($self) = @_;
			if ( $self->is_user_authenticated ) {
				return 1;
			}
			$self->render( 'login', redirect_to => $self->req->url );
			return undef;
		}
	);

	$authed_r->get('/account')->to('account#account');
	$authed_r->get('/export.json')->to('account#json_export');
	$authed_r->get('/history')->to('traveling#history');
	$authed_r->get('/history.json')->to('traveling#json_history');
	$authed_r->get('/journey/:id')->to('traveling#journey_details');
	$authed_r->get('/s/*station')->to('traveling#station');
	$authed_r->post('/delete')->to('account#delete');
	$authed_r->post('/logout')->to('account#do_logout');
	$authed_r->post('/set_token')->to('api#set_token');

}

1;
