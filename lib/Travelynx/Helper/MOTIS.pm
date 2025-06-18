package Travelynx::Helper::MOTIS;

# Copyright (C) 2025 networkException <git@nwex.de>
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

use Travel::Status::MOTIS;

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

	return Travel::Status::MOTIS::get_service($service);
}

sub get_station_by_query_p {
	my ( $self, %opt ) = @_;

	$opt{service} //= 'transitous';

	my $promise = Mojo::Promise->new;

	Travel::Status::MOTIS->new_p(
		cache       => $self->{cache},
		promise     => 'Mojo::Promise',
		user_agent  => Mojo::UserAgent->new,
		time_zone   => 'Europe/Berlin',
		lwp_options => {
			timeout => 10,
			agent   => $self->{header}{'User-Agent'},
		},

		service        => $opt{service},
		stops_by_query => $opt{query},
	)->then(
		sub {
			my ($motis) = @_;
			my $found;

			for my $result ( $motis->results ) {
				if ( defined $result->id ) {
					$promise->resolve($result);
					return;
				}
			}

			$promise->reject("Unable to find station '$opt{query}'");
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("'$err' while trying to look up '$opt{query}'");
			return;
		}
	)->wait;

	return $promise;
}

sub get_departures_p {
	my ( $self, %opt ) = @_;

	$opt{service} //= 'transitous';

	my $timestamp = (
		  $opt{timestamp}
		? $opt{timestamp}->clone
		: DateTime->now
	)->subtract( minutes => $opt{lookbehind} );

	return Travel::Status::MOTIS->new_p(
		cache       => $self->{cache},
		promise     => 'Mojo::Promise',
		user_agent  => Mojo::UserAgent->new,
		time_zone   => 'Europe/Berlin',
		lwp_options => {
			timeout => 10,
			agent   => $self->{header}{'User-Agent'},
		},

		service   => $opt{service},
		timestamp => $timestamp,
		stop_id   => $opt{station_id},
		results   => 60,
	);
}

sub get_trip_p {
	my ( $self, %opt ) = @_;

	$opt{service} //= 'transitous';

	my $promise = Mojo::Promise->new;

	Travel::Status::MOTIS->new_p(
		with_polyline => $opt{with_polyline},
		cache         => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => Mojo::UserAgent->new,
		time_zone     => 'Europe/Berlin',

		service => $opt{service},
		trip_id => $opt{trip_id},
	)->then(
		sub {
			my ($motis) = @_;
			my $journey = $motis->result;

			if ($journey) {
				$self->{log}->debug("get_trip_p($opt{trip_id}): success");
				$promise->resolve($journey);
				return;
			}

			$self->{log}->debug("get_trip_p($opt{trip_id}): no journey");
			$promise->reject('no journey');
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$self->{log}->debug("get_trip_p($opt{trip_id}): error $err");
			$promise->reject($err);
			return;
		}
	)->wait;

	return $promise;
}

1;
