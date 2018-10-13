#!/usr/bin/env perl

use Mojolicious::Lite;
use Cache::File;
use DateTime;
use DBI;
use Encode qw(decode);
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

my $dbname = $ENV{TRAVELYNX_DB_FILE} // 'travelynx.sqlite';

my %action_type = (
	checkin  => 1,
	checkout => 2,
	undo     => -1
);

app->defaults( layout => 'default' );

app->attr(
	add_station_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{
			insert into stations (ds100, name) values (?, ?)
		}
		);
	}
);
app->attr(
	add_user_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{
			insert into users (name) values (?)
		}
		);
	}
);
app->attr(
	checkin_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{
			insert into user_actions (
				user_id, action_id, station_id, action_time,
				train_type, train_line, train_no, train_id,
				sched_time, real_time,
				route, messages
			) values (
				?, $action_type{checkin}, ?, ?,
				?, ?, ?, ?,
				?, ?,
				?, ?
			)
		}
		);
	},
);
app->attr(
	checkout_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{
			insert into user_actions (
				user_id, action_id, station_id, action_time,
				train_type, train_line, train_no, train_id,
				sched_time, real_time,
				route, messages
			) values (
				?, $action_type{checkout}, ?, ?,
				?, ?, ?, ?,
				?, ?,
				?, ?
			)
		}
		);
	}
);
app->attr(
	dbh => sub {
		my ($self) = @_;

		return DBI->connect( "dbi:SQLite:dbname=${dbname}", q{}, q{} );
	}
);
app->attr(
	get_all_actions_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{
			select action_id, action_time, stations.ds100, stations.name,
			train_type, train_line, train_no, train_id,
			sched_time, real_time,
			route, messages
			from user_actions
			join stations on station_id = stations.id
			where user_id = ?
			order by action_time desc
		}
		);
	}
);
app->attr(
	get_last_actions_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{
			select action_id, action_time, stations.ds100, stations.name,
			train_type, train_line, train_no, train_id,
			sched_time, real_time,
			route, messages
			from user_actions
			join stations on station_id = stations.id
			where user_id = ?
			order by action_time desc
			limit 10
		}
		);
	}
);
app->attr(
	get_userid_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{select id from users where name = ?});
	}
);
app->attr(
	get_stationid_by_ds100_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{select id from stations where ds100 = ?});
	}
);
app->attr(
	get_stationid_by_name_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{select id from stations where name = ?});
	}
);
app->attr(
	undo_query => sub {
		my ($self) = @_;

		return $self->app->dbh->prepare(
			qq{
			insert into user_actions (
				user_id, action_id, action_time,
			) values (
				?, $action_type{undo}, ?
			)
		}
		);
	},
);

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

