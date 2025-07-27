package Travelynx::Command::translation;

# Copyright (C) 2025 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use Mojo::Base 'Mojolicious::Command';
use Travelynx::Helper::Locales;

has description => 'Export translation status';

has usage => sub { shift->extract_usage };

sub run {
	my ( $self, $command ) = @_;

	my @locales = (qw(de-DE en-GB fr-FR hu-HU pl-PL));

	my %handle;
	for my $locale (@locales) {
		$handle{$locale} = Travelynx::Helper::Locales->get_handle($locale);
		$handle{$locale}->fail_with('failure_handler_auto');
	}

	binmode( STDOUT, ':encoding(utf-8)' );

	if ( not $command ) {
		$self->help;
	}
	elsif ( $command eq 'status' ) {
		say '# Translation Status';
		say q{};

		open( my $fh, '<:encoding(utf-8)', 'share/locales/de_DE.po' );
		for my $line (<$fh>) {
			chomp $line;
			if ( $line =~ m{ ^ [#] \s+ (.*) $ }x ) {
				say "## $1";
				say q{};
			}
			elsif ( $line =~ m{ ^ msgid \s+ " (.*) " $ }x ) {
				my $id = $1;
				say "### ${id}";
				say q{};
				for my $locale (@locales) {
					my $translation = $handle{$locale}->maketext($id);
					if ( $translation ne $id ) {
						say "* ${locale}: ${translation}";
					}
					else {
						say "* ${locale} *missing*";
					}
				}
				say q{};
			}
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
