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
	my ( $self, $ts, $train_no ) = @_;
	my $api_ts = $ts->strftime('%Y%m%d%H%M');
	my $url
	  = "https://ist-wr.noncd.db.de/wagenreihung/1.0/${train_no}/${api_ts}";
	my $cache   = $self->{realtime_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->get("HEAD $url") ) {
		if ( $content eq 'n' ) {
			$self->{log}
			  ->debug("has_wagonorder_p(${train_no}/${api_ts}): n (cached)");
			return $promise->reject;
		}
		else {
			$self->{log}
			  ->debug("has_wagonorder_p(${train_no}/${api_ts}): y (cached)");
			return $promise->resolve($content);
		}
	}

	$self->{user_agent}->request_timeout(5)->head_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;
			if ( $tx->result->is_success ) {
				$self->{log}
				  ->debug("has_wagonorder_p(${train_no}/${api_ts}): a");
				$cache->set( "HEAD $url", 'a' );
				$promise->resolve('a');
			}
			else {
				$self->{log}
				  ->debug("has_wagonorder_p(${train_no}/${api_ts}): n");
				$cache->set( "HEAD $url", 'n' );
				$promise->reject;
			}
			return;
		}
	)->catch(
		sub {
			$self->{log}->debug("has_wagonorder_p(${train_no}/${api_ts}): n");
			$cache->set( "HEAD $url", 'n' );
			$promise->reject;
			return;
		}
	)->wait;
	return $promise;
}

sub get_wagonorder_p {
	my ( $self, $api, $ts, $train_no ) = @_;
	my $api_ts = $ts->strftime('%Y%m%d%H%M');
	my $url
	  = "https://ist-wr.noncd.db.de/wagenreihung/1.0/${train_no}/${api_ts}";

	my $cache   = $self->{realtime_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$self->{log}
		  ->debug("get_wagonorder_p(${train_no}/${api_ts}): (cached)");
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
				$self->{log}
				  ->debug("get_wagonorder_p(${train_no}/${api_ts}): success");
				$cache->freeze( $url, $json );
				$promise->resolve($json);
			}
			else {
				my $code = $tx->code;
				$self->{log}->debug(
					"get_wagonorder_p(${train_no}/${api_ts}): HTTP ${code}");
				$promise->reject("HTTP ${code}");
			}
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}
			  ->debug("get_wagonorder_p(${train_no}/${api_ts}): error ${err}");
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
