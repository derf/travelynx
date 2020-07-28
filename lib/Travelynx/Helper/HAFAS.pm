package Travelynx::Helper::HAFAS;

use strict;
use warnings;
use 5.020;

use DateTime;
use Encode qw(decode);
use JSON;
use Mojo::Promise;
use XML::LibXML;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header} = {
		'User-Agent' =>
"travelynx/${version} +https://finalrewind.org/projects/travelynx"
	};

	return bless( \%opt, $class );
}

sub get_polyline_p {
	my ( $self, $train, $trip_id ) = @_;

	my $line = $train->line // 0;
	my $url
		= "https://2.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;
	my $version = $self->{version};

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p(
		$url => $self->{header}
	)->then(
		sub {
			my ($tx) = @_;
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
						push( @{$coord}, $feature->{properties}{id} );
						push( @station_list,
							$feature->{properties}{name} );
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

					# borders ("(Gr)" as in "Grenze") are only returned by HAFAS.
					# They are not stations.
			my $iris_stations = join( '|', $train->route );
			my $hafas_stations
				= join( '|', grep { $_ !~ m{\(Gr\)$} } @station_list );

				# Do not return polyline if it belongs to an entirely different
				# train. Trains with longer routes (e.g. due to train number
				# changes, which are handled by HAFAS but left out in IRIS)
				# are okay though.
			if ( $iris_stations ne $hafas_stations
				and index( $hafas_stations, $iris_stations ) == -1 )
			{
				$self->{log}->warn( 'Ignoring polyline for '
						. $train->line
						. ": IRIS route does not agree with HAFAS route: $iris_stations != $hafas_stations"
				);
				$promise->reject('polyline route mismatch');
			}
			else {
				$promise->resolve($ret);
			}
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
		}
	)->wait;

	return $promise;
}

sub get_tripid_p {
	my ( $self, $train ) = @_;

	my $promise = Mojo::Promise->new;
	my $cache   = $self->{main_cache};
	my $eva     = $train->station_uic;

	my $dep_ts = DateTime->now( time_zone => 'Europe/Berlin' );
	my $url
		= "https://2.db.transport.rest/stations/${eva}/departures?duration=5&when=$dep_ts";

	if ( $train->sched_departure ) {
		$dep_ts = $train->sched_departure->epoch;
		$url
			= "https://2.db.transport.rest/stations/${eva}/departures?duration=5&when=$dep_ts";
	}
	elsif ( $train->sched_arrival ) {
		$dep_ts = $train->sched_arrival->epoch;
		$url
			= "https://2.db.transport.rest/stations/${eva}/arrivals?duration=5&when=$dep_ts";
	}

	$self->get_rest_p($url)->then(
		sub {
			my ($json) = @_;

			for my $result ( @{$json} ) {
				if (    $result->{line}
					and $result->{line}{fahrtNr} == $train->train_no )
				{
					my $trip_id = $result->{tripId};
					$promise->resolve($trip_id);
					return;
				}
			}
			$promise->reject;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
		}
	)->wait;

	return $promise;
}

sub get_rest_p {
	my ( $self, $url ) = @_;

	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p($url => $self->{header})->then(
		sub {
			my ($tx) = @_;
			my $json = JSON->new->decode( $tx->res->body );
			$cache->freeze( $url, $json );
			$promise->resolve($json);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("get($url): $err");
			$promise->reject($err);
		}
	)->wait;
	return $promise;
}

sub get_json_p {
	my ( $self, $url ) = @_;

	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p($url => $self->{header})->then(
		sub {
			my ($tx) = @_;
			my $body = decode( 'ISO-8859-15', $tx->res->body );

			$body =~ s{^TSLs[.]sls = }{};
			$body =~ s{;$}{};
			$body =~ s{&#x0028;}{(}g;
			$body =~ s{&#x0029;}{)}g;
			my $json = JSON->new->decode($body);
			$cache->freeze( $url, $json );
			$promise->resolve($json);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("get($url): $err");
			$promise->reject($err);
		}
	)->wait;
	return $promise;
}

sub get_xml_p {
	my ( $self, $url ) = @_;

	my $cache   = $self->{realtime_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p($url => $self->{header})->then(
		sub {
			my ($tx) = @_;
			my $body = decode( 'ISO-8859-15', $tx->res->body );
			my $tree;

			my $traininfo = {
				station  => {},
				messages => [],
			};

			# <SDay text="... &gt; ..."> is invalid HTML, but present in
			# regardless. As it is the last tag, we just throw it away.
			$body =~ s{<SDay [^>]*/>}{}s;

			# More fixes for invalid XML
			$body =~ s{P&R}{P&amp;R};
			eval { $tree = XML::LibXML->load_xml( string => $body ) };
			if ($@) {
				$self->{log}->warn("load_xml($url): $@");
				$cache->freeze( $url, $traininfo );
				$promise->resolve($traininfo);
				return;
			}

			for my $station ( $tree->findnodes('/Journey/St') ) {
				my $name   = $station->getAttribute('name');
				my $adelay = $station->getAttribute('adelay');
				my $ddelay = $station->getAttribute('ddelay');
				$traininfo->{station}{$name} = {
					adelay => $adelay,
					ddelay => $ddelay,
				};
			}

			for my $message ( $tree->findnodes('/Journey/HIMMessage') )
			{
				my $header  = $message->getAttribute('header');
				my $lead    = $message->getAttribute('lead');
				my $display = $message->getAttribute('display');
				push(
					@{ $traininfo->{messages} },
					{
						header  => $header,
						lead    => $lead,
						display => $display
					}
				);
			}

			$cache->freeze( $url, $traininfo );
			$promise->resolve($traininfo);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->warn("get($url): $err");
			$promise->reject($err);
		}
	)->wait;
	return $promise;
}

1;
