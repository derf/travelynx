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
use XML::LibXML;

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

sub get_polyline_p {
	my ( $self, $train, $trip_id ) = @_;

	my $line    = $train->line // 0;
	my $backend = $self->{hafas_rest_api};
	my $url     = "${backend}/trips/${trip_id}?lineName=${line}&polyline=true";
	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;
	my $version = $self->{version};

	if ( my $content = $cache->thaw($url) ) {
		return $promise->resolve($content);
	}

	my $log_url = $url;
	$log_url =~ s{://\K[^:]+:[^@]+\@}{***@};

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$promise->reject(
"hafas->get_polyline_p($log_url) returned HTTP $err->{code} $err->{message}"
				);
				return;
			}

			my $body = decode( 'utf-8', $tx->res->body );
			my $json = JSON->new->decode($body);
			my @station_list;
			my @coordinate_list;

			for my $feature ( @{ $json->{polyline}{features} } ) {
				if ( exists $feature->{geometry}{coordinates} ) {
					my $coord = $feature->{geometry}{coordinates};
					if ( exists $feature->{properties}{type}
						and $feature->{properties}{type} eq 'stop' )
					{
						push( @{$coord},     $feature->{properties}{id} );
						push( @station_list, $feature->{properties}{name} );
					}
					push( @coordinate_list, $coord );
				}
			}

			my $ret = {
				name     => $json->{line}{name} // '?',
				polyline => [@coordinate_list],
				raw      => $json,
			};

			$cache->freeze( $url, $ret );

			# borders (Gr" as in "Grenze") are only returned by HAFAS.
			# They are not stations.
			my $iris_stations = join( '|', $train->route );
			my $hafas_stations
			  = join( '|', grep { $_ !~ m{(\(Gr\)|\)Gr)$} } @station_list );

			# Do not return polyline if it belongs to an entirely different
			# train. Trains with longer routes (e.g. due to train number
			# changes, which are handled by HAFAS but left out in IRIS)
			# are okay though.
			if ( $iris_stations ne $hafas_stations
				and index( $hafas_stations, $iris_stations ) == -1 )
			{
				$self->{log}->info( 'Ignoring polyline for '
					  . $train->line
					  . ": IRIS route does not agree with HAFAS route: $iris_stations != $hafas_stations"
				);
				$promise->reject(
					"hafas->get_polyline_p($log_url): polyline route mismatch");
			}
			else {
				$promise->resolve($ret);
			}
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("hafas->get_polyline_p($log_url): $err");
			return;
		}
	)->wait;

	return $promise;
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

sub get_route_timestamps_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $now     = DateTime->now( time_zone => 'Europe/Berlin' );

	Travel::Status::DE::HAFAS->new_p(
		journey => {
			id => $opt{trip_id},

			# name => $opt{train_no},
		},
		cache      => $self->{realtime_cache},
		promise    => 'Mojo::Promise',
		user_agent => $self->{user_agent}->request_timeout(10)
	)->then(
		sub {
			my ($hafas) = @_;
			my $journey = $hafas->result;
			my $ret     = {};

			my $station_is_past = 1;
			for my $stop ( $journey->route ) {
				my $name = $stop->{name};
				$ret->{$name} = {
					sched_arr   => _epoch( $stop->{sched_arr} ),
					sched_dep   => _epoch( $stop->{sched_dep} ),
					rt_arr      => _epoch( $stop->{rt_arr} ),
					rt_dep      => _epoch( $stop->{rt_dep} ),
					arr_delay   => $stop->{arr_delay},
					dep_delay   => $stop->{dep_delay},
					eva         => $stop->{eva},
					load        => $stop->{load},
					isCancelled => (
						( $stop->{arr_cancelled} or not $stop->{sched_arr} )
						  and
						  ( $stop->{dep_cancelled} or not $stop->{sched_dep} )
					),
				};
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

			$promise->resolve( $ret, $journey );
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
