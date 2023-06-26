#!/usr/bin/env perl

# Copyright (C) 2023 Birthe Friesel <derf@finalrewind.org>
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

$t->app->pg->db->query('drop schema if exists travelynx_test_22 cascade');
$t->app->pg->db->query('create schema travelynx_test_22');
$t->app->pg->db->query('set search_path to travelynx_test_22');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_22');
	}
);

$t->app->config->{mail}->{disabled} = 1;

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

sub test_visibility {
	my %opt = @_;

	if ( $opt{set_default_visibility} ) {
		my %p = %{ $u->get_privacy_by( uid => $opt{uid} ) };
		$p{default_visibility} = $opt{set_default_visibility};
		$u->set_privacy(
			uid => $opt{uid},
			%p
		);
	}

	if ( $opt{set_visibility} ) {
		$t->app->in_transit->update_visibility(
			uid        => $opt{uid},
			visibility => $opt{set_visibility}
		);
	}

	my $status = $t->app->get_user_status( $opt{uid} );
	my $token
	  = $status->{sched_departure}->epoch
	  . q{?token=}
	  . $status->{dep_eva} . q{-}
	  . $status->{timestamp}->epoch % 337;

	is( $status->{visibility},               $opt{visibility} );
	is( $status->{visibility_str},           $opt{visibility_str} );
	is( $status->{effective_visibility},     $opt{effective_visibility} );
	is( $status->{effective_visibility_str}, $opt{effective_visibility_str} );

	if ( $opt{public} ) {
		$t->get_ok('/status/test1')->status_is(200)->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok('/status/test1')->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
	}

	if ( $opt{with_token} ) {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
	}

	login(
		user     => 'test1',
		password => 'password1'
	);

	# users can see their own status if visibility is >= followrs
	if ( $opt{effective_visibility} >= 60 ) {
		$t->get_ok('/status/test1')->status_is(200)->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok('/status/test1')->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
	}

	# users can see their own status with token if visibility is >= unlisted
	if ( $opt{effective_visibility} >= 30 ) {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
	}

	logout();
	login(
		user     => 'test2',
		password => 'password2'
	);

	# uid2 can see uid1 if visibility is >= followers
	if ( $opt{effective_visibility} >= 60 ) {
		$t->get_ok('/status/test1')->status_is(200)->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok('/status/test1')->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
	}

	# uid2 can see uid1 with token if visibility is >= unlisted
	if ( $opt{effective_visibility} >= 30 ) {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
	}

	logout();
	login(
		user     => 'test3',
		password => 'password3'
	);

	# uid3 can see uid1 if visibility is >= travelynx
	if ( $opt{effective_visibility} >= 80 ) {
		$t->get_ok('/status/test1')->status_is(200)->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok('/status/test1')->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
	}

	# uid3 can see uid1 with token if visibility is >= unlisted
	if ( $opt{effective_visibility} >= 30 ) {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{DPN 667});
	}
	else {
		$t->get_ok("/status/test1/$token")->status_is(200)
		  ->content_like(qr{nicht eingecheckt});
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

my $dep       = DateTime->now;
my $arr       = $dep->clone->add( hours => 1 );
my $train_dep = Travel::Status::DE::IRIS::Result->new(
	classes      => 'N',
	type         => 'DPN',
	train_no     => '667',
	raw_id       => '1234-2306251312-1',
	departure_ts => '2306251312',
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
	arrival_ts  => '2306252000',
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
);
$t->app->in_transit->set_arrival_eva(
	uid         => $uid1,
	arrival_eva => 8000002,
);

test_visibility(
	uid                      => $uid1,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 30,
	effective_visibility_str => 'unlisted',
	public                   => 0,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_default_visibility   => 10,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 10,
	effective_visibility_str => 'private',
	public                   => 0,
	with_token               => 0,
);

test_visibility(
	uid                      => $uid1,
	set_default_visibility   => 30,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 30,
	effective_visibility_str => 'unlisted',
	public                   => 0,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_default_visibility   => 60,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 60,
	effective_visibility_str => 'followers',
	public                   => 0,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_default_visibility   => 80,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 80,
	effective_visibility_str => 'travelynx',
	public                   => 0,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_default_visibility   => 100,
	visibility               => undef,
	visibility_str           => 'default',
	effective_visibility     => 100,
	effective_visibility_str => 'public',
	public                   => 1,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_visibility           => 'private',
	visibility               => 10,
	visibility_str           => 'private',
	effective_visibility     => 10,
	effective_visibility_str => 'private',
	public                   => 0,
	with_token               => 0,
);

test_visibility(
	uid                      => $uid1,
	set_visibility           => 'unlisted',
	visibility               => 30,
	visibility_str           => 'unlisted',
	effective_visibility     => 30,
	effective_visibility_str => 'unlisted',
	public                   => 0,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_visibility           => 'followers',
	visibility               => 60,
	visibility_str           => 'followers',
	effective_visibility     => 60,
	effective_visibility_str => 'followers',
	public                   => 0,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_visibility           => 'travelynx',
	visibility               => 80,
	visibility_str           => 'travelynx',
	effective_visibility     => 80,
	effective_visibility_str => 'travelynx',
	public                   => 0,
	with_token               => 1,
);

test_visibility(
	uid                      => $uid1,
	set_visibility           => 'public',
	visibility               => 100,
	visibility_str           => 'public',
	effective_visibility     => 100,
	effective_visibility_str => 'public',
	public                   => 1,
	with_token               => 1,
);

$t->app->pg->db->query('drop schema travelynx_test_22 cascade');
done_testing();
