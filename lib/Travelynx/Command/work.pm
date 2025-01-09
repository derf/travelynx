package Travelynx::Command::work;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';
use Mojo::Promise;

use utf8;

use DateTime;
use JSON;
use List::Util;

has description => 'Update real-time data of active journeys';

has usage => sub { shift->extract_usage };

sub run {
	my ($self) = @_;

	my $now              = DateTime->now( time_zone => 'Europe/Berlin' );
	my $checkin_deadline = $now->clone->subtract( hours => 48 );
	my $json             = JSON->new;

	if ( -e 'maintenance' ) {
		$self->app->log->debug('work: "maintenance" file found, aborting');
		return;
	}

	my $num_incomplete = $self->app->in_transit->delete_incomplete_checkins(
		earlier_than => $checkin_deadline );

	if ($num_incomplete) {
		$self->app->log->debug("Removed ${num_incomplete} incomplete checkins");
	}

	my $errors = 0;

	for my $entry ( $self->app->in_transit->get_all_active ) {

		if ( -e 'maintenance' ) {
			$self->app->log->debug('work: "maintenance" file found, aborting');
			return;
		}

		my $uid      = $entry->{user_id};
		my $dep      = $entry->{dep_eva};
		my $arr      = $entry->{arr_eva};
		my $train_id = $entry->{train_id};

		if ( $entry->{is_hafas} ) {

			eval {

				$self->app->hafas->get_journey_p(
					trip_id => $train_id,
					service => $entry->{backend_name}
				)->then(
					sub {
						my ($journey) = @_;

						my $found_dep;
						my $found_arr;
						for my $stop ( $journey->route ) {
							if ( $stop->loc->eva == $dep ) {
								$found_dep = $stop;
							}
							if ( $arr and $stop->loc->eva == $arr ) {
								$found_arr = $stop;
								last;
							}
						}
						if ( not $found_dep ) {
							$self->app->log->debug(
								"Did not find $dep within journey $train_id");
							return;
						}

						if ( $found_dep->rt_dep ) {
							$self->app->in_transit->update_departure_hafas(
								uid     => $uid,
								journey => $journey,
								stop    => $found_dep,
								dep_eva => $dep,
								arr_eva => $arr
							);
						}
						if (
							$found_dep->sched_dep
							and (  $entry->{backend_id} <= 1
								or $entry->{backend_name} eq 'VRN'
								or $entry->{backend_name} eq 'ÖBB' )
							and $journey->class <= 16
							and $found_dep->dep->epoch > $now->epoch
						  )
						{
							$self->app->add_wagonorder(
								uid          => $uid,
								train_id     => $journey->id,
								is_departure => 1,
								eva          => $dep,
								datetime     => $found_dep->sched_dep,
								train_type   => $journey->type =~ s{ +$}{}r,
								train_no     => $journey->number,
							);
							$self->app->add_stationinfo( $uid, 1,
								$journey->id, $found_dep->loc->eva );
						}

						if ( $found_arr and $found_arr->rt_arr ) {
							$self->app->in_transit->update_arrival_hafas(
								uid     => $uid,
								journey => $journey,
								stop    => $found_arr,
								dep_eva => $dep,
								arr_eva => $arr
							);
							if (    $entry->{backend_id} <= 1
								and $journey->class <= 16
								and $found_arr->rt_arr->epoch - $now->epoch
								< 600 )
							{
								$self->app->add_wagonorder(
									uid        => $uid,
									train_id   => $journey->id,
									is_arrival => 1,
									eva        => $arr,
									datetime   => $found_arr->sched_dep,
									train_type => $journey->type,
									train_no   => $journey->number,
								);
								$self->app->add_stationinfo( $uid, 0,
									$journey->id, $found_dep->loc->eva,
									$found_arr->loc->eva );
							}
						}
					}
				)->catch(
					sub {
						my ($err) = @_;
						if ( $err
							=~ m{svcResL\[0\][.]err is (?:FAIL|PARAMETER)$} )
						{
							# HAFAS do be weird. These are not actionable.
							$self->app->log->debug(
"work($uid) @ HAFAS $entry->{backend_name}: journey: $err"
							);
						}
						else {
							$self->app->log->error(
"work($uid) @ HAFAS $entry->{backend_name}: journey: $err"
							);
						}
					}
				)->wait;

				if (    $arr
					and $entry->{real_arr_ts}
					and $now->epoch - $entry->{real_arr_ts} > 600 )
				{
					$self->app->checkout_p(
						station => $arr,
						force   => 2,
						dep_eva => $dep,
						arr_eva => $arr,
						uid     => $uid
					)->wait;
				}
			};
			if ($@) {
				$errors += 1;
				$self->app->log->error(
					"work($uid) @ HAFAS $entry->{backend_name}: $@");
			}
			next;
		}

		# TODO irgendwo ist hier ne race condition wo ein neuer checkin (in HAFAS) mit IRIS-Daten überschrieben wird.
		# Die ganzen updates brauchen wirklich mal sanity checks mit train id ...

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
					$self->app->log->debug(
						"could not find train $train_id at $dep\n");
					return;
				}

				$self->app->in_transit->update_departure(
					uid     => $uid,
					train   => $train,
					dep_eva => $dep,
					arr_eva => $arr,
					route   => [ $self->app->iris->route_diff($train) ]
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
						$self->app->checkout_p(
							station => $arr,
							force   => 2,
							dep_eva => $dep,
							arr_eva => $arr,
							uid     => $uid
						)->wait;
					}
				}
				else {
					$self->app->add_route_timestamps( $uid, $train, 1 );
					$self->app->add_wagonorder(
						uid          => $uid,
						train_id     => $train->train_id,
						is_departure => 1,
						eva          => $dep,
						datetime     => $train->sched_departure,
						train_type   => $train->type,
						train_no     => $train->train_no
					);
					$self->app->add_stationinfo( $uid, 1, $train->train_id,
						$dep, $arr );
				}
			}
		};
		if ($@) {
			$errors += 1;
			$self->app->log->error("work($uid) @ IRIS: departure: $@");
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
					dep_eva => $dep,
					arr_eva => $arr,
				);

				if ( $checked_in and $train->arrival_is_cancelled ) {

					# check out (adds a cancelled journey and resets journey state
					# to destination selection)
					$self->app->checkout_p(
						station => $arr,
						force   => 0,
						dep_eva => $dep,
						arr_eva => $arr,
						uid     => $uid
					)->wait;
				}
				else {
					$self->app->add_route_timestamps(
						$uid, $train, 0,
						(
							defined $entry->{real_arr_ts}
							  and $now->epoch > $entry->{real_arr_ts}
						) ? 1 : 0
					);
					$self->app->add_wagonorder(
						uid        => $uid,
						train_id   => $train->train_id,
						is_arrival => 1,
						eva        => $arr,
						datetime   => $train->sched_departure,
						train_type => $train->type,
						train_no   => $train->train_no
					);
					$self->app->add_stationinfo( $uid, 0, $train->train_id,
						$dep, $arr );
				}
			}
			elsif ( $entry->{real_arr_ts} ) {
				my ( undef, $error ) = $self->app->checkout_p(
					station => $arr,
					force   => 2,
					dep_eva => $dep,
					arr_eva => $arr,
					uid     => $uid
				)->catch(
					sub {
						my ($error) = @_;
						$self->app->log->error(
							"work($uid) @ IRIS: arrival: $error");
						$errors += 1;
					}
				)->wait;
			}
		};
		if ($@) {
			$self->app->log->error("work($uid) @ IRIS: arrival: $@");
			$errors += 1;
		}

		eval { };
	}

	my $started_at       = $now;
	my $main_finished_at = DateTime->now( time_zone => 'Europe/Berlin' );
	my $worker_duration  = $main_finished_at->epoch - $started_at->epoch;

	if ( $self->app->config->{influxdb}->{url} ) {
		if ( $self->app->mode eq 'development' ) {
			$self->app->log->debug( 'POST '
				  . $self->app->config->{influxdb}->{url}
				  . " worker runtime_seconds=${worker_duration},errors=${errors}"
			);
		}
		else {
			$self->app->ua->post_p( $self->app->config->{influxdb}->{url},
				"worker runtime_seconds=${worker_duration},errors=${errors}" )
			  ->wait;
		}
	}

	if ( not $self->app->config->{traewelling}->{separate_worker} ) {
		$self->app->start('traewelling');
	}

	# add_wagonorder and add_stationinfo assume a permanently running IOLoop
	# and do not allow Mojolicious commands to wait until they have completed.
	# Hence, some add_wagonorder and add_stationinfo calls made here may not
	# complete before the work command exits, and thus have no effect.
	#
	# This is not ideal and will need fixing at some point.  Until then, here
	# is the pragmatic solution for 99% of the associated issues.
	Mojo::Promise->timer(5)->wait;
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl work

  Work Work Work.

  Should be called from a cronjob every three minutes or so.
