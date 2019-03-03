#!/usr/bin/env perl

use Mojolicious::Lite;
use Mojolicious::Plugin::Authentication;
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
	undo     => 3,
);

my @action_types = (qw(checkin checkout undo));

app->plugin(
	authentication => {
		autoload_user => 1,
		session_key   => 'foodor',
		load_user     => sub {
			my ( $app, $uid ) = @_;
			if ( $uid == 1 ) {
				return {
					name => 'dev',
				};
			}
			return undef;
		},
		validate_user => sub {
			my ( $c, $username, $password, $extradata ) = @_;
			if ( $username eq 'dev' and $password eq 'ohai' ) {
				return 1;
			}
			return undef;
		},
	}
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
			left outer join stations on station_id = stations.id
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
			left outer join stations on station_id = stations.id
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
				user_id, action_id, action_time
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
			datetime       => DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( minutes => $lookbehind ),
			lookahead => $lookbehind + 10,
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

helper 'undo' => sub {
	my ($self) = @_;

	my $uid = $self->get_user_id;
	$self->app->get_last_actions_query->execute($uid);
	my $rows = $self->app->get_last_actions_query->fetchall_arrayref;

	if ( @{$rows} and $rows->[0][0] == $action_type{undo} ) {
		return 'Nested undo (undoing an undo) is not supported';
	}

	if ( @{$rows} > 1 and $rows->[1][0] == $action_type{undo} ) {
		return 'Repeated undo is not supported';
	}

	my $success
	  = $self->app->undo_query->execute( $self->get_user_id,
		DateTime->now( time_zone => 'Europe/Berlin' )->epoch,
	  );

	if ( defined $success ) {
		return;
	}
	else {
		return 'INSERT failed';
	}
};

helper 'checkout' => sub {
	my ( $self, $station, $force ) = @_;

	my $status   = get_departures( $station, 180 );
	my $user     = $self->get_user_status;
	my $train_id = $user->{train_id};

	if ( not $user->{checked_in} ) {
		return 'You are not checked into any train';
	}
	if ( $status->{errstr} and not $force ) {
		return $status->{errstr};
	}

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
				undef, undef, undef, undef, undef, undef,
				undef, undef
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
		$rows = $self->app->get_userid_query->fetchall_arrayref;
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
	my $prev_action = 0;

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
		elsif ( $action == $action_type{checkin}
			and $prev_action == $action_type{checkout} )
		{
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
		$prev_action = $action;
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

		my @cols = @{ $rows->[0] };
		if ( @{$rows} > 2 and $rows->[0][0] == $action_type{undo} ) {
			@cols = @{ $rows->[2] };
		}

		my $ts = epoch_to_dt( $cols[1] );
		my $checkin_station_name = decode( 'UTF-8', $cols[3] );
		my @route = split( qr{[|]}, decode( 'UTF-8', $cols[10] // q{} ) );
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
			checked_in      => ( $cols[0] == $action_type{checkin} ),
			timestamp       => $ts,
			timestamp_delta => $now->epoch - $ts->epoch,
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
			json => {
				success => 0,
				error   => 'Missing action value',
			},
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
	elsif ( $params->{action} eq 'undo' ) {
		my $error = $self->undo;
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
	else {
		$self->render(
			json => {
				success => 0,
				error   => 'invalid action value',
			},
			status => 400,
		);
	}
};

get '/a/account' => sub {
	my ($self) = @_;

	$self->render('account');
};

get '/a/export.json' => sub {
	my ($self) = @_;
	my $uid    = $self->get_user_id;
	my $query  = $self->app->get_all_actions_query;

	$query->execute($uid);

	my @entries;

	while ( my @row = $query->fetchrow_array ) {
		my (
			$action,       $raw_ts,      $ds100,     $name,
			$train_type,   $train_line,  $train_no,  $train_id,
			$raw_sched_ts, $raw_real_ts, $raw_route, $raw_messages
		) = @row;

		$name         = decode( 'UTF-8', $name );
		$raw_route    = decode( 'UTF-8', $raw_route );
		$raw_messages = decode( 'UTF-8', $raw_messages );
		push(
			@entries,
			{
				action        => $action_types[ $action - 1 ],
				action_ts     => $raw_ts,
				station_ds100 => $ds100,
				station_name  => $name,
				train_type    => $train_type,
				train_line    => $train_line,
				train_no      => $train_no,
				train_id      => $train_id,
				scheduled_ts  => $raw_sched_ts,
				realtime_ts   => $raw_real_ts,
				messages      => $raw_messages
				? [ map { [ split(qr{:}) ] } split( qr{[|]}, $raw_messages ) ]
				: undef,
				route => $raw_route ? [ split( qr{[|]}, $raw_route ) ]
				: undef,
			}
		);
	}

	$self->render(
		json => [@entries],
	);
};

get '/a/history' => sub {
	my ($self) = @_;

	$self->render('history');
};

get '/x/about' => sub {
	my ($self) = @_;

	$self->render( 'about', version => $VERSION );
};

get '/x/impressum' => sub {
	my ($self) = @_;

	$self->render('imprint');
};

get '/x/imprint' => sub {
	my ($self) = @_;

	$self->render('imprint');
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

get '/x/login' => sub {
	my ($self) = @_;
	$self->render('login');
};

post '/x/login' => sub {
	my ($self)   = @_;
	my $user     = $self->req->param('user');
	my $password = $self->req->param('password');

	# Keep cookies for 6 months
	$self->session( expiration => 60 * 60 * 24 * 180 );

	if ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'login',
			invalid => 'csrf',
		);
	}
	else {
		if ( $self->authenticate( $user, $password ) ) {
			$self->redirect_to('/');
		}
		else {
			$self->render( 'login', invalid => 'credentials' );
		}
	}
};

get '/x/logout' => sub {
	my ($self) = @_;
	$self->logout;
	$self->redirect_to('/x/login');
};

get '/x/register' => sub {
	my ($self) = @_;
	$self->render('register');
};

get '/*station' => sub {
	my ($self) = @_;
	my $station = $self->stash('station');

	my $status = get_departures($station);

	if ( $status->{errstr} ) {
		$self->render( 'landingpage', error => $status->{errstr} );
	}
	else {
		# You can't check into a train which terminates here
		my @results = grep { $_->departure } @{ $status->{results} };

		@results = map { $_->[0] }
		  sort { $b->[1] <=> $a->[1] }
		  map { [ $_, $_->departure->epoch // $_->sched_departure->epoch ] }
		  @results;

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
