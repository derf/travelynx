package Travelynx::Model::InTransit;
# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: MIT

use strict;
use warnings;
use 5.020;

use DateTime;
use JSON;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
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

sub update_data {
	my ( $self, %opt ) = @_;

	my $uid      = $opt{uid};
	my $db       = $opt{db} // $self->{pg}->db;
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
	my $db       = $opt{db} // $self->{pg}->db;
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
