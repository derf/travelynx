package Travelynx::Controller::Static;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

my $travelynx_version = qx{git describe --dirty} || 'experimental';

sub about {
	my ($self) = @_;

	$self->render( 'about',
		version => $self->app->config->{version} // 'UNKNOWN' );
}

sub changelog {
	my ($self) = @_;

	$self->render( 'changelog',
		version => $self->app->config->{version} // 'UNKNOWN' );
}

sub imprint {
	my ($self) = @_;

	$self->render('imprint');
}

sub legend {
	my ($self) = @_;

	$self->render('legend');
}

sub offline {
	my ($self) = @_;

	$self->render('offline');
}

1;
