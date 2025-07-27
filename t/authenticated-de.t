#!/usr/bin/env perl

# Copyright (C) 2025 Birte Kristina Friesel <derf@finalrewind.org>
#
# SPDX-License-Identifier: MIT

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

# Include application
use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new('Travelynx');

$t->ua->on( start => sub { $_[1]->req->headers->accept_language('de-DE') } );

if ( not $t->app->config->{db} ) {
	plan( skip_all => 'No database configured' );
}

# Account boilerplate

$t->app->pg->db->query('drop schema if exists travelynx_test_auth_de cascade');
$t->app->pg->db->query('create schema travelynx_test_auth_de');
$t->app->pg->db->query('set search_path to travelynx_test_auth_de');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_auth_de');
	}
);

$t->app->config->{mail}->{disabled} = 1;

$ENV{__TRAVELYNX_TEST_MINI_IRIS} = 1;
$t->app->start( 'database', 'migrate' );

my $csrf_token
  = $t->ua->get('/register')->res->dom->at('input[name=csrf_token]')
  ->attr('value');

# Successful registration
$t->post_ok(
	'/register' => form => {
		csrf_token => $csrf_token,
		dt         => 1,
		user       => 'someone',
		email      => 'foo@example.org',
		password   => 'foofoofoo',
		password2  => 'foofoofoo',
	}
);
$t->status_is(200)->content_like(qr{Verifizierungslink});

my $res = $t->app->pg->db->select( 'users', ['id'], { name => 'someone' } );
my $uid = $res->hash->{id};
$res = $t->app->pg->db->select( 'pending_registrations', ['token'],
	{ user_id => $uid } );
my $token = $res->hash->{token};

# Successful verification
$t->get_ok("/reg/${uid}/${token}");
$t->status_is(200)->content_like(qr{freigeschaltet});

# Successful login
$t->post_ok(
	'/login' => form => {
		csrf_token => $csrf_token,
		user       => 'someone',
		password   => 'foofoofoo',
	}
);
$t->status_is(302)->header_is( location => '/' );

# Actual Test

$t->get_ok('/account')->status_is(200);
$t->text_like( 'a[href="/p/someone"]' => qr{Öffentliches Profil} );
$t->text_like( 'a[href="/api"]'       => qr{Dokumentation} );

for my $subpage (qw(privacy social profile hooks insight language)) {
	$t->get_ok("/account/${subpage}")->status_is(200);
	$t->text_like( 'button' => qr{Speichern} );
}

for my $subpage (qw(password mail name)) {
	$t->get_ok("/account/${subpage}")->status_is(200);
	$t->text_like( 'button' => qr{Ändern} );
}

$t->get_ok('/account/select_backend')->status_is(200);
$t->text_like( 'a[href="#help"]' => qr{Details} );

$t->get_ok('/account/traewelling')->status_is(200);
$t->text_like( 'button' => qr{Verknüpfen} );

$t->get_ok('/history')->status_is(200);
$t->text_like( 'a[href="/history/map"]' => qr{Fahrtenkarte} );

$t->get_ok('/history/map')->status_is(200);
$t->text_like( 'button[type="submit"]' => qr{Anzeigen} );

$t->get_ok('/history/commute')->status_is(200);
$t->text_like( 'button[type="submit"]' => qr{Anzeigen} );

$t->get_ok('/journey/add')->status_is(200);
$t->text_like( 'button[type="submit"]' => qr{Hinzufügen} );

done_testing();
