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

sub get_connections_p {
	my ( $self, %opt ) = @_;
	my $promise      = Mojo::Promise->new;
	my @destinations = @{ $opt{destinations} };

	$self->get_departures_p(
		service    => $opt{service},
		name       => $opt{name},
		timestamp  => $opt{timestamp},
		lookbehind => 0,
		lookahead  => 60,
	)->then(
		sub {
			my ($status) = @_;
			my @suggestions;
			my %via_count;
			for my $dep ( $status->results ) {
				destination: for my $dest (@destinations) {
					for my $stop ( $dep->route_post ) {
						if ( $stop->full_name eq $dest->{name} ) {
							if ( not $dep->is_cancelled ) {
								$via_count{ $dep->stop_id_num } += 1;
							}
							if ( $via_count{ $dep->stop_id_num } > 2 ) {
								next destination;
							}
							my $dep_json = {
								id => $dep->id,
								ts => ( $dep->sched_datetime // $dep->datetime )
								  ->epoch,
								is_cancelled => $dep->is_cancelled,
								stop_id_num  => $dep->stop_id_num,
								sched_hhmm   =>
								  $dep->sched_datetime->strftime('%H:%M'),
								rt_hhmm  => $dep->datetime->strftime('%H:%M'),
								delay    => $dep->delay,
								platform => $dep->platform,
								type     => $dep->type,
								line     => $dep->line,
							};
							push(
								@suggestions,
								[
									$dep_json, $dest,
									$stop->arr->strftime('%H:%M')
								]
							);
							next destination;
						}
					}
				}
			}
			@suggestions = map { $_->[0] }
			  sort { $a->[1] <=> $b->[1] }
			  map { [ $_, $_->[0]->{ts} ] } @suggestions;
			$promise->resolve( \@suggestions );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject(
				"get_departures_p($opt{service}, $opt{name}): $err");
			return;
		}
	)->wait;
	return $promise;
}

sub get_journey_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;
	my $agent   = $self->{user_agent};
	my $stopseq;

	if ( $opt{trip_id}
		=~ m{ ^ ([^@]*) @ ([^@]*) [(] ([^T]*) T ([^)]*) [)] (.*) $ }x )
	{
		$stopseq = {
			stateless => $1,
			stop_id   => $2,
			date      => $3,
			time      => $4,
			key       => $5
		};
	}
	else {
		return $promise->reject("Invalid trip_id: $opt{trip_id}");
	}

	Travel::Status::DE::EFA->new_p(
		service    => $opt{service},
		stopseq    => $stopseq,
		cache      => $self->{realtime_cache},
		promise    => 'Mojo::Promise',
		user_agent => $agent->request_timeout(10),
	)->then(
		sub {
			my ($efa) = @_;
			my $journey = $efa->result;

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
