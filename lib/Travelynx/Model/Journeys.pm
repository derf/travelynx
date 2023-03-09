package Travelynx::Model::Journeys;

# Copyright (C) 2020-2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use GIS::Distance;
use List::MoreUtils qw(after_incl before_incl);

use strict;
use warnings;
use 5.020;
use utf8;

use DateTime;
use JSON;

my %visibility_itoa = (
	100 => 'public',
	80  => 'travelynx',
	60  => 'followers',
	30  => 'unlisted',
	10  => 'private',
);

my %visibility_atoi = (
	public    => 100,
	travelynx => 80,
	followers => 60,
	unlisted  => 30,
	private   => 10,
);

my @month_name
  = (
	qw(Januar Februar März April Mai Juni Juli August September Oktober November Dezember)
  );

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

sub min_to_human {
	my ($minutes) = @_;

	my @ret;

	if ( $minutes >= 14 * 24 * 60 ) {
		push( @ret, int( $minutes / ( 7 * 24 * 60 ) ) . ' Wochen' );
	}
	elsif ( $minutes >= 7 * 24 * 60 ) {
		push( @ret, '1 Woche' );
	}
	$minutes %= 7 * 24 * 60;

	if ( $minutes >= 2 * 24 * 60 ) {
		push( @ret, int( $minutes / ( 24 * 60 ) ) . ' Tage' );
	}
	elsif ( $minutes >= 24 * 60 ) {
		push( @ret, '1 Tag' );
	}
	$minutes %= 24 * 60;

	if ( $minutes >= 2 * 60 ) {
		push( @ret, int( $minutes / 60 ) . ' Stunden' );
	}
	elsif ( $minutes >= 60 ) {
		push( @ret, '1 Stunde' );
	}
	$minutes %= 60;

	if ( $minutes >= 2 ) {
		push( @ret, "$minutes Minuten" );
	}
	elsif ($minutes) {
		push( @ret, '1 Minute' );
	}

	if ( @ret == 0 ) {
		return '0 Minuten';
	}

	if ( @ret == 1 ) {
		return $ret[0];
	}

	my $last = pop(@ret);
	return join( ', ', @ret ) . " und $last";
}

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub stats_cache {
	my ($self) = @_;
	return $self->{stats_cache};
}

