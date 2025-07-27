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

	my %count;
	my %handle;
	for my $locale (@locales) {
		$handle{$locale} = Travelynx::Helper::Locales->get_handle($locale);
		$handle{$locale}->fail_with('failure_handler_auto');
		$count{$locale} = 0;
	}

	binmode( STDOUT, ':encoding(utf-8)' );

	if ( not $command ) {
		$self->help;
	}
	elsif ( $command eq 'update-ref' ) {
		my @buf;

		open( my $fh, '<:encoding(utf-8)', 'share/locales/de_DE.po' );
		my $comment;
		for my $line (<$fh>) {
			chomp $line;
			if ( $line =~ m{ ^ [#] \s+ (.*) $ }x ) {
				push( @buf, "## $1\n" );
			}
			elsif ( $line =~ m{ ^ [#] , \s+ (.*) $ }x ) {
				$comment = $1;
			}
			elsif ( $line =~ m{ ^ msgid \s+ " (.*) " $ }x ) {
				my $id = $1;
				push( @buf, "### ${id}\n" );
				if ($comment) {
					push( @buf, '*' . $comment . "*\n" );
					$comment = undef;
				}
				for my $locale (@locales) {
					my $translation = $handle{$locale}->maketext($id);
					if ( $translation ne $id ) {
						push( @buf, "* ${locale}: ${translation}" );
						$count{$locale} += 1;
					}
					else {
						push( @buf, "* ${locale} *missing*" );
					}
				}
				push( @buf, q{} );
			}
		}
		close($fh);

		open( $fh, '>:encoding(utf-8)', 'share/locales/reference.md' );
		say $fh '# Translation Status';
		say $fh q{};
		for my $locale (@locales) {
			say $fh sprintf(
				'* %s: %.1f%% complete (%d missing)',
				$locale,
				$count{$locale} * 100 / $count{'de-DE'},
				$count{'de-DE'} - $count{$locale},
			);
		}
		say $fh q{};
		for my $line (@buf) {
			say $fh $line;
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

  Usage: index.pl translation <command>

  Supported commands:

  * update-ref: update share/locales/reference.md
