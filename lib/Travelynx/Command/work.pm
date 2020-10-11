package Travelynx::Command::work;
use Mojo::Base 'Mojolicious::Command';

use DateTime;
use JSON;
use List::Util;

has description =>
  'Perform automatic checkout when users arrive at their destination';

has usage => sub { shift->extract_usage };

sub run {
	my ($self) = @_;

	my $now  = DateTime->now( time_zone => 'Europe/Berlin' );
	my $json = JSON->new;

	my $db = $self->app->pg->db;

	for my $entry (
		$db->select( 'in_transit_str', '*', { cancelled => 0 } )->hashes->each )
	{

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

				# selecting on user_id and train_no avoids a race condition when
				# a user checks into a new train while we are fetching data for
				# their previous journey. In this case, the new train would
				# receive data from the previous journey.
				$db->update(
					'in_transit',
					{
						dep_platform   => $train->platform,
						real_departure => $train->departure,
						route          => $json->encode(
							[ $self->app->iris->route_diff($train) ]
						),
						messages => $json->encode(
							[
								map { [ $_->[0]->epoch, $_->[1] ] }
								  $train->messages
							]
						),
					},
					{
						user_id  => $uid,
						train_no => $train->train_no
					}
				);
				if ( $train->departure_is_cancelled and $arr ) {

					# depending on the amount of users in transit, some time may
					# have passed between fetching $entry from the database and
					# now. Ensure that the user is still checked into this train
					# before calling checkout to mark the cancellation.
					if (
						$db->select(
							'in_transit',
							'count(*) as count',
							{
								user_id             => $uid,
								train_no            => $train->train_no,
								checkin_station_id  => $dep,
								checkout_station_id => $arr,
							}
						)->hash->{count}
					  )
					{
						$db->update(
							'in_transit',
							{
								cancelled => 1,
							},
							{
								user_id             => $uid,
								train_no            => $train->train_no,
								checkin_station_id  => $dep,
								checkout_station_id => $arr,
							}
						);

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

             # selecting on user_id, train_no and checkout_station_id avoids a
             # race condition when a user checks into a new train or changes
             # their destination station while we are fetching times based on no
             # longer valid database entries.
				$db->update(
					'in_transit',
					{
						arr_platform  => $train->platform,
						sched_arrival => $train->sched_arrival,
						real_arrival  => $train->arrival,
						route         => $json->encode(
							[ $self->app->iris->route_diff($train) ]
						),
						messages => $json->encode(
							[
								map { [ $_->[0]->epoch, $_->[1] ] }
								  $train->messages
							]
						),
					},
					{
						user_id             => $uid,
						train_no            => $train->train_no,
						checkout_station_id => $arr
					}
				);
				if ( $train->arrival_is_cancelled ) {

					# depending on the amount of users in transit, some time may
					# have passed between fetching $entry from the database and
					# now. Ensure that the user is still checked into this train
					# before calling checkout to mark the cancellation.
					if (
						$db->select(
							'in_transit',
							'count(*) as count',
							{
								user_id             => $uid,
								train_no            => $train->train_no,
								checkout_station_id => $arr
							}
						)->hash->{count}
					  )
					{
                  # check out (adds a cancelled journey and resets journey state
                  # to destination selection)
						$self->app->checkout(
							station => $arr,
							force   => 0,
							uid     => $uid
						);
					}
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

	for my $account_data ( $self->app->traewelling->get_pull_accounts ) {

		# $account_data->{user_id} is the travelynx uid
		# $account_data->{user_name} is the Träwelling username
		$self->app->log->debug(
			"Pulling Traewelling status for UID $account_data->{user_id}");
		$self->app->traewelling_api->get_status_p(
			username => $account_data->{data}{user_name},
			token    => $account_data->{token}
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
				$self->app->log->debug("Error $err");
			}
		)->wait;
	}

	for my $candidate ( $self->app->traewelling->get_pushable_accounts ) {
		$self->app->log->debug(
			"Pushing to Traewelling for UID $candidate->{uid}");
		my $trip_id = $candidate->{journey_data}{trip_id};
		if ( not $trip_id ) {
			$self->app->log->debug("... trip_id is missing");
			$self->app->traewelling->log(
				uid => $candidate->{uid},
				message =>
"Fehler bei $candidate->{train_type} $candidate->{train_no}: Keine trip_id vorhanden",
				is_error => 1
			);
			return;
		}
		if (    $candidate->{data}{latest_push_ts}
			and $candidate->{data}{latest_push_ts} == $candidate->{checkin_ts} )
		{
			$self->app->log->debug("... already handled");
			return;
		}
		$self->app->traewelling_api->checkin( %{$candidate},
			trip_id => $trip_id );
	}

	# Computing yearly stats may take a while, but we've got all time in the
	# world here. This means users won't have to wait when loading their
	# own by-year journey log.
	for my $user ( $db->select( 'users', 'id', { status => 1 } )->hashes->each )
	{
		$self->app->get_journey_stats(
			uid  => $user->{id},
			year => $now->year
		);
	}

	# TODO wait until all background jobs have terminated
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl work

  Work Work Work.

  Should be called from a cronjob every three minutes or so.
