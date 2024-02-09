package Travelynx::Command::dumpstops;

# Copyright (C) 2024 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Command';
use List::Util qw();
use Text::CSV;

has description => 'Export HAFAS/IRIS stops to CSV';

has usage => sub { shift->extract_usage };

sub run {
	my ( $self, $command, $filename ) = @_;
	my $db = $self->app->pg->db;

	if ( not $command or not $filename ) {
		$self->help;
	}
	elsif ( $command eq 'csv' ) {
		open( my $fh, '>', $filename ) or die("open($filename): $!\n");

		my $csv = Text::CSV->new( { eol => "\r\n" } );
		$csv->combine(qw(name eva lat lon source archived));
		print $fh $csv->string;

		my $iter = $self->app->stations->get_db_iterator;
		while ( my $row = $iter->hash ) {
			$csv->combine( @{$row}{qw{name eva lat lon source archived}} );
			print $fh $csv->string;
		}
		close($fh);
	}
	else {
		$self->help;
	}
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl dumpstops <format> <filename>

  Exports known stops to <filename>.
  Right now, only the "csv" format is supported.
