package Travelynx::Command::missingstations;

# Copyright (C) 2022 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Command';
use List::Util qw();
use Travel::Status::DE::IRIS::Stations;

sub run {
	my ($self) = @_;

	my %station;

	for my $s ( Travel::Status::DE::IRIS::Stations::get_stations() ) {
		$station{ $s->[2] } = 1;
	}

	my @journey_stations;

	my $res
	  = $self->app->pg->db->select( 'journeys', ['checkin_station_id'], {},
		{ group_by => ['checkin_station_id'] } );
	for my $j ( $res->hashes->each ) {
		push( @journey_stations, $j->{checkin_station_id} );
	}

	$res = $self->app->pg->db->select( 'journeys', ['checkout_station_id'], {},
		{ group_by => ['checkout_station_id'] } );
	for my $j ( $res->hashes->each ) {
		push( @journey_stations, $j->{checkout_station_id} );
	}

	@journey_stations = List::Util::uniq @journey_stations;

	for my $eva (@journey_stations) {
		if ( not $station{$eva} ) {
			say $eva;
		}
	}
}

1;
