package Travelynx::Command::munin;
# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: MIT
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Generate statistics for munin-node';

has usage => sub { shift->extract_usage };

sub query_to_munin {
	my ( $label, $value ) = @_;

	if ( defined $value ) {
		printf( "%s.value %f\n", $label, $value );
	}
}

sub run {
	my ( $self, $filename ) = @_;

	my $db = $self->app->pg->db;

	my $now    = DateTime->now( time_zone => 'Europe/Berlin' );
	my $active = $now->clone->subtract( months => 1 );

	my $checkin_window_query
	  = qq{select count(*) as count from journeys where checkin_time > to_timestamp(?);};

	query_to_munin( 'reg_user_count',
		$db->select( 'users', 'count(*) as count', { status => 1 } )
		  ->hash->{count} );
	query_to_munin(
		'active_user_count',
		$db->select(
			'users',
			'count(*) as count',
			{
				status    => 1,
				last_seen => { '>', $active }
			}
		)->hash->{count}
	);
	query_to_munin( 'checked_in',
		$db->select( 'in_transit', 'count(*) as count' )->hash->{count} );
	query_to_munin(
		'checkins_24h',
		$db->query( $checkin_window_query,
			$now->subtract( hours => 24 )->epoch )->hash->{count}
	);
	query_to_munin( 'checkins_7d',
		$db->query( $checkin_window_query, $now->subtract( days => 7 )->epoch )
		  ->hash->{count} );
	query_to_munin(
		'checkins_30d',
		$db->query(
			$checkin_window_query, $now->subtract( days => 30 )->epoch
		)->hash->{count}
	);
	query_to_munin( 'polylines',
		$db->select( 'polylines', 'count(*) as count' )->hash->{count} );
	query_to_munin(
		'polyline_ratio',
		$db->query(
'select (select count(polyline_id) from journeys)::float / (select count(*) from polylines) as ratio'
		)->hash->{ratio}
	);
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl munin

  Write statistics for munin-node to stdout