sub get_departures {
	my ( $station, $lookbehind ) = @_;

	$lookbehind //= 60;

	my @station_matches
	  = Travel::Status::DE::IRIS::Stations::get_station($station);

	if ( @station_matches == 1 ) {
		$station = $station_matches[0][0];
		my $status = Travel::Status::DE::IRIS->new(
			station        => $station,
			main_cache     => $cache_iris_main,
			realtime_cache => $cache_iris_rt,
			lookbehind     => 20,
			datetime       => DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( minutes => $lookbehind ),
			lookahead => $lookbehind + 20,
		);
		return {
			results => [ $status->results ],
			errstr  => $status->errstr,
			station_ds100 =>
			  ( $status->station ? $status->station->{ds100} : 'undef' ),
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

sub get_station {
	my ($station_name) = @_;

	my @candidates
	  = Travel::Status::DE::IRIS::Stations::get_station($station_name);

	if ( @candidates == 1 ) {
		return $candidates[0];
	}
	return undef;
}

helper 'checkin' => sub {
	my ( $self, $station, $train_id ) = @_;

	my $status = get_departures($station);
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
			my $success = $self->app->checkin_query->execute(
				$self->get_user_id,
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
				join( '|',
					map { ( $_->[0] ? $_->[0]->epoch : q{} ) . ':' . $_->[1] }
					  $train->messages )
			);
			if ( defined $success ) {
				return ( $train, undef );
			}
			else {
				return ( undef, 'INSERT failed' );
			}
		}
	}
};

helper 'checkout' => sub {
	my ( $self, $station, $force ) = @_;

	my $status   = get_departures( $station, 180 );
	my $user     = $self->get_user_status;
	my $train_id = $user->{train_id};

	if ( $status->{errstr} and not $force ) {
		return $status->{errstr};
	}
	if ( not $user->{checked_in} ) {
		return 'You are not checked into any train';
	}
	else {
		my ($train)
		  = first { $_->train_id eq $train_id } @{ $status->{results} };
		if ( not defined $train ) {
			if ($force) {
				my $success = $self->app->checkout_query->execute(
					$self->get_user_id,
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
			my $success = $self->app->checkout_query->execute(
				$self->get_user_id,
				$self->get_station_id(
					ds100 => $status->{station_ds100},
					name  => $status->{station_name}
				),
				DateTime->now( time_zone => 'Europe/Berlin' )->epoch,
				$train->type,
				$train->line_no,
				$train->train_no,
				$train->train_id,
				$train->sched_arrival ? $train->sched_arrival->epoch : undef,
				$train->arrival       ? $train->arrival->epoch       : undef,
				join( '|', $train->route ),
				join( '|',
					map { ( $_->[0] ? $_->[0]->epoch : q{} ) . ':' . $_->[1] }
					  $train->messages )
			);
			if ( defined $success ) {
				return;
			}
			else {
				return 'INSERT failed';
			}
		}
	}
};

helper 'get_station_id' => sub {
	my ( $self, %opt ) = @_;

	$self->app->get_stationid_by_ds100_query->execute( $opt{ds100} );
	my $rows = $self->app->get_stationid_by_ds100_query->fetchall_arrayref;
	if ( @{$rows} ) {
		return $rows->[0][0];
	}
	else {
		$self->app->add_station_query->execute( $opt{ds100}, $opt{name} );
		$self->app->get_stationid_by_ds100_query->execute( $opt{ds100} );
		my $rows = $self->app->get_stationid_by_ds100_query->fetchall_arrayref;
		return $rows->[0][0];
	}
};

helper 'get_user_name' => sub {
	my ($self) = @_;

	my $user = $self->req->headers->header('X-Remote-User') // 'dev';

	return $user;
};

helper 'get_user_id' => sub {
	my ( $self, $user_name ) = @_;

	$user_name //= $self->get_user_name;

	if ( not -e $dbname ) {
		$self->app->dbh->do(
			qq{
			create table users (
				id integer primary key,
				name char(64) not null unique
			)
		}
		);
		$self->app->dbh->do(
			qq{
			create table stations (
				id integer primary key,
				ds100 char(16) not null unique,
				name char(64) not null unique
			)
		}
		);
		$self->app->dbh->do(
			qq{
			create table user_actions (
				user_id int not null,
				action_id int not null,
				station_id int,
				action_time int not null,
				train_type char(16),
				train_line char(16),
				train_no char(16),
				train_id char(128),
				sched_time int,
				real_time int,
				route text,
				messages text,
				primary key (user_id, action_time)
			)
		}
		);
	}

	$self->app->get_userid_query->execute($user_name);
	my $rows = $self->app->get_userid_query->fetchall_arrayref;

	if ( @{$rows} ) {
		return $rows->[0][0];
	}
	else {
		$self->app->add_user_query->execute($user_name);
		$self->app->get_userid_query->execute($user_name);
		my $rows = $self->app->get_userid_query->fetchall_arrayref;
		return $rows->[0][0];
	}
};

helper 'get_user_travels' => sub {
	my ( $self, $limit ) = @_;

	my $uid   = $self->get_user_id;
	my $query = $self->app->get_all_actions_query;
	if ($limit) {
		$query = $self->app->get_last_actions_query;
	}
	$query->execute($uid);

	my @travels;

	while ( my @row = $query->fetchrow_array ) {
		my (
			$action,       $raw_ts,      $ds100,     $name,
			$train_type,   $train_line,  $train_no,  $train_id,
			$raw_sched_ts, $raw_real_ts, $raw_route, $raw_messages
		) = @row;

		$name         = decode( 'UTF-8', $name );
		$raw_route    = decode( 'UTF-8', $raw_route );
		$raw_messages = decode( 'UTF-8', $raw_messages );

		if ( $action == $action_type{checkout} ) {
			push(
				@travels,
				{
					to_name       => $name,
					sched_arrival => epoch_to_dt($raw_sched_ts),
					rt_arrival    => epoch_to_dt($raw_real_ts),
					type          => $train_type,
					line          => $train_line,
					no            => $train_no,
					messages      => $raw_messages
					? [ split( qr{[|]}, $raw_messages ) ]
					: undef,
					route => $raw_route ? [ split( qr{[|]}, $raw_route ) ]
					: undef,
					completed => 0,
				}
			);
		}
		elsif ( $action == $action_type{checkin} and @travels ) {
			my $ref = $travels[-1];
			$ref->{from_name}       = $name;
			$ref->{completed}       = 1;
			$ref->{sched_departure} = epoch_to_dt($raw_sched_ts),
			  $ref->{rt_departure}  = epoch_to_dt($raw_real_ts),
			  $ref->{type}   //= $train_type;
			$ref->{line}     //= $train_line;
			$ref->{no}       //= $train_no;
			$ref->{messages} //= [ split( qr{[|]}, $raw_messages ) ];
			$ref->{route}    //= [ split( qr{[|]}, $raw_route ) ];
		}
	}

	return @travels;
};

helper 'get_user_status' => sub {
	my ($self) = @_;

	my $uid = $self->get_user_id;
	$self->app->get_last_actions_query->execute($uid);
	my $rows = $self->app->get_last_actions_query->fetchall_arrayref;

	if ( @{$rows} ) {
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		my $ts = epoch_to_dt( $rows->[0][1] );
		my $checkin_station_name = decode( 'UTF-8', $rows->[0][3] );
		my @route = split( qr{[|]}, decode( 'UTF-8', $rows->[0][10] // q{} ) );
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
			checked_in      => ( $rows->[0][0] == $action_type{checkin} ),
			timestamp       => $ts,
			timestamp_delta => $now->subtract_datetime($ts),
			station_ds100   => $rows->[0][2],
			station_name    => $rows->[0][3],
			train_type      => $rows->[0][4],
			train_line      => $rows->[0][5],
			train_no        => $rows->[0][6],
			train_id        => $rows->[0][7],
			route           => \@route,
			route_after     => \@route_after,
		};
	}
	return {
		checked_in => 0,
		timestamp  => 0
	};
};

helper 'get_travel_distance' => sub {
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
			$distance += $geo->distance( 'kilometer', $prev_station->[3],
				$prev_station->[4], $station->[3], $station->[4] );
			$prev_station = $station;
		}
	}

	return $distance;
};

helper 'navbar_class' => sub {
	my ( $self, $path ) = @_;

	if ( $self->req->url eq $self->url_for($path) ) {
		return 'active';
	}
	return q{};
};

get '/' => sub {
	my ($self) = @_;
	$self->render( 'landingpage', with_geolocation => 1 );
};

post '/action' => sub {
	my ($self) = @_;
	my $params = $self->req->json;

	if ( not exists $params->{action} ) {
		$params = $self->req->params->to_hash;
	}

	if ( not $params->{action} ) {
		$self->render(
			json   => {},
			status => 400,
		);
		return;
	}

	my $station = $params->{station};

	if ( $params->{action} eq 'checkin' ) {

		my ( $train, $error )
		  = $self->checkin( $params->{station}, $params->{train}, );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'checkout' ) {
		my $error = $self->checkout( $params->{station}, $params->{force}, );

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			$self->render(
				json => {
					success => 1,
				},
			);
		}
	}
};

get '/a/history' => sub {
	my ($self) = @_;

	$self->render('history');
};

get '/x/about' => sub {
	my ($self) = @_;

	$self->render( 'about', version => $VERSION );
};

post '/x/geolocation' => sub {
	my ($self) = @_;

	my $lon = $self->param('lon');
	my $lat = $self->param('lat');

	if ( not $lon or not $lat ) {
		$self->render( json => { error => 'Invalid lon/lat received' } );
	}
	else {
		my @candidates = map {
			{
				ds100    => $_->[0][0],
				name     => $_->[0][1],
				eva      => $_->[0][2],
				lon      => $_->[0][3],
				lat      => $_->[0][4],
				distance => $_->[1],
			}
		} Travel::Status::DE::IRIS::Stations::get_station_by_location( $lon,
			$lat, 5 );
		$self->render(
			json => {
				candidates => [@candidates],
			}
		);
	}

};

get '/*station' => sub {
	my ($self) = @_;
	my $station = $self->stash('station');

	my $status = get_departures($station);

	if ( $status->{errstr} ) {
		$self->render( 'landingpage', error => $status->{errstr} );
	}
	else {
		my @results = sort { $a->line cmp $b->line } @{ $status->{results} };

		# You can't check into a train which terminates here
		@results = grep { $_->departure } @results;
		$self->render(
			'departures',
			ds100   => $status->{station_ds100},
			results => \@results,
			station => $status->{station_name}
		);
	}
};

app->defaults( layout => 'default' );

app->config(
	hypnotoad => {
		accepts  => 10,
		listen   => [ $ENV{DBFAKEDISPLAY_LISTEN} // 'http://*:8092' ],
		pid_file => '/tmp/db-fakedisplay.pid',
		workers  => $ENV{DBFAKEDISPLAY_WORKERS} // 2,
	},
);

app->start;
