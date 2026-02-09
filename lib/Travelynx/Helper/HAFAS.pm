package Travelynx::Helper::HAFAS;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;
use utf8;

use DateTime;
use Encode     qw(decode);
use List::Util qw(max);
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

sub class_to_product {
	my ( $self, $hafas ) = @_;

	my $bits = $hafas->get_active_service->{productbits};
	my $ret;

	for my $i ( 0 .. $#{$bits} ) {
		$ret->{ 2**$i }
		  = ref( $bits->[$i] ) eq 'ARRAY' ? $bits->[$i][0] : $bits->[$i];
	}

	return $ret;
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
	my $old_desc   = $train_desc;

	$train_desc =~ s{^- }{};
	if ( $train->type eq 'ECE' ) {
		$train_desc = 'EC ' . $train->train_no;
	}
	elsif ( $train->type
		=~ m{ ^ (?: ABR | ag | ALX | BRB | EB | ERB | HLB | MRB | NBE | STB | TLX | OE | VIA ) $ }x
	  )
	{
		$train_desc = $train->train_no;
	}
	elsif ( grep { $_ eq 'S' } $train->classes ) {
		$train_desc = 'DB ' . $train->train_no;
	}
	elsif ( ( grep { $_ eq 'N' } $train->classes or not scalar $train->classes )
		and $train->type ne 'FLX' )
	{
		$train_desc = $train->train_no;
	}

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
				$self->{log}
				  ->debug("get_tripid_p($old_desc -> $train_desc): no results");
				$promise->reject(
					"journeyMatch($train_desc) returned no results");
				return;
			}

			$self->{log}
			  ->debug("get_tripid_p($old_desc -> $train_desc): success");

			for my $journey (@results) {
				if (
					List::Util::any { $_->loc->eva == $opt{from_eva} }
					$journey->route
					and List::Util::any { $_->loc->eva == $opt{to_eva} }
					$journey->route
				  )
				{
					$promise->resolve( $journey->id );
					return;
				}
			}

			for my $journey (@results) {
				if ( ( $journey->route )[0]->loc->name eq $train->origin ) {
					$promise->resolve( $journey->id );
					return;
				}
			}

			my $num_trips = scalar @results;
			$promise->reject(
"get_tripid_p($old_desc -> $train_desc): found no matches in $num_trips trips"
			);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}
			  ->debug("get_tripid_p($old_desc -> $train_desc): error $err");
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

				$polyline = {
					from_eva => ( $journey->route )[0]->loc->eva,
					to_eva   => ( $journey->route )[-1]->loc->eva,
					coords   => \@coordinate_list,
				};
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
