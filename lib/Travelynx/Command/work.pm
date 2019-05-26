package Travelynx::Command::work;
use Mojo::Base 'Mojolicious::Command';

use DateTime;
use JSON;
use List::Util qw(first);

has description =>
  'Perform automatic checkout when users arrive at their destination';

has usage => sub { shift->extract_usage };

sub run {
	my ($self) = @_;

	my $now = DateTime->now( time_zone => 'Europe/Berlin' );
	my $json = JSON->new;

	my $db = $self->app->pg->db;

	for my $entry (
		$db->select( 'in_transit_str', '*', { cancelled => 0 } )->hashes->each )
	{

		my $uid      = $entry->{user_id};
		my $dep      = $entry->{dep_ds100};
		my $arr      = $entry->{arr_ds100};
		my $train_id = $entry->{train_id};

		$self->app->log->debug("Processing $uid");

		eval {
			if ( $now->epoch - $entry->{real_dep_ts} < 300 ) {
				$self->app->log->debug("  - updating departure");
				my $status = $self->app->get_departures( $dep, 30, 30 );
				if ( $status->{errstr} ) {
					die("get_departures($dep): $status->{errstr}\n");
				}

				my ($train)
				  = first { $_->train_id eq $train_id } @{ $status->{results} };

				if ( not $train ) {
					die("could not find train $train_id at $dep\n");
				}

				$db->update(
					'in_transit',
					{
						dep_platform   => $train->platform,
						real_departure => $train->departure,
						route =>
						  $json->encode( [ map { [$_] } $train->route ] ),
						messages => $json->encode(
							[
								map { [ $_->[0]->epoch, $_->[1] ] }
								  $train->messages
							]
						),
					},
					{ user_id => $uid }
				);
			}
		};
		if ($@) {
			$self->app->log->error("work($uid)/departure: $@");
		}

		eval {
			if (
				$entry->{arr_name}
				and ( not $entry->{real_arr_ts}
					or $now->epoch - $entry->{real_arr_ts} < 60 )
			  )
			{
				$self->app->log->debug("  - updating arrival");
				my $status = $self->app->get_departures( $arr, 20, 220 );
				if ( $status->{errstr} ) {
					die("get_departures($arr): $status->{errstr}\n");
				}

				my ($train)
				  = first { $_->train_id eq $train_id } @{ $status->{results} };

				if ( not $train ) {
					if ( $entry->{real_arr_ts} ) {
						die(
"could not find train $train_id at $arr -- did it disappear?\n"
						);
					}
					else {
                     # If we haven't seen the train yet, its arrival is probably
                     # too far in the future. This is not critical.
						return;
					}
				}

				$db->update(
					'in_transit',
					{
						arr_platform  => $train->platform,
						sched_arrival => $train->sched_arrival,
						real_arrival  => $train->arrival,
						route =>
						  $json->encode( [ map { [$_] } $train->route ] ),
						messages => $json->encode(
							[
								map { [ $_->[0]->epoch, $_->[1] ] }
								  $train->messages
							]
						),
					},
					{ user_id => $uid }
				);
			}
			elsif ( $entry->{real_arr_ts} ) {
				$self->app->log->debug("  - checking out");
				my ( undef, $error ) = $self->app->checkout( $arr, 1, $uid );
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
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl work

  Work Work Work.

  Should be called from a cronjob every three minutes or so.
