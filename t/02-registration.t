#!/usr/bin/env perl

# Copyright (C) 2020 Daniel Friesel <daniel.friesel@uos.de>
#
# SPDX-License-Identifier: MIT

use Mojo::Base -strict;

# Tests the standard registration -> verification -> successful login flow

use Test::More;
use Test::Mojo;

# Include application
use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new('Travelynx');

if ( not $t->app->config->{db} ) {
	plan( skip_all => 'No database configured' );
}

$t->app->pg->db->query('drop schema if exists travelynx_test_02 cascade');
$t->app->pg->db->query('create schema travelynx_test_02');
$t->app->pg->db->query('set search_path to travelynx_test_02');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_02');
	}
);

$t->app->config->{mail}->{disabled} = 1;

$t->app->start( 'database', 'migrate' );

my $csrf_token
  = $t->ua->get('/register')->res->dom->at('input[name=csrf_token]')
  ->attr('value');

# Successful registration
$t->post_ok(
	'/register' => form => {
		csrf_token => $csrf_token,
		user       => 'someone',
		email      => 'foo@example.org',
		password   => 'foofoofoo',
		password2  => 'foofoofoo',
	}
);
$t->status_is(200)->content_like(qr{Verifizierungslink});

# Failed registration (user name not available)
$t->post_ok(
	'/register' => form => {
		csrf_token => $csrf_token,
		user       => 'someone',
		email      => 'foo@example.org',
		password   => 'foofoofoo',
		password2  => 'foofoofoo',
	}
);
$t->status_is(200)->content_like(qr{Name bereits vergeben});

$csrf_token = $t->ua->get('/login')->res->dom->at('input[name=csrf_token]')
  ->attr('value');

# Failed login (not verified yet)
$t->post_ok(
	'/login' => form => {
		csrf_token => $csrf_token,
		user       => 'someone',
		password   => 'foofoofoo',
	}
);
$t->status_is(200)->content_like(qr{nicht freigeschaltet});

my $res = $t->app->pg->db->select( 'users', ['id'], { name => 'someone' } );
my $uid = $res->hash->{id};
$res = $t->app->pg->db->select( 'pending_registrations', ['token'],
	{ user_id => $uid } );
my $token = $res->hash->{token};

# Successful verification
$t->get_ok("/reg/${uid}/${token}");
$t->status_is(200)->content_like(qr{freigeschaltet});

# Failed login (wrong password)
$t->post_ok(
	'/login' => form => {
		csrf_token => $csrf_token,
		user       => 'someone',
		password   => 'definitely invalid',
	}
);
$t->status_is(200)->content_like(qr{falsches Passwort});

# Successful login
$t->post_ok(
	'/login' => form => {
		csrf_token => $csrf_token,
		user       => 'someone',
		password   => 'foofoofoo',
	}
);
$t->status_is(302)->header_is( location => '/' );

# Request deletion

$csrf_token = $t->ua->get('/account')->res->dom->at('input[name=csrf_token]')
  ->attr('value');

$t->post_ok(
	'/delete' => form => {
		action     => 'delete',
		csrf_token => $csrf_token,
		password   => 'foofoofoo',
	}
);
$t->status_is(302)->header_is( location => '/account' );
$t->get_ok('/account');
$t->status_is(200)->content_like(qr{wird gelöscht});

$t->post_ok(
	'/delete' => form => {
		action     => 'undelete',
		csrf_token => $csrf_token,
	}
);
$t->status_is(302)->header_is( location => '/account' );
$t->get_ok('/account');
$t->status_is(200)->content_unlike(qr{wird gelöscht});

$csrf_token
  = $t->ua->get('/account/password')->res->dom->at('input[name=csrf_token]')
  ->attr('value');

$t->post_ok(
	'/account/password' => form => {
		csrf_token => $csrf_token,
		oldpw      => 'foofoofoo',
		newpw      => 'barbarbar',
		newpw2     => 'barbarbar',
	}
);
$t->status_is(302)->header_is( location => '/account' );

$csrf_token = $t->ua->get('/account')->res->dom->at('input[name=csrf_token]')
  ->attr('value');
$t->post_ok(
	'/logout' => form => {
		csrf_token => $csrf_token,
	}
);
$t->status_is(302)->header_is( location => '/login' );

$csrf_token = $t->ua->get('/login')->res->dom->at('input[name=csrf_token]')
  ->attr('value');
$t->post_ok(
	'/login' => form => {
		csrf_token => $csrf_token,
		user       => 'someone',
		password   => 'barbarbar',
	}
);
$t->status_is(302)->header_is( location => '/' );

$csrf_token = $t->ua->get('/account')->res->dom->at('input[name=csrf_token]')
  ->attr('value');
$t->post_ok(
	'/logout' => form => {
		csrf_token => $csrf_token,
	}
);
$t->status_is(302)->header_is( location => '/login' );

$csrf_token = $t->ua->get('/recover')->res->dom->at('input[name=csrf_token]')
  ->attr('value');
$t->post_ok(
	'/recover' => form => {
		csrf_token => $csrf_token,
		action     => 'initiate',
		user       => 'someone',
		email      => 'foo@example.org',
	}
);
$t->status_is(200)->content_like(qr{wird durchgeführt});

$res = $t->app->pg->db->select( 'pending_passwords', ['token'],
	{ user_id => $uid } );
$token = $res->hash->{token};

$t->get_ok("/recover/${uid}/${token}")->status_is(200)
  ->content_like(qr{Neues Passwort eintragen});

$t->post_ok(
	'/recover' => form => {
		csrf_token => $csrf_token,
		action     => 'set_password',
		id         => $uid,
		token      => $token,
		newpw      => 'foofoofoo2',
		newpw2     => 'foofoofoo2',
	}
);
$t->status_is(302)->header_is( location => '/account' );

$t->app->pg->db->query('drop schema travelynx_test_02 cascade');
done_testing();
