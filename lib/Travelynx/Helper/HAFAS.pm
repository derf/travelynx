package Travelynx::Helper::HAFAS;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;
use utf8;

use DateTime;
use Encode qw(decode);
use JSON;
use Mojo::Promise;
use Mojo::UserAgent;
use Travel::Status::DE::HAFAS;

sub _epoch {
	my ($dt) = @_;

	return $dt ? $dt->epoch : 0;
}

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"travelynx/${version} on $opt{root_url} +https://finalrewind.org/projects/travelynx"
	  };

	return bless( \%opt, $class );
}

sub get_service {
	my ( $self, $service ) = @_;

	return Travel::Status::DE::HAFAS::get_service($service);
}

sub get_departures_p {
	my ( $self, %opt ) = @_;

	$opt{service} //= 'ÖBB';

	my $agent = $self->{user_agent};
	if ( my $proxy = $self->{service_config}{ $opt{service} }{proxy} ) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	my $when = (
		  $opt{timestamp}
		? $opt{timestamp}->clone
		: DateTime->now( time_zone => 'Europe/Berlin' )
	)->subtract( minutes => $opt{lookbehind} );
	return Travel::Status::DE::HAFAS->new_p(
		service    => $opt{service},
		station    => $opt{eva},
		datetime   => $when,
		lookahead  => $opt{lookahead} + $opt{lookbehind},
		results    => 300,
		cache      => $self->{realtime_cache},
		promise    => 'Mojo::Promise',
		user_agent => $agent->request_timeout(5),
	);
}

sub search_location_p {
	my ( $self, %opt ) = @_;

	$opt{service} //= 'ÖBB';

	my $agent = $self->{user_agent};
	if ( my $proxy = $self->{service_config}{ $opt{service} }{proxy} ) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	return Travel::Status::DE::HAFAS->new_p(
		service        => $opt{service},
		locationSearch => $opt{query},
		cache          => $self->{realtime_cache},
		promise        => 'Mojo::Promise',
		user_agent     => $agent->request_timeout(5),
	);
}

sub get_tripid_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;

	my $train      = $opt{train};
	my $train_desc = $train->type . ' ' . $train->train_no;
	$train_desc =~ s{^- }{};

	$opt{service} //= 'ÖBB';

	my $agent = $self->{user_agent};
	if ( my $proxy = $self->{service_config}{ $opt{service} }{proxy} ) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	Travel::Status::DE::HAFAS->new_p(
		service      => $opt{service},
		journeyMatch => $train_desc,
		datetime     => $train->start,
		cache        => $self->{realtime_cache},
		promise      => 'Mojo::Promise',
		user_agent   => $agent->request_timeout(10),
	)->then(
		sub {
			my ($hafas) = @_;
			my @results = $hafas->results;

			if ( not @results ) {
				$self->{log}->debug("get_tripid_p($train_desc): no results");
				$promise->reject(
					"journeyMatch($train_desc) returned no results");
				return;
			}

			$self->{log}->debug("get_tripid_p($train_desc): success");

			my $result = $results[0];
			if ( @results > 1 ) {
				for my $journey (@results) {
					if ( ( $journey->route )[0]->loc->name eq $train->origin ) {
						$result = $journey;
						last;
					}
				}
			}

			$promise->resolve( $result->id );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("get_tripid_p($train_desc): error $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub get_journey_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $now     = DateTime->now( time_zone => 'Europe/Berlin' );

	$opt{service} //= 'ÖBB';

	my $agent = $self->{user_agent};
	if ( my $proxy = $self->{service_config}{ $opt{service} }{proxy} ) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	Travel::Status::DE::HAFAS->new_p(
		service => $opt{service},
		journey => {
			id => $opt{trip_id},
		},
		with_polyline => $opt{with_polyline},
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $agent->request_timeout(10),
	)->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;

			if ($journey) {
				$self->{log}->debug("get_journey_p($opt{trip_id}): success");
				$promise->resolve($journey);
				return;
			}
			$self->{log}->debug("get_journey_p($opt{trip_id}): no journey");
			$promise->reject('no journey');
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("get_journey_p($opt{trip_id}): error $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

sub get_route_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $now     = DateTime->now( time_zone => 'Europe/Berlin' );

	$opt{service} //= 'ÖBB';

	my $agent = $self->{user_agent};
	if ( my $proxy = $self->{service_config}{ $opt{service} }{proxy} ) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	Travel::Status::DE::HAFAS->new_p(
		service => $opt{service},
		journey => {
			id => $opt{trip_id},

			# name => $opt{train_no},
		},
		with_polyline => $opt{with_polyline},
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $agent->request_timeout(10),
	)->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;
			my $ret     = [];
			my $polyline;

			my $station_is_past = 1;
			for my $stop ( $journey->route ) {
				my $entry = {
					name      => $stop->loc->name,
					eva       => $stop->loc->eva,
					sched_arr => _epoch( $stop->sched_arr ),
					sched_dep => _epoch( $stop->sched_dep ),
					rt_arr    => _epoch( $stop->rt_arr ),
					rt_dep    => _epoch( $stop->rt_dep ),
					arr_delay => $stop->arr_delay,
					dep_delay => $stop->dep_delay,
					load      => $stop->load,
					lat       => $stop->loc->lat,
					lon       => $stop->loc->lon,
				};
				if ( $stop->tz_offset ) {
					$entry->{tz_offset} = $stop->tz_offset;
				}
				if (    ( $stop->arr_cancelled or not $stop->sched_arr )
					and ( $stop->dep_cancelled or not $stop->sched_dep ) )
				{
					$entry->{isCancelled} = 1;
				}
				if (
					    $station_is_past
					and not $entry->{isCancelled}
					and $now->epoch < (
						$entry->{rt_arr} // $entry->{rt_dep}
						  // $entry->{sched_arr} // $entry->{sched_dep}
						  // $now->epoch
					)
				  )
				{
					$station_is_past = 0;
				}
				$entry->{isPast} = $station_is_past;
				push( @{$ret}, $entry );
			}

			if ( $journey->polyline ) {
				my @station_list;
				my @coordinate_list;

				for my $coord ( $journey->polyline ) {
					if ( $coord->{name} ) {
						push( @coordinate_list,
							[ $coord->{lon}, $coord->{lat}, $coord->{eva} ] );
						push( @station_list, $coord->{name} );
					}
					else {
						push( @coordinate_list,
							[ $coord->{lon}, $coord->{lat} ] );
					}
				}
				my $iris_stations = join( '|', $opt{train}->route );

				# borders (Gr" as in "Grenze") are only returned by HAFAS.
				# They are not stations.
				my $hafas_stations
				  = join( '|', grep { $_ !~ m{(\(Gr\)|\)Gr)$} } @station_list );

				if ( $iris_stations eq $hafas_stations
					or index( $hafas_stations, $iris_stations ) != -1 )
				{
					$polyline = {
						from_eva => ( $journey->route )[0]->loc->eva,
						to_eva   => ( $journey->route )[-1]->loc->eva,
						coords   => \@coordinate_list,
					};
				}
				else {
					$self->{log}->debug( 'Ignoring polyline for '
						  . $opt{train}->line
						  . ": IRIS route does not agree with HAFAS route: $iris_stations != $hafas_stations"
					);
				}
			}

			$self->{log}->debug("get_route_p($opt{trip_id}): success");
			$promise->resolve( $ret, $journey, $polyline );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("get_route_p($opt{trip_id}): error $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

1;
