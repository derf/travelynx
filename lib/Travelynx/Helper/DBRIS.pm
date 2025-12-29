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

sub get_agent {
	my ($self) = @_;

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

	return $agent;
}

sub geosearch_p {
	my ( $self, %opt ) = @_;

	return Travel::Status::DE::DBRIS->new_p(
		promise        => 'Mojo::Promise',
		user_agent     => $self->get_agent,
		geoSearch      => \%opt,
		developer_mode => $self->{log}->is_level('debug') ? 1 : 0,
	);
}

sub get_station_id_p {
	my ( $self, $station_name ) = @_;

	my $promise = Mojo::Promise->new;

	Travel::Status::DE::DBRIS->new_p(
		locationSearch => $station_name,
		cache          => $self->{realtime_cache},
		lwp_options    => {
			timeout => 10,
			agent   => $self->{header}{'User-Agent'},
		},
		promise        => 'Mojo::Promise',
		user_agent     => $self->get_agent,
		developer_mode => $self->{log}->is_level('debug') ? 1 : 0,
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
		station        => $opt{station},
		datetime       => $when,
		num_vias       => 42,
		cache          => $self->{realtime_cache},
		promise        => 'Mojo::Promise',
		user_agent     => $self->get_agent->request_timeout(10),
		developer_mode => $self->{log}->is_level('debug') ? 1 : 0,
	);
}

sub get_connections_p {
	my ( $self, %opt ) = @_;
	my $promise      = Mojo::Promise->new;
	my $destinations = $opt{destinations};

	$self->{log}->debug(
"get_connections_p(station => $opt{station}, timestamp => $opt{timestamp})"
	);

	$self->get_departures_p(
		station    => '@L=' . $opt{station},
		timestamp  => $opt{timestamp},
		lookbehind => 0,
		lookahead  => 60,
	)->then(
		sub {
			my ($status) = @_;
			my @suggestions = $self->grep_suggestions(
				status       => $status,
				destinations => $destinations,
				max_per_dest => 2
			);
			@suggestions
			  = sort { $a->[0]{sort_ts} <=> $b->[0]{sort_ts} } @suggestions;
			$promise->resolve( \@suggestions );
			return;
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject("get_departures_p($opt{station}): $err");
			return;
		}
	)->wait;
	return $promise;
}

sub get_journey_p {
	my ( $self, %opt ) = @_;

	my $promise = Mojo::Promise->new;

	Travel::Status::DE::DBRIS->new_p(
		journey        => $opt{trip_id},
		with_polyline  => $opt{with_polyline},
		cache          => $self->{realtime_cache},
		promise        => 'Mojo::Promise',
		user_agent     => $self->get_agent->request_timeout(10),
		developer_mode => $self->{log}->is_level('debug') ? 1 : 0,
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

sub get_wagonorder_p {
	my ( $self, %opt ) = @_;

	$self->{log}
	  ->debug("get_wagonorder_p($opt{train_type} $opt{train_no} @ $opt{eva})");

	return Travel::Status::DE::DBRIS->new_p(
		cache         => $self->{main_cache},
		failure_cache => $self->{realtime_cache},
		promise       => 'Mojo::Promise',
		user_agent    => $self->get_agent->request_timeout(10),
		formation     => {
			departure    => $opt{datetime},
			eva          => $opt{eva},
			train_type   => $opt{train_type},
			train_number => $opt{train_no}
		},
		developer_mode => $self->{log}->is_level('debug') ? 1 : 0,
	);
}

sub grep_suggestions {
	my ( $self, %opt ) = @_;
	my $status       = $opt{status};
	my $destinations = $opt{destinations};
	my $max_per_dest = $opt{max_per_dest};

	my @suggestions;
	my %via_count;

	for my $dep ( $status->results ) {
		my $dep_json = {
			id            => $dep->id,
			ts            => ( $dep->sched_dep // $dep->dep )->epoch,
			sort_ts       => $dep->dep->epoch,
			is_cancelled  => $dep->is_cancelled,
			stop_eva      => $dep->stop_eva,
			maybe_line_no => $dep->maybe_line_no,
			sched_hhmm    => $dep->sched_dep->strftime('%H:%M'),
			rt_hhmm       => $dep->dep->strftime('%H:%M'),
			delay         => $dep->delay,
			platform      => $dep->platform,
			type          => $dep->type,
			line          => $dep->line,
		};
		destination: for my $dest ( @{$destinations} ) {
			if (    $dep->destination
				and $dep->destination eq $dest->{name} )
			{
				if ( not $dep->is_cancelled ) {
					$via_count{ $dest->{name} } += 1;
				}
				if (    $max_per_dest
					and $via_count{ $dest->{name} }
					and $via_count{ $dest->{name} } > $max_per_dest )
				{
					next destination;
				}
				push( @suggestions, [ $dep_json, $dest ] );
				next destination;
			}
			for my $via_name ( $dep->via ) {
				if ( $via_name eq $dest->{name} ) {
					if ( not $dep->is_cancelled ) {
						$via_count{ $dest->{name} } += 1;
					}
					if (    $max_per_dest
						and $via_count{ $dest->{name} }
						and $via_count{ $dest->{name} } > $max_per_dest )
					{
						next destination;
					}
					push( @suggestions, [ $dep_json, $dest ] );
					next destination;
				}
			}
		}
	}

	return @suggestions;
}

1;
