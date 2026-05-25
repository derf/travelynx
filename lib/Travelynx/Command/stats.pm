package Travelynx::Command::stats;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Deal with monthly and yearly statistics';

has usage => sub { shift->extract_usage };

sub compute_distances {
	my ($self) = @_;

	my $db      = $self->app->pg->db;
	my $total   = $db->select( 'journeys', 'count(*) as count' )->hash->{count};
	my $i       = 1;
	my $updated = 0;

	say
	  'Storing travel distances for past journeys, this make take a while ...';

	for
	  my $journey ( $db->select( 'journeys', [qw[id user_id distance_beeline]] )
		->hashes->each )
	{
		if ( not defined $journey->{distance_beeline} ) {
			$self->app->journeys->update_distances(
				db         => $db,
				uid        => $journey->{user_id},
				journey_id => $journey->{id}
			);
			$updated++;
		}
		if ( $i == $total or ( $i % 100 ) == 0 ) {
			printf( "%6.2f%% complete\n", $i * 100 / $total );
		}
		$i++;
	}
	say "Added travel distances to $updated of $i journeys";
}

sub purge_cache {
	my ($self) = @_;

	say 'Purging cached journey stats: TRUNCATE TABLE journey_stats';

	my $db = $self->app->pg->db;
	$db->query('truncate table journey_stats;');
}

sub run {
	my ( $self, $cmd, @arg ) = @_;

	if ( $cmd eq 'compute-distances' ) {
		$self->compute_distances(@arg);
	}
	elsif ( $cmd eq 'purge-cache' ) {
		$self->purge_cache(@arg);
	}

}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl stats refresh-all

  Refreshes all stats
