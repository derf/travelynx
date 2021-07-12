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
use XML::LibXML;

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

	my $line = $train->line // 0;
	my $url
	  = "https://v5.db.transport.rest/trips/${trip_id}?lineName=${line}&polyline=true";
	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;
	my $version = $self->{version};

	if ( my $content = $cache->thaw($url) ) {
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$promise->reject(
"hafas->get_polyline_p($url) returned HTTP $err->{code} $err->{message}"
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
				$self->{log}->info( 'Ignoring polyline for '
					  . $train->line
					  . ": IRIS route does not agree with HAFAS route: $iris_stations != $hafas_stations"
				);
				$promise->reject(
					"hafas->get_polyline_p($url): polyline route mismatch");
			}
			else {
				$promise->resolve($ret);
			}
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("hafas->get_polyline_p($url): $err");
			return;
		}
	)->wait;

	return $promise;
}

sub get_json_p {
	my ( $self, $url ) = @_;

	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;

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

			my $body = decode( 'ISO-8859-15', $tx->res->body );

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

sub get_xml_p {
	my ( $self, $url ) = @_;

	my $cache   = $self->{realtime_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$promise->reject(
"hafas->get_xml_p($url) returned HTTP $err->{code} $err->{message}"
				);
				return;
			}

			my $body = decode( 'ISO-8859-15', $tx->res->body );
			my $tree;

			my $traininfo = {
				station  => {},
				messages => [],
			};

			# <SDay text="... &gt; ..."> is invalid XML, but present in
			# regardless. As it is the last tag, we just throw it away.
			$body =~ s{<SDay [^>]*/>}{}s;

			# More fixes for invalid XML
			$body =~ s{P&R}{P&amp;R};
			$body =~ s{Wagen \d+ \K&}{&amp;};
			$body =~ s{Wagen \d+, \d+ \K&}{&amp;};

			# <Attribute [...] text="[...]"[...]"" /> is invalid XML.
			# Work around it.
			$body
			  =~ s{<Attribute([^>]+)text="([^"]*)"([^"=>]*)""}{<Attribute$1text="$2&#042;$3&#042;"}s;

			# Same for <HIMMessage lead="[...]"[...]"[...]" />
			$body
			  =~ s{<HIMMessage([^>]+)lead="([^"]*)"([^"=>]*)"([^"]*)"}{<Attribute$1text="$2&#042;$3&#042;$4"}s;

			# ... and <HIMMessage [...] lead="[...]<>[...]">
			# (replace <> with t$t)
			while ( $body
				=~ s{<HIMMessage([^>]+)lead="([^"]*)<>([^"=]*)"}{<HIMMessage$1lead="$2&#11020;$3"}gis
			  )
			{
			}

			# Dito for <HIMMessage [...] lead="[...]<br>[...]">.
			while ( $body
				=~ s{<HIMMessage([^>]+)lead="([^"]*)<br/?>([^"=]*)"}{<HIMMessage$1lead="$2 $3"}is
			  )
			{
			}

			# ... and any other HTML tag inside an XML attribute
			while ( $body
				=~ s{<HIMMessage([^>]+)lead="([^"]*)<[^>]+>([^"=]*)"}{<HIMMessage$1lead="$2$3"}is
			  )
			{
			}

			eval { $tree = XML::LibXML->load_xml( string => $body ) };
			if ( my $err = $@ ) {
				if ( $err =~ m{extra content at the end}i ) {

					# We requested XML, but received an HTML error page
					# (which was returned with HTTP 200 OK).
					$self->{log}->debug("load_xml($url): $err");
				}
				else {
					# There is invalid XML which we might be able to fix via
					# regular expressions, so dump it into the production log.
					$self->{log}->info("load_xml($url): $err");
				}
				$cache->freeze( $url, $traininfo );
				$promise->reject("hafas->get_xml_p($url): $err");
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

			for my $message ( $tree->findnodes('/Journey/HIMMessage') ) {
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
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->info("hafas->get_xml_p($url): $err");
			$promise->reject("hafas->get_xml_p($url): $err");
			return;
		}
	)->wait;
	return $promise;
}

1;
