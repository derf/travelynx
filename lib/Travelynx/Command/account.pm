package Travelynx::Command::account;

# Copyright (C) 2021 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';
use UUID::Tiny qw(:std);

has description => 'Add or remove user accounts';

has usage => sub { shift->extract_usage };

sub add_user {
	my ( $self, $name, $email ) = @_;

	my $db = $self->app->pg->db;

	if ( my $error = $self->app->users->is_name_invalid( name => $name ) ) {
		say "Cannot add account '$name': $error";
		die;
	}

	my $token    = "tmp";
	my $password = substr( create_uuid_as_string(UUID_V4), 0, 18 );

	my $tx      = $db->begin;
	my $user_id = $self->app->users->add(
		db       => $db,
		name     => $name,
		email    => $email,
		token    => $token,
		password => $password,
	);
	my $success = $self->app->users->verify_registration_token(
		db             => $db,
		uid            => $user_id,
		token          => $token,
		in_transaction => 1,
	);

	if ($success) {
		$tx->commit;
		say "Added user $name ($email) with UID $user_id";
		say "Temporary password for login: $password";
	}
}

sub delete_user {
	my ( $self, $uid, $name ) = @_;

	my $user_data = $self->app->users->get( uid => $uid );

	if ( not $user_data ) {
		say "UID $uid does not exist.";
		return;
	}

	if ( $user_data->{name} ne $name ) {
		say
"User name $name does not match UID $uid. Account will not be marked for deletion.";
		return;
	}

	$self->app->users->flag_deletion( uid => $uid );

	say "User $user_data->{name} (UID $uid) has been marked for deletion.";
	say 'The account and all corresponding data will be deleted in three days.';
}

sub undelete_user {
	my ( $self, $uid, $name ) = @_;

	my $user_data = $self->app->users->get( uid => $uid );

	if ( not $user_data ) {
		say "UID $uid does not exist.";
		return;
	}

	if ( $user_data->{name} ne $name ) {
		say
"User name $name does not match UID $uid. Account will not be marked for deletion.";
		return;
	}

	$self->app->users->unflag_deletion( uid => $uid );

	say "User $user_data->{name} (UID $uid) is no longer marked for deletion.";
}

sub really_delete_user {
	my ( $self, $uid, $name ) = @_;

	my $user_data = $self->app->users->get( uid => $uid );

	if ( not $user_data ) {
		say "UID $uid does not exist.";
		return;
	}

	if ( $user_data->{name} ne $name ) {
		say
		  "User name $name does not match UID $uid. Account deletion aborted.";
		return;
	}

	say "About to immediately and irrevocably delete user ${name} (UID ${uid})";
	say 'If this was a mistake, press Ctrl+C now.';
	say q{};
	$| = 1;
	for my $i ( reverse 1 .. 6 ) {
		print "\r\e[2KCommencing deletion in ${i} seconds ...";
		sleep(1);
	}
	print "\r\e[2K";

	my $count = $self->app->users->delete( uid => $uid );

	printf( "Deleted %s -- %d tokens, %d monthly stats, %d journeys\n",
		$name, $count->{tokens}, $count->{stats}, $count->{journeys} );

	return;
}

sub delete_journeys {
	my ( $self, $uid, $name ) = @_;

	my $user_data = $self->app->users->get( uid => $uid );

	if ( not $user_data ) {
		say "UID $uid does not exist.";
		return;
	}

	if ( $user_data->{name} ne $name ) {
		say
		  "User name $name does not match UID $uid. Account deletion aborted.";
		return;
	}

	say
"About to immediately and irrevocably delete all journeys of user ${name} (UID ${uid})";
	say 'If this was a mistake, press Ctrl+C now.';
	say q{};
	$| = 1;
	for my $i ( reverse 1 .. 6 ) {
		print "\r\e[2KCommencing deletion in ${i} seconds ...";
		sleep(1);
	}
	print "\r\e[2K";

	my $db = $self->app->pg->db;
	my $rows;
	eval { $rows = $db->delete( 'journeys', { user_id => $uid } )->rows; };
	if ($@) {
		$self->app->log->error("DELETE-JOURNEYS($uid): $@");
		return;
	}

	printf( "Deleted %s journeys\n", $rows );
}

sub run {
	my ( $self, $command, @args ) = @_;

	if ( not $command ) {
		$self->help;
	}
	elsif ( $command eq 'add' ) {
		$self->add_user(@args);
	}
	elsif ( $command eq 'delete' ) {
		$self->delete_user(@args);
	}
	elsif ( $command eq 'undelete' ) {
		$self->undelete_user(@args);
	}
	elsif ( $command eq 'DELETE' ) {
		$self->really_delete_user(@args);
	}
	elsif ( $command eq 'DELETE-JOURNEYS' ) {
		$self->delete_journeys(@args);
	}
	else {
		$self->help;
	}
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl account add [name] [email]

  Adds user [name] with a temporary password, which is shown on stdout.
  Users can change the password once logged in.

  Usage: index.pl account delete <uid> <name>

  Request deletion of user <uid>. This has the same effect as using the
  account deletion button. The user account and all corresponding data will
  be deleted by a maintenance run after three days.

  Usage: index.pl account undelete <uid> <name>

  Abort pending deletion request of user <uid>.

  Usage: index.pl account DELETE [uid] [name]

  Immediately delete user [uid]/[name] and all associated data. Deletion is
  irrevocable. Deletion is only performed if [name] matches the name of [uid].
