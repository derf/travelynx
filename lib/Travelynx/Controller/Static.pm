package Travelynx::Controller::Static;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

sub about {
	my ($self) = @_;

	$self->render( 'about', title => 'Über travelynx' );
}

sub changelog {
	my ($self) = @_;

	$self->render( 'changelog', title => 'travelynx: Changelog' );
}

sub imprint {
	my ($self) = @_;

	$self->render( 'imprint', title => 'travelynx: Impressum' );
}

sub legend {
	my ($self) = @_;

	$self->render( 'legend', title => 'travelynx: Legende' );
}

sub offline {
	my ($self) = @_;

	$self->render('offline');
}

sub tos {
	my ($self) = @_;

	$self->render('terms-of-service');
}

1;
