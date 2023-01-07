package Travelynx::Command::traewelling;

# Copyright (C) 2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';
use Mojo::Promise;

use DateTime;
use JSON;
use List::Util;

has description => 'Synchronize with Traewelling';

has usage => sub { shift->extract_usage };

sub pull_sync {
	my ($self) = @_;
	my $request_count = 0;
	for my $account_data ( $self->app->traewelling->get_pull_accounts ) {

		my $in_transit = $self->app->in_transit->get(
			uid => $account_data->{user_id},
		);
		if ($in_transit) {
			$self->app->log->debug(
"Skipping Traewelling status pull for UID $account_data->{user_id}: already checked in"
			);
			next;
		}

		# $account_data->{user_id} is the travelynx uid
		# $account_data->{user_name} is the Träwelling username
		$request_count += 1;
		$self->app->log->debug(
"Scheduling Traewelling status pull for UID $account_data->{user_id}"
		);

		# In 'work', the event loop is not running,
		# so there's no need to multiply by $request_count at the moment
		Mojo::Promise->timer(0.5)->then(
			sub {
				return $self->app->traewelling_api->get_status_p(
					username => $account_data->{data}{user_name},
					token    => $account_data->{token}
				);
			}
		)->then(
			sub {
				my ($traewelling) = @_;
				$self->app->traewelling_to_travelynx(
					traewelling => $traewelling,
					user_data   => $account_data
				);
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->app->traewelling->log(
					uid      => $account_data->{user_id},
					message  => "Fehler bei der Status-Abfrage: $err",
					is_error => 1
				);
				$self->app->log->debug("Error $err");
			}
		)->wait;
	}
}

sub push_sync {
	my ($self) = @_;

	for my $candidate ( $self->app->traewelling->get_pushable_accounts ) {
		$self->app->log->debug(
			"Pushing to Traewelling for UID $candidate->{uid}");
		my $trip_id = $candidate->{journey_data}{trip_id};
		if ( not $trip_id ) {
			$self->app->log->debug("... trip_id is missing");
			$self->app->traewelling->log(
				uid     => $candidate->{uid},
				message =>
"Konnte $candidate->{train_type} $candidate->{train_no} nicht übertragen: Keine trip_id vorhanden",
				is_error => 1
			);
			next;
		}
		if (    $candidate->{data}{latest_push_ts}
			and $candidate->{data}{latest_push_ts} == $candidate->{checkin_ts} )
		{
			$self->app->log->debug("... already handled");
			next;
		}
		$self->app->traewelling_api->checkin( %{$candidate},
			trip_id => $trip_id );
	}
}

sub run {
	my ( $self, $direction ) = @_;

	my $now        = DateTime->now( time_zone => 'Europe/Berlin' );
	my $started_at = $now;

	if ( not $direction or $direction eq 'push' ) {
		$self->push_sync;
	}

	my $trwl_push_finished_at = DateTime->now( time_zone => 'Europe/Berlin' );

	if ( not $direction or $direction eq 'pull' ) {
		$self->pull_sync;
	}

	my $trwl_pull_finished_at = DateTime->now( time_zone => 'Europe/Berlin' );

	my $trwl_push_duration = $trwl_push_finished_at->epoch - $started_at->epoch;
	my $trwl_pull_duration
	  = $trwl_pull_finished_at->epoch - $trwl_push_finished_at->epoch;
	my $trwl_duration = $trwl_pull_finished_at->epoch - $started_at->epoch;

	if ( $self->app->config->{influxdb}->{url} ) {
		my $report = "sync_runtime_seconds=${trwl_duration}";
		if ( not $direction or $direction eq 'push' ) {
			$report .= ",push_runtime_seconds=${trwl_push_duration}";
		}
		if ( not $direction or $direction eq 'pull' ) {
			$report .= ",pull_runtime_seconds=${trwl_pull_duration}";
		}
		if ( $self->app->mode eq 'development' ) {
			$self->app->log->debug( 'POST '
				  . $self->app->config->{influxdb}->{url}
				  . " traewelling ${report}" );
		}
		else {
			$self->app->ua->post_p( $self->app->config->{influxdb}->{url},
				"traewelling ${report}" )->wait;
		}
	}
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl traewelling [direction]

  Performs both push and pull synchronization by default.
  If "direction" is specified, only synchronizes in the specified direction
  ("push" or "pull")

  Should be called from a cronjob every three to ten minutes.
