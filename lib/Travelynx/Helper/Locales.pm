package Travelynx::Helper::Locales;

use strict;
use warnings;

use base qw(Locale::Maketext);

our %Lexicon = (
	_AUTO => 1,
);

use Locale::Maketext::Lexicon {
	_decode => 1,
	'*'     => [ Gettext => 'share/locales/*.po' ],
};

sub init {
	my ($self) = @_;
	return $self->SUPER::init( @_[ 1 .. $#_ ] );
}

1;
