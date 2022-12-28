package Travelynx::Command::influxdb;

# Copyright (C) 2022 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Generate statistics for InfluxDB';

has usage => sub { shift->extract_usage };

sub query_to_influx {
	my ( $label, $value ) = @_;

	if ( defined $value ) {
		return sprintf( '%s=%f', $label, $value );
	}
	return;
}

sub run {
	my ($self) = @_;

	my $db = $self->app->pg->db;

	my $now    = DateTime->now( time_zone => 'Europe/Berlin' );
	my $active = $now->clone->subtract( months => 1 );

	my $checkin_window_query
	  = qq{select count(*) as count from journeys where checkin_time > to_timestamp(?);};

	# DateTime's  math does not like time zones: When subtracting 7 days from
	# sun 2am and the previous sunday was the switch from CET to CEST (i.e.,
	# the switch to daylight saving time), the resulting datetime is invalid.
	# This is a fatal error. We avoid this edge case by performing date math
	# on the epoch timestamp, which does not know or care about time zones and
	# daylight saving time.
	my $one_day   = 24 * 60 * 60;
	my $one_week  = 7 * $one_day;
	my $one_month = 30 * $one_day;

	my @out;

	push(
		@out,
		query_to_influx(
			'pending_user_count',
			$db->select( 'users', 'count(*) as count', { status => 0 } )
			  ->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'reg_user_count',
			$db->select( 'users', 'count(*) as count', { status => 1 } )
			  ->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'active_user_count',
			$db->select(
				'users',
				'count(*) as count',
				{
					status    => 1,
					last_seen => { '>', $active }
				}
			)->hash->{count}
		)
	);

	push(
		@out,
		query_to_influx(
			'checked_in_count',
			$db->select( 'in_transit', 'count(*) as count' )->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'checkins_24h_count',
			$db->query( $checkin_window_query, $now->epoch - $one_day )
			  ->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'checkins_7d_count',
			$db->query( $checkin_window_query, $now->epoch - $one_week )
			  ->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'checkins_30d_count',
			$db->query( $checkin_window_query, $now->epoch - $one_month )
			  ->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'polyline_count',
			$db->select( 'polylines', 'count(*) as count' )->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'traewelling_pull_count',
			$db->select(
				'traewelling',
				'count(*) as count',
				{ pull_sync => 1 }
			)->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'traewelling_push_count',
			$db->select(
				'traewelling',
				'count(*) as count',
				{ push_sync => 1 }
			)->hash->{count}
		)
	);
	push(
		@out,
		query_to_influx(
			'polyline_ratio',
			$db->query(
'select (select count(polyline_id) from journeys)::float / (select count(*) from polylines) as ratio'
			)->hash->{ratio}
		)
	);

	say join( ',', @out );
	return;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl influx

  Write statistics for InfluxDB to stdout
