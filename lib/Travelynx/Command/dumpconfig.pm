package Travelynx::Command::dumpconfig;
# Copyright (C) 2020-2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';

use Data::Dumper;

has description => 'Dump current configuration';

has usage => sub { shift->extract_usage };

sub run {
	my ($self) = @_;

	print Dumper( $self->app->config );
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl dumpconfig

  Dumps the current configuration (travelynx.conf) to stdout.
