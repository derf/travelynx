package Travelynx::Command::work;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';
use Mojo::Promise;

use DateTime;
use JSON;
use List::Util;

has description =>
  'Perform automatic checkout when users arrive at their destination';

has usage => sub { shift->extract_usage };

sub run {
	my ($self) = @_;

	my $now              = DateTime->now( time_zone => 'Europe/Berlin' );
	my $checkin_deadline = $now->clone->subtract( hours => 48 );
	my $json             = JSON->new;

	my $num_incomplete = $self->app->in_transit->delete_incomplete_checkins(
		earlier_than => $checkin_deadline );

	if ($num_incomplete) {
		$self->app->log->debug("Removed ${num_incomplete} incomplete checkins");
	}

	for my $entry ( $self->app->in_transit->get_all_active ) {

		my $uid      = $entry->{user_id};
		my $dep      = $entry->{dep_eva};
		my $arr      = $entry->{arr_eva};
		my $train_id = $entry->{train_id};

		# Note: IRIS data is not always updated in real-time. Both departure and
		# arrival delays may take several minutes to appear, especially in case
		# of large-scale disturbances. We work around this by continuing to
		# update departure data for up to 15 minutes after departure and
		# delaying automatic checkout by at least 10 minutes.

		eval {
			if ( $now->epoch - $entry->{real_dep_ts} < 900 ) {
				my $status = $self->app->iris->get_departures(
					station    => $dep,
					lookbehind => 30,
					lookahead  => 30
				);
				if ( $status->{errstr} ) {
					die("get_departures($dep): $status->{errstr}\n");
				}

				my ($train) = List::Util::first { $_->train_id eq $train_id }
				@{ $status->{results} };

				if ( not $train ) {
					die("could not find train $train_id at $dep\n");
				}

				$self->app->in_transit->update_departure(
					uid   => $uid,
					train => $train,
					route => [ $self->app->iris->route_diff($train) ]
				);

				if ( $train->departure_is_cancelled and $arr ) {
					my $checked_in
					  = $self->app->in_transit->update_departure_cancelled(
						uid     => $uid,
						train   => $train,
						dep_eva => $dep,
						arr_eva => $arr,
					  );

					# depending on the amount of users in transit, some time may
					# have passed between fetching $entry from the database and
					# now. Only check out if the user is still checked into this
					# train.
					if ($checked_in) {

                  # check out (adds a cancelled journey and resets journey state
                  # to checkin
						$self->app->checkout(
							station => $arr,
							force   => 1,
							uid     => $uid
						);
					}
				}
				else {
					$self->app->add_route_timestamps( $uid, $train, 1 );
				}
			}
		};
		if ($@) {
			$self->app->log->error("work($uid)/departure: $@");
		}

		eval {
			if (
				$arr
				and ( not $entry->{real_arr_ts}
					or $now->epoch - $entry->{real_arr_ts} < 600 )
			  )
			{
				my $status = $self->app->iris->get_departures(
					station    => $arr,
					lookbehind => 20,
					lookahead  => 220
				);
				if ( $status->{errstr} ) {
					die("get_departures($arr): $status->{errstr}\n");
				}

				# Note that a train may pass the same station several times.
				# Notable example: S41 / S42 ("Ringbahn") both starts and
				# terminates at Berlin Südkreuz
				my ($train) = List::Util::first {
					$_->train_id eq $train_id
					  and $_->sched_arrival
					  and $_->sched_arrival->epoch > $entry->{sched_dep_ts}
				}
				@{ $status->{results} };

				$train //= List::Util::first { $_->train_id eq $train_id }
				@{ $status->{results} };

				if ( not $train ) {

					# If we haven't seen the train yet, its arrival is probably
					# too far in the future. This is not critical.
					return;
				}

				my $checked_in = $self->app->in_transit->update_arrival(
					uid     => $uid,
					train   => $train,
					route   => [ $self->app->iris->route_diff($train) ],
					arr_eva => $arr,
				);

				if ( $checked_in and $train->arrival_is_cancelled ) {

                  # check out (adds a cancelled journey and resets journey state
                  # to destination selection)
					$self->app->checkout(
						station => $arr,
						force   => 0,
						uid     => $uid
					);
				}
				else {
					$self->app->add_route_timestamps( $uid, $train, 0 );
				}
			}
			elsif ( $entry->{real_arr_ts} ) {
				my ( undef, $error ) = $self->app->checkout(
					station => $arr,
					force   => 1,
					uid     => $uid
				);
				if ($error) {
					die("${error}\n");
				}
			}
		};
		if ($@) {
			$self->app->log->error("work($uid)/arrival: $@");
		}

		eval { }
	}

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

	my $request_count = 0;
	for my $account_data ( $self->app->traewelling->get_pull_accounts ) {

		# $account_data->{user_id} is the travelynx uid
		# $account_data->{user_name} is the Träwelling username
		$request_count += 1;
		$self->app->log->debug(
"Scheduling Traewelling status pull for UID $account_data->{user_id}"
		);
		Mojo::Promise->timer( $request_count * 0.2 )->then(
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

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl work

  Work Work Work.

  Should be called from a cronjob every three minutes or so.
