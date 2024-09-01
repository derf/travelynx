package Travelynx::Command::integritycheck;

# Copyright (C) 2022 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Command';
use List::Util qw();
use Travel::Status::DE::IRIS::Stations;

sub run {
	my ( $self, $mode ) = @_;
	my $found = 0;
	my $db    = $self->app->pg->db;

	if ( $mode eq 'all' or $mode eq 'unknown-evas' ) {

		my %notified;
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
	}

	if ($found) {
		say '------------8<----------';
		say '';
		$found = 0;
	}

	if ( $mode eq 'all' or $mode eq 'unknown-route-entries' ) {

		my %notified;
		my $rename = $self->app->renamed_station;
		my $res    = $db->select( 'journeys', [ 'route', 'edited' ] )->expand;

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
						say
						  'Note that this check ignores manual route entries.';
						say
'All reports refer to routes obtained via HAFAS/IRIS.';
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
	}

	if ($found) {
		say '------------8<----------';
		say '';
		$found = 0;
	}

	if ( $mode eq 'all' or $mode eq 'checkout-eva-vs-route-eva' ) {

		my $res = $db->select(
			'journeys_str',
			[ 'journey_id', 'sched_arr_ts', 'route', 'arr_name', 'arr_eva' ],
			{ backend_id => 0 }
		)->expand;

		journey: while ( my $j = $res->hash ) {
			my $found_in_route;
			my $found_arr;
			for my $stop ( @{ $j->{route} // [] } ) {
				if ( not $stop->[1] ) {
					next journey;
				}
				if ( $stop->[1] == $j->{arr_eva} ) {
					$found_in_route = 1;
					last;
				}
				if (    $stop->[2]{sched_arr}
					and $j->{sched_arr_ts}
					and $stop->[2]{sched_arr} == int( $j->{sched_arr_ts} ) )
				{
					$found_arr = $stop;
				}
			}
			if ( $found_arr and not $found_in_route ) {
				if ( not $found ) {
					say q{};
					say
'The following journeys have route entries which do not agree with checkout EVA ID.';
					say
'checkout station ID (left) vs route entry with matching checkout time (right)';
					say '------------8<----------';
					$found = 1;
				}
				printf(
					"%7d  %d (%s) vs %d (%s)\n",
					$j->{journey_id}, $j->{arr_eva}, $j->{arr_name},
					$found_arr->[1],  $found_arr->[0]
				);
			}
		}
	}

	if ($found) {
		say '------------8<----------';
		say '';
		$found = 0;
	}
}

1;
