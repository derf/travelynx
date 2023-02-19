package Travelynx::Model::InTransit;

# Copyright (C) 2020-2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use JSON;

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
	my $train              = $opt{train};
	my $checkin_station_id = $opt{departure_eva};
	my $route              = $opt{route};

	my $json = JSON->new;

	$db->insert(
		'in_transit',
		{
			user_id   => $uid,
			cancelled => $train->departure_is_cancelled
			? 1
			: 0,
			checkin_station_id => $checkin_station_id,
			checkin_time       => DateTime->now( time_zone => 'Europe/Berlin' ),
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
			)
		}
	);
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

sub get {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $table = 'in_transit';

	if ( $opt{with_timestamps} ) {
		$table = 'in_transit_str';
	}

	my $res = $db->select( $table, '*', { user_id => $uid } );

	if ( $opt{with_data} ) {
		return $res->expand->hash;
	}
	return $res->hash;
}

sub get_all_active {
	my ( $self, %opt ) = @_;
	my $db = $opt{db} // $self->{pg}->db;
	return $db->select( 'in_transit_str', '*', { cancelled => 0 } )
	  ->hashes->each;
}

sub get_checkout_station_id {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $status = $db->select( 'in_transit', ['checkout_station_id'],
		{ user_id => $uid } )->hash;

	if ($status) {
		return $status->{checkout_station_id};
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
	my $route = $opt{route};

	$route = $self->_merge_old_route(
		db    => $db,
		uid   => $uid,
		route => $route
	);

	my $json = JSON->new;

	$db->update(
		'in_transit',
		{
			checkout_time => DateTime->now( time_zone => 'Europe/Berlin' ),
			arr_platform  => $train->platform,
			sched_arrival => $train->sched_arrival,
			real_arrival  => $train->arrival,
			route         => $json->encode($route),
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

sub set_polyline_id {
	my ( $self, %opt ) = @_;

	my $uid         = $opt{uid};
	my $db          = $opt{db} // $self->{pg}->db;
	my $polyline_id = $opt{polyline_id};

	$db->update(
		'in_transit',
		{ polyline_id => $polyline_id },
		{ user_id     => $uid }
	);
}

sub set_route_data {
	my ( $self, %opt ) = @_;

	my $uid       = $opt{uid};
	my $db        = $opt{db} // $self->{pg}->db;
	my $route     = $opt{route};
	my $delay_msg = $opt{delay_messages};
	my $qos_msg   = $opt{qos_messages};
	my $him_msg   = $opt{him_messages};

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
		{ user_id => $uid }
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
	my $uid   = $opt{uid};
	my $db    = $opt{db} // $self->{pg}->db;
	my $train = $opt{train};
	my $route = $opt{route};
	my $json  = JSON->new;

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
			user_id  => $uid,
			train_no => $train->train_no
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

sub update_arrival {
	my ( $self, %opt ) = @_;
	my $uid     = $opt{uid};
	my $db      = $opt{db} // $self->{pg}->db;
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
			checkout_station_id => $arr_eva,
		}
	)->rows;

	return $rows;
}

sub update_data {
	my ( $self, %opt ) = @_;

	my $uid      = $opt{uid};
	my $db       = $opt{db}   // $self->{pg}->db;
	my $new_data = $opt{data} // {};

	my $res_h = $db->select( 'in_transit', ['data'], { user_id => $uid } )
	  ->expand->hash;

	my $data = $res_h ? $res_h->{data} : {};

	while ( my ( $k, $v ) = each %{$new_data} ) {
		$data->{$k} = $v;
	}

	$db->update(
		'in_transit',
		{ data    => JSON->new->encode($data) },
		{ user_id => $uid }
	);
}

sub update_user_data {
	my ( $self, %opt ) = @_;

	my $uid      = $opt{uid};
	my $db       = $opt{db}        // $self->{pg}->db;
	my $new_data = $opt{user_data} // {};

	my $res_h = $db->select( 'in_transit', ['user_data'], { user_id => $uid } )
	  ->expand->hash;

	my $data = $res_h ? $res_h->{user_data} : {};

	while ( my ( $k, $v ) = each %{$new_data} ) {
		$data->{$k} = $v;
	}

	$db->update(
		'in_transit',
		{ user_data => JSON->new->encode($data) },
		{ user_id   => $uid }
	);
}

1;
