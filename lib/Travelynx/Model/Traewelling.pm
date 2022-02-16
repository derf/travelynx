package Travelynx::Model::Traewelling;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;

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

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub now {
	return DateTime->now( time_zone => 'Europe/Berlin' );
}

sub link {
	my ( $self, %opt ) = @_;

	my $log = [ [ $self->now->epoch, "Erfolgreich angemeldet" ] ];

	my $data = {
		log     => $log,
		expires => $opt{expires}->epoch,
	};

	my $user_entry = {
		user_id   => $opt{uid},
		email     => $opt{email},
		push_sync => 0,
		pull_sync => 0,
		token     => $opt{token},
		data      => JSON->new->encode($data),
	};

	$self->{pg}->db->insert(
		'traewelling',
		$user_entry,
		{
			on_conflict => \
'(user_id) do update set email = EXCLUDED.email, token = EXCLUDED.token, push_sync = false, pull_sync = false, data = null, errored = false, latest_run = null'
		}
	);

	return $user_entry;
}

sub set_user {
	my ( $self, %opt ) = @_;

	my $res_h
	  = $self->{pg}
	  ->db->select( 'traewelling', 'data', { user_id => $opt{uid} } )
	  ->expand->hash;

	$res_h->{data}{user_id}     = $opt{trwl_id};
	$res_h->{data}{screen_name} = $opt{screen_name};
	$res_h->{data}{user_name}   = $opt{user_name};

	$self->{pg}->db->update(
		'traewelling',
		{ data    => JSON->new->encode( $res_h->{data} ) },
		{ user_id => $opt{uid} }
	);
}

sub unlink {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};

	$self->{pg}->db->delete( 'traewelling', { user_id => $uid } );
}

sub get {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $res_h
	  = $db->select( 'traewelling_str', '*', { user_id => $uid } )
	  ->expand->hash;

	$res_h->{latest_run} = epoch_to_dt( $res_h->{latest_run_ts} );
	for my $log_entry ( @{ $res_h->{data}{log} // [] } ) {
		$log_entry->[0] = epoch_to_dt( $log_entry->[0] );
	}
	$res_h->{expires_on} = epoch_to_dt( $res_h->{data}{expires} );

	my $expires_in = ( $res_h->{data}{expires} // 0 ) - $self->now->epoch;

	if ( $expires_in < 0 ) {
		$res_h->{expired} = 1;
	}
	elsif ( $expires_in < 14 * 24 * 3600 ) {
		$res_h->{expiring} = 1;
	}

	return $res_h;
}

sub log {
	my ( $self, %opt ) = @_;
	my $uid      = $opt{uid};
	my $message  = $opt{message};
	my $is_error = $opt{is_error};
	my $db       = $opt{db} // $self->{pg}->db;
	my $res_h
	  = $db->select( 'traewelling', 'data', { user_id => $uid } )->expand->hash;
	splice( @{ $res_h->{data}{log} // [] }, 9 );
	unshift(
		@{ $res_h->{data}{log} },
		[ $self->now->epoch, $message, $opt{status_id} ]
	);

	if ($is_error) {
		$res_h->{data}{error} = $message;
	}
	$db->update(
		'traewelling',
		{
			errored    => $is_error ? 1 : 0,
			latest_run => $self->now,
			data       => JSON->new->encode( $res_h->{data} )
		},
		{ user_id => $uid }
	);
}

sub set_latest_pull_status_id {
	my ( $self, %opt ) = @_;
	my $uid       = $opt{uid};
	my $status_id = $opt{status_id};
	my $db        = $opt{db} // $self->{pg}->db;

	my $res_h
	  = $db->select( 'traewelling', 'data', { user_id => $uid } )->expand->hash;

	$res_h->{data}{latest_pull_status_id} = $status_id;

	$db->update(
		'traewelling',
		{ data    => JSON->new->encode( $res_h->{data} ) },
		{ user_id => $uid }
	);
}

sub set_latest_push_ts {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $ts  = $opt{ts};
	my $db  = $opt{db} // $self->{pg}->db;

	my $res_h
	  = $db->select( 'traewelling', 'data', { user_id => $uid } )->expand->hash;

	$res_h->{data}{latest_push_ts} = $ts;

	$db->update(
		'traewelling',
		{ data    => JSON->new->encode( $res_h->{data} ) },
		{ user_id => $uid }
	);
}

sub set_sync {
	my ( $self, %opt ) = @_;

	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;

	my $res_h
	  = $db->select( 'traewelling', 'data', { user_id => $uid } )->expand->hash;

	$res_h->{data}{toot}  = $opt{toot};
	$res_h->{data}{tweet} = $opt{tweet};

	$db->update(
		'traewelling',
		{
			push_sync => $opt{push_sync},
			pull_sync => $opt{pull_sync},
			data      => JSON->new->encode( $res_h->{data} ),
		},
		{ user_id => $uid }
	);
}

sub get_pushable_accounts {
	my ($self) = @_;
	my $res = $self->{pg}->db->query(
		qq{select t.user_id as uid, t.token as token, t.data as data,
			i.user_data as user_data,
			i.checkin_station_id as dep_eva, i.checkout_station_id as arr_eva,
			i.data as journey_data, i.train_type as train_type,
			i.train_line as train_line, i.train_no as train_no,
			extract(epoch from i.checkin_time) as checkin_ts,
			extract(epoch from i.sched_departure) as dep_ts,
			extract(epoch from i.sched_arrival) as arr_ts
			from traewelling as t
			join in_transit as i on t.user_id = i.user_id
			where t.push_sync = True
			and i.checkout_station_id is not null
			and i.cancelled = False
		}
	);
	return $res->expand->hashes->each;
}

sub get_pull_accounts {
	my ($self) = @_;
	my $res = $self->{pg}->db->select(
		'traewelling',
		[ 'user_id', 'token', 'data' ],
		{ pull_sync => 1 }
	);
	return $res->expand->hashes->each;
}

1;
