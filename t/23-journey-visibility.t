#!/usr/bin/env perl

# Copyright (C) 2023 Birte Kristina Friesel <derf@finalrewind.org>
#
# SPDX-License-Identifier: MIT

use Mojo::Base -strict;

# Tests journey entry and statistics

use Test::More;
use Test::Mojo;

use DateTime;
use Travel::Status::DE::IRIS::Result;

# Include application
use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new('Travelynx');

if ( not $t->app->config->{db} ) {
	plan( skip_all => 'No database configured' );
}

$t->app->pg->db->query('drop schema if exists travelynx_test_23 cascade');
$t->app->pg->db->query('create schema travelynx_test_23');
$t->app->pg->db->query('set search_path to travelynx_test_23');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_23');
	}
);

$t->app->config->{mail}->{disabled} = 1;

$ENV{__TRAVELYNX_TEST_MINI_IRIS} = 1;
$t->app->start( 'database', 'migrate' );

my $u = $t->app->users;

sub login {
	my %opt = @_;
	my $csrf_token
	  = $t->ua->get('/login')->res->dom->at('input[name=csrf_token]')
	  ->attr('value');
	$t->post_ok(
		'/login' => form => {
			csrf_token => $csrf_token,
			user       => $opt{user},
			password   => $opt{password},
		}
	);
	$t->status_is(302)->header_is( location => '/' );
}

sub logout {
	my $csrf_token
	  = $t->ua->get('/account')->res->dom->at('input[name=csrf_token]')
	  ->attr('value');
	$t->post_ok(
		'/logout' => form => {
			csrf_token => $csrf_token,
		}
	);
	$t->status_is(302)->header_is( location => '/login' );
}

