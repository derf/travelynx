package Travelynx::Helper::DBDB;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use Encode qw(decode);
use Mojo::Promise;
use JSON;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"travelynx/${version} on $opt{root_url} +https://finalrewind.org/projects/travelynx"
	  };

	return bless( \%opt, $class );

}

sub has_wagonorder_p {
	my ( $self, %opt ) = @_;

	$opt{train_type} //= q{};
	my $datetime = $opt{datetime}->clone->set_time_zone('UTC');
	my %param    = (
		administrationId => 80,
		category         => $opt{train_type},
		date             => $datetime->strftime('%Y-%m-%d'),
		evaNumber        => $opt{eva},
		number           => $opt{train_no},
		time             => $datetime->rfc3339 =~ s{(?=Z)}{.000}r
	);

	my $url = sprintf( '%s?%s',
'https://www.bahn.de/web/api/reisebegleitung/wagenreihung/vehicle-sequence',
		join( '&', map { $_ . '=' . $param{$_} } sort keys %param ) );

	my $promise = Mojo::Promise->new;
	my $debug_prefix
	  = "has_wagonorder_p($opt{train_type} $opt{train_no} @ $opt{eva})";

	if ( my $content = $self->{main_cache}->get("HEAD $url")
		// $self->{realtime_cache}->get("HEAD $url") )
	{
		if ( $content eq 'n' ) {
			$self->{log}->debug("${debug_prefix}: n (cached)");
			return $promise->reject;
		}
		else {
			$self->{log}->debug("${debug_prefix}: ${content} (cached)");
			return $promise->resolve($content);
		}
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;
			if ( $tx->result->is_success ) {
				$self->{log}->debug("${debug_prefix}: a");
				$self->{main_cache}->set( "HEAD $url", 'a' );
				my $body = decode( 'utf-8', $tx->res->body );
				my $json = JSON->new->decode($body);
				$self->{main_cache}->freeze( $url, $json );
				$promise->resolve('a');
			}
			else {
				my $code = $tx->res->code;
				$self->{log}->debug("${debug_prefix}: n (HTTP $code)");
				$self->{realtime_cache}->set( "HEAD $url", 'n' );
				$promise->reject;
			}
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("${debug_prefix}: n ($err)");
			$self->{realtime_cache}->set( "HEAD $url", 'n' );
			$promise->reject;
			return;
		}
	)->wait;
	return $promise;
}

sub get_wagonorder_p {
	my ( $self, %opt ) = @_;

	my $datetime = $opt{datetime}->clone->set_time_zone('UTC');
	my %param    = (
		administrationId => 80,
		category         => $opt{train_type},
		date             => $datetime->strftime('%Y-%m-%d'),
		evaNumber        => $opt{eva},
		number           => $opt{train_no},
		time             => $datetime->rfc3339 =~ s{(?=Z)}{.000}r
	);

	my $url = sprintf( '%s?%s',
'https://www.bahn.de/web/api/reisebegleitung/wagenreihung/vehicle-sequence',
		join( '&', map { $_ . '=' . $param{$_} } sort keys %param ) );
	my $debug_prefix
	  = "get_wagonorder_p($opt{train_type} $opt{train_no} @ $opt{eva})";

	my $promise = Mojo::Promise->new;

	if ( my $content = $self->{main_cache}->thaw($url) ) {
		$self->{log}->debug("${debug_prefix}: (cached)");
		$promise->resolve($content);
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( $tx->result->is_success ) {
				my $body = decode( 'utf-8', $tx->res->body );
				my $json = JSON->new->decode($body);
				$self->{log}->debug("${debug_prefix}: success");
				$self->{main_cache}->freeze( $url, $json );
				$promise->resolve($json);
			}
			else {
				my $code = $tx->res->code;
				$self->{log}->debug("${debug_prefix}: HTTP ${code}");
				$promise->reject("HTTP ${code}");
			}
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("${debug_prefix}: error ${err}");
			$promise->reject($err);
			return;
		}
	)->wait;
	return $promise;
}

sub get_stationinfo_p {
	my ( $self, $eva ) = @_;

	my $url = "https://lib.finalrewind.org/dbdb/s/${eva}.json";

	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$self->{log}->debug("get_stationinfo_p(${eva}): (cached)");
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				$self->{log}->debug(
"get_stationinfo_p(${eva}): HTTP $err->{code} $err->{message}"
				);
				$cache->freeze( $url, {} );
				$promise->reject("HTTP $err->{code} $err->{message}");
				return;
			}

			my $json = $tx->result->json;
			$self->{log}->debug("get_stationinfo_p(${eva}): success");
			$cache->freeze( $url, $json );
			$promise->resolve($json);
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("get_stationinfo_p(${eva}): Error ${err}");
			$cache->freeze( $url, {} );
			$promise->reject($err);
			return;
		}
	)->wait;
	return $promise;
}

1;
