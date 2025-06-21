package Travelynx::Model::InTransit;

# Copyright (C) 2020-2025 Birte Kristina Friesel
# Copyright (C) 2025 networkException <git@nwex.de>
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use JSON;

my %visibility_itoa = (
	100     => 'public',
	80      => 'travelynx',
	60      => 'followers',
	30      => 'unlisted',
	10      => 'private',
	default => 'default',
);

my %visibility_atoi = (
	public    => 100,
	travelynx => 80,
	followers => 60,
	unlisted  => 30,
	private   => 10,
);

sub _epoch {
	my ($dt) = @_;

	return $dt ? $dt->epoch : undef;
}

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

sub epoch_or_dt_to_dt {
	my ($input) = @_;

	if ( ref($input) eq 'DateTime' ) {
		return $input;
	}

	return epoch_to_dt($input);
}

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

# merge [name, eva, data] from old_route into [name, undef, undef] from new_route.
# If new_route already has eva/data, it is kept as-is.
# changes new_route.
sub _merge_old_route {
	my ( $self, %opt ) = @_;
	my $db        = $opt{db};
	my $uid       = $opt{uid};
	my $new_route = $opt{route};

	my $res_h = $db->select( 'in_transit', ['route'], { user_id => $uid } )
	  ->expand->hash;
	my $old_route = $res_h ? $res_h->{route} : [];

	for my $i ( 0 .. $#{$new_route} ) {
		if ( $old_route->[$i] and $old_route->[$i][0] eq $new_route->[$i][0] ) {
			$new_route->[$i][1] //= $old_route->[$i][1];
			if ( not keys %{ $new_route->[$i][2] // {} } ) {
				$new_route->[$i][2] = $old_route->[$i][2];
			}
		}
	}

	return $new_route;
}

sub add {
	my ( $self, %opt ) = @_;

	my $uid                = $opt{uid};
	my $db                 = $opt{db} // $self->{pg}->db;
	my $backend_id         = $opt{backend_id};
	my $train              = $opt{train};
	my $train_suffix       = $opt{train_suffix};
	my $journey            = $opt{journey};
	my $stop               = $opt{stop};
	my $stopover           = $opt{stopover};
	my $manual             = $opt{manual};
	my $checkin_station_id = $opt{departure_eva};
	my $route              = $opt{route};
	my $data               = $opt{data};
	my $persistent_data;

	my $json = JSON->new;
	my $now  = DateTime->now( time_zone => 'Europe/Berlin' );

	if ($train) {
		$db->insert(
			'in_transit',
			{
				user_id   => $uid,
				cancelled => $train->departure_is_cancelled ? 1
				: 0,
				checkin_station_id => $checkin_station_id,
				checkin_time       => $now,
				dep_platform       => $train->platform,
				train_type         => $train->type,
				train_line         => $train->line_no,
				train_no           => $train->train_no,
				train_id           => $train->train_id,
				sched_departure    => $train->sched_departure,
				real_departure     => $train->departure,
				route              => $json->encode($route),
				messages           => $json->encode(
					[ map { [ $_->[0]->epoch, $_->[1] ] } $train->messages ]
				),
				data => JSON->new->encode(
					{
						rt => $train->departure_has_realtime ? 1
						: 0,
						%{ $data // {} }
					}
				),
				backend_id => $backend_id,
			}
		);
	}
	elsif ( $journey
		and $stop
		and ref($journey) eq 'Travel::Status::DE::EFA::Trip' )
	{
		my @route;
		for my $j_stop ( $journey->route ) {
			push(
				@route,
				[
					$j_stop->full_name,
					$j_stop->id_num,
					{
						sched_arr   => _epoch( $j_stop->sched_arr ),
						sched_dep   => _epoch( $j_stop->sched_dep ),
						rt_arr      => _epoch( $j_stop->rt_arr ),
						rt_dep      => _epoch( $j_stop->rt_dep ),
						isCancelled => $j_stop->is_cancelled,
						arr_delay   => $j_stop->arr_delay,
						dep_delay   => $j_stop->dep_delay,
						efa_load    => $j_stop->occupancy,
						lat         => $j_stop->latlon->[0],
						lon         => $j_stop->latlon->[1],
					}
				]
			);
		}
		$persistent_data->{operator} = $journey->operator;
		$db->insert(
			'in_transit',
			{
				user_id            => $uid,
				cancelled          => $stop->is_cancelled ? 1 : 0,
				checkin_station_id => $stop->id_num,
				checkin_time       => $now,
				dep_platform       => $stop->platform,
				train_type         => $journey->type // q{},
				train_line         => $journey->line,
				train_no           => $journey->number // q{},
				train_id           => $opt{trip_id},
				sched_departure    => $stop->sched_dep,
				real_departure     => $stop->rt_dep // $stop->sched_dep,
				route              => $json->encode( \@route ),
				data               => JSON->new->encode(
					{
						rt => $stop->rt_dep ? 1 : 0,
						%{ $data // {} }
					}
				),
				user_data  => JSON->new->encode($persistent_data),
				backend_id => $backend_id,
			}
		);
	}
	elsif ( $journey
		and $stop
		and ref($journey) eq 'Travel::Status::DE::HAFAS::Journey' )
	{
		my @route;
		my $product = $journey->product_at( $stop->loc->eva )
		  // $journey->product;
		for my $j_stop ( $journey->route ) {
			push(
				@route,
				[
					$j_stop->loc->name,
					$j_stop->loc->eva,
					{
						sched_arr => _epoch( $j_stop->sched_arr ),
						sched_dep => _epoch( $j_stop->sched_dep ),
						rt_arr    => _epoch( $j_stop->rt_arr ),
						rt_dep    => _epoch( $j_stop->rt_dep ),
						arr_delay => $j_stop->arr_delay,
						dep_delay => $j_stop->dep_delay,
						load      => $j_stop->load,
						lat       => $j_stop->loc->lat,
						lon       => $j_stop->loc->lon,
					}
				]
			);
			if ( defined $j_stop->tz_offset ) {
				$route[-1][2]{tz_offset} = $j_stop->tz_offset;
			}
		}
		if ( scalar $journey->operators ) {
			$persistent_data->{operators} = [ $journey->operators ];
		}
		$db->insert(
			'in_transit',
			{
				user_id   => $uid,
				cancelled => $stop->{dep_cancelled}
				? 1
				: 0,
				checkin_station_id => $stop->loc->eva,
				checkin_time       => $now,
				dep_platform       => $stop->{platform},
				train_type         => $product->type // q{},
				train_line         => $product->line_no,
				train_no           => $product->number // q{},
				train_id           => $journey->id,
				sched_departure    => $stop->{sched_dep},
				real_departure     => $stop->{rt_dep} // $stop->{sched_dep},
				route              => $json->encode( \@route ),
				data               => JSON->new->encode(
					{
						rt => $stop->{rt_dep} ? 1 : 0,
						%{ $data // {} }
					}
				),
				user_data  => JSON->new->encode($persistent_data),
				backend_id => $backend_id,
			}
		);
	}
	elsif ( $journey
		and $stop
		and ref($journey) eq 'Travel::Status::DE::DBRIS::Journey' )
	{
		my $number = $journey->train_no // $journey->number // $train_suffix;

		my $line;
		if ( defined $journey->line_no and $journey->line_no ne $number ) {
			$line = $journey->line_no;
		}
		elsif ( defined $train_suffix and $train_suffix ne $number ) {
			$line = $train_suffix;
		}

		my @route;
		for my $j_stop ( $journey->route ) {
			push(
				@route,
				[
					$j_stop->name,
					$j_stop->eva,
					{
						sched_arr   => _epoch( $j_stop->sched_arr ),
						sched_dep   => _epoch( $j_stop->sched_dep ),
						rt_arr      => _epoch( $j_stop->rt_arr ),
						rt_dep      => _epoch( $j_stop->rt_dep ),
						isCancelled => $j_stop->is_cancelled,
						arr_delay   => $j_stop->arr_delay,
						dep_delay   => $j_stop->dep_delay,
						load        => {
							FIRST  => $j_stop->occupancy_first,
							SECOND => $j_stop->occupancy_second
						},
						lat => $j_stop->lat,
						lon => $j_stop->lon,
					}
				]
			);
		}
		my @messages;
		for my $msg ( $journey->messages ) {
			if ( not $msg->{ueberschrift} ) {
				push(
					@{ $data->{him_msg} },
					{
						header => q{},
						prio   => $msg->{prioritaet},
						lead   => $msg->{text}
					}
				);
				push(
					@{ $persistent_data->{him_msg} },
					{
						prio => $msg->{prioritaet},
						lead => $msg->{text}
					}
				);
			}
		}
		$db->insert(
			'in_transit',
			{
				user_id   => $uid,
				cancelled => $stop->is_cancelled
				? 1
				: 0,
				checkin_station_id => $stop->eva,
				checkin_time       => $now,
				dep_platform       => $stop->platform,
				train_type         => $journey->type // q{},
				train_line         => $line,
				train_no           => $number,
				train_id           => $data->{trip_id},
				sched_departure    => $stop->sched_dep,
				real_departure     => $stop->rt_dep // $stop->sched_dep,
				route              => $json->encode( \@route ),
				data               => JSON->new->encode(
					{
						rt => $stop->{rt_dep} ? 1 : 0,
						%{ $data // {} }
					}
				),
				user_data  => JSON->new->encode($persistent_data),
				backend_id => $backend_id,
			}
		);
	}
	elsif ( $journey
		and $stopover
		and ref($journey) eq 'Travel::Status::MOTIS::Trip' )
	{
		my @route;
		for my $journey_stopover ( $journey->stopovers ) {
			push(
				@route,
				[
					$journey_stopover->stop->name,
					$journey_stopover->stop->{eva}
					  // die('eva not set for stopover'),
					{
						sched_arr =>
						  _epoch( $journey_stopover->scheduled_arrival ),
						sched_dep =>
						  _epoch( $journey_stopover->scheduled_departure ),
						rt_arr => _epoch( $journey_stopover->realtime_arrival ),
						rt_dep =>
						  _epoch( $journey_stopover->realtime_departure ),
						arr_delay => $journey_stopover->arrival_delay,
						dep_delay => $journey_stopover->departure_delay,
						lat       => $journey_stopover->stop->lat,
						lon       => $journey_stopover->stop->lon,
					}
				]
			);
		}

		$persistent_data->{operator} = $journey->agency;

		$db->insert(
			'in_transit',
			{
				user_id   => $uid,
				cancelled => $stopover->{is_cancelled}
				? 1
				: 0,
				checkin_station_id => $stopover->stop->{eva},
				checkin_time => DateTime->now( time_zone => 'Europe/Berlin' ),
				dep_platform => $stopover->track,
				train_type   => $journey->mode,
				train_no     => q{},
				train_id     => $journey->id,
				train_line   => $journey->route_name,
				sched_departure => $stopover->scheduled_departure,
				real_departure  => $stopover->departure,
				route           => $json->encode( \@route ),
				data            => $json->encode(
					{
						rt => $stopover->{is_realtime} ? 1 : 0,
						%{ $data // {} }
					}
				),
				user_data  => $json->encode($persistent_data),
				backend_id => $backend_id,
			}
		);
	}
	elsif ($manual) {
		if ( $manual->{comment} ) {
			$persistent_data->{comment} = $manual->{comment};
		}
		$db->insert(
			'in_transit',
			{
				user_id             => $uid,
				cancelled           => 0,
				checkin_station_id  => $manual->{dep_id},
				checkout_station_id => $manual->{arr_id},
				checkin_time => DateTime->now( time_zone => 'Europe/Berlin' ),
				train_type   => $manual->{train_type},
				train_no     => $manual->{train_no} || q{},
				train_id     => 'manual',
				train_line   => $manual->{train_line} || undef,
				sched_departure => $manual->{sched_departure},
				real_departure  => $manual->{sched_departure},
				sched_arrival   => $manual->{sched_arrival},
				real_arrival    => $manual->{sched_arrival},
				route           => $json->encode( $manual->{route} // [] ),
				data            => $json->encode(
					{
						manual => \1,
						%{ $data // {} }
					}
				),
				user_data  => $json->encode($persistent_data),
				backend_id => $backend_id,
			}
		);
		return;
	}
	else {
		die('invalid arguments / argument types passed to InTransit->add');
	}
}

sub add_from_journey {
	my ( $self, %opt ) = @_;

	my $journey = $opt{journey};
	my $db      = $opt{db} // $self->{pg}->db;

	$db->insert( 'in_transit', $journey );
}

sub delete {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	$db->delete( 'in_transit', { user_id => $uid } );
}

sub delete_incomplete_checkins {
	my ( $self, %opt ) = @_;

	my $db = $opt{db} // $self->{pg}->db;

	return $db->delete( 'in_transit',
		{ checkin_time => { '<', $opt{earlier_than} } } )->rows;
}

sub postprocess {
	my ( $self, $ret ) = @_;
	my $now   = DateTime->now( time_zone => 'Europe/Berlin' );
	my $epoch = $now->epoch;
	my @route = @{ $ret->{route} // [] };
	my @route_after;
	my $dep_info;
	my $is_after = 0;

	for my $station (@route) {
		if ($is_after) {
			push( @route_after, $station );
		}

		# Note that the departure stop may be present more than once in @route,
		# e.g. when traveling along ring lines such as S41 / S42 in Berlin.
		if (
			    $ret->{dep_name}
			and $station->[0] eq $ret->{dep_name}
			and not($station->[2]{sched_dep}
				and $station->[2]{sched_dep} < $ret->{sched_dep_ts} )
		  )
		{
			$is_after = 1;
			if ( @{$station} > 1 and not $dep_info ) {
				$dep_info = $station->[2];
			}
		}
	}

	my $ts          = $ret->{checkout_ts} // $ret->{checkin_ts};
	my $action_time = epoch_to_dt($ts);

	$ret->{checked_in}         = !$ret->{cancelled};
	$ret->{timestamp}          = $action_time;
	$ret->{timestamp_delta}    = $now->epoch - $action_time->epoch;
	$ret->{boarding_countdown} = -1;
	$ret->{sched_departure}    = epoch_to_dt( $ret->{sched_dep_ts} );
	$ret->{real_departure}     = epoch_to_dt( $ret->{real_dep_ts} );
	$ret->{sched_arrival}      = epoch_to_dt( $ret->{sched_arr_ts} );
	$ret->{real_arrival}       = epoch_to_dt( $ret->{real_arr_ts} );
	$ret->{route_after}        = \@route_after;
	$ret->{extra_data}         = $ret->{data};
	$ret->{comment}            = $ret->{user_data}{comment};
	$ret->{wagongroups}        = $ret->{user_data}{wagongroups};

	$ret->{platform_type} = 'Gleis';
	if ( $ret->{train_type} and $ret->{train_type} =~ m{ ast | bus | ruf }ix ) {
		$ret->{platform_type} = 'Steig';
	}

	$ret->{visibility_str}
	  = $visibility_itoa{ $ret->{visibility} // 'default' };
	$ret->{effective_visibility_str}
	  = $visibility_itoa{ $ret->{effective_visibility} // 'default' };

	my @parsed_messages;
	for my $message ( @{ $ret->{messages} // [] } ) {
		my ( $ts, $msg ) = @{$message};
		push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
	}
	$ret->{messages} = [ reverse @parsed_messages ];

	@parsed_messages = ();
	for my $message ( @{ $ret->{extra_data}{qos_msg} // [] } ) {
		my ( $ts, $msg ) = @{$message};
		push( @parsed_messages, [ epoch_to_dt($ts), $msg ] );
	}
	$ret->{extra_data}{qos_msg} = [@parsed_messages];

	if ( $dep_info and $dep_info->{sched_arr} ) {
		$dep_info->{sched_arr}
		  = epoch_to_dt( $dep_info->{sched_arr} );
		$dep_info->{rt_arr}           = epoch_to_dt( $dep_info->{rt_arr} );
		$dep_info->{rt_arr_countdown} = $ret->{boarding_countdown}
		  = $dep_info->{rt_arr}->epoch - $epoch;
	}

	for my $station (@route) {
		if ( @{$station} > 1 ) {

			# Note: $station->[2]{sched_arr} may already have been
			# converted to a DateTime object. This can happen when a
			# station is present several times in a train's route, e.g.
			# for Frankfurt Flughafen in some nightly connections.
			my $times = $station->[2] // {};
			for my $key (qw(sched_arr rt_arr sched_dep rt_dep)) {
				if ( $times->{$key} ) {
					$times->{$key}
					  = epoch_or_dt_to_dt( $times->{$key} );
				}
			}
			if ( $times->{sched_arr} and $times->{rt_arr} ) {
				$times->{arr_delay}
				  = $times->{rt_arr}->epoch - $times->{sched_arr}->epoch;
			}
			if ( $times->{sched_arr} or $times->{rt_arr} ) {
				$times->{arr} = $times->{rt_arr} || $times->{sched_arr};
				$times->{arr_countdown} = $times->{arr}->epoch - $epoch;
			}
			if ( $times->{sched_dep} and $times->{rt_dep} ) {
				$times->{dep_delay}
				  = $times->{rt_dep}->epoch - $times->{sched_dep}->epoch;
			}
			if ( $times->{sched_dep} or $times->{rt_dep} ) {
				$times->{dep} = $times->{rt_dep} || $times->{sched_dep};
				$times->{dep_countdown} = $times->{dep}->epoch - $epoch;
			}
		}
	}

	$ret->{departure_countdown} = $ret->{real_departure}->epoch - $now->epoch;

	if ( $ret->{real_arr_ts} ) {
		$ret->{arrival_countdown} = $ret->{real_arrival}->epoch - $now->epoch;
		$ret->{journey_duration}
		  = $ret->{real_arrival}->epoch - $ret->{real_departure}->epoch;
		$ret->{journey_completion}
		  = $ret->{journey_duration}
		  ? 1 - ( $ret->{arrival_countdown} / $ret->{journey_duration} )
		  : 1;
		if ( $ret->{journey_completion} > 1 ) {
			$ret->{journey_completion} = 1;
		}
		elsif ( $ret->{journey_completion} < 0 ) {
			$ret->{journey_completion} = 0;
		}

	}
	else {
		$ret->{arrival_countdown}  = undef;
		$ret->{journey_duration}   = undef;
		$ret->{journey_completion} = undef;
	}

	return $ret;
}

sub get {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $table = 'in_transit';

	if ( $opt{with_timestamps} or $opt{with_polyline} ) {
		$table = 'in_transit_str';
	}

	my $res = $db->select( $table, '*', { user_id => $uid } );
	my $ret;

	if ( $opt{with_data} ) {
		$ret = $res->expand->hash;
	}
	else {
		$ret = $res->hash;
	}

	if ( $opt{with_polyline} and $ret ) {
		$ret->{dep_latlon} = [ $ret->{dep_lat}, $ret->{dep_lon} ];
		$ret->{arr_latlon} = [ $ret->{arr_lat}, $ret->{arr_lon} ];
	}

	if ( $opt{with_visibility} and $ret ) {
		$ret->{visibility_str}
		  = $visibility_itoa{ $ret->{visibility} // 'default' };
		$ret->{effective_visibility_str}
		  = $visibility_itoa{ $ret->{effective_visibility} // 'default' };
	}

	if ( $opt{postprocess} and $ret ) {
		return $self->postprocess($ret);
	}

	return $ret;
}

sub get_timeline {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $where = {
		follower_id          => $uid,
		effective_visibility => { '>=', 60 }
	};

	if ( $opt{short} ) {
		return $db->select(
			'follows_in_transit',
			[
				qw(followee_name train_type train_line train_no train_id dep_eva dep_name arr_eva arr_name)
			],
			$where
		)->hashes->each;
	}

	my $res = $db->select( 'follows_in_transit', '*', $where );
	my $ret;

	if ( $opt{with_data} ) {
		return map { $self->postprocess($_) } $res->expand->hashes->each;
	}
	else {
		return $res->hashes->each;
	}
}

sub get_all_active {
	my ( $self, %opt ) = @_;
	my $db = $opt{db} // $self->{pg}->db;
	return $db->select( 'in_transit_str', '*', { cancelled => 0 } )
	  ->hashes->each;
}

sub get_checkout_ids {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $status = $db->select(
		'in_transit',
		[ 'checkout_station_id', 'backend_id' ],
		{ user_id => $uid }
	)->hash;

	if ($status) {
		return $status->{checkout_station_id}, $status->{backend_id};
	}
	return;
}

sub set_cancelled_destination {
	my ( $self, %opt ) = @_;

	my $uid                   = $opt{uid};
	my $db                    = $opt{db} // $self->{pg}->db;
	my $cancelled_destination = $opt{cancelled_destination};

	my $res_h = $db->select( 'in_transit', ['data'], { user_id => $uid } )
	  ->expand->hash;

	my $data = $res_h ? $res_h->{data} : {};

	$data->{cancelled_destination} = $cancelled_destination;

	$db->update(
		'in_transit',
		{
			checkout_station_id => undef,
			checkout_time       => undef,
			arr_platform        => undef,
			sched_arrival       => undef,
			real_arrival        => undef,
			data                => JSON->new->encode($data),
		},
		{ user_id => $uid }
	);
}

sub set_arrival {
	my ( $self, %opt ) = @_;

	my $uid   = $opt{uid};
	my $db    = $opt{db} // $self->{pg}->db;
	my $train = $opt{train};

	my $json = JSON->new;

	$db->update(
		'in_transit',
		{
			checkout_time => DateTime->now( time_zone => 'Europe/Berlin' ),
			arr_platform  => $train->platform,
			sched_arrival => $train->sched_arrival,
			real_arrival  => $train->arrival,
			messages      => $json->encode(
				[ map { [ $_->[0]->epoch, $_->[1] ] } $train->messages ]
			)
		},
		{ user_id => $uid }
	);
}

sub set_arrival_eva {
	my ( $self, %opt ) = @_;

	my $uid                 = $opt{uid};
	my $db                  = $opt{db} // $self->{pg}->db;
	my $checkout_station_id = $opt{arrival_eva};

	$db->update(
		'in_transit',
		{
			checkout_station_id => $checkout_station_id,
		},
		{ user_id => $uid }
	);
}

sub set_arrival_times {
	my ( $self, %opt ) = @_;

	my $uid       = $opt{uid};
	my $db        = $opt{db} // $self->{pg}->db;
	my $sched_arr = $opt{sched_arrival};
	my $rt_arr    = $opt{rt_arrival};

	$db->update(
		'in_transit',
		{
			sched_arrival => $sched_arr,
			real_arrival  => $rt_arr
		},
		{ user_id => $uid }
	);
}

sub set_polyline {
	my ( $self, %opt ) = @_;

	my $uid      = $opt{uid};
	my $db       = $opt{db} // $self->{pg}->db;
	my $polyline = $opt{polyline};
	my $old_id   = $opt{old_id};

	my $coords   = $polyline->{coords};
	my $from_eva = $polyline->{from_eva};
	my $to_eva   = $polyline->{to_eva};

	my $polyline_str = JSON->new->encode($coords);

	my $pl_res = $db->select(
		'polylines',
		['id'],
		{
			origin_eva      => $from_eva,
			destination_eva => $to_eva,
			polyline        => $polyline_str,
		},
		{ limit => 1 }
	);

	my $polyline_id;
	if ( my $h = $pl_res->hash ) {
		$polyline_id = $h->{id};
	}
	else {
		eval {
			$polyline_id = $db->insert(
				'polylines',
				{
					origin_eva      => $from_eva,
					destination_eva => $to_eva,
					polyline        => $polyline_str
				},
				{ returning => 'id' }
			)->hash->{id};
		};
		if ($@) {
			$self->{log}->warn("add_route_timestamps: insert polyline: $@");
		}
	}
	if ( $polyline_id and ( not defined $old_id or $polyline_id != $old_id ) ) {
		$self->set_polyline_id(
			uid         => $uid,
			db          => $db,
			polyline_id => $polyline_id,
			train_id    => $opt{train_id},
		);
	}

}

sub set_polyline_id {
	my ( $self, %opt ) = @_;

	my $uid         = $opt{uid};
	my $db          = $opt{db} // $self->{pg}->db;
	my $polyline_id = $opt{polyline_id};

	my %where = ( user_id => $uid );

	if ( $opt{train_id} ) {
		$where{train_id} = $opt{train_id};
	}

	$db->update( 'in_transit', { polyline_id => $polyline_id }, \%where );
}

sub set_route_data {
	my ( $self, %opt ) = @_;

	my $uid       = $opt{uid};
	my $db        = $opt{db} // $self->{pg}->db;
	my $route     = $opt{route};
	my $delay_msg = $opt{delay_messages};
	my $qos_msg   = $opt{qos_messages};
	my $him_msg   = $opt{him_messages};

	my %where = ( user_id => $uid );

	if ( $opt{train_id} ) {
		$where{train_id} = $opt{train_id};
	}

	my $res_h = $db->select( 'in_transit', ['data'], { user_id => $uid } )
	  ->expand->hash;

	my $data = $res_h ? $res_h->{data} : {};

	$data->{delay_msg} = $opt{delay_messages};
	$data->{qos_msg}   = $opt{qos_messages};
	$data->{him_msg}   = $opt{him_messages};

	# no need to merge $route, it already contains HAFAS data
	$db->update(
		'in_transit',
		{
			route => JSON->new->encode($route),
			data  => JSON->new->encode($data)
		},
		\%where
	);
}

sub unset_arrival_data {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	$db->update(
		'in_transit',
		{
			checkout_time => undef,
			arr_platform  => undef,
			sched_arrival => undef,
			real_arrival  => undef,
		},
		{ user_id => $uid }
	);
}

sub update_departure {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $train   = $opt{train};
	my $route   = $opt{route};
	my $json    = JSON->new;

	$route = $self->_merge_old_route(
		db    => $db,
		uid   => $uid,
		route => $route
	);

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			dep_platform   => $train->platform,
			real_departure => $train->departure,
			route          => $json->encode($route),
			messages       => $json->encode(
				[ map { [ $_->[0]->epoch, $_->[1] ] } $train->messages ]
			),
		},
		{
			user_id             => $uid,
			train_no            => $train->train_no,
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_departure_cancelled {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $train   = $opt{train};

	# depending on the amount of users in transit, some time may
	# have passed between fetching $entry from the database and
	# now. Ensure that the user is still checked into this train
	# by selecting on uid, train no, and checkin/checkout station ID.
	my $rows = $db->update(
		'in_transit',
		{
			cancelled => 1,
		},
		{
			user_id             => $uid,
			train_no            => $train->train_no,
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	)->rows;

	return $rows;
}

sub update_departure_dbris {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $journey = $opt{journey};
	my $stop    = $opt{stop};
	my $json    = JSON->new;

	my $res_h = $db->select( 'in_transit', [ 'data', 'user_data' ],
		{ user_id => $uid } )->expand->hash;
	my $ephemeral_data  = $res_h ? $res_h->{data}      : {};
	my $persistent_data = $res_h ? $res_h->{user_data} : {};

	if ( $stop->{rt_dep} ) {
		$ephemeral_data->{rt} = 1;
	}

	$ephemeral_data->{him_msg}  = [];
	$persistent_data->{him_msg} = [];
	for my $msg ( $journey->messages ) {
		if ( not $msg->{ueberschrift} ) {
			push(
				@{ $ephemeral_data->{him_msg} },
				{
					header => q{},
					prio   => $msg->{prioritaet},
					lead   => $msg->{text}
				}
			);
			push(
				@{ $persistent_data->{him_msg} },
				{
					prio => $msg->{prioritaet},
					lead => $msg->{text}
				}
			);
		}
	}

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			real_departure => $stop->{rt_dep},
			data           => $json->encode($ephemeral_data),
			user_data      => $json->encode($persistent_data),
		},
		{
			user_id             => $uid,
			train_id            => $opt{train_id},
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_departure_efa {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $journey = $opt{journey};
	my $stop    = $opt{stop};
	my $json    = JSON->new;

	my $res_h = $db->select( 'in_transit', ['data'], { user_id => $uid } )
	  ->expand->hash;
	my $ephemeral_data = $res_h ? $res_h->{data} : {};
	if ( $stop->rt_dep ) {
		$ephemeral_data->{rt} = 1;
	}

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			data           => $json->encode($ephemeral_data),
			real_departure => $stop->rt_dep,
		},
		{
			user_id             => $uid,
			train_id            => $opt{trip_id},
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_departure_motis {
	my ( $self, %opt ) = @_;
	my $uid      = $opt{uid};
	my $db       = $opt{db} // $self->{pg}->db;
	my $dep_eva  = $opt{dep_eva};
	my $arr_eva  = $opt{arr_eva};
	my $journey  = $opt{journey};
	my $stopover = $opt{stopover};
	my $json     = JSON->new;

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			real_departure => $stopover->{realtime_departure},
		},
		{
			user_id             => $uid,
			train_id            => $opt{train_id},
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_departure_hafas {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $journey = $opt{journey};
	my $stop    = $opt{stop};
	my $json    = JSON->new;

	my $res_h = $db->select( 'in_transit', ['data'], { user_id => $uid } )
	  ->expand->hash;
	my $ephemeral_data = $res_h ? $res_h->{data} : {};
	if ( $stop->{rt_dep} ) {
		$ephemeral_data->{rt} = 1;
	}

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			data           => $json->encode($ephemeral_data),
			real_departure => $stop->{rt_dep},
		},
		{
			user_id             => $uid,
			train_id            => $journey->id,
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_arrival {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $train   = $opt{train};
	my $route   = $opt{route};
	my $json    = JSON->new;

	$route = $self->_merge_old_route(
		db    => $db,
		uid   => $uid,
		route => $route
	);

	# selecting on user_id, train_no and checkout_station_id avoids a
	# race condition when a user checks into a new train or changes
	# their destination station while we are fetching times based on no
	# longer valid database entries.
	my $rows = $db->update(
		'in_transit',
		{
			arr_platform  => $train->platform,
			sched_arrival => $train->sched_arrival,
			real_arrival  => $train->arrival,
			route         => $json->encode($route),
			messages      => $json->encode(
				[ map { [ $_->[0]->epoch, $_->[1] ] } $train->messages ]
			),
		},
		{
			user_id             => $uid,
			train_no            => $train->train_no,
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	)->rows;

	return $rows;
}

sub update_arrival_dbris {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $journey = $opt{journey};
	my $stop    = $opt{stop};
	my $json    = JSON->new;

	my $res_h = $db->select( 'in_transit', [ 'data', 'user_data' ],
		{ user_id => $uid } )->expand->hash;
	my $ephemeral_data  = $res_h ? $res_h->{data}      : {};
	my $persistent_data = $res_h ? $res_h->{user_data} : {};

	if ( $stop->{rt_arr} ) {
		$ephemeral_data->{rt} = 1;
	}

	$ephemeral_data->{him_msg}  = [];
	$persistent_data->{him_msg} = [];
	for my $msg ( $journey->messages ) {
		if ( not $msg->{ueberschrift} ) {
			push(
				@{ $ephemeral_data->{him_msg} },
				{
					header => q{},
					prio   => $msg->{prioritaet},
					lead   => $msg->{text}
				}
			);
			push(
				@{ $persistent_data->{him_msg} },
				{
					prio => $msg->{prioritaet},
					lead => $msg->{text}
				}
			);
		}
	}

	my @route;
	for my $j_stop ( $journey->route ) {
		push(
			@route,
			[
				$j_stop->name,
				$j_stop->eva,
				{
					sched_arr   => _epoch( $j_stop->sched_arr ),
					sched_dep   => _epoch( $j_stop->sched_dep ),
					rt_arr      => _epoch( $j_stop->rt_arr ),
					rt_dep      => _epoch( $j_stop->rt_dep ),
					platform    => $j_stop->platform,
					isCancelled => $j_stop->is_cancelled,
					arr_delay   => $j_stop->arr_delay,
					dep_delay   => $j_stop->dep_delay,
					load        => {
						FIRST  => $j_stop->occupancy_first,
						SECOND => $j_stop->occupancy_second
					},
					lat => $j_stop->lat,
					lon => $j_stop->lon,
				}
			]
		);
	}

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			real_arrival => $stop->{rt_arr},
			arr_platform => $stop->{platform},
			route        => $json->encode( [@route] ),
			data         => $json->encode($ephemeral_data),
			user_data    => $json->encode($persistent_data),
		},
		{
			user_id             => $uid,
			train_id            => $opt{train_id},
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_arrival_efa {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $journey = $opt{journey};
	my $stop    = $opt{stop};
	my $json    = JSON->new;

	my $res_h
	  = $db->select( 'in_transit', [ 'data', 'route' ], { user_id => $uid } )
	  ->expand->hash;
	my $ephemeral_data = $res_h ? $res_h->{data}  : {};
	my $old_route      = $res_h ? $res_h->{route} : [];

	if ( $stop->rt_arr ) {
		$ephemeral_data->{rt} = 1;
	}

	my @route;
	for my $j_stop ( $journey->route ) {
		push(
			@route,
			[
				$j_stop->full_name,
				$j_stop->id_num,
				{
					sched_arr   => _epoch( $j_stop->sched_arr ),
					sched_dep   => _epoch( $j_stop->sched_dep ),
					rt_arr      => _epoch( $j_stop->rt_arr ),
					rt_dep      => _epoch( $j_stop->rt_dep ),
					isCancelled => $j_stop->is_cancelled,
					arr_delay   => $j_stop->arr_delay,
					dep_delay   => $j_stop->dep_delay,
					efa_load    => $j_stop->occupancy,
					lat         => $j_stop->latlon->[0],
					lon         => $j_stop->latlon->[1],
				}
			]
		);
	}

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			data         => $json->encode($ephemeral_data),
			real_arrival => $stop->rt_arr,
			route        => $json->encode( [@route] ),
		},
		{
			user_id             => $uid,
			train_id            => $opt{trip_id},
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_arrival_motis {
	my ( $self, %opt ) = @_;
	my $uid      = $opt{uid};
	my $db       = $opt{db} // $self->{pg}->db;
	my $dep_eva  = $opt{dep_eva};
	my $arr_eva  = $opt{arr_eva};
	my $journey  = $opt{journey};
	my $stopover = $opt{stopover};
	my $json     = JSON->new;

	my @route;
	for my $journey_stopover ( $journey->stopovers ) {
		push(
			@route,
			[
				$journey_stopover->stop->name,
				$journey_stopover->stop->{eva}
				  // die('eva not set for stopover'),
				{
					sched_arr => _epoch( $journey_stopover->scheduled_arrival ),
					sched_dep =>
					  _epoch( $journey_stopover->scheduled_departure ),
					rt_arr => _epoch( $journey_stopover->realtime_arrival ),
					rt_dep => _epoch( $journey_stopover->realtime_departure ),
					arr_delay => $journey_stopover->arrival_delay,
					dep_delay => $journey_stopover->departure_delay,
					lat       => $journey_stopover->stop->lat,
					lon       => $journey_stopover->stop->lon,
				}
			]
		);
	}

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			real_arrival => $stopover->{realtime_arrival},
			route        => $json->encode( [@route] ),
		},
		{
			user_id             => $uid,
			train_id            => $opt{train_id},
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_arrival_hafas {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
	my $dep_eva = $opt{dep_eva};
	my $arr_eva = $opt{arr_eva};
	my $journey = $opt{journey};
	my $stop    = $opt{stop};
	my $json    = JSON->new;

	my $res_h
	  = $db->select( 'in_transit', [ 'data', 'route' ], { user_id => $uid } )
	  ->expand->hash;
	my $ephemeral_data = $res_h ? $res_h->{data}  : {};
	my $old_route      = $res_h ? $res_h->{route} : [];

	if ( $stop->{rt_arr} ) {
		$ephemeral_data->{rt} = 1;
	}

	my @route;
	for my $j_stop ( $journey->route ) {
		push(
			@route,
			[
				$j_stop->loc->name,
				$j_stop->loc->eva,
				{
					sched_arr => _epoch( $j_stop->sched_arr ),
					sched_dep => _epoch( $j_stop->sched_dep ),
					rt_arr    => _epoch( $j_stop->rt_arr ),
					rt_dep    => _epoch( $j_stop->rt_dep ),
					arr_delay => $j_stop->arr_delay,
					dep_delay => $j_stop->dep_delay,
					load      => $j_stop->load,
					lat       => $j_stop->loc->lat,
					lon       => $j_stop->loc->lon,
				}
			]
		);
		if ( defined $j_stop->tz_offset ) {
			$route[-1][2]{tz_offset} = $j_stop->tz_offset;
		}
	}

	for my $i ( 0 .. $#route ) {
		if ( $old_route->[$i] and $old_route->[$i][1] == $route[$i][1] ) {
			for my $k (qw(rt_arr rt_dep arr_delay dep_delay)) {
				$route[$i][2]{$k} //= $old_route->[$i][2]{$k};
			}
		}
	}

	# selecting on user_id and train_no avoids a race condition if a user checks
	# into a new train while we are fetching data for their previous journey. In
	# this case, the new train would receive data from the previous journey.
	$db->update(
		'in_transit',
		{
			data         => $json->encode($ephemeral_data),
			real_arrival => $stop->{rt_arr},
			route        => $json->encode( [@route] ),
		},
		{
			user_id             => $uid,
			train_id            => $journey->id,
			checkin_station_id  => $dep_eva,
			checkout_station_id => $arr_eva,
		}
	);
}

sub update_data {
	my ( $self, %opt ) = @_;

	my $uid      = $opt{uid};
	my $db       = $opt{db}   // $self->{pg}->db;
	my $new_data = $opt{data} // {};

	my %where = ( user_id => $uid );

	if ( $opt{train_id} ) {
		$where{train_id} = $opt{train_id};
	}

	my $res_h = $db->select( 'in_transit', ['data'], { user_id => $uid } )
	  ->expand->hash;

	my $data = $res_h ? $res_h->{data} : {};

	while ( my ( $k, $v ) = each %{$new_data} ) {
		$data->{$k} = $v;
	}

	$db->update( 'in_transit', { data => JSON->new->encode($data) }, \%where );
}

sub update_user_data {
	my ( $self, %opt ) = @_;

	my $uid      = $opt{uid};
	my $db       = $opt{db}        // $self->{pg}->db;
	my $new_data = $opt{user_data} // {};

	my %where = ( user_id => $uid );

	if ( $opt{train_id} ) {
		$where{train_id} = $opt{train_id};
	}

	my $res_h = $db->select( 'in_transit', ['user_data'], { user_id => $uid } )
	  ->expand->hash;

	my $data = $res_h ? $res_h->{user_data} : {};

	while ( my ( $k, $v ) = each %{$new_data} ) {
		$data->{$k} = $v;
	}

	$db->update( 'in_transit',
		{ user_data => JSON->new->encode($data) }, \%where );
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
		'in_transit',
		{ visibility => $visibility },
		{ user_id    => $uid }
	);
}

1;
