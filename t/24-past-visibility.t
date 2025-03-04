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

$t->app->pg->db->query('drop schema if exists travelynx_test_24 cascade');
$t->app->pg->db->query('create schema travelynx_test_24');
$t->app->pg->db->query('set search_path to travelynx_test_24');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_24');
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

sub test_history_visibility {
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

	if ( $opt{set_past_visibility} ) {
		my %p = %{ $u->get_privacy_by( uid => $opt{uid} ) };
		$p{past_visibility} = $opt{set_past_visibility};
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
		uid             => $opt{uid},
		journey_id      => $jid,
		with_visibility => 1,
	);
	my $token
	  = q{?token=}
	  . $status->{dep_eva} . q{-}
	  . $journey->{checkin_ts} % 337 . q{-}
	  . $status->{sched_departure}->epoch;

	$opt{set_past_visibility} //= q{};
	my $desc
	  = "history vis=$opt{set_past_visibility} journey=$jid vis=$journey->{effective_visibility_str}";

	if ( $opt{public} ) {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_like( qr{DPN\s*667}, "public $desc" );
	}
	else {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_unlike( qr{DPN\s*667}, "public $desc" );
	}

	login(
		user     => 'test1',
		password => 'password1'
	);

	if ( $opt{self} ) {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_like( qr{DPN\s*667}, "self $desc" );
	}
	else {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_unlike( qr{DPN\s*667}, "self $desc" );
	}

	logout();
	login(
		user     => 'test2',
		password => 'password2'
	);

	if ( $opt{followers} ) {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_like( qr{DPN\s*667}, "follower $desc" );
	}
	else {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_unlike( qr{DPN\s*667}, "follower $desc" );
	}

	logout();
	login(
		user     => 'test3',
		password => 'password3'
	);

	if ( $opt{travelynx} ) {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_like( qr{DPN\s*667}, "travelynx $desc" );
	}
	else {
		$t->get_ok('/p/test1')->status_is(200)
		  ->content_unlike( qr{DPN\s*667}, "travelynx $desc" );
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

$t->app->in_transit->update_visibility(
	uid        => $uid1,
	visibility => 'public',
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

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_past_visibility => 10,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_past_visibility => 60,
	self                => 1,
	followers           => 1,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_past_visibility => 80,
	self                => 1,
	followers           => 1,
	travelynx           => 1,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_past_visibility => 100,
	self                => 1,
	followers           => 1,
	travelynx           => 1,
	public              => 1,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'private',
	set_past_visibility => 10,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'private',
	set_past_visibility => 60,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'private',
	set_past_visibility => 80,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'private',
	set_past_visibility => 100,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'unlisted',
	set_past_visibility => 10,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'unlisted',
	set_past_visibility => 60,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'unlisted',
	set_past_visibility => 80,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'unlisted',
	set_past_visibility => 100,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'followers',
	set_past_visibility => 10,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'followers',
	set_past_visibility => 60,
	self                => 1,
	followers           => 1,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'followers',
	set_past_visibility => 80,
	self                => 1,
	followers           => 1,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'followers',
	set_past_visibility => 100,
	self                => 1,
	followers           => 1,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'travelynx',
	set_past_visibility => 10,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'travelynx',
	set_past_visibility => 60,
	self                => 1,
	followers           => 1,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'travelynx',
	set_past_visibility => 80,
	self                => 1,
	followers           => 1,
	travelynx           => 1,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'travelynx',
	set_past_visibility => 100,
	self                => 1,
	followers           => 1,
	travelynx           => 1,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'public',
	set_past_visibility => 10,
	self                => 0,
	followers           => 0,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'public',
	set_past_visibility => 60,
	self                => 1,
	followers           => 1,
	travelynx           => 0,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'public',
	set_past_visibility => 80,
	self                => 1,
	followers           => 1,
	travelynx           => 1,
	public              => 0,
);

test_history_visibility(
	uid                 => $uid1,
	journey_id          => $jid,
	set_visibility      => 'public',
	set_past_visibility => 100,
	self                => 1,
	followers           => 1,
	travelynx           => 1,
	public              => 1,
);

$t->app->pg->db->query('drop schema travelynx_test_24 cascade');
done_testing();
