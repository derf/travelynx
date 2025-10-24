package Travelynx::Helper::DBDB;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use Encode qw(decode);
use Mojo::Promise;
use Mojo::UserAgent;
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

sub get_stationinfo_p {
	my ( $self, $eva ) = @_;

	my $url = "https://lib.finalrewind.org/dbdb/s/${eva}.json";

	my $cache   = $self->{main_cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$self->{log}->debug("get_stationinfo_p(${eva}): (cached)");
		return $promise->resolve($content);
	}

	$self->{user_agent}->request_timeout(5)
	  ->get_p( $url => $self->{header} )
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
