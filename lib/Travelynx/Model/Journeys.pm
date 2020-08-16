package Travelynx::Model::Journeys;

use Geo::Distance;
use List::MoreUtils qw(after_incl before_incl);
use Travel::Status::DE::IRIS::Stations;

use strict;
use warnings;
use 5.020;

use DateTime;
use JSON;

sub epoch_to_dt {
	my ($epoch) = @_;

	# Bugs (and user errors) may lead to undefined timestamps. Set them to
	# 1970-01-01 to avoid crashing and show obviously wrong data instead.
	$epoch //= 0;

	return DateTime->from_epoch(
		epoch     => $epoch,
		time_zone => 'Europe/Berlin',
		locale    => 'de-DE',
	);
}

sub get_station {
	my ( $station_name, $exact_match ) = @_;

	my @candidates
	  = Travel::Status::DE::IRIS::Stations::get_station($station_name);

	if ( @candidates == 1 ) {
		if ( not $exact_match ) {
			return $candidates[0];
		}
		if (   $candidates[0][0] eq $station_name
			or $candidates[0][1] eq $station_name
			or $candidates[0][2] eq $station_name )
		{
			return $candidates[0];
		}
		return undef;
	}
	return undef;
}

sub grep_unknown_stations {
	my (@stations) = @_;

	my @unknown_stations;
	for my $station (@stations) {
		my $station_info = get_station($station);
		if ( not $station_info ) {
			push( @unknown_stations, $station );
		}
	}
	return @unknown_stations;
}

sub new {
	my ( $class, %opt ) = @_;

	$opt{journey_edit_mask} = {
		sched_departure => 0x0001,
		real_departure  => 0x0002,
		from_station    => 0x0004,
		route           => 0x0010,
		is_cancelled    => 0x0020,
		sched_arrival   => 0x0100,
		real_arrival    => 0x0200,
		to_station      => 0x0400,
	};

	return bless( \%opt, $class );
}

# Returns (journey id, error)
# Must be called during a transaction.
# Must perform a rollback on error.
sub add {
	my ( $self, %opt ) = @_;

	my $db          = $opt{db};
	my $uid         = $opt{uid};
	my $now         = DateTime->now( time_zone => 'Europe/Berlin' );
	my $dep_station = get_station( $opt{dep_station} );
	my $arr_station = get_station( $opt{arr_station} );

	if ( not $dep_station ) {
		return ( undef, 'Unbekannter Startbahnhof' );
	}
	if ( not $arr_station ) {
		return ( undef, 'Unbekannter Zielbahnhof' );
	}

	my $daily_journey_count = $db->select(
		'journeys_str',
		'count(*) as count',
		{
			user_id     => $uid,
			real_dep_ts => {
				-between => [
					$opt{rt_departure}->clone->subtract( days => 1 )->epoch,
					$opt{rt_departure}->epoch
				],
			},
		}
	)->hash->{count};

	if ( $daily_journey_count >= 100 ) {
		return ( undef,
"In den 24 Stunden vor der angegebenen Abfahrtszeit wurden ${daily_journey_count} weitere Fahrten angetreten. Das kann nicht stimmen."
		);
	}

	my @route = ( [ $dep_station->[1], {}, undef ] );

	if ( $opt{route} ) {
		my @unknown_stations;
		for my $station ( @{ $opt{route} } ) {
			my $station_info = get_station($station);
			if ($station_info) {
				push( @route, [ $station_info->[1], {}, undef ] );
			}
			else {
				push( @route, [ $station, {}, undef ] );
				push( @unknown_stations, $station );
			}
		}

		if ( not $opt{lax} ) {
			if ( @unknown_stations == 1 ) {
				return ( undef,
					"Unbekannter Unterwegshalt: $unknown_stations[0]" );
			}
			elsif (@unknown_stations) {
				return ( undef,
					'Unbekannte Unterwegshalte: '
					  . join( ', ', @unknown_stations ) );
			}
		}
	}

	push( @route, [ $arr_station->[1], {}, undef ] );

	if ( $route[0][0] eq $route[1][0] ) {
		shift(@route);
	}

	if ( $route[-2][0] eq $route[-1][0] ) {
		pop(@route);
	}

	my $entry = {
		user_id             => $uid,
		train_type          => $opt{train_type},
		train_line          => $opt{train_line},
		train_no            => $opt{train_no},
		train_id            => 'manual',
		checkin_station_id  => $dep_station->[2],
		checkin_time        => $now,
		sched_departure     => $opt{sched_departure},
		real_departure      => $opt{rt_departure},
		checkout_station_id => $arr_station->[2],
		sched_arrival       => $opt{sched_arrival},
		real_arrival        => $opt{rt_arrival},
		checkout_time       => $now,
		edited              => 0x3fff,
		cancelled           => $opt{cancelled} ? 1 : 0,
		route               => JSON->new->encode( \@route ),
	};

	if ( $opt{comment} ) {
		$entry->{user_data}
		  = JSON->new->encode( { comment => $opt{comment} } );
	}

	my $journey_id = undef;
	eval {
		$journey_id
		  = $db->insert( 'journeys', $entry, { returning => 'id' } )
		  ->hash->{id};
		$self->invalidate_stats_cache(
			ts  => $opt{rt_departure},
			db  => $db,
			uid => $uid
		);
	};

	if ($@) {
		$self->{log}->error("add_journey($uid): $@");
		return ( undef, 'add_journey failed: ' . $@ );
	}

	return ( $journey_id, undef );
}

