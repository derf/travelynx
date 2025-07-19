package Travelynx::Helper::Locales;

use strict;
use warnings;

#BEGIN { package Locale::Maketext; sub DEBUG() {1} };
#BEGIN { package Locale::Maketext::Guts; sub DEBUG() {1} };

use base qw(Locale::Maketext);

# Uncomment this to show raw strings for untranslated content rather than
# falling back to German.

#our %Lexicon = (
#	_AUTO => 1,
#);

use Locale::Maketext::Lexicon {
	_decode => 1,
	'*'     => [ Gettext => 'share/locales/*.po' ],
};

sub init {
	my ($self) = @_;
	return $self->SUPER::init( @_[ 1 .. $#_ ] );
}

1;
