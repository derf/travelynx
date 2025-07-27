#!/usr/bin/env perl

# Copyright (C) 2020 Birte Kristina Friesel <derf@finalrewind.org>
#
# SPDX-License-Identifier: MIT

use Mojo::Base -strict;

# Regression test: handle negative cumulative arrival / departure delay

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

$t->app->pg->db->query(
	'drop schema if exists travelynx_regr_negative_delay cascade');
$t->app->pg->db->query('create schema travelynx_regr_negative_delay');
$t->app->pg->db->query('set search_path to travelynx_regr_negative_delay');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_regr_negative_delay');
	}
);

$t->app->config->{mail}->{disabled} = 1;

$ENV{__TRAVELYNX_TEST_MINI_IRIS} = 0;
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

$csrf_token
  = $t->ua->get('/journey/add')->res->dom->at('input[name=csrf_token]')
  ->attr('value');
$t->post_ok(
	'/journey/add' => form => {
		csrf_token      => $csrf_token,
		action          => 'save',
		train           => 'RE 42 11238',
		dep_station     => 'EMSTP',
		sched_departure => '2018-10-16T17:36',
		rt_departure    => '2018-10-16T17:35',
		arr_station     => 'EG',
		sched_arrival   => '2018-10-16T18:34',
		rt_arrival      => '2018-10-16T18:32',
	}
);
$t->status_is(302)->header_is( location => '/journey/1' )->content_is(q{});

$t->get_ok('/history/2018/10')
  ->status_is(200)
  ->content_like(qr{62 km})
  ->content_like(qr{00:57 Stunden})
  ->content_like(qr{nach Fahrplan: 00:58})
  ->content_like(qr{Bei Abfahrt: -00:01 Stunden})
  ->content_like(qr{Bei Ankunft: -00:02 Stunden});

$t->app->pg->db->query('drop schema travelynx_regr_negative_delay cascade');
done_testing();
