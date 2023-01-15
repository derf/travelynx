package Travelynx::Helper::HAFAS;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode);
use JSON;
use Mojo::Promise;
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

sub get_json_p {
	my ( $self, $url, %opt ) = @_;

	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;

	if ( $opt{realtime} ) {
		$cache = $self->{realtime_cache};
	}
	$opt{encoding} //= 'ISO-8859-15';

	if ( my $content = $cache->thaw($url) ) {
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$promise->reject(
"hafas->get_json_p($url) returned HTTP $err->{code} $err->{message}"
				);
				return;
			}

			my $body = decode( $opt{encoding}, $tx->res->body );

			$body =~ s{^TSLs[.]sls = }{};
			$body =~ s{;$}{};
			$body =~ s{&#x0028;}{(}g;
			$body =~ s{&#x0029;}{)}g;
			my $json = JSON->new->decode($body);
			$cache->freeze( $url, $json );
			$promise->resolve($json);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->info("hafas->get_json_p($url): $err");
			$promise->reject("hafas->get_json_p($url): $err");
			return;
		}
	)->wait;
	return $promise;
}

sub get_departures_p {
	my ( $self, %opt ) = @_;

	my $when = DateTime->now( time_zone => 'Europe/Berlin' )
	  ->subtract( minutes => $opt{lookbehind} );
	return Travel::Status::DE::HAFAS->new_p(
		station    => $opt{eva},
		datetime   => $when,
		duration   => $opt{lookahead},
		results    => 120,
		cache      => $self->{realtime_cache},
		promise    => 'Mojo::Promise',
		user_agent => $self->{user_agent}->request_timeout(5),
	);
}

sub get_route_timestamps_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $now     = DateTime->now( time_zone => 'Europe/Berlin' );

	Travel::Status::DE::HAFAS->new_p(
		journey => {
			id => $opt{trip_id},

			# name => $opt{train_no},
		},
		with_polyline => $opt{with_polyline},
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $self->{user_agent}->request_timeout(10),
	)->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;
			my $ret     = {};
			my $polyline;

			my $station_is_past = 1;
			for my $stop ( $journey->route ) {
				my $name = $stop->{name};
				$ret->{$name} = $ret->{ $stop->{eva} } = {
					name      => $stop->{name},
					eva       => $stop->{eva},
					sched_arr => _epoch( $stop->{sched_arr} ),
					sched_dep => _epoch( $stop->{sched_dep} ),
					rt_arr    => _epoch( $stop->{rt_arr} ),
					rt_dep    => _epoch( $stop->{rt_dep} ),
					arr_delay => $stop->{arr_delay},
					dep_delay => $stop->{dep_delay},
					eva       => $stop->{eva},
					load      => $stop->{load}
				};
				if (    ( $stop->{arr_cancelled} or not $stop->{sched_arr} )
					and ( $stop->{dep_cancelled} or not $stop->{sched_dep} ) )
				{
					$ret->{$name}{isCancelled} = 1;
				}
				if (
					    $station_is_past
					and not $ret->{$name}{isCancelled}
					and $now->epoch < (
						$ret->{$name}{rt_arr} // $ret->{$name}{rt_dep}
						  // $ret->{$name}{sched_arr}
						  // $ret->{$name}{sched_dep} // $now->epoch
					)
				  )
				{
					$station_is_past = 0;
				}
				$ret->{$name}{isPast} = $station_is_past;
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
						from_eva => ( $journey->route )[0]{eva},
						to_eva   => ( $journey->route )[-1]{eva},
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

			$promise->resolve( $ret, $journey, $polyline );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

1;