# Returns (journey id, error)
# Must be called during a transaction.
# Must perform a rollback on error.
sub add {
	my ( $self, %opt ) = @_;

	my $db          = $opt{db};
	my $uid         = $opt{uid};
	my $now         = DateTime->now( time_zone => 'Europe/Berlin' );
	my $dep_station = $self->{stations}->search( $opt{dep_station} );
	my $arr_station = $self->{stations}->search( $opt{arr_station} );

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

	my $route_has_start = 0;
	my $route_has_stop  = 0;

	for my $station ( @{ $opt{route} || [] } ) {
		if (   $station eq $dep_station->{name}
			or $station eq $dep_station->{ds100} )
		{
			$route_has_start = 1;
		}
		if (   $station eq $arr_station->{name}
			or $station eq $arr_station->{ds100} )
		{
			$route_has_stop = 1;
		}
	}

	my @route;

	if ( not $route_has_start ) {
		push( @route, [ $dep_station->{name}, $dep_station->{eva}, {} ] );
	}

	if ( $opt{route} ) {
		my @unknown_stations;
		for my $station ( @{ $opt{route} } ) {
			my $station_info = $self->{stations}->search($station);
			if ($station_info) {
				push( @route,
					[ $station_info->{name}, $station_info->{eva}, {} ] );
			}
			else {
				push( @route,            [ $station, undef, {} ] );
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

	if ( not $route_has_stop ) {
		push( @route, [ $arr_station->{name}, $arr_station->{eva}, {} ] );
	}

	my $entry = {
		user_id             => $uid,
		train_type          => $opt{train_type},
		train_line          => $opt{train_line},
		train_no            => $opt{train_no},
		train_id            => 'manual',
		checkin_station_id  => $dep_station->{eva},
		checkin_time        => $now,
		sched_departure     => $opt{sched_departure},
		real_departure      => $opt{rt_departure},
		checkout_station_id => $arr_station->{eva},
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
		$self->stats_cache->invalidate(
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

sub add_from_in_transit {
	my ( $self, %opt ) = @_;
	my $db      = $opt{db};
	my $journey = $opt{journey};

	delete $journey->{data};
	$journey->{edited}        = 0;
	$journey->{checkout_time} = DateTime->now( time_zone => 'Europe/Berlin' );

	$db->insert( 'journeys', $journey );
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
			my $from_station = $self->{stations}->search( $opt{from_name} );
			if ( not $from_station ) {
				die("Unbekannter Startbahnhof\n");
			}
			$rows = $db->update(
				'journeys',
				{
					checkin_station_id => $from_station->{eva},
					edited             => $journey->{edited} | 0x0004,
				},
				{
					id => $journey_id,
				}
			)->rows;
		}
		if ( exists $opt{to_name} ) {
			my $to_station = $self->{stations}->search( $opt{to_name} );
			if ( not $to_station ) {
				die("Unbekannter Zielbahnhof\n");
			}
			$rows = $db->update(
				'journeys',
				{
					checkout_station_id => $to_station->{eva},
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
			$self->stats_cache->invalidate(
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
			my @new_route = map { [ $_, undef, {} ] } @{ $opt{route} };
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
		$self->stats_cache->invalidate(
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
		$self->stats_cache->invalidate(
			ts  => epoch_to_dt( $journey->{rt_dep_ts} ),
			uid => $uid
		);
		return undef;
	}
	return sprintf( 'Deleted %d rows, expected 1', $rows );
}

# Used for undo (move journey entry to in_transit)
sub pop {
	my ( $self, %opt ) = @_;

	my $uid        = $opt{uid};
	my $db         = $opt{db};
	my $journey_id = $opt{journey_id};

	my $journey = $db->select(
		'journeys',
		'*',
		{
			user_id => $uid,
			id      => $journey_id
		}
	)->hash;

	$db->delete(
		'journeys',
		{
			user_id => $uid,
			id      => $journey_id
		}
	);

	return $journey;
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
		qw(journey_id train_type train_line train_no checkin_ts sched_dep_ts real_dep_ts dep_eva dep_ds100 dep_name dep_lat dep_lon checkout_ts sched_arr_ts real_arr_ts arr_eva arr_ds100 arr_name arr_lat arr_lon cancelled edited route messages user_data visibility)
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

	if ( $opt{sched_dep_ts} ) {
		$where{sched_dep_ts} = $opt{sched_dep_ts};
	}

	if ( $opt{journey_id} ) {
		$where{journey_id} = $opt{journey_id};
		delete $where{cancelled};
	}
	elsif ( $opt{after} and $opt{before} ) {
		$where{real_dep_ts}
		  = { -between => [ $opt{after}->epoch, $opt{before}->epoch, ] };
	}
	elsif ( $opt{after} ) {
		$where{real_dep_ts} = { '>=', $opt{after}->epoch };
	}
	elsif ( $opt{before} ) {
		$where{real_dep_ts} = { '<=', $opt{before}->epoch };
	}

	if ( $opt{with_polyline} ) {
		push( @select, 'polyline' );
	}

	if ( $opt{min_visibility} ) {
		if ( $visibility_atoi{ $opt{min_visibility} } ) {
			$opt{min_visibility} = $visibility_atoi{ $opt{min_visibility} };
		}
		if ( $opt{with_default_visibility} ) {
			$where{visibility} = [
				-or => { '=', undef },
				{ '>=', $opt{min_visibility} }
			];
		}
		else {
			$where{visibility} = [
				-and => { '!=', undef },
				{ '>=', $opt{min_visibility} }
			];
		}
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
			from_ds100   => $entry->{dep_ds100},
			from_name    => $entry->{dep_name},
			from_latlon  => [ $entry->{dep_lat}, $entry->{dep_lon} ],
			checkin_ts   => $entry->{checkin_ts},
			sched_dep_ts => $entry->{sched_dep_ts},
			rt_dep_ts    => $entry->{real_dep_ts},
			to_eva       => $entry->{arr_eva},
			to_ds100     => $entry->{arr_ds100},
			to_name      => $entry->{arr_name},
			to_latlon    => [ $entry->{arr_lat}, $entry->{arr_lon} ],
			checkout_ts  => $entry->{checkout_ts},
			sched_arr_ts => $entry->{sched_arr_ts},
			rt_arr_ts    => $entry->{real_arr_ts},
			messages     => $entry->{messages},
			route        => $entry->{route},
			edited       => $entry->{edited},
			user_data    => $entry->{user_data},
			visibility   => $entry->{visibility},
		};

		if ( $opt{with_visibility} ) {
			$ref->{visibility_str}
			  = $ref->{visibility}
			  ? $visibility_itoa{ $ref->{visibility} }
			  : 'default';
		}

		if ( $opt{with_polyline} ) {
			$ref->{polyline} = $entry->{polyline};
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
				if ( $stop->[0] =~ m{^Betriebsstelle nicht bekannt (\d+)$} ) {
					if ( my $s = $self->{stations}->get_by_eva($1) ) {
						$stop->[0] = $s->{name};
					}
				}
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

sub get_latest {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $latest_successful = $db->select(
		'journeys_str',
		'*',
		{
			user_id   => $uid,
			cancelled => 0
		},
		{
			order_by => { -desc => 'journey_id' },
			limit    => 1
		}
	)->expand->hash;

	$latest_successful->{visibility_str}
	  = $latest_successful->{visibility}
	  ? $visibility_itoa{ $latest_successful->{visibility} }
	  : 'default';

	my $latest = $db->select(
		'journeys_str',
		'*',
		{
			user_id => $uid,
		},
		{
			order_by => { -desc => 'journey_id' },
			limit    => 1
		}
	)->expand->hash;

	$latest->{visibility_str}
	  = $latest->{visibility}
	  ? $visibility_itoa{ $latest->{visibility} }
	  : 'default';

	return ( $latest_successful, $latest );
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

sub get_latest_checkout_station_id {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $res_h = $db->select(
		'journeys',
		['checkout_station_id'],
		{
			user_id   => $uid,
			cancelled => 0
		},
		{
			limit    => 1,
			order_by => { -desc => 'real_departure' }
		}
	)->hash;

	if ( not $res_h ) {
		return;
	}

	return $res_h->{checkout_station_id};
}

sub get_latest_checkout_stations {
	my ( $self, %opt ) = @_;
	my $uid   = $opt{uid};
	my $db    = $opt{db}    // $self->{pg}->db;
	my $limit = $opt{limit} // 5;

	my $res = $db->select(
		'journeys_str',
		[ 'arr_name', 'arr_eva' ],
		{
			user_id   => $uid,
			cancelled => 0
		},
		{
			limit    => $limit,
			order_by => { -desc => 'journey_id' }
		}
	);

	if ( not $res ) {
		return;
	}

	my @ret;

	while ( my $row = $res->hash ) {
		push(
			@ret,
			{
				name => $row->{arr_name},
				eva  => $row->{arr_eva}
			}
		);
	}

	return @ret;
}

sub get_nav_years {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $res = $db->select(
		'journeys',
		'distinct extract(year from real_departure) as year',
		{ user_id  => $uid },
		{ order_by => { -asc => 'year' } }
	);

	my @ret;
	for my $row ( $res->hashes->each ) {
		push( @ret, [ $row->{year}, $row->{year} ] );
	}
	return @ret;
}

sub get_years {
	my ( $self, %opt ) = @_;

	my @years = $self->get_nav_years(%opt);

	for my $year (@years) {
		my $stats = $self->stats_cache->get(
			uid   => $opt{uid},
			year  => $year,
			month => 0,
		);
		$year->[2] = $stats // {};
	}
	return @years;
}

sub get_months_for_year {
	my ( $self, %opt ) = @_;

	my $uid  = $opt{uid};
	my $db   = $opt{db} // $self->{pg}->db;
	my $year = $opt{year};

	my $res = $db->select(
		'journeys',
'distinct extract(year from real_departure) as year, extract(month from real_departure) as month',
		{ user_id  => $uid },
		{ order_by => { -asc => 'year' } }
	);

	my @ret;

	for my $month ( 1 .. 12 ) {
		push( @ret,
			[ sprintf( '%d/%02d', $year, $month ), $month_name[ $month - 1 ] ]
		);
	}

	for my $row ( $res->hashes->each ) {
		if ( $row->{year} == $year ) {

			my $stats = $self->stats_cache->get(
				db    => $db,
				uid   => $uid,
				year  => $year,
				month => $row->{month}
			);

			# undef -> no journeys for this month; empty hash -> no cached stats
			$ret[ $row->{month} - 1 ][2] = $stats // {};
		}
	}
	return @ret;
}

sub get_yyyymm_having_journeys {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;
	my $res = $db->select(
		'journeys',
		"distinct to_char(real_departure, 'YYYY.MM') as yearmonth",
		{ user_id  => $uid },
		{ order_by => { -asc => 'yearmonth' } }
	);

	my @ret;
	for my $row ( $res->hashes->each ) {
		push( @ret, [ split( qr{[.]}, $row->{yearmonth} ) ] );
	}

	return @ret;
}

sub generate_missing_stats {
	my ( $self, %opt ) = @_;
	my $uid            = $opt{uid};
	my $db             = $opt{db} // $self->{pg}->db;
	my @journey_months = $self->get_yyyymm_having_journeys(
		uid => $uid,
		db  => $db
	);
	my @stats_months = $self->stats_cache->get_yyyymm_having_stats(
		uid => $uid,
		$db => $db
	);

	my $stats_index = 0;

	for my $journey_index ( 0 .. $#journey_months ) {
		if (    $stats_index < @stats_months
			and $journey_months[$journey_index][0]
			== $stats_months[$stats_index][0]
			and $journey_months[$journey_index][1]
			== $stats_months[$stats_index][1] )
		{
			$stats_index++;
		}
		else {
			my ( $year, $month ) = @{ $journey_months[$journey_index] };
			$self->get_stats(
				uid        => $uid,
				db         => $db,
				year       => $year,
				month      => $month,
				write_only => 1
			);
		}
	}
}

sub get_nav_months {
	my ( $self, %opt ) = @_;

	my $uid          = $opt{uid};
	my $db           = $opt{db} // $self->{pg}->db;
	my $filter_year  = $opt{year};
	my $filter_month = $opt{month};

	my $selected_index = undef;

	my $res = $db->select(
		'journeys',
		"distinct to_char(real_departure, 'YYYY.MM') as yearmonth",
		{ user_id  => $uid },
		{ order_by => { -asc => 'yearmonth' } }
	);

	my @months;
	for my $row ( $res->hashes->each ) {
		my ( $year, $month ) = split( qr{[.]}, $row->{yearmonth} );
		push( @months, [ $year, $month ] );
		if ( $year eq $filter_year and $month eq $filter_month ) {
			$selected_index = $#months;
		}
	}

	# returns (previous entry, current month, next entry). if there is no
	# previous or next entry, the corresponding field is undef. Previous/next
	# entry is usually previous/next month, but may also have a distance of
	# more than one month if there are months without travels
	my @ret = ( undef, undef, undef );

	$ret[1] = [
		"${filter_year}/${filter_month}",
		$month_name[ $filter_month - 1 ] // $filter_month
	];

	if ( not defined $selected_index ) {
		return @ret;
	}

	if ( $selected_index > 0 and $months[ $selected_index - 1 ] ) {
		my ( $year, $month ) = @{ $months[ $selected_index - 1 ] };
		$ret[0] = [ "${year}/${month}", "${month}.${year}" ];
	}
	if ( $selected_index < $#months ) {
		my ( $year, $month ) = @{ $months[ $selected_index + 1 ] };
		$ret[2] = [ "${year}/${month}", "${month}.${year}" ];
	}

	return @ret;
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
		  = $self->{stations}
		  ->grep_unknown( map { $_->[0] } @{ $journey->{route} } );
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
	my $from_latlon  = $journey->{from_latlon};
	my $to           = $journey->{to_name};
	my $to_eva       = $journey->{to_eva};
	my $to_latlon    = $journey->{to_latlon};
	my $route_ref    = $journey->{route};
	my $polyline_ref = $journey->{polyline};

	if ( not $to ) {
		$self->{log}
		  ->warn("Journey $journey->{id} has no to_name for EVA $to_eva");
	}

	if ( not $from ) {
		$self->{log}
		  ->warn("Journey $journey->{id} has no from_name for EVA $from_eva");
	}

	my $distance_polyline     = 0;
	my $distance_intermediate = 0;
	my $distance_beeline      = 0;
	my $skipped               = 0;
	my $geo                   = GIS::Distance->new();
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
		$distance_polyline += $geo->distance_metal(
			$prev_station->[1], $prev_station->[0],
			$station->[1],      $station->[0]
		);
		$prev_station = $station;
	}

	$prev_station = $self->{latlon_by_station}->{ shift @route };
	if ( not $prev_station ) {
		return ( $distance_polyline, 0, 0 );
	}

	for my $station_name (@route) {
		if ( my $station = $self->{latlon_by_station}->{$station_name} ) {
			$distance_intermediate += $geo->distance_metal(
				$prev_station->[0], $prev_station->[1],
				$station->[0],      $station->[1]
			);
			$prev_station = $station;
		}
	}

	$distance_beeline = $geo->distance_metal( @{$from_latlon}, @{$to_latlon} );

	return ( $distance_polyline, $distance_intermediate,
		$distance_beeline, $skipped );
}

sub grep_single {
	my ( $self, @journeys ) = @_;

	my %num_by_trip;
	for my $journey (@journeys) {
		if ( $journey->{from_name} and $journey->{to_name} ) {
			$num_by_trip{ $journey->{from_name} . '|' . $journey->{to_name} }
			  += 1;
		}
	}

	return
	  grep { $num_by_trip{ $_->{from_name} . '|' . $_->{to_name} } == 1 }
	  @journeys;
}

sub compute_review {
	my ( $self, $stats, @journeys ) = @_;
	my $longest_km;
	my $longest_t;
	my $shortest_km;
	my $shortest_t;
	my $most_delayed;
	my $most_delay;
	my $most_undelay;
	my $num_cancelled = 0;
	my $num_fgr       = 0;
	my $num_punctual  = 0;
	my $message_count = 0;
	my %num_by_message;
	my %num_by_wrtype;
	my %num_by_linetype;
	my %num_by_stop;
	my %num_by_trip;

	if ( not $stats or not @journeys or $stats->{num_trains} == 0 ) {
		return;
	}

	my %review;

	for my $journey (@journeys) {
		if ( $journey->{cancelled} ) {
			$num_cancelled += 1;
			next;
		}

		my %seen;

		if ( $journey->{rt_duration} and $journey->{rt_duration} > 0 ) {
			if ( not $longest_t
				or $journey->{rt_duration} > $longest_t->{rt_duration} )
			{
				$longest_t = $journey;
			}
			if ( not $shortest_t
				or $journey->{rt_duration} < $shortest_t->{rt_duration} )
			{
				$shortest_t = $journey;
			}
		}

		if ( $journey->{km_route} ) {
			if ( not $longest_km
				or $journey->{km_route} > $longest_km->{km_route} )
			{
				$longest_km = $journey;
			}
			if ( not $shortest_km
				or $journey->{km_route} < $shortest_km->{km_route} )
			{
				$shortest_km = $journey;
			}
		}

		if ( $journey->{messages} and @{ $journey->{messages} } ) {
			$message_count += 1;
			for my $message ( @{ $journey->{messages} } ) {
				if ( not $seen{ $message->[1] } ) {
					$num_by_message{ $message->[1] } += 1;
					$seen{ $message->[1] } = 1;
				}
			}
		}

		if ( $journey->{type} ) {
			$num_by_linetype{ $journey->{type} } += 1;
		}

		if ( $journey->{from_name} ) {
			$num_by_stop{ $journey->{from_name} } += 1;
		}
		if ( $journey->{to_name} ) {
			$num_by_stop{ $journey->{to_name} } += 1;
		}
		if ( $journey->{from_name} and $journey->{to_name} ) {
			$num_by_trip{ $journey->{from_name} . '|' . $journey->{to_name} }
			  += 1;
		}

		if ( $journey->{sched_dep_ts} and $journey->{rt_dep_ts} ) {
			$journey->{delay_dep}
			  = ( $journey->{rt_dep_ts} - $journey->{sched_dep_ts} ) / 60;
		}
		if ( $journey->{sched_arr_ts} and $journey->{rt_arr_ts} ) {
			$journey->{delay_arr}
			  = ( $journey->{rt_arr_ts} - $journey->{sched_arr_ts} ) / 60;
		}

		if ( $journey->{delay_arr} and $journey->{delay_arr} >= 60 ) {
			$num_fgr += 1;
		}
		if ( not $journey->{delay_arr} and not $journey->{delay_dep} ) {
			$num_punctual += 1;
		}

		if ( $journey->{delay_arr} and $journey->{delay_arr} > 0 ) {
			if ( not $most_delayed
				or $journey->{delay_arr} > $most_delayed->{delay_arr} )
			{
				$most_delayed = $journey;
			}
		}

		if (    $journey->{rt_duration}
			and $journey->{sched_duration}
			and $journey->{rt_duration} > 0
			and $journey->{sched_duration} > 0 )
		{
			my $slowdown = $journey->{rt_duration} - $journey->{sched_duration};
			my $speedup  = -$slowdown;
			if (
				not $most_delay
				or $slowdown > (
					$most_delay->{rt_duration} - $most_delay->{sched_duration}
				)
			  )
			{
				$most_delay = $journey;
			}
			if (
				not $most_undelay
				or $speedup > (
					    $most_undelay->{sched_duration}
					  - $most_undelay->{rt_duration}
				)
			  )
			{
				$most_undelay = $journey;
			}
		}
	}

	my @linetypes = sort { $b->[1] <=> $a->[1] }
	  map { [ $_, $num_by_linetype{$_} ] } keys %num_by_linetype;
	my @stops = sort { $b->[1] <=> $a->[1] }
	  map { [ $_, $num_by_stop{$_} ] } keys %num_by_stop;
	my @trips = sort { $b->[1] <=> $a->[1] }
	  map { [ $_, $num_by_trip{$_} ] } keys %num_by_trip;

	my @reasons = sort { $b->[1] <=> $a->[1] }
	  map { [ $_, $num_by_message{$_} ] } keys %num_by_message;

	$review{num_stops} = scalar @stops;
	$review{km_circle} = $stats->{km_route} / 40030;
	$review{km_diag}   = $stats->{km_route} / 12742;

	$review{trains_per_day} = sprintf( '%.1f', $stats->{num_trains} / 365 );
	$review{km_route}       = sprintf( '%.0f', $stats->{km_route} );
	$review{km_beeline}     = sprintf( '%.0f', $stats->{km_beeline} );
	$review{km_circle_h}    = sprintf( '%.1f', $review{km_circle} );
	$review{km_diag_h}      = sprintf( '%.1f', $review{km_diag} );

	$review{trains_per_day} =~ tr{.}{,};
	$review{km_circle_h}    =~ tr{.}{,};
	$review{km_diag_h}      =~ tr{.}{,};

	my $min_total = $stats->{min_travel_real} + $stats->{min_interchange_real};
	$review{traveling_min_total} = $min_total;
	$review{traveling_percentage_year}
	  = sprintf( "%.1f%%", $min_total * 100 / 525948.77 );
	$review{traveling_percentage_year} =~ tr{.}{,};
	$review{traveling_time_year} = min_to_human($min_total);

	if (@linetypes) {
		$review{typical_type_1} = $linetypes[0][0];
	}
	if ( @linetypes > 1 ) {
		$review{typical_type_2} = $linetypes[1][0];
	}
	if ( @stops >= 3 ) {
		my $desc = q{};
		$review{typical_stops_3} = [ $stops[0][0], $stops[1][0], $stops[2][0] ];
	}
	elsif ( @stops == 2 ) {
		$review{typical_stops_2} = [ $stops[0][0], $stops[1][0] ];
	}
	$review{typical_time}
	  = min_to_human( $stats->{min_travel_real} / $stats->{num_trains} );
	$review{typical_km}
	  = sprintf( '%.0f', $stats->{km_route} / $stats->{num_trains} );
	$review{typical_kmh} = sprintf( '%.0f',
		$stats->{km_route} / ( $stats->{min_travel_real} / 60 ) );
	$review{typical_delay_dep}
	  = sprintf( '%.0f', $stats->{delay_dep} / $stats->{num_trains} );
	$review{typical_delay_dep_h} = min_to_human( $review{typical_delay_dep} );
	$review{typical_delay_arr}
	  = sprintf( '%.0f', $stats->{delay_arr} / $stats->{num_trains} );
	$review{typical_delay_arr_h} = min_to_human( $review{typical_delay_arr} );

	if ($longest_t) {
		$review{longest_t_time}
		  = min_to_human( $longest_t->{rt_duration} / 60 );
		$review{longest_t_type}   = $longest_t->{type};
		$review{longest_t_lineno} = $longest_t->{line} // $longest_t->{no};
		$review{longest_t_from}   = $longest_t->{from_name};
		$review{longest_t_to}     = $longest_t->{to_name};
		$review{longest_t_id}     = $longest_t->{id};
	}

	if ($longest_km) {
		$review{longest_km_km}     = sprintf( '%.0f', $longest_km->{km_route} );
		$review{longest_km_type}   = $longest_km->{type};
		$review{longest_km_lineno} = $longest_km->{line} // $longest_km->{no};
		$review{longest_km_from}   = $longest_km->{from_name};
		$review{longest_km_to}     = $longest_km->{to_name};
		$review{longest_km_id}     = $longest_km->{id};
	}

	if ($shortest_t) {
		$review{shortest_t_time}
		  = min_to_human( $shortest_t->{rt_duration} / 60 );
		$review{shortest_t_type}   = $shortest_t->{type};
		$review{shortest_t_lineno} = $shortest_t->{line} // $shortest_t->{no};
		$review{shortest_t_from}   = $shortest_t->{from_name};
		$review{shortest_t_to}     = $shortest_t->{to_name};
		$review{shortest_t_id}     = $shortest_t->{id};
	}

	if ($shortest_km) {
		$review{shortest_km_m}
		  = sprintf( '%.0f', $shortest_km->{km_route} * 1000 );
		$review{shortest_km_type}   = $shortest_km->{type};
		$review{shortest_km_lineno} = $shortest_km->{line}
		  // $shortest_km->{no};
		$review{shortest_km_from} = $shortest_km->{from_name};
		$review{shortest_km_to}   = $shortest_km->{to_name};
		$review{shortest_km_id}   = $shortest_km->{id};
	}

	if ($most_delayed) {
		$review{most_delayed_type} = $most_delayed->{type};
		$review{most_delayed_delay_dep}
		  = min_to_human( $most_delayed->{delay_dep} );
		$review{most_delayed_delay_arr}
		  = min_to_human( $most_delayed->{delay_arr} );
		$review{most_delayed_lineno} = $most_delayed->{line}
		  // $most_delayed->{no};
		$review{most_delayed_from} = $most_delayed->{from_name};
		$review{most_delayed_to}   = $most_delayed->{to_name};
		$review{most_delayed_id}   = $most_delayed->{id};
	}

	if ($most_delay) {
		$review{most_delay_type}      = $most_delay->{type};
		$review{most_delay_delay_dep} = $most_delay->{delay_dep};
		$review{most_delay_delay_arr} = $most_delay->{delay_arr};
		$review{most_delay_sched_time}
		  = min_to_human( $most_delay->{sched_duration} / 60 );
		$review{most_delay_real_time}
		  = min_to_human( $most_delay->{rt_duration} / 60 );
		$review{most_delay_delta}
		  = min_to_human(
			( $most_delay->{rt_duration} - $most_delay->{sched_duration} )
			/ 60 );
		$review{most_delay_lineno} = $most_delay->{line} // $most_delay->{no};
		$review{most_delay_from}   = $most_delay->{from_name};
		$review{most_delay_to}     = $most_delay->{to_name};
		$review{most_delay_id}     = $most_delay->{id};
	}

	if ($most_undelay) {
		$review{most_undelay_type}      = $most_undelay->{type};
		$review{most_undelay_delay_dep} = $most_undelay->{delay_dep};
		$review{most_undelay_delay_arr} = $most_undelay->{delay_arr};
		$review{most_undelay_sched_time}
		  = min_to_human( $most_undelay->{sched_duration} / 60 );
		$review{most_undelay_real_time}
		  = min_to_human( $most_undelay->{rt_duration} / 60 );
		$review{most_undelay_delta}
		  = min_to_human(
			( $most_undelay->{sched_duration} - $most_undelay->{rt_duration} )
			/ 60 );
		$review{most_undelay_lineno} = $most_undelay->{line}
		  // $most_undelay->{no};
		$review{most_undelay_from} = $most_undelay->{from_name};
		$review{most_undelay_to}   = $most_undelay->{to_name};
		$review{most_undelay_id}   = $most_undelay->{id};
	}

	$review{issue_percent}
	  = sprintf( '%.0f%%', $message_count * 100 / $stats->{num_trains} );
	for my $i ( 0 .. 2 ) {
		if ( $reasons[$i] ) {
			my $p = 'issue' . ( $i + 1 );
			$review{"${p}_count"} = $reasons[$i][1];
			$review{"${p}_text"}  = $reasons[$i][0];
		}
	}

	$review{cancel_count}  = $num_cancelled;
	$review{fgr_percent}   = $num_fgr * 100 / $stats->{num_trains};
	$review{fgr_percent_h} = sprintf( '%.1f%%', $review{fgr_percent} );
	$review{fgr_percent_h} =~ tr{.}{,};
	$review{punctual_percent} = $num_punctual * 100 / $stats->{num_trains};
	$review{punctual_percent_h}
	  = sprintf( '%.1f%%', $review{punctual_percent} );
	$review{punctual_percent_h} =~ tr{.}{,};

	my $top_trip_count    = 0;
	my $single_trip_count = 0;
	for my $i ( 0 .. 3 ) {
		if ( $trips[$i] ) {
			my ( $from, $to ) = split( qr{[|]}, $trips[$i][0] );
			my $found = 0;
			for my $j ( 0 .. $#{ $review{top_trips} } ) {
				if (    $review{top_trips}[$j][0] eq $to
					and $review{top_trips}[$j][2] eq $from )
				{
					$review{top_trips}[$j][1] = '↔';
					$found = 1;
					last;
				}
			}
			if ( not $found ) {
				push( @{ $review{top_trips} }, [ $from, '→', $to ] );
			}
			$top_trip_count += $trips[$i][1];
		}
	}

	for my $trip (@trips) {
		if ( $trip->[1] == 1 ) {
			$single_trip_count += 1;
			if ( @{ $review{single_trips} // [] } < 3 ) {
				push(
					@{ $review{single_trips} },
					[ split( qr{[|]}, $trip->[0] ) ]
				);
			}
		}
	}

	$review{top_trip_count} = $top_trip_count;
	$review{top_trip_percent_h}
	  = sprintf( '%.1f%%', $top_trip_count * 100 / $stats->{num_trains} );
	$review{top_trip_percent_h} =~ tr{.}{,};

	$review{single_trip_count} = $single_trip_count;
	$review{single_trip_percent_h}
	  = sprintf( '%.1f%%', $single_trip_count * 100 / $stats->{num_trains} );
	$review{single_trip_percent_h} =~ tr{.}{,};

	return \%review;
}

sub compute_stats {
	my ( $self, @journeys ) = @_;
	my $km_route         = 0;
	my $km_beeline       = 0;
	my $min_travel_sched = 0;
	my $min_travel_real  = 0;
	my $delay_dep        = 0;
	my $delay_arr        = 0;
	my $interchange_real = 0;
	my $num_trains       = 0;
	my $num_journeys     = 0;
	my @inconsistencies;

	my $next_departure = 0;
	my $next_id;
	my $next_train;

	for my $journey (@journeys) {
		$num_trains++;
		$km_route   += $journey->{km_route};
		$km_beeline += $journey->{km_beeline};
		if (    $journey->{sched_duration}
			and $journey->{sched_duration} > 0 )
		{
			$min_travel_sched += $journey->{sched_duration} / 60;
		}
		if ( $journey->{rt_duration} and $journey->{rt_duration} > 0 ) {
			$min_travel_real += $journey->{rt_duration} / 60;
		}
		if ( $journey->{sched_dep_ts} and $journey->{rt_dep_ts} ) {
			$delay_dep
			  += ( $journey->{rt_dep_ts} - $journey->{sched_dep_ts} ) / 60;
		}
		if ( $journey->{sched_arr_ts} and $journey->{rt_arr_ts} ) {
			$delay_arr
			  += ( $journey->{rt_arr_ts} - $journey->{sched_arr_ts} ) / 60;
		}

		# Note that journeys are sorted from recent to older entries
		if (    $journey->{rt_arr_ts}
			and $next_departure
			and $next_departure - $journey->{rt_arr_ts} < ( 60 * 60 ) )
		{
			if ( $next_departure - $journey->{rt_arr_ts} < 0 ) {
				push(
					@inconsistencies,
					{
						conflict => {
							train => $journey->{type} . ' '
							  . ( $journey->{line} // $journey->{no} ),
							arr => epoch_to_dt( $journey->{rt_arr_ts} )
							  ->strftime('%d.%m.%Y %H:%M'),
							id => $journey->{id},
						},
						ignored => {
							train => $next_train,
							dep   => epoch_to_dt($next_departure)
							  ->strftime('%d.%m.%Y %H:%M'),
							id => $next_id,
						},
					}
				);
			}
			else {
				$interchange_real
				  += ( $next_departure - $journey->{rt_arr_ts} ) / 60;
			}
		}
		else {
			$num_journeys++;
		}
		$next_departure = $journey->{rt_dep_ts};
		$next_id        = $journey->{id};
		$next_train
		  = $journey->{type} . ' ' . ( $journey->{line} // $journey->{no} ),;
	}
	my $ret = {
		km_route             => $km_route,
		km_beeline           => $km_beeline,
		num_trains           => $num_trains,
		num_journeys         => $num_journeys,
		min_travel_sched     => $min_travel_sched,
		min_travel_real      => $min_travel_real,
		min_interchange_real => $interchange_real,
		delay_dep            => $delay_dep,
		delay_arr            => $delay_arr,
		inconsistencies      => \@inconsistencies,
	};
	for my $key (
		qw(min_travel_sched min_travel_real min_interchange_real delay_dep delay_arr)
	  )
	{
		my $strf_key = $key . '_strf';
		my $value    = $ret->{$key};
		$ret->{$strf_key} = q{};
		if ( $ret->{$key} < 0 ) {
			$ret->{$strf_key} .= '-';
			$value *= -1;
		}
		$ret->{$strf_key} .= sprintf( '%02d:%02d', $value / 60, $value % 60 );
	}
	return $ret;
}

sub get_stats {
	my ( $self, %opt ) = @_;

	if ( $opt{cancelled} ) {
		$self->{log}
		  ->warn('get_journey_stats called with illegal option cancelled => 1');
		return {};
	}

	my $uid   = $opt{uid};
	my $db    = $opt{db}    // $self->{pg}->db;
	my $year  = $opt{year}  // 0;
	my $month = $opt{month} // 0;

	# Assumption: If the stats cache contains an entry it is up-to-date.
	# -> Cache entries must be explicitly invalidated whenever the user
	# checks out of a train or manually edits/adds a journey.

	if (
		    not $opt{write_only}
		and not $opt{review}
		and my $stats = $self->stats_cache->get(
			uid   => $uid,
			db    => $db,
			year  => $year,
			month => $month
		)
	  )
	{
		return $stats;
	}

	my $interval_start = DateTime->new(
		time_zone => 'Europe/Berlin',
		year      => 2000,
		month     => 1,
		day       => 1,
		hour      => 0,
		minute    => 0,
		second    => 0,
	);

	# I wonder if people will still be traveling by train in the year 3000
	my $interval_end = $interval_start->clone->add( years => 1000 );

	if ( $opt{year} and $opt{month} ) {
		$interval_start->set(
			year  => $opt{year},
			month => $opt{month}
		);
		$interval_end = $interval_start->clone->add( months => 1 );
	}
	elsif ( $opt{year} ) {
		$interval_start->set( year => $opt{year} );
		$interval_end = $interval_start->clone->add( years => 1 );
	}

	my @journeys = $self->get(
		uid           => $uid,
		cancelled     => 0,
		verbose       => 1,
		with_polyline => 1,
		after         => $interval_start,
		before        => $interval_end
	);
	my $stats = $self->compute_stats(@journeys);

	$self->stats_cache->add(
		uid   => $uid,
		db    => $db,
		year  => $year,
		month => $month,
		stats => $stats
	);

	if ( $opt{review} ) {
		my @cancelled_journeys = $self->get(
			uid       => $uid,
			cancelled => 1,
			verbose   => 1,
			after     => $interval_start,
			before    => $interval_end
		);
		return ( $stats,
			$self->compute_review( $stats, @journeys, @cancelled_journeys ) );
	}

	return $stats;
}

sub get_latest_dest_id {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	if (
		my $id = $self->{in_transit}->get_checkout_station_id(
			uid => $uid,
			db  => $db
		)
	  )
	{
		return $id;
	}

	return $self->get_latest_checkout_station_id(
		uid => $uid,
		db  => $db
	);
}

sub get_connection_targets {
	my ( $self, %opt ) = @_;

	my $uid       = $opt{uid};
	my $threshold = $opt{threshold}
	  // DateTime->now( time_zone => 'Europe/Berlin' )->subtract( months => 4 );
	my $db        = $opt{db} //= $self->{pg}->db;
	my $min_count = $opt{min_count} // 3;

	if ( $opt{destination_name} ) {
		return ( $opt{destination_name} );
	}

	my $dest_id = $opt{eva} // $self->get_latest_dest_id(%opt);

	if ( not $dest_id ) {
		return;
	}

	my $res = $db->query(
		qq{
			select
			count(checkout_station_id) as count,
			checkout_station_id as dest
			from journeys
			where user_id = ?
			and checkin_station_id = ?
			and real_departure > ?
			group by checkout_station_id
			order by count desc;
		},
		$uid,
		$dest_id,
		$threshold
	);
	my @destinations
	  = $res->hashes->grep( sub { shift->{count} >= $min_count } )
	  ->map( sub { shift->{dest} } )->each;
	@destinations = $self->{stations}->get_by_evas(@destinations);
	@destinations = map { $_->{name} } @destinations;
	return @destinations;
}

sub update_visibility {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $visibility;

	if ( $opt{visibility} and $visibility_atoi{ $opt{visibility} } ) {
		$visibility = $visibility_atoi{ $opt{visibility} };
	}

	$db->update(
		'journeys',
		{ visibility => $visibility },
		{
			user_id => $uid,
			id      => $opt{id}
		}
	);
}

1;
