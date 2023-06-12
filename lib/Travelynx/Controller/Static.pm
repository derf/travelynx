package Travelynx::Controller::Static;

# Copyright (C) 2020-2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

sub about {
	my ($self) = @_;

	$self->render('about');
}

sub changelog {
	my ($self) = @_;

	$self->render('changelog');
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
