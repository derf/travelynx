package Travelynx::Command::integritycheck;

# Copyright (C) 2022 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Command';
use List::Util qw();
use Travel::Status::DE::IRIS::Stations;

sub run {
	my ($self) = @_;

	my %station
	  = map { $_->[2] => 1 } Travel::Status::DE::IRIS::Stations::get_stations();

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
	my $found = 0;

	for my $eva (@journey_stations) {
		if ( not $station{$eva} ) {
			if ( not $found ) {
				say
'Journeys in the travelynx database contain the following unknown EVA IDs.';
				say '------------8<----------';
				say 'Travel::Status::DE::IRIS v'
				  . $Travel::Status::DE::IRIS::Stations::VERSION;
				$found = 1;
			}
			say $eva;
		}
	}
	if ($found) {
		say '------------8<----------';
		say '';
		$found = 0;
	}

	%station
	  = map { $_->[1] => 1 } Travel::Status::DE::IRIS::Stations::get_stations();
	my %notified;
	my $rename = $self->app->renamed_station;

	$res
	  = $self->app->pg->db->select( 'journeys', [ 'route', 'edited' ] )->expand;
	while ( my $j = $res->hash ) {
		if ( $j->{edited} & 0x0010 ) {
			next;
		}
		for my $stop ( @{ $j->{route} // [] } ) {
			my $stop_name = $stop->[0];
			if ( $rename->{$stop_name} ) {
				$stop_name = $rename->{$stop_name};
			}
			if ( not $station{$stop_name} and not $notified{$stop_name} ) {
				if ( not $found ) {
					say
'Journeys in the travelynx database contain the following unknown route entries.';
					say 'Note that this check ignores manual route entries.';
					say 'All reports refer to routes obtained via HAFAS/IRIS.';
					say '------------8<----------';
					say 'Travel::Status::DE::IRIS v'
					  . $Travel::Status::DE::IRIS::Stations::VERSION;
					$found = 1;
				}
				say $stop_name;
				$notified{$stop_name} = 1;
			}
		}
	}
	if ($found) {
		say '------------8<----------';
		say '';
	}
}

1;
