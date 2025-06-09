package Travelynx::Controller::Traewelling;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Promise;

sub oauth {
	my ($self) = @_;

	if (    $self->param('action')
		and $self->validation->csrf_protect->has_error('csrf_token') )
	{
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}

	$self->render_later;

	my $oa = $self->config->{traewelling}{oauth};

	return $self->oauth2->get_token_p(
		traewelling => {
			redirect_uri =>
			  $self->base_url_for('/oauth/traewelling')->to_abs->scheme(
				$self->app->mode eq 'development' ? 'http' : 'https'
			  )->to_string,
			scope => 'read-statuses write-statuses'
		}
	)->then(
		sub {
			my ($provider) = @_;
			if ( not defined $provider ) {

				# OAuth2 plugin performed a redirect, no need to render
				return;
			}
			if ( not $provider or not $provider->{access_token} ) {
				$self->flash( new_traewelling => 1 );
				$self->flash( login_error     => 'no token received' );
				$self->redirect_to('/account/traewelling');
				return;
			}
			my $uid   = $self->current_user->{id};
			my $token = $provider->{access_token};
			$self->traewelling->link(
				uid           => $self->current_user->{id},
				token         => $provider->{access_token},
				refresh_token => $provider->{refresh_token},
				expires_in    => $provider->{expires_in},
			);
			return $self->traewelling_api->get_user_p( $uid, $token )->then(
				sub {
					$self->flash( new_traewelling => 1 );
					$self->redirect_to('/account/traewelling');
				}
			);
		}
	)->catch(
		sub {
			my ($err) = @_;
			say "error $err";
			$self->flash( new_traewelling => 1 );
			$self->flash( login_error     => $err );
			$self->redirect_to('/account/traewelling');
			return;
		}
	);
}

sub settings {
	my ($self) = @_;

	my $uid = $self->current_user->{id};

	if (    $self->param('action')
		and $self->validation->csrf_protect->has_error('csrf_token') )
	{
		$self->render(
			'bad_request',
			csrf   => 1,
			status => 400
		);
		return;
	}

	if ( $self->param('action') and $self->param('action') eq 'logout' ) {
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

	$self->stash( title => 'travelynx × träwelling' );
	$self->render(
		'traewelling',
		traewelling => $traewelling,
	);
}

1;
