package Travelynx::Controller::Traewelling;

# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Promise;

sub settings {
	my ($self) = @_;

	my $uid = $self->current_user->{id};

	if (    $self->param('action')
		and $self->validation->csrf_protect->has_error('csrf_token') )
	{
		$self->render(
			'traewelling',
			invalid => 'csrf',
		);
		return;
	}

	if ( $self->param('action') and $self->param('action') eq 'login' ) {
		my $email    = $self->param('email');
		my $password = $self->param('password');
		$self->render_later;
		$self->traewelling_api->login_p(
			uid      => $uid,
			email    => $email,
			password => $password
		)->then(
			sub {
				my $traewelling = $self->traewelling->get( uid => $uid );
				$self->param( sync_source => 'none' );
				$self->render(
					'traewelling',
					traewelling     => $traewelling,
					new_traewelling => 1,
				);
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					'traewelling',
					traewelling     => {},
					new_traewelling => 1,
					login_error     => $err,
				);
			}
		)->wait;
		return;
	}
	elsif ( $self->param('action') and $self->param('action') eq 'logout' ) {
		$self->render_later;
		my $traewelling = $self->traewelling->get( uid => $uid );
		$self->traewelling_api->logout_p(
			uid   => $uid,
			token => $traewelling->{token}
		)->then(
			sub {
				$self->flash( success => 'traewelling' );
				$self->redirect_to('account');
			}
		)->catch(
			sub {
				my ($err) = @_;
				$self->render(
					'traewelling',
					traewelling     => {},
					new_traewelling => 1,
					logout_error    => $err,
				);
			}
		)->wait;
		return;
	}
	elsif ( $self->param('action') and $self->param('action') eq 'config' ) {
		$self->traewelling->set_sync(
			uid       => $uid,
			push_sync => $self->param('sync_source') eq 'travelynx'   ? 1 : 0,
			pull_sync => $self->param('sync_source') eq 'traewelling' ? 1 : 0,
			toot      => $self->param('toot')                         ? 1 : 0,
			tweet     => $self->param('tweet')                        ? 1 : 0,
		);
		$self->flash( success => 'traewelling' );
		$self->redirect_to('account');
		return;
	}

	my $traewelling = $self->traewelling->get( uid => $uid );

	if ( $traewelling->{push_sync} ) {
		$self->param( sync_source => 'travelynx' );
	}
	elsif ( $traewelling->{pull_sync} ) {
		$self->param( sync_source => 'traewelling' );
	}
	else {
		$self->param( sync_source => 'none' );
	}
	if ( $traewelling->{data}{toot} ) {
		$self->param( toot => 1 );
	}
	if ( $traewelling->{data}{tweet} ) {
		$self->param( tweet => 1 );
	}

	$self->render(
		'traewelling',
		traewelling => $traewelling,
	);
}

1;
