#!/usr/bin/env perl

# Copyright (C) 2020 Birte Kristina Friesel <derf@finalrewind.org>
#
# SPDX-License-Identifier: MIT

use Mojo::Base -strict;

# Tests journey entry and statistics

use Test::More;
use Test::Mojo;

# Include application
use FindBin;
require "$FindBin::Bin/../index.pl";

use DateTime;
use utf8;

my $t = Test::Mojo->new('Travelynx');

if ( not $t->app->config->{db} ) {
	plan( skip_all => 'No database configured' );
}

$t->app->pg->db->query('drop schema if exists travelynx_test_12 cascade');
$t->app->pg->db->query('create schema travelynx_test_12');
$t->app->pg->db->query('set search_path to travelynx_test_12');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_12');
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

my ( $success, $error ) = $t->app->journeys->add(
	db              => $t->app->pg->db,
	uid             => $uid,
	backend_id      => 1,
	dep_station     => 'Münster(Westf)Hbf',
	arr_station     => 'Gelsenkirchen Hbf',
	sched_departure => DateTime->new(
		year      => 2018,
		month     => 10,
		day       => 16,
		hour      => 17,
		minute    => 36,
		time_zone => 'Europe/Berlin'
	),
	rt_departure => DateTime->new(
		year      => 2018,
		month     => 10,
		day       => 16,
		hour      => 17,
		minute    => 36,
		time_zone => 'Europe/Berlin'
	),
	sched_arrival => DateTime->new(
		year      => 2018,
		month     => 10,
		day       => 16,
		hour      => 18,
		minute    => 34,
		time_zone => 'Europe/Berlin'
	),
	rt_arrival => DateTime->new(
		year      => 2018,
		month     => 10,
		day       => 16,
		hour      => 18,
		minute    => 34,
		time_zone => 'Europe/Berlin'
	),
	cancelled  => 0,
	train_type => 'RE',
	train_line => '42',
	train_no   => '11238',
	comment    => 'Huhu'
);

ok( $success, "journeys->add" );
is( $error, undef, "journeys->add" );

$t->get_ok('/journey/1')
  ->status_is(200)
  ->content_like(qr{M.nster\(Westf\)Hbf})
  ->content_like(qr{Gelsenkirchen Hbf})
  ->content_like(qr{RE 11238})
  ->content_like(qr{Linie 42})
  ->content_like(qr{..:36})
  ->content_like(qr{..:34})
  ->content_like(qr{ca[.] 62 km})
  ->content_like(qr{Luftlinie: 62 km})
  ->content_like(qr{64 km/h})
  ->content_like(qr{Huhu})
  ->content_like(qr{Daten wurden manuell eingetragen});

$t->post_ok(
	'/journey/edit' => form => {
		action     => 'edit',
		journey_id => 1,
	}
);

$t->status_is(200)
  ->content_like(qr{M.nster\(Westf\)Hbf})
  ->content_like(qr{Gelsenkirchen Hbf})
  ->content_like(qr{RE 11238})
  ->content_like(qr{Linie 42})
  ->content_like(qr{16.10.2018 ..:36})
  ->content_like(qr{16.10.2018 ..:34})
  ->content_like(qr{Huhu});

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

$t->post_ok(
	'/journey/edit' => form => {
		action          => 'save',
		journey_id      => 1,
		csrf_token      => $csrf_token,
		from_name       => 'Münster(Westf)Hbf',
		to_name         => 'Gelsenkirchen Hbf',
		sched_departure => '16.10.2018 17:36',
		rt_departure    => '16.10.2018 17:36',
		sched_arrival   => '16.10.2018 18:34',
		rt_arrival      => '16.10.2018 18:34',
	}
);

$t->status_is(302)->header_is( location => '/journey/1' );

$t->get_ok('/journey/1')
  ->status_is(200)
  ->content_like(qr{M.nster\(Westf\)Hbf})
  ->content_like(qr{Gelsenkirchen Hbf})
  ->content_like(qr{RE 11238})
  ->content_like(qr{Linie 42})
  ->content_like(qr{..:36})
  ->content_like(qr{..:34})
  ->content_like(qr{ca[.] 62 km})
  ->content_like(qr{Luftlinie: 62 km})
  ->content_like(qr{64 km/h})
  ->content_like(qr{Huhu})
  ->content_like(qr{Daten wurden manuell eingetragen});

$t->post_ok(
	'/journey/edit' => form => {
		action     => 'edit',
		journey_id => 1,
	}
);

$t->status_is(200)
  ->content_like(qr{M.nster\(Westf\)Hbf})
  ->content_like(qr{Gelsenkirchen Hbf})
  ->content_like(qr{RE 11238})
  ->content_like(qr{Linie 42})
  ->content_like(qr{16.10.2018 ..:36})
  ->content_like(qr{16.10.2018 ..:34})
  ->content_like(qr{Huhu});

$csrf_token = $t->tx->res->dom->at('input[name=csrf_token]')->attr('value');

$t->post_ok(
	'/journey/edit' => form => {
		action          => 'save',
		journey_id      => 1,
		csrf_token      => $csrf_token,
		from_name       => 'Münster(Westf)Hbf',
		to_name         => 'Gelsenkirchen Hbf',
		sched_departure => '16.10.2018 17:36',
		rt_departure    => '16.10.2018 17:42',
		sched_arrival   => '16.10.2018 18:34',
		rt_arrival      => '16.10.2018 18:33',
	}
);

$t->status_is(302)->header_is( location => '/journey/1' );

$t->get_ok('/journey/1')
  ->status_is(200)
  ->content_like(qr{M.nster\(Westf\)Hbf})
  ->content_like(qr{Gelsenkirchen Hbf})
  ->content_like(qr{RE 11238})
  ->content_like(qr{Linie 42})
  ->content_like(qr{..:42\s*\n*\s*\(\+6,\s*Plan: ..:36\)})
  ->content_like(qr{..:33\s*\n*\s*\(-1,\s*Plan: ..:34\)})
  ->content_like(qr{ca[.] 62 km})
  ->content_like(qr{Luftlinie: 62 km})
  ->content_like(qr{73 km/h})
  ->content_like(qr{Huhu})
  ->content_like(qr{Daten wurden manuell eingetragen});

$t->app->pg->db->query('drop schema travelynx_test_12 cascade');
done_testing();
