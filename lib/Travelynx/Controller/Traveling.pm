package Travelynx::Controller::Traveling;
use Mojo::Base 'Mojolicious::Controller';

use DateTime;
use DateTime::Format::Strptime;
use List::Util qw(uniq);
use List::UtilsBy qw(uniq_by);
use List::MoreUtils qw(first_index);
use Travel::Status::DE::IRIS::Stations;

sub homepage {
	my ($self) = @_;
	if ( $self->is_user_authenticated ) {
		$self->render(
			'landingpage',
			version           => $self->app->config->{version} // 'UNKNOWN',
			with_autocomplete => 1,
			with_geolocation  => 1
		);
		$self->mark_seen( $self->current_user->{id} );
	}
	else {
		$self->render(
			'landingpage',
			version => $self->app->config->{version} // 'UNKNOWN',
			intro   => 1
		);
	}
}

sub user_status {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $ts   = $self->stash('ts');
	my $user = $self->get_privacy_by_name($name);

	if (
		$user
		and ( $user->{public_level} & 0x02
			or
			( $user->{public_level} & 0x01 and $self->is_user_authenticated ) )
	  )
	{
		my $status = $self->get_user_status( $user->{id} );

		my %tw_data = (
			card  => 'summary',
			site  => '@derfnull',
			image => $self->url_for('/static/icons/icon-512x512.png')
			  ->to_abs->scheme('https'),
		);

		if (
			$ts
			and ( not $status->{checked_in}
				or $status->{sched_departure}->epoch != $ts )
		  )
		{
			$tw_data{title}       = "Bahnfahrt beendet";
			$tw_data{description} = "${name} hat das Ziel erreicht";
		}
		elsif ( $status->{checked_in} ) {
			$tw_data{title}       = "${name} ist unterwegs";
			$tw_data{description} = sprintf(
				'%s %s von %s nach %s',
				$status->{train_type},
				$status->{train_line} // $status->{train_no},
				$status->{dep_name},
				$status->{arr_name} // 'irgendwo'
			);
			if ( $status->{real_arrival}->epoch ) {
				$tw_data{description} .= $status->{real_arrival}
				  ->strftime(' – Ankunft gegen %H:%M Uhr');
			}
		}
		else {
			$tw_data{title}       = "${name} ist gerade nicht eingecheckt";
			$tw_data{description} = "Letztes Fahrtziel: $status->{arr_name}";
		}

		$self->render(
			'user_status',
			name         => $name,
			public_level => $user->{public_level},
			journey      => $status,
			twitter      => \%tw_data,
		);
	}
	elsif ( $user->{public_level} & 0x01 ) {
		$self->render( 'login', redirect_to => $self->req->url );
	}
	else {
		$self->render('not_found');
	}
}

sub public_status_card {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $user = $self->get_privacy_by_name($name);

	delete $self->stash->{layout};

	if (
		$user
		and ( $user->{public_level} & 0x02
			or
			( $user->{public_level} & 0x01 and $self->is_user_authenticated ) )
	  )
	{
		my $status = $self->get_user_status( $user->{id} );
		$self->render(
			'_public_status_card',
			name         => $name,
			public_level => $user->{public_level},
			journey      => $status
		);
	}
	else {
		$self->render('not_found');
	}
}

sub status_card {
	my ($self) = @_;
	my $status = $self->get_user_status;

	delete $self->stash->{layout};

	if ( $status->{checked_in} ) {
		$self->render( '_checked_in', journey => $status );
	}
	else {
		$self->render( '_checked_out', journey => $status );
	}
}

sub geolocation {
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
			$lat, 10 );
		@candidates = uniq_by { $_->{name} } @candidates;
		if ( @candidates > 5 ) {
			$self->render(
				json => {
					candidates => [ @candidates[ 0 .. 4 ] ],
				}
			);
		}
		else {
			$self->render(
				json => {
					candidates => [@candidates],
				}
			);
		}
	}
}

