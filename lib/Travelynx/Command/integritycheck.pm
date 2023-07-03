package Travelynx::Command::integritycheck;

# Copyright (C) 2022 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Command';
use List::Util qw();
use Travel::Status::DE::IRIS::Stations;

sub run {
	my ($self) = @_;
	my $found  = 0;
	my $db     = $self->app->pg->db;

	my $res1 = $db->query(
		qq{
			select checkin_station_id
			from journeys
			left join stations on journeys.checkin_station_id = stations.eva
			where stations.eva is null;
		}
	);

	my $res2 = $db->query(
		qq{
			select checkout_station_id
			from journeys
			left join stations on journeys.checkout_station_id = stations.eva
			where stations.eva is null;
		}
	);

	my %notified;
	while ( my $row = $res1->hash ) {
		my $eva = $row->{checkin_station_id};
		if ( not $found ) {
			$found = 1;
			say
'Journeys in the travelynx database contain the following unknown EVA IDs.';
			say '------------8<----------';
			say 'Travel::Status::DE::IRIS v'
			  . $Travel::Status::DE::IRIS::Stations::VERSION;
		}
		if ( not $notified{$eva} ) {
			say $eva;
			$notified{$eva} = 1;
		}
	}

	while ( my $row = $res2->hash ) {
		my $eva = $row->{checkout_station_id};
		if ( not $found ) {
			$found = 1;
			say
'Journeys in the travelynx database contain the following unknown EVA IDs.';
			say '------------8<----------';
			say 'Travel::Status::DE::IRIS v'
			  . $Travel::Status::DE::IRIS::Stations::VERSION;
		}
		if ( not $notified{$eva} ) {
			say $eva;
			$notified{$eva} = 1;
		}
	}

	if ($found) {
		say '------------8<----------';
		say '';
		$found = 0;
	}

	my $rename = $self->app->renamed_station;

	my $res = $db->select( 'journeys', [ 'route', 'edited' ] )->expand;
	while ( my $j = $res->hash ) {
		if ( $j->{edited} & 0x0010 ) {
			next;
		}
		my @stops = @{ $j->{route} // [] };
		for my $stop (@stops) {
			my $stop_name = $stop->[0];
			if ( $rename->{ $stop->[0] } ) {
				$stop->[0] = $rename->{ $stop->[0] };
			}
		}
		my @unknown
		  = $self->app->stations->grep_unknown( map { $_->[0] } @stops );
		for my $stop_name (@unknown) {
			if ( not $notified{$stop_name} ) {
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
