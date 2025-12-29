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

	# Berlin Hbf exists twice:
	# - BLS / 8011160
	# - BL / 8098160 (formerly "Berlin Hbf (tief)")
	# Right now, travelynx assumes that station name -> EVA / DS100 is a unique
	# map.  This is not the case. Work around it here until travelynx has been
	# adjusted properly.
	if ( $station eq 'Berlin Hbf' or $station eq '8011160' ) {
		$with_related = 1;
	}

	my @station_matches
	  = Travel::Status::DE::IRIS::Stations::get_station($station);

	if ( $station =~ m{ ^ \d+ $ }x ) {
		@station_matches = ( [ undef, undef, $station ] );
	}

	if ( @station_matches == 1 ) {
		$station = $station_matches[0][2];
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

	# Berlin Hbf exists twice:
	# - BLS / 8011160
	# - BL / 8098160 (formerly "Berlin Hbf (tief)")
	# Right now, travelynx assumes that station name -> EVA / DS100 is a unique
	# map.  This is not the case. Work around it here until travelynx has been
	# adjusted properly.
	if ( $station eq 'Berlin Hbf' or $station eq '8011160' ) {
		$with_related = 1;
	}

	my @station_matches
	  = Travel::Status::DE::IRIS::Stations::get_station($station);

	if ( $station =~ m{ ^ \d+ $ }x ) {
		@station_matches = ( [ undef, undef, $station ] );
	}

	if ( @station_matches == 1 ) {
		$station = $station_matches[0][2];
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
					$err,
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
			'ambiguous station name',
			{
				results     => [],
				errstr      => "Mehrdeutiger Stationsname: '$station'",
				suggestions => [
					map { { name => $_->[1], eva => $_->[2] } }
					  @station_matches
				],
			}
		);
	}
	else {
		return Mojo::Promise->reject(
			'unknown station',
			{
				results => [],
				errstr  => 'Unbekannte Station',
			}
		);
	}
}

sub get_connections_p {
	my ( $self, %opt ) = @_;
	my $promise      = Mojo::Promise->new;
	my $destinations = $opt{destinations};

	$self->{log}->debug(
"get_connections_p(station => $opt{station}, timestamp => $opt{timestamp})"
	);

	$self->get_departures_p(
		station      => $opt{station},
		timestamp    => $opt{timestamp},
		lookbehind   => 0,
		lookahead    => 60,
		with_related => 1,
	)->then(
		sub {
			my ($res) = @_;
			my @suggestions = $self->grep_suggestions(
				results      => $res->{results},
				destinations => $destinations,
				max_per_dest => 2
			);
			@suggestions
			  = sort { $a->[0]{sort_ts} <=> $b->[0]{sort_ts} } @suggestions;
			$promise->resolve( \@suggestions );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("get_departures_p($opt{station}): $err");
			return;
		}
	)->wait;
	return $promise;
}

sub grep_suggestions {
	my ( $self, %opt ) = @_;
	my $results      = $opt{results};
	my $destinations = $opt{destinations};
	my $max_per_dest = $opt{max_per_dest};

	my @suggestions;
	my %via_count;

	for my $dep ( @{$results} ) {
		destination: for my $dest ( @{$destinations} ) {
			for my $via_name ( $dep->route_post ) {
				if ( $via_name eq $dest->{name} ) {
					if ( not $dep->departure_is_cancelled ) {
						$via_count{ $dest->{name} } += 1;
					}
					if (    $max_per_dest
						and $via_count{ $dest->{name} }
						and $via_count{ $dest->{name} } > $max_per_dest )
					{
						next destination;
					}
					my $dep_json = {
						id => $dep->train_id,
						ts =>
						  ( $dep->sched_departure // $dep->departure )->epoch,
						sort_ts                => $dep->departure->epoch,
						station_uic            => $dep->station_uic,
						departure_is_cancelled => $dep->departure_is_cancelled,
						sched_hhmm => $dep->sched_departure->strftime('%H:%M'),
						rt_hhmm    => $dep->departure->strftime('%H:%M'),
						departure_delay => $dep->departure_delay,
						platform        => $dep->platform,
						type            => $dep->type,
						line            => $dep->line,
					};
					push( @suggestions, [ $dep_json, $dest ] );
					next destination;
				}
			}
		}
	}

	return @suggestions;
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
				[ $route[$route_idx], undef, { isAdditional => 1 } ], );
			$route_idx++;
		}
		else {
			push( @json_route,
				[ $sched_route[$sched_idx], undef, { isCancelled => 1 } ], );
			$sched_idx++;
		}
	}
	while ( $route_idx <= $#route ) {
		push( @json_route,
			[ $route[$route_idx], undef, { isAdditional => 1 } ], );
		$route_idx++;
	}
	while ( $sched_idx <= $#sched_route ) {
		push( @json_route,
			[ $sched_route[$sched_idx], undef, { isCancelled => 1 } ], );
		$sched_idx++;
	}
	return @json_route;
}

1;