sub update {
	my ( $self, %opt ) = @_;

	my $db         = $opt{db} // $self->{pg}->db;
	my $uid        = $opt{uid};
	my $journey_id = $opt{id};

	my $rows;

	my $journey = $self->get_single(
		uid           => $uid,
		db            => $db,
		journey_id    => $journey_id,
		with_datetime => 1,
	);

	eval {
		if ( exists $opt{from_name} ) {
			my $from_station = get_station( $opt{from_name}, 1 );
			if ( not $from_station ) {
				die("Unbekannter Startbahnhof\n");
			}
			$rows = $db->update(
				'journeys',
				{
					checkin_station_id => $from_station->[2],
					edited             => $journey->{edited} | 0x0004,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{to_name} ) {
			my $to_station = get_station( $opt{to_name}, 1 );
			if ( not $to_station ) {
				die("Unbekannter Zielbahnhof\n");
			}
			$rows = $db->update(
				'journeys',
				{
					checkout_station_id => $to_station->[2],
					edited              => $journey->{edited} | 0x0400,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{sched_departure} ) {
			$rows = $db->update(
				'journeys',
				{
					sched_departure => $opt{sched_departure},
					edited          => $journey->{edited} | 0x0001,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{rt_departure} ) {
			$rows = $db->update(
				'journeys',
				{
					real_departure => $opt{rt_departure},
					edited         => $journey->{edited} | 0x0002,
				},
				{
					id => $journey_id,
				}
			)->rows;

			# stats are partitioned by rt_departure -> both the cache for
			# the old value (see bottom of this function) and the new value
			# (here) must be invalidated.
			$self->invalidate_stats_cache(
				ts  => $opt{rt_departure},
				db  => $db,
				uid => $uid,
			);
		}
		if ( exists $opt{sched_arrival} ) {
			$rows = $db->update(
				'journeys',
				{
					sched_arrival => $opt{sched_arrival},
					edited        => $journey->{edited} | 0x0100,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{rt_arrival} ) {
			$rows = $db->update(
				'journeys',
				{
					real_arrival => $opt{rt_arrival},
					edited       => $journey->{edited} | 0x0200,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{route} ) {
			my @new_route = map { [ $_, {}, undef ] } @{ $opt{route} };
			$rows = $db->update(
				'journeys',
				{
					route  => JSON->new->encode( \@new_route ),
					edited => $journey->{edited} | 0x0010,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{cancelled} ) {
			$rows = $db->update(
				'journeys',
				{
					cancelled => $opt{cancelled},
					edited    => $journey->{edited} | 0x0020,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{comment} ) {
			$journey->{user_data}{comment} = $opt{comment};
			$rows = $db->update(
				'journeys',
				{
					user_data => JSON->new->encode( $journey->{user_data} ),
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( not defined $rows ) {
			die("Invalid update key\n");
		}
	};

	if ($@) {
		$self->{log}->error("update($journey_id): $@");
		return "update($journey_id): $@";
	}
	if ( $rows == 1 ) {
		$self->invalidate_stats_cache(
			ts  => $journey->{rt_departure},
			db  => $db,
			uid => $uid,
		);
		return undef;
	}
	return "update($journey_id): did not match any journey part";
}

sub delete {
	my ( $self, %opt ) = @_;

	my $uid            = $opt{uid};
	my $db             = $opt{db} // $self->{pg}->db;
	my $journey_id     = $opt{id};
	my $checkin_epoch  = $opt{checkin};
	my $checkout_epoch = $opt{checkout};

	my @journeys = $self->get(
		uid        => $uid,
		journey_id => $journey_id
	);
	if ( @journeys == 0 ) {
		return 'Journey not found';
	}
	my $journey = $journeys[0];

	# Double-check (comparing both ID and action epoch) to make sure we
	# are really deleting the right journey and the user isn't just
	# playing around with POST requests.
	if (   $journey->{id} != $journey_id
		or $journey->{checkin_ts} != $checkin_epoch
		or $journey->{checkout_ts} != $checkout_epoch )
	{
		return 'Invalid journey data';
	}

	my $rows;
	eval {
		$rows = $db->delete(
			'journeys',
			{
				user_id => $uid,
				id      => $journey_id,
			}
		)->rows;
	};

	if ($@) {
		$self->{log}->error("Delete($uid, $journey_id): $@");
		return 'DELETE failed: ' . $@;
	}

	if ( $rows == 1 ) {
		$self->invalidate_stats_cache(
			ts  => epoch_to_dt( $journey->{rt_dep_ts} ),
			uid => $uid
		);
		return undef;
	}
	return sprintf( 'Deleted %d rows, expected 1', $rows );
}

sub get {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};

	# If get is called from inside a transaction, db
	# specifies the database handle performing the transaction.
	# Otherwise, we grab a fresh one.
	my $db = $opt{db} // $self->{pg}->db;

	my @select
	  = (
		qw(journey_id train_type train_line train_no checkin_ts sched_dep_ts real_dep_ts dep_eva checkout_ts sched_arr_ts real_arr_ts arr_eva cancelled edited route messages user_data)
	  );
	my %where = (
		user_id   => $uid,
		cancelled => 0
	);
	my %order = (
		order_by => {
			-desc => 'real_dep_ts',
		}
	);

	if ( $opt{cancelled} ) {
		$where{cancelled} = 1;
	}

	if ( $opt{limit} ) {
		$order{limit} = $opt{limit};
	}

	if ( $opt{journey_id} ) {
		$where{journey_id} = $opt{journey_id};
		delete $where{cancelled};
	}
	elsif ( $opt{after} and $opt{before} ) {
		$where{real_dep_ts}
		  = { -between => [ $opt{after}->epoch, $opt{before}->epoch, ] };
	}

	if ( $opt{with_polyline} ) {
		push( @select, 'polyline' );
	}

	my @travels;

	my $res = $db->select( 'journeys_str', \@select, \%where, \%order );

	for my $entry ( $res->expand->hashes->each ) {

		my $ref = {
			id           => $entry->{journey_id},
			type         => $entry->{train_type},
			line         => $entry->{train_line},
			no           => $entry->{train_no},
			from_eva     => $entry->{dep_eva},
			checkin_ts   => $entry->{checkin_ts},
			sched_dep_ts => $entry->{sched_dep_ts},
			rt_dep_ts    => $entry->{real_dep_ts},
			to_eva       => $entry->{arr_eva},
			checkout_ts  => $entry->{checkout_ts},
			sched_arr_ts => $entry->{sched_arr_ts},
			rt_arr_ts    => $entry->{real_arr_ts},
			messages     => $entry->{messages},
			route        => $entry->{route},
			edited       => $entry->{edited},
			user_data    => $entry->{user_data},
		};

		if ( $opt{with_polyline} ) {
			$ref->{polyline} = $entry->{polyline};
		}

		if ( my $station = $self->{station_by_eva}->{ $ref->{from_eva} } ) {
			$ref->{from_ds100} = $station->[0];
			$ref->{from_name}  = $station->[1];
		}
		if ( my $station = $self->{station_by_eva}->{ $ref->{to_eva} } ) {
			$ref->{to_ds100} = $station->[0];
			$ref->{to_name}  = $station->[1];
		}

		if ( $opt{with_datetime} ) {
			$ref->{checkin} = epoch_to_dt( $ref->{checkin_ts} );
			$ref->{sched_departure}
			  = epoch_to_dt( $ref->{sched_dep_ts} );
			$ref->{rt_departure}  = epoch_to_dt( $ref->{rt_dep_ts} );
			$ref->{checkout}      = epoch_to_dt( $ref->{checkout_ts} );
			$ref->{sched_arrival} = epoch_to_dt( $ref->{sched_arr_ts} );
			$ref->{rt_arrival}    = epoch_to_dt( $ref->{rt_arr_ts} );
		}

		if ( $opt{verbose} ) {
			my $rename = $self->{renamed_station};
			for my $stop ( @{ $ref->{route} } ) {
				if ( $rename->{ $stop->[0] } ) {
					$stop->[0] = $rename->{ $stop->[0] };
				}
			}
			$ref->{cancelled} = $entry->{cancelled};
			my @parsed_messages;
			for my $message ( @{ $ref->{messages} // [] } ) {
				my ( $ts, $msg ) = @{$message};
				push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
			}
			$ref->{messages} = [ reverse @parsed_messages ];
			$ref->{sched_duration}
			  = defined $ref->{sched_arr_ts}
			  ? $ref->{sched_arr_ts} - $ref->{sched_dep_ts}
			  : undef;
			$ref->{rt_duration}
			  = defined $ref->{rt_arr_ts}
			  ? $ref->{rt_arr_ts} - $ref->{rt_dep_ts}
			  : undef;
			my ( $km_polyline, $km_route, $km_beeline, $skip )
			  = $self->get_travel_distance($ref);
			$ref->{km_route}     = $km_polyline || $km_route;
			$ref->{skip_route}   = $km_polyline ? 0 : $skip;
			$ref->{km_beeline}   = $km_beeline;
			$ref->{skip_beeline} = $skip;
			my $kmh_divisor
			  = ( $ref->{rt_duration} // $ref->{sched_duration} // 999999 )
			  / 3600;
			$ref->{kmh_route}
			  = $kmh_divisor ? $ref->{km_route} / $kmh_divisor : -1;
			$ref->{kmh_beeline}
			  = $kmh_divisor
			  ? $ref->{km_beeline} / $kmh_divisor
			  : -1;
		}

		push( @travels, $ref );
	}

	return @travels;
}

sub get_single {
	my ( $self, %opt ) = @_;

	$opt{cancelled} = 'any';
	my @journeys = $self->get(%opt);
	if ( @journeys == 0 ) {
		return undef;
	}

	return $journeys[0];
}

sub get_oldest_ts {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $res_h = $db->select(
		'journeys_str',
		['sched_dep_ts'],
		{
			user_id => $uid,
		},
		{
			limit    => 1,
			order_by => {
				-asc => 'real_dep_ts',
			},
		}
	)->hash;

	if ($res_h) {
		return epoch_to_dt( $res_h->{sched_dep_ts} );
	}
	return undef;
}

sub sanity_check {
	my ( $self, $journey, $lax ) = @_;

	if ( defined $journey->{sched_duration}
		and $journey->{sched_duration} <= 0 )
	{
		return
'Die geplante Dauer dieser Zugfahrt ist ≤ 0. Teleportation und Zeitreisen werden aktuell nicht unterstützt.';
	}
	if ( defined $journey->{rt_duration}
		and $journey->{rt_duration} <= 0 )
	{
		return
'Die Dauer dieser Zugfahrt ist ≤ 0. Teleportation und Zeitreisen werden aktuell nicht unterstützt.';
	}
	if (    $journey->{sched_duration}
		and $journey->{sched_duration} > 60 * 60 * 24 )
	{
		return 'Die Zugfahrt ist länger als 24 Stunden.';
	}
	if (    $journey->{rt_duration}
		and $journey->{rt_duration} > 60 * 60 * 24 )
	{
		return 'Die Zugfahrt ist länger als 24 Stunden.';
	}
	if ( $journey->{kmh_route} > 500 or $journey->{kmh_beeline} > 500 ) {
		return 'Zugfahrten mit über 500 km/h? Schön wär\'s.';
	}
	if ( $journey->{route} and @{ $journey->{route} } > 99 ) {
		my $stop_count = @{ $journey->{route} };
		return
"Die Zugfahrt hat $stop_count Unterwegshalte. Also ich weiß ja nicht so recht.";
	}
	if ( $journey->{edited} & 0x0010 and not $lax ) {
		my @unknown_stations
		  = grep_unknown_stations( map { $_->[0] } @{ $journey->{route} } );
		if (@unknown_stations) {
			return 'Unbekannte Station(en): ' . join( ', ', @unknown_stations );
		}
	}

	return undef;
}

sub get_travel_distance {
	my ( $self, $journey ) = @_;

	my $from         = $journey->{from_name};
	my $from_eva     = $journey->{from_eva};
	my $to           = $journey->{to_name};
	my $to_eva       = $journey->{to_eva};
	my $route_ref    = $journey->{route};
	my $polyline_ref = $journey->{polyline};

	my $distance_polyline     = 0;
	my $distance_intermediate = 0;
	my $distance_beeline      = 0;
	my $skipped               = 0;
	my $geo                   = Geo::Distance->new();
	my @stations              = map { $_->[0] } @{$route_ref};
	my @route                 = after_incl { $_ eq $from } @stations;
	@route = before_incl { $_ eq $to } @route;

	if ( @route < 2 ) {

		# I AM ERROR
		return ( 0, 0, 0 );
	}

	my @polyline = after_incl { $_->[2] and $_->[2] == $from_eva }
	@{ $polyline_ref // [] };
	@polyline
	  = before_incl { $_->[2] and $_->[2] == $to_eva } @polyline;

	my $prev_station = shift @polyline;
	for my $station (@polyline) {

		#lonlatlonlat
		$distance_polyline
		  += $geo->distance( 'kilometer', $prev_station->[0],
			$prev_station->[1], $station->[0], $station->[1] );
		$prev_station = $station;
	}

	$prev_station = get_station( shift @route );
	if ( not $prev_station ) {
		return ( $distance_polyline, 0, 0 );
	}

	# Geo-coordinates for stations outside Germany are not available
	# at the moment. When calculating distance with intermediate stops,
	# these are simply left out (as if they were not part of the route).
	# For beeline distance calculation, we use the route's first and last
	# station with known geo-coordinates.
	my $from_station_beeline;
	my $to_station_beeline;

	# $#{$station} >= 4    iff    $station has geocoordinates
	for my $station_name (@route) {
		if ( my $station = get_station($station_name) ) {
			if ( not $from_station_beeline and $#{$prev_station} >= 4 ) {
				$from_station_beeline = $prev_station;
			}
			if ( $#{$station} >= 4 ) {
				$to_station_beeline = $station;
			}
			if ( $#{$prev_station} >= 4 and $#{$station} >= 4 ) {
				$distance_intermediate
				  += $geo->distance( 'kilometer', $prev_station->[3],
					$prev_station->[4], $station->[3], $station->[4] );
			}
			else {
				$skipped++;
			}
			$prev_station = $station;
		}
	}

	if ( $from_station_beeline and $to_station_beeline ) {
		$distance_beeline = $geo->distance(
			'kilometer',                $from_station_beeline->[3],
			$from_station_beeline->[4], $to_station_beeline->[3],
			$to_station_beeline->[4]
		);
	}

	return ( $distance_polyline, $distance_intermediate,
		$distance_beeline, $skipped );
}

# Statistics are partitioned by real_departure, which must be provided
# when calling this function e.g. after journey deletion or editing.
# If a joureny's real_departure has been edited, this function must be
# called twice: once with the old and once with the new value.
sub invalidate_stats_cache {
	my ( $self, %opt ) = @_;

	my $ts  = $opt{ts};
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	$db->delete(
		'journey_stats',
		{
			user_id => $uid,
			year    => $ts->year,
			month   => $ts->month,
		}
	);
	$db->delete(
		'journey_stats',
		{
			user_id => $uid,
			year    => $ts->year,
			month   => 0,
		}
	);
}

1;
