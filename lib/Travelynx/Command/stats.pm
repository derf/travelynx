package Travelynx::Command::stats;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';

use DateTime;

has description => 'Deal with monthly and yearly statistics';

has usage => sub { shift->extract_usage };

sub refresh_all {
	my ($self) = @_;

	my $db  = $self->app->pg->db;
	my $now = DateTime->now( time_zone => 'Europe/Berlin' );

	say 'Refreshing all stats, this may take a while ...';

	my $total = $db->select( 'users', 'count(*) as count', { status => 1 } )
	  ->hash->{count};
	my $i = 1;

	for
	  my $user ( $db->select( 'users', ['id'], { status => 1 } )->hashes->each )
	{
		$self->app->journeys->generate_missing_stats( uid => $user->{id} );
		$self->app->journeys->get_stats(
			uid        => $user->{id},
			year       => $now->year,
			write_only => 1,
		);
		if ( $i == $total or ( $i % 10 ) == 0 ) {
			printf( "%.f%% complete", $i * 100 / $total );
		}
		$i++;
	}
}

sub run {
	my ( $self, $cmd, @arg ) = @_;

	if ( $cmd eq 'refresh-all' ) {
		$self->refresh_all(@arg);
	}

}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl stats refresh-all

  Refreshes all stats
