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

	my @stats;
	my @traewelling;

	push(
		@stats,
		query_to_influx(
			'pending_user_count',
			$db->select( 'users', 'count(*) as count', { status => 0 } )
			  ->hash->{count}
		)
	);
	push(
		@stats,
		query_to_influx(
			'reg_user_count',
			$db->select( 'users', 'count(*) as count', { status => 1 } )
			  ->hash->{count}
		)
	);
	push(
		@stats,
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
		@stats,
		query_to_influx(
			'checked_in_count',
			$db->select( 'in_transit', 'count(*) as count' )->hash->{count}
		)
	);
	push(
		@stats,
		query_to_influx(
			'checkin_count',
			$db->select( 'journeys', 'count(*) as count' )->hash->{count}
		)
	);
	push(
		@stats,
		query_to_influx(
			'polyline_count',
			$db->select( 'polylines', 'count(*) as count' )->hash->{count}
		)
	);
	push(
		@traewelling,
		query_to_influx(
			'pull_user_count',
			$db->select(
				'traewelling',
				'count(*) as count',
				{ pull_sync => 1 }
			)->hash->{count}
		)
	);
	push(
		@traewelling,
		query_to_influx(
			'push_user_count',
			$db->select(
				'traewelling',
				'count(*) as count',
				{ push_sync => 1 }
			)->hash->{count}
		)
	);
	push(
		@stats,
		query_to_influx(
			'polyline_ratio',
			$db->query(
'select (select count(polyline_id) from journeys)::float / (select count(*) from polylines) as ratio'
			)->hash->{ratio}
		)
	);

	if ( $self->app->config->{influxdb}->{url} ) {
		$self->app->ua->post_p(
			$self->app->config->{influxdb}->{url},
			'stats ' . join( ',', @stats )
		)->wait;
		$self->app->ua->post_p(
			$self->app->config->{influxdb}->{url},
			'traewelling ' . join( ',', @traewelling )
		)->wait;
	}
	else {
		$self->app->log->warn(
			"influxdb command called, but no influxdb url has been configured");
	}

	return;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl influxdb

  Write statistics to InfluxDB