sub log_action {
	my ($self) = @_;
	my $params = $self->req->json;

	if ( not exists $params->{action} ) {
		$params = $self->req->params->to_hash;
	}

	if ( not $self->is_user_authenticated ) {

		# We deliberately do not set the HTTP status for these replies, as it
		# confuses jquery.
		$self->render(
			json => {
				success => 0,
				error   => 'Session error, please login again',
			},
		);
		return;
	}

	if ( not $params->{action} ) {
		$self->render(
			json => {
				success => 0,
				error   => 'Missing action value',
			},
		);
		return;
	}

	my $station = $params->{station};

	if ( $params->{action} eq 'checkin' ) {

		my ( $train, $error )
		  = $self->checkin( $params->{station}, $params->{train} );
		my $destination = $params->{dest};

		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		elsif ( not $destination ) {
			$self->render(
				json => {
					success     => 1,
					redirect_to => '/',
				},
			);
		}
		else {
			# Silently ignore errors -- if they are permanent, the user will see
			# them when selecting the destination manually.
			my ( $still_checked_in, undef )
			  = $self->checkout( $destination, 0 );
			my $station_link = '/s/' . $destination;
			$self->render(
				json => {
					success     => 1,
					redirect_to => $still_checked_in ? '/' : $station_link,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'checkout' ) {
		my ( $still_checked_in, $error )
		  = $self->checkout( $params->{station}, $params->{force} );
		my $station_link = '/s/' . $params->{station};

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
					success     => 1,
					redirect_to => $still_checked_in ? '/' : $station_link,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'undo' ) {
		my $status = $self->get_user_status;
		my $error  = $self->undo( $params->{undo_id} );
		if ($error) {
			$self->render(
				json => {
					success => 0,
					error   => $error,
				},
			);
		}
		else {
			my $redir = '/';
			if ( $status->{checked_in} or $status->{cancelled} ) {
				$redir = '/s/' . $status->{dep_ds100};
			}
			$self->render(
				json => {
					success     => 1,
					redirect_to => $redir,
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_from' ) {
		my ( undef, $error )
		  = $self->checkin( $params->{station}, $params->{train} );

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
					success     => 1,
					redirect_to => '/',
				},
			);
		}
	}
	elsif ( $params->{action} eq 'cancelled_to' ) {
		my ( undef, $error )
		  = $self->checkout( $params->{station}, 1 );

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
					success     => 1,
					redirect_to => '/',
				},
			);
		}
	}
	elsif ( $params->{action} eq 'delete' ) {
		my $error = $self->delete_journey( $params->{id}, $params->{checkin},
			$params->{checkout} );
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
					success     => 1,
					redirect_to => '/history',
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
		);
	}
}

