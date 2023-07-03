package Travelynx::Helper::IRIS;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use utf8;

use Mojo::Promise;
use Mojo::UserAgent;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub get_departures {
	my ( $self, %opt ) = @_;
	my $station      = $opt{station};
	my $lookbehind   = $opt{lookbehind}   // 180;
	my $lookahead    = $opt{lookahead}    // 30;
	my $with_related = $opt{with_related} // 0;

	my @station_matches
	  = Travel::Status::DE::IRIS::Stations::get_station($station);

	if ( @station_matches == 1 ) {
		$station = $station_matches[0][0];
		my $status = Travel::Status::DE::IRIS->new(
			station        => $station,
			main_cache     => $self->{main_cache},
			realtime_cache => $self->{realtime_cache},
			keep_transfers => 1,
			lookbehind     => 20,
			datetime       => DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( minutes => $lookbehind ),
			lookahead   => $lookbehind + $lookahead,
			lwp_options => {
				timeout => 10,
				agent   => 'travelynx/'
				  . $self->{version}
				  . ' +https://travelynx.de',
			},
			with_related => $with_related,
		);
		return {
			results       => [ $status->results ],
			errstr        => $status->errstr,
			station_ds100 =>
			  ( $status->station ? $status->station->{ds100} : undef ),
			station_eva =>
			  ( $status->station ? $status->station->{uic} : undef ),
			station_name =>
			  ( $status->station ? $status->station->{name} : undef ),
			related_stations => [ $status->related_stations ],
		};
	}
	elsif ( @station_matches > 1 ) {
		return {
			results => [],
			errstr  =>
			  "Mehrdeutiger Stationsname: '$station'. Mögliche Eingaben: "
			  . join( q{, }, map { $_->[1] } @station_matches ),
		};
	}
	else {
		return {
			results => [],
			errstr  => 'Unbekannte Station',
		};
	}
}

sub get_departures_p {
	my ( $self, %opt ) = @_;
	my $station      = $opt{station};
	my $lookbehind   = $opt{lookbehind}   // 180;
	my $lookahead    = $opt{lookahead}    // 30;
	my $with_related = $opt{with_related} // 0;

	my @station_matches
	  = Travel::Status::DE::IRIS::Stations::get_station($station);

	if ( @station_matches == 1 ) {
		$station = $station_matches[0][0];
		my $promise = Mojo::Promise->new;
		Travel::Status::DE::IRIS->new_p(
			station        => $station,
			main_cache     => $self->{main_cache},
			realtime_cache => $self->{realtime_cache},
			keep_transfers => 1,
			lookbehind     => 20,
			datetime       => DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( minutes => $lookbehind ),
			lookahead   => $lookbehind + $lookahead,
			lwp_options => {
				timeout => 10,
				agent   => 'travelynx/'
				  . $self->{version}
				  . ' +https://travelynx.de',
			},
			with_related => $with_related,
			promise      => 'Mojo::Promise',
			user_agent   => Mojo::UserAgent->new,
			get_station  => \&Travel::Status::DE::IRIS::Stations::get_station,
			meta         => Travel::Status::DE::IRIS::Stations::get_meta(),
		)->then(
			sub {
				my ($status) = @_;
				$promise->resolve(
					{
						results       => [ $status->results ],
						errstr        => $status->errstr,
						station_ds100 => (
							  $status->station
							? $status->station->{ds100}
							: undef
						),
						station_eva => (
							$status->station ? $status->station->{uic} : undef
						),
						station_name => (
							$status->station ? $status->station->{name} : undef
						),
						related_stations => [ $status->related_stations ],
					}
				);
				return;
			}
		)->catch(
			sub {
				my ($err) = @_;
				$promise->reject(
					{
						results => [],
						errstr  => "Error in promise: $err",
					}
				);
				return;
			}
		)->wait;
		return $promise;
	}
	elsif ( @station_matches > 1 ) {
		return Mojo::Promise->reject(
			{
				results => [],
				errstr  =>
				  "Mehrdeutiger Stationsname: '$station'. Mögliche Eingaben: "
				  . join( q{, }, map { $_->[1] } @station_matches ),
			}
		);
	}
	else {
		return Mojo::Promise->reject(
			{
				results => [],
				errstr  => 'Unbekannte Station',
			}
		);
	}
}

sub route_diff {
	my ( $self, $train ) = @_;
	my @json_route;
	my @route       = $train->route;
	my @sched_route = $train->sched_route;

	my $route_idx = 0;
	my $sched_idx = 0;

	while ( $route_idx <= $#route and $sched_idx <= $#sched_route ) {
		if ( $route[$route_idx] eq $sched_route[$sched_idx] ) {
			push( @json_route, [ $route[$route_idx], undef, {} ] );
			$route_idx++;
			$sched_idx++;
		}

		# this branch is inefficient, but won't be taken frequently
		elsif ( not( grep { $_ eq $route[$route_idx] } @sched_route ) ) {
			push( @json_route,
				[ $route[$route_idx], undef, { isAdditional => 1 } ],
			);
			$route_idx++;
		}
		else {
			push( @json_route,
				[ $sched_route[$sched_idx], undef, { isCancelled => 1 } ],
			);
			$sched_idx++;
		}
	}
	while ( $route_idx <= $#route ) {
		push( @json_route,
			[ $route[$route_idx], undef, { isAdditional => 1 } ],
		);
		$route_idx++;
	}
	while ( $sched_idx <= $#sched_route ) {
		push( @json_route,
			[ $sched_route[$sched_idx], undef, { isCancelled => 1 } ],
		);
		$sched_idx++;
	}
	return @json_route;
}

1;