sub test_journey_visibility {
	my %opt = @_;
	my $jid = $opt{journey_id};

	if ( $opt{set_default_visibility} ) {
		my %p = %{ $u->get_privacy_by( uid => $opt{uid} ) };
		$p{default_visibility} = $opt{set_default_visibility};
		$u->set_privacy(
			uid => $opt{uid},
			%p
		);
	}

	if ( $opt{set_visibility} ) {
		$t->app->journeys->update_visibility(
			uid        => $opt{uid},
			id         => $jid,
			visibility => $opt{set_visibility}
		);
	}

	my $status  = $t->app->get_user_status( $opt{uid} );
	my $journey = $t->app->journeys->get_single(
		uid        => $opt{uid},
		journey_id => $jid
	);
	my $token
	  = q{?token=}
	  . $status->{dep_eva} . q{-}
	  . $journey->{checkin_ts} % 337 . q{-}
	  . $status->{sched_departure}->epoch;

	my $desc
	  = "journey=$jid vis=$opt{effective_visibility_str} (from $opt{visibility_str})";

	is( $status->{visibility},           $opt{visibility},           $desc );
	is( $status->{visibility_str},       $opt{visibility_str},       $desc );
	is( $status->{effective_visibility}, $opt{effective_visibility}, $desc );
	is( $status->{effective_visibility_str},
		$opt{effective_visibility_str}, $desc );

	if ( $opt{public} ) {
		$t->get_ok("/p/test1/j/$jid")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	if ( $opt{with_token} ) {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	login(
		user     => 'test1',
		password => 'password1'
	);

	# users can see their own status if visibility is >= followrs
	if ( $opt{effective_visibility} >= 60 ) {
		$t->get_ok("/p/test1/j/$jid")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	# users can see their own status with token if visibility is >= unlisted
	if ( $opt{effective_visibility} >= 30 ) {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	logout();
	login(
		user     => 'test2',
		password => 'password2'
	);

	# uid2 can see uid1 if visibility is >= followers
	if ( $opt{effective_visibility} >= 60 ) {
		$t->get_ok("/p/test1/j/$jid")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	# uid2 can see uid1 with token if visibility is >= unlisted
	if ( $opt{effective_visibility} >= 30 ) {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	logout();
	login(
		user     => 'test3',
		password => 'password3'
	);

	# uid3 can see uid1 if visibility is >= travelynx
	if ( $opt{effective_visibility} >= 80 ) {
		$t->get_ok("/p/test1/j/$jid")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	# uid3 can see uid1 with token if visibility is >= unlisted
	if ( $opt{effective_visibility} >= 30 ) {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(200)
		  ->content_like(qr{DPN\s*667});
	}
	else {
		$t->get_ok("/p/test1/j/$jid$token")->status_is(404)
		  ->content_like(qr{Fahrt nicht gefunden.});
	}

	logout();
}

my $uid1 = $u->add(
	name     => 'test1',
	email    => 'test1@example.org',
	token    => 'abcd',
	password => 'password1',
);

my $uid2 = $u->add(
	name     => 'test2',
	email    => 'test2@example.org',
	token    => 'efgh',
	password => 'password2',
);

my $uid3 = $u->add(
	name     => 'test3',
	email    => 'test3@example.org',
	token    => 'ijkl',
	password => 'password3',
);

$u->verify_registration_token(
	uid   => $uid1,
	token => 'abcd'
);
$u->verify_registration_token(
	uid   => $uid2,
	token => 'efgh'
);
$u->verify_registration_token(
	uid   => $uid3,
	token => 'ijkl'
);

$u->set_social(
	uid            => $uid1,
	accept_follows => 1
);
$u->set_social(
	uid            => $uid2,
	accept_follows => 1
);
$u->set_social(
	uid            => $uid3,
	accept_follows => 1
);

$u->follow(
	uid    => $uid2,
	target => $uid1
);

is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	'follows'
);
is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	undef
);

my $dep       = DateTime->now->subtract( hours => 2 );
my $arr       = DateTime->now->subtract( hours => 1 );
my $train_dep = Travel::Status::DE::IRIS::Result->new(
	classes      => 'N',
	type         => 'DPN',
	train_no     => '667',
	raw_id       => '1234-2306251312-1',
	departure_ts => $dep->strftime('%y%m%d%H%M'),
	platform     => 8,
	station      => 'Aachen Hbf',
	station_uic  => 8000001,
	route_post   => 'Mainz Hbf|Aalen Hbf',
);
my $train_arr = Travel::Status::DE::IRIS::Result->new(
	classes     => 'N',
	type        => 'DPN',
	train_no    => '667',
	raw_id      => '1234-2306251312-3',
	arrival_ts  => $arr->strftime('%y%m%d%H%M'),
	platform    => 1,
	station     => 'Aalen Hbf',
	station_uic => 8000002,
	route_pre   => 'Aachen Hbf|Mainz Hbf',
);
$t->app->in_transit->add(
	uid           => $uid1,
	departure_eva => 8000001,
	train         => $train_dep,
	route         => [],
	backend_id    => $t->app->stations->get_backend_id( iris => 1 ),
);
$t->app->in_transit->set_arrival_eva(
	uid         => $uid1,
	arrival_eva => 8000002,
);

my $db = $t->app->pg->db;
my $tx = $db->begin;

my $journey = $t->app->in_transit->get(
	uid => $uid1,
	db  => $db,
);
my $jid = $t->app->journeys->add_from_in_transit(
	journey => $journey,
	db      => $db
);
$t->app->in_transit->delete(
	uid => $uid1,
	db  => $db
);
$tx->commit;

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 30,
	effective_visibility_str => 'unlisted',
	public                   => 0,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_default_visibility   => 10,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 10,
	effective_visibility_str => 'private',
	public                   => 0,
	with_token               => 0,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_default_visibility   => 30,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 30,
	effective_visibility_str => 'unlisted',
	public                   => 0,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_default_visibility   => 60,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 60,
	effective_visibility_str => 'followers',
	public                   => 0,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_default_visibility   => 80,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 80,
	effective_visibility_str => 'travelynx',
	public                   => 0,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_default_visibility   => 100,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 100,
	effective_visibility_str => 'public',
	public                   => 1,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_visibility           => 'private',
	visibility               => 10,
	visibility_str           => 'private',
	effective_visibility     => 10,
	effective_visibility_str => 'private',
	public                   => 0,
	with_token               => 0,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_visibility           => 'unlisted',
	visibility               => 30,
	visibility_str           => 'unlisted',
	effective_visibility     => 30,
	effective_visibility_str => 'unlisted',
	public                   => 0,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_visibility           => 'followers',
	visibility               => 60,
	visibility_str           => 'followers',
	effective_visibility     => 60,
	effective_visibility_str => 'followers',
	public                   => 0,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_visibility           => 'travelynx',
	visibility               => 80,
	visibility_str           => 'travelynx',
	effective_visibility     => 80,
	effective_visibility_str => 'travelynx',
	public                   => 0,
	with_token               => 1,
);

test_journey_visibility(
	uid                      => $uid1,
	journey_id               => $jid,
	set_visibility           => 'public',
	visibility               => 100,
	visibility_str           => 'public',
	effective_visibility     => 100,
	effective_visibility_str => 'public',
	public                   => 1,
	with_token               => 1,
);

$t->app->pg->db->query('drop schema travelynx_test_23 cascade');
done_testing();