sub station {
	my ($self)  = @_;
	my $station = $self->stash('station');
	my $train   = $self->param('train');

	my $status = $self->get_departures( $station, 120, 30, 1 );

	if ( $status->{errstr} ) {
		$self->render(
			'landingpage',
			version           => $self->app->config->{version} // 'UNKNOWN',
			with_autocomplete => 1,
			with_geolocation  => 1,
			error             => $status->{errstr}
		);
	}
	else {
		# You can't check into a train which terminates here
		my @results = grep { $_->departure } @{ $status->{results} };

		@results = map { $_->[0] }
		  sort { $b->[1] <=> $a->[1] }
		  map { [ $_, $_->departure->epoch // $_->sched_departure->epoch ] }
		  @results;

		if ($train) {
			@results
			  = grep { $_->type . ' ' . $_->train_no eq $train } @results;
		}

		$self->render(
			'departures',
			eva              => $status->{station_eva},
			results          => \@results,
			station          => $status->{station_name},
			related_stations => $status->{related_stations},
			title            => "travelynx: $status->{station_name}",
		);
	}
	$self->mark_seen( $self->current_user->{id} );
}

sub redirect_to_station {
	my ($self) = @_;
	my $station = $self->param('station');

	$self->redirect_to("/s/${station}");
}

sub cancelled {
	my ($self) = @_;
	my @journeys = $self->get_user_travels(
		cancelled     => 1,
		with_datetime => 1
	);

	$self->respond_to(
		json => { json => [@journeys] },
		any  => {
			template => 'cancelled',
			journeys => [@journeys]
		}
	);
}

sub history {
	my ($self) = @_;

	$self->render( template => 'history' );
}

sub map_history {
	my ($self) = @_;

	my $location = $self->app->coordinates_by_station;

	my @journeys = $self->get_user_travels;

	if ( not @journeys ) {
		$self->render(
			template            => 'history_map',
			with_map            => 1,
			skipped_journeys    => [],
			station_coordinates => [],
			polyline_groups     => [],
		);
		return;
	}

	my $include_manual = $self->param('include_manual') ? 1 : 0;

	my $first_departure = $journeys[-1]->{rt_departure};
	my $last_departure  = $journeys[0]->{rt_departure};

	my @stations = uniq map { $_->{to_name} } @journeys;
	push( @stations, uniq map { $_->{from_name} } @journeys );
	@stations = uniq @stations;
	my @station_coordinates = map { [ $location->{$_}, $_ ] }
	  grep { exists $location->{$_} } @stations;

	my @station_pairs;
	my %seen;

	my @skipped_journeys;

	for my $journey (@journeys) {

		my @route = map { $_->[0] } @{ $journey->{route} };

		my $from_index = first_index { $_ eq $journey->{from_name} } @route;
		my $to_index   = first_index { $_ eq $journey->{to_name} } @route;

		if ( $from_index == -1 ) {
			my $rename = $self->app->renamed_station;
			$from_index
			  = first_index { ( $rename->{$_} // $_ ) eq $journey->{from_name} }
			@route;
		}
		if ( $to_index == -1 ) {
			my $rename = $self->app->renamed_station;
			$to_index
			  = first_index { ( $rename->{$_} // $_ ) eq $journey->{to_name} }
			@route;
		}

		if (   $from_index == -1
			or $to_index == -1 )
		{
			push( @skipped_journeys,
				[ $journey, 'Start/Ziel nicht in Route gefunden' ] );
			next;
		}

		# Manual journey entries are only included if one of the following
		# conditions is satisfied:
		# * their route has more than two elements (-> probably more than just
		#   start and stop station), or
		# * $include_manual is true (-> user wants to see incomplete routes)
		# This avoids messing up the map in case an A -> B connection has been
		# tracked both with a regular checkin (-> detailed route shown on map)
		# and entered manually (-> beeline also shown on map, typically
		# significantly differs from detailed route) -- unless the user
		# sets include_manual, of course.
		if (    $journey->{edited} & 0x0010
			and @route <= 2
			and not $include_manual )
		{
			push( @skipped_journeys,
				[ $journey, 'Manueller Eintrag ohne Unterwegshalte' ] );
			next;
		}

		@route = @route[ $from_index .. $to_index ];

		my $key = join( '|', @route );

		if ( $seen{$key} ) {
			next;
		}

		$seen{$key} = 1;

		# direction does not matter at the moment
		$seen{ join( '|', reverse @route ) } = 1;

		my $prev_station = shift @route;
		for my $station (@route) {
			push( @station_pairs, [ $prev_station, $station ] );
			$prev_station = $station;
		}
	}

	@station_pairs = uniq_by { $_->[0] . '|' . $_->[1] } @station_pairs;
	@station_pairs
	  = grep { exists $location->{ $_->[0] } and exists $location->{ $_->[1] } }
	  @station_pairs;
	@station_pairs
	  = map { [ $location->{ $_->[0] }, $location->{ $_->[1] } ] }
	  @station_pairs;

	my @routes;

	$self->render(
		template            => 'history_map',
		with_map            => 1,
		skipped_journeys    => \@skipped_journeys,
		station_coordinates => \@station_coordinates,
		polyline_groups     => [
			{
				polylines  => \@station_pairs,
				color      => '#673ab7',
				opacity    => 0.6,
				fit_bounds => 1,
			}
		]
	);
}

sub json_history {
	my ($self) = @_;

	$self->render( json => [ $self->get_user_travels ] );
}

sub yearly_history {
	my ($self) = @_;
	my $year = $self->stash('year');
	my @journeys;
	my $stats;

	# DateTime is very slow when looking far into the future due to DST changes
	# -> Limit time range to avoid accidental DoS.
	if ( not( $year =~ m{ ^ [0-9]{4} $ }x and $year > 1990 and $year < 2100 ) )
	{
		@journeys = $self->get_user_travels( with_datetime => 1 );
	}
	else {
		my $interval_start = DateTime->new(
			time_zone => 'Europe/Berlin',
			year      => $year,
			month     => 1,
			day       => 1,
			hour      => 0,
			minute    => 0,
			second    => 0,
		);
		my $interval_end = $interval_start->clone->add( years => 1 );
		@journeys = $self->get_user_travels(
			after         => $interval_start,
			before        => $interval_end,
			with_datetime => 1
		);
		$stats = $self->get_journey_stats( year => $year );
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_year',
			journeys   => [@journeys],
			year       => $year,
			statistics => $stats
		}
	);

}

sub monthly_history {
	my ($self) = @_;
	my $year   = $self->stash('year');
	my $month  = $self->stash('month');
	my @journeys;
	my $stats;
	my @months
	  = (
		qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
	  );

	if (
		not(    $year =~ m{ ^ [0-9]{4} $ }x
			and $year > 1990
			and $year < 2100
			and $month =~ m{ ^ [0-9]{1,2} $ }x
			and $month > 0
			and $month < 13 )
	  )
	{
		@journeys = $self->get_user_travels( with_datetime => 1 );
	}
	else {
		my $interval_start = DateTime->new(
			time_zone => 'Europe/Berlin',
			year      => $year,
			month     => $month,
			day       => 1,
			hour      => 0,
			minute    => 0,
			second    => 0,
		);
		my $interval_end = $interval_start->clone->add( months => 1 );
		@journeys = $self->get_user_travels(
			after         => $interval_start,
			before        => $interval_end,
			with_datetime => 1
		);
		$stats = $self->get_journey_stats(
			year  => $year,
			month => $month
		);
	}

	$self->respond_to(
		json => {
			json => {
				journeys   => [@journeys],
				statistics => $stats
			}
		},
		any => {
			template   => 'history_by_month',
			journeys   => [@journeys],
			year       => $year,
			month      => $month,
			month_name => $months[ $month - 1 ],
			statistics => $stats
		}
	);

}

sub journey_details {
	my ($self) = @_;
	my $journey_id = $self->stash('id');

	my $uid = $self->current_user->{id};

	$self->param( journey_id => $journey_id );

	if ( not( $journey_id and $journey_id =~ m{ ^ \d+ $ }x ) ) {
		$self->render(
			'journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->get_journey(
		uid           => $uid,
		journey_id    => $journey_id,
		verbose       => 1,
		with_datetime => 1,
	);

	if ($journey) {
		$self->render(
			'journey',
			error   => undef,
			journey => $journey,
		);
	}
	else {
		$self->render(
			'journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
	}

}

sub comment_form {
	my ($self) = @_;
	my $dep_ts = $self->param('dep_ts');
	my $status = $self->get_user_status;

	if ( not $status->{checked_in} ) {
		$self->render(
			'edit_comment',
			error   => 'notfound',
			journey => {}
		);
	}
	elsif ( not $dep_ts ) {
		$self->param( dep_ts  => $status->{sched_departure}->epoch );
		$self->param( comment => $status->{comment} );
		$self->render(
			'edit_comment',
			error   => undef,
			journey => $status
		);
	}
	elsif ( $self->validation->csrf_protect->has_error('csrf_token') ) {
		$self->render(
			'edit_comment',
			error   => undef,
			journey => $status
		);
	}
	elsif ( $dep_ts != $status->{sched_departure}->epoch ) {

		# TODO find and update appropriate past journey (if it exists)
		$self->param( comment => $status->{comment} );
		$self->render(
			'edit_comment',
			error   => undef,
			journey => $status
		);
	}
	else {
		$self->app->log->debug("set comment");
		$self->update_in_transit_comment( $self->param('comment') );
		$self->redirect_to('/');
	}
}

sub edit_journey {
	my ($self)     = @_;
	my $journey_id = $self->param('journey_id');
	my $uid        = $self->current_user->{id};

	if ( not( $journey_id =~ m{ ^ \d+ $ }x ) ) {
		$self->render(
			'edit_journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->get_journey(
		uid           => $uid,
		journey_id    => $journey_id,
		verbose       => 1,
		with_datetime => 1,
	);

	if ( not $journey ) {
		$self->render(
			'edit_journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $error = undef;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);

		my $db = $self->pg->db;
		my $tx = $db->begin;

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			my $datetime = $parser->parse_datetime( $self->param($key) );
			if ( $datetime and $datetime->epoch ne $journey->{$key}->epoch ) {
				$error = $self->update_journey_part( $db, $journey->{id},
					$key, $datetime );
				if ($error) {
					last;
				}
			}
		}
		for my $key (qw(comment)) {
			if (
				defined $self->param($key)
				and ( not $journey->{user_data}
					or $journey->{user_data}{$key} ne $self->param($key) )
			  )
			{
				$error = $self->update_journey_part( $db, $journey->{id}, $key,
					$self->param($key) );
				if ($error) {
					last;
				}
			}
		}
		if ( defined $self->param('route') ) {
			my @route_old = map { $_->[0] } @{ $journey->{route} };
			my @route_new = split( qr{\r?\n\r?}, $self->param('route') );
			@route_new = grep { $_ ne '' } @route_new;
			if ( join( '|', @route_old ) ne join( '|', @route_new ) ) {
				$error
				  = $self->update_journey_part( $db, $journey->{id}, 'route',
					[@route_new] );
			}
		}
		{
			my $cancelled_old = $journey->{cancelled};
			my $cancelled_new = $self->param('cancelled') // 0;
			if ( $cancelled_old != $cancelled_new ) {
				$error
				  = $self->update_journey_part( $db, $journey->{id},
					'cancelled', $cancelled_new );
			}
		}

		if ( not $error ) {
			$journey = $self->get_journey(
				uid           => $uid,
				db            => $db,
				journey_id    => $journey_id,
				verbose       => 1,
				with_datetime => 1,
			);
			$error = $self->journey_sanity_check($journey);
		}
		if ( not $error ) {
			$tx->commit;
			$self->redirect_to("/journey/${journey_id}");
			return;
		}
	}

	for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival)) {
		if ( $journey->{$key} and $journey->{$key}->epoch ) {
			$self->param(
				$key => $journey->{$key}->strftime('%d.%m.%Y %H:%M') );
		}
	}

	$self->param(
		route => join( "\n", map { $_->[0] } @{ $journey->{route} } ) );

	$self->param( cancelled => $journey->{cancelled} );

	for my $key (qw(comment)) {
		if ( $journey->{user_data} and $journey->{user_data}{$key} ) {
			$self->param( $key => $journey->{user_data}{$key} );
		}
	}

	$self->render(
		'edit_journey',
		error   => $error,
		journey => $journey
	);
}

sub add_journey_form {
	my ($self) = @_;

	if ( $self->param('action') and $self->param('action') eq 'save' ) {
		my $parser = DateTime::Format::Strptime->new(
			pattern   => '%d.%m.%Y %H:%M',
			locale    => 'de_DE',
			time_zone => 'Europe/Berlin'
		);
		my %opt;

		my @parts = split( qr{\s+}, $self->param('train') );

		if ( @parts == 2 ) {
			@opt{ 'train_type', 'train_no' } = @parts;
		}
		elsif ( @parts == 3 ) {
			@opt{ 'train_type', 'train_line', 'train_no' } = @parts;
		}
		else {
			$self->render(
				'add_journey',
				with_autocomplete => 1,
				error =>
'Zug muss als „Typ Nummer“ oder „Typ Linie Nummer“ eingegeben werden.'
			);
			return;
		}

		for my $key (qw(sched_departure rt_departure sched_arrival rt_arrival))
		{
			if ( $self->param($key) ) {
				my $datetime = $parser->parse_datetime( $self->param($key) );
				if ( not $datetime ) {
					$self->render(
						'add_journey',
						with_autocomplete => 1,
						error => "${key}: Ungültiges Datums-/Zeitformat"
					);
					return;
				}
				$opt{$key} = $datetime;
			}
		}

		$opt{rt_departure} //= $opt{sched_departure};
		$opt{rt_arrival}   //= $opt{sched_arrival};

		for my $key (qw(dep_station arr_station route cancelled comment)) {
			$opt{$key} = $self->param($key);
		}

		if ( $opt{route} ) {
			$opt{route} = [ split( qr{\r?\n\r?}, $opt{route} ) ];
		}

		my $db = $self->pg->db;
		my $tx = $db->begin;

		$opt{db} = $db;

		my ( $journey_id, $error ) = $self->add_journey(%opt);

		if ( not $error ) {
			my $journey = $self->get_journey(
				uid        => $self->current_user->{id},
				db         => $db,
				journey_id => $journey_id,
				verbose    => 1
			);
			$error = $self->journey_sanity_check($journey);
		}

		if ($error) {
			$self->render(
				'add_journey',
				with_autocomplete => 1,
				error             => $error,
			);
		}
		else {
			$tx->commit;
			$self->redirect_to("/journey/${journey_id}");
		}
	}
	else {
		$self->render(
			'add_journey',
			with_autocomplete => 1,
			error             => undef
		);
	}
}

1;
