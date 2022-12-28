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
			'checkin_count',
			$db->select( 'journeys', 'count(*) as count' )->hash->{count}
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
