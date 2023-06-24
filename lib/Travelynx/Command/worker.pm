package Travelynx::Command::worker;

# Copyright (C) 2020-2023 Birthe Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';
use Mojo::IOLoop;

has description => 'travelynx background worker';

has usage => sub { shift->extract_usage };

sub run {
	my ($self) = @_;

	Mojo::IOLoop->recurring(
		180 => sub {
			$self->app->start('work');
		}
	);

	Mojo::IOLoop->recurring(
		36000 => sub {
			$self->app->start('maintenance');
		}
	);

	if ( not Mojo::IOLoop->is_running ) {
		Mojo::IOLoop->start;
	}
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl worker

  Background worker for cron-less setups, e.g. Docker.

  Calls "index.pl work" every 3 minutes and "index.pl maintenance" every 10 hours.
