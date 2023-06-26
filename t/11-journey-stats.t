#!/usr/bin/env perl

# Copyright (C) 2020 Birthe Friesel <derf@finalrewind.org>
#
# SPDX-License-Identifier: MIT

use Mojo::Base -strict;

# Tests journey entry and statistics

use Test::More;
use Test::Mojo;

# Include application
use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new('Travelynx');

if ( not $t->app->config->{db} ) {
	plan( skip_all => 'No database configured' );
}

$t->app->pg->db->query('drop schema if exists travelynx_test_11 cascade');
$t->app->pg->db->query('create schema travelynx_test_11');
$t->app->pg->db->query('set search_path to travelynx_test_11');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_11');
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
		dep_station     => 'EMST',
		sched_departure => '16.10.2018 17:36',
		rt_departure    => '16.10.2018 17:36',
		arr_station     => 'EG',
		sched_arrival   => '16.10.2018 18:34',
		rt_arrival      => '16.10.2018 18:34',
		comment         => 'Passierschein A38',
	}
);
$t->status_is(302)->header_is( location => '/journey/1' );

$t->get_ok('/journey/1')->status_is(200)->content_like(qr{M.nster\(Westf\)Hbf})
  ->content_like(qr{Gelsenkirchen Hbf})->content_like(qr{RE 11238})
  ->content_like(qr{Linie 42})->content_like(qr{..:36})
  ->content_like(qr{..:34})->content_like(qr{ca[.] 62 km})
  ->content_like(qr{Luftlinie: 62 km})->content_like(qr{64 km/h})
  ->content_like(qr{Passierschein A38})
  ->content_like(qr{Daten wurden manuell eingetragen});

$t->get_ok('/history/2018/10')->status_is(200)->content_like(qr{62 km})
  ->content_like(qr{00:58 Stunden})->content_like(qr{00:00 Stunden})
  ->content_like(qr{Bei Abfahrt: 00:00 Stunden})
  ->content_like(qr{Bei Ankunft: 00:00 Stunden});

$t->get_ok('/history/2018')->status_is(200)->content_like(qr{62 km})
  ->content_like(qr{00:58 Stunden})->content_like(qr{00:00 Stunden})
  ->content_like(qr{Bei Abfahrt: 00:00 Stunden})
  ->content_like(qr{Bei Ankunft: 00:00 Stunden});

$t->get_ok('/history/map')->status_is(200)
  ->content_like(qr{\[\[51.956[^,]*,7.635[^]]*\],'M.nster\(Westf\)Hbf'\],})
  ->content_like(qr{\[\[51.504[^,]*,7.102[^]]*\],'Gelsenkirchen Hbf'\]});

$csrf_token
  = $t->ua->get('/journey/add')->res->dom->at('input[name=csrf_token]')
  ->attr('value');
$t->post_ok(
	'/journey/add' => form => {
		csrf_token      => $csrf_token,
		action          => 'save',
		train           => 'RE 42 11238',
		dep_station     => 'EMST',
		sched_departure => '16.11.2018 17:36',
		rt_departure    => '16.11.2018 17:45',
		arr_station     => 'EG',
		sched_arrival   => '16.11.2018 18:34',
		rt_arrival      => '16.11.2018 19:00',
	}
);
$t->status_is(302)->header_is( location => '/journey/2' );

$t->get_ok('/history/2018/11')->status_is(200)->content_like(qr{62 km})
  ->content_like(qr{01:15 Stunden})->content_like(qr{nach Fahrplan: 00:58})
  ->content_like(qr{00:00 Stunden})
  ->content_like(qr{Bei Abfahrt: 00:09 Stunden})
  ->content_like(qr{Bei Ankunft: 00:26 Stunden});

$t->get_ok('/history/2018')->status_is(200)->content_like(qr{124 km})
  ->content_like(qr{02:13 Stunden})->content_like(qr{nach Fahrplan: 01:56})
  ->content_like(qr{00:00 Stunden})
  ->content_like(qr{Bei Abfahrt: 00:09 Stunden})
  ->content_like(qr{Bei Ankunft: 00:26 Stunden});

$csrf_token
  = $t->ua->get('/journey/add')->res->dom->at('input[name=csrf_token]')
  ->attr('value');
$t->post_ok(
	'/journey/add' => form => {
		csrf_token      => $csrf_token,
		action          => 'save',
		train           => 'ICE 1',
		dep_station     => 'EE',
		sched_departure => '17.11.2018 15:42',
		rt_departure    => '',
		arr_station     => 'BL',
		sched_arrival   => '17.11.2018 19:42',
		rt_arrival      => '',
	}
);
$t->status_is(302)->header_is( location => '/journey/3' );

$t->get_ok('/history/2018/11')->status_is(200)->content_like(qr{513 km})
  ->content_like(qr{05:15 Stunden})->content_like(qr{nach Fahrplan: 04:58})
  ->content_like(qr{00:00 Stunden})
  ->content_like(qr{Bei Abfahrt: 00:09 Stunden})
  ->content_like(qr{Bei Ankunft: 00:26 Stunden});

$t->get_ok('/history/2018')->status_is(200)->content_like(qr{576 km})
  ->content_like(qr{06:13 Stunden})->content_like(qr{nach Fahrplan: 05:56})
  ->content_like(qr{00:00 Stunden})
  ->content_like(qr{Bei Abfahrt: 00:09 Stunden})
  ->content_like(qr{Bei Ankunft: 00:26 Stunden});

$t->app->pg->db->query('drop schema travelynx_test_11 cascade');
done_testing();
