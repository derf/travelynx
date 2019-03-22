package Travelynx::Controller::Static;
use Mojo::Base 'Mojolicious::Controller';

my $travelynx_version = qx{git describe --dirty} || 'experimental';

sub about {
	my ($self) = @_;

	$self->render( 'about', version => $travelynx_version );
}

sub imprint {
	my ($self) = @_;

	$self->render('imprint');
}

1;
