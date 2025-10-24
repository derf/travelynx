package Travelynx::Helper::DBRIS;

# Copyright (C) 2025 Birte Kristina Friesel
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
use Travel::Status::DE::DBRIS;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"travelynx/${version} on $opt{root_url} +https://finalrewind.org/projects/travelynx"
	  };

	return bless( \%opt, $class );
}

sub geosearch_p {
	my ( $self, %opt ) = @_;
	my $agent = $self->{user_agent};
	my $proxy;
	if ( my @proxies = @{ $self->{service_config}{'bahn.de'}{proxies} // [] } )
	{
		$proxy = $proxies[ int( rand( scalar @proxies ) ) ];
	}
	elsif ( my $p = $self->{service_config}{'bahn.de'}{proxy} ) {
		$proxy = $p;
	}

	if ($proxy) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	return Travel::Status::DE::DBRIS->new_p(
		promise    => 'Mojo::Promise',
		user_agent => $agent,
		geoSearch  => \%opt,
	);
}

sub get_station_id_p {
	my ( $self, $station_name ) = @_;

	my $agent = $self->{user_agent};
	my $proxy;
	if ( my @proxies = @{ $self->{service_config}{'bahn.de'}{proxies} // [] } )
	{
		$proxy = $proxies[ int( rand( scalar @proxies ) ) ];
	}
	elsif ( my $p = $self->{service_config}{'bahn.de'}{proxy} ) {
		$proxy = $p;
	}

	if ($proxy) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	my $promise = Mojo::Promise->new;
	Travel::Status::DE::DBRIS->new_p(
		locationSearch => $station_name,
		cache          => $self->{cache},
		lwp_options    => {
			timeout => 10,
			agent   => $self->{header}{'User-Agent'},
		},
		promise    => 'Mojo::Promise',
		user_agent => $agent,
	)->then(
		sub {
			my ($dbris) = @_;
			my $found;
			for my $result ( $dbris->results ) {
				if ( defined $result->eva ) {
					$promise->resolve($result);
					return;
				}
			}
			$promise->reject("Unable to find station '$station_name'");
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("'$err' while trying to look up '$station_name'");
			return;
		}
	)->wait;
	return $promise;
}

sub get_departures_p {
	my ( $self, %opt ) = @_;

	my $agent = $self->{user_agent};
	my $proxy;
	if ( my @proxies = @{ $self->{service_config}{'bahn.de'}{proxies} // [] } )
	{
		$proxy = $proxies[ int( rand( scalar @proxies ) ) ];
	}
	elsif ( my $p = $self->{service_config}{'bahn.de'}{proxy} ) {
		$proxy = $p;
	}

	if ($proxy) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	if ( $opt{station} =~ m{ [@] L = (?<eva> \d+ ) }x ) {
		$opt{station} = {
			eva => $+{eva},
			id  => $opt{station},
		};
	}

	my $when = (
		  $opt{timestamp}
		? $opt{timestamp}->clone
		: DateTime->now( time_zone => 'Europe/Berlin' )
	)->subtract( minutes => $opt{lookbehind} );
	return Travel::Status::DE::DBRIS->new_p(
		station    => $opt{station},
		datetime   => $when,
		cache      => $self->{cache},
		promise    => 'Mojo::Promise',
		user_agent => $agent->request_timeout(10),
	);
}

sub get_journey_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;

	my $agent = $self->{user_agent};
	my $proxy;
	if ( my @proxies = @{ $self->{service_config}{'bahn.de'}{proxies} // [] } )
	{
		$proxy = $proxies[ int( rand( scalar @proxies ) ) ];
	}
	elsif ( my $p = $self->{service_config}{'bahn.de'}{proxy} ) {
		$proxy = $p;
	}

	if ($proxy) {
		$agent = Mojo::UserAgent->new;
		$agent->proxy->http($proxy);
		$agent->proxy->https($proxy);
	}

	Travel::Status::DE::DBRIS->new_p(
		journey       => $opt{trip_id},
		with_polyline => $opt{with_polyline},
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $agent->request_timeout(10),
	)->then(
		sub {
			my ($dbris) = @_;
			my $journey = $dbris->result;

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

1;
