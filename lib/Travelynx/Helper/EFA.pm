package Travelynx::Helper::EFA;

# Copyright (C) 2024 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

use Travel::Status::DE::EFA;

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

	say "get_service $service";

	return Travel::Status::DE::EFA::get_service($service);
}

sub get_departures_p {
	my ( $self, %opt ) = @_;

	my $when = (
		  $opt{timestamp}
		? $opt{timestamp}->clone
		: DateTime->now( time_zone => 'Europe/Berlin' )
	)->subtract( minutes => $opt{lookbehind} );
	return Travel::Status::DE::EFA->new_p(
		service     => $opt{service},
		name        => $opt{name},
		datetime    => $when,
		full_routes => 1,
		cache       => $self->{realtime_cache},
		promise     => 'Mojo::Promise',
		user_agent  => $self->{user_agent}->request_timeout(5),
	);
}

1;
