#!/usr/bin/env perl

# Copyright (C) 2023 Birthe Friesel <derf@finalrewind.org>
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

$t->app->pg->db->query('drop schema if exists travelynx_test_21 cascade');
$t->app->pg->db->query('create schema travelynx_test_21');
$t->app->pg->db->query('set search_path to travelynx_test_21');
$t->app->pg->on(
	connection => sub {
		my ( $pg, $dbh ) = @_;
		$dbh->do('set search_path to travelynx_test_21');
	}
);

$t->app->config->{mail}->{disabled} = 1;

$t->app->start( 'database', 'migrate' );

my $u = $t->app->users;

my $uid1 = $u->add(
	name     => 'test1',
	email    => 'test1@example.org',
	token    => 'abcd',
	password => q{},
);

my $uid2 = $u->add(
	name     => 'test2',
	email    => 'test2@example.org',
	token    => 'efgh',
	password => q{},
);

$u->verify_registration_token(
	uid   => $uid1,
	token => 'abcd'
);
$u->verify_registration_token(
	uid   => $uid2,
	token => 'efgh'
);

$u->set_social(
	uid                    => $uid1,
	accept_follow_requests => 1
);
$u->set_social(
	uid                    => $uid2,
	accept_follow_requests => 1
);

is(
	$u->get_relation(
		uid    => $uid1,
		target => $uid2
	),
	undef
);
is(
	$u->get_relation(
		uid    => $uid2,
		target => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );

$u->request_follow(
	uid    => $uid1,
	target => $uid2
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	'requests_follow'
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 1 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        1 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       1 );
is_deeply(
	[ $u->get_follow_requests( uid => $uid2 ) ],
	[ { id => $uid1, name => 'test1' } ]
);

$u->reject_follow_request(
	uid       => $uid2,
	applicant => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	undef
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );

$u->request_follow(
	uid    => $uid1,
	target => $uid2
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	'requests_follow'
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 1 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        1 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       1 );
is_deeply(
	[ $u->get_follow_requests( uid => $uid2 ) ],
	[ { id => $uid1, name => 'test1' } ]
);

$u->accept_follow_request(
	uid       => $uid2,
	applicant => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	'follows'
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       1 );
is( scalar $u->get_followees( uid => $uid1 ),       1 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );
is_deeply(
	[ $u->get_followers( uid => $uid2 ) ],
	[
		{
			id                      => $uid1,
			name                    => 'test1',
			following_back          => 0,
			followback_requested    => 0,
			can_follow_back         => 0,
			can_request_follow_back => 1
		}
	]
);
is_deeply(
	[ $u->get_followees( uid => $uid1 ) ],
	[ { id => $uid2, name => 'test2' } ]
);

$u->remove_follower(
	uid      => $uid2,
	follower => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	undef
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );

$u->request_follow(
	uid    => $uid1,
	target => $uid2
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	'requests_follow'
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);

$u->block(
	uid    => $uid2,
	target => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	'is_blocked_by'
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   1 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );
is_deeply(
	[ $u->get_blocked_users( uid => $uid2 ) ],
	[ { id => $uid1, name => 'test1' } ]
);

$u->unblock(
	uid    => $uid2,
	target => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	undef
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );

$u->block(
	uid    => $uid2,
	target => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	'is_blocked_by'
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   1 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );
is_deeply(
	[ $u->get_blocked_users( uid => $uid2 ) ],
	[ { id => $uid1, name => 'test1' } ]
);

$u->unblock(
	uid    => $uid2,
	target => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	undef
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );

$u->request_follow(
	uid    => $uid1,
	target => $uid2
);
$u->accept_follow_request(
	uid       => $uid2,
	applicant => $uid1
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	'follows'
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       1 );
is( scalar $u->get_followees( uid => $uid1 ),       1 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );
is_deeply(
	[ $u->get_followers( uid => $uid2 ) ],
	[
		{
			id                      => $uid1,
			name                    => 'test1',
			following_back          => 0,
			followback_requested    => 0,
			can_follow_back         => 0,
			can_request_follow_back => 1
		}
	]
);
is_deeply(
	[ $u->get_followees( uid => $uid1 ) ],
	[ { id => $uid2, name => 'test2' } ]
);

$u->unfollow(
	uid    => $uid1,
	target => $uid2
);

is(
	$u->get_relation(
		subject => $uid1,
		object  => $uid2
	),
	undef
);
is(
	$u->get_relation(
		subject => $uid2,
		object  => $uid1
	),
	undef
);
is( scalar $u->get_followers( uid => $uid1 ),       0 );
is( scalar $u->get_followers( uid => $uid2 ),       0 );
is( scalar $u->get_followees( uid => $uid1 ),       0 );
is( scalar $u->get_followees( uid => $uid2 ),       0 );
is( scalar $u->get_follow_requests( uid => $uid1 ), 0 );
is( scalar $u->get_follow_requests( uid => $uid2 ), 0 );
is( scalar $u->get_blocked_users( uid => $uid1 ),   0 );
is( scalar $u->get_blocked_users( uid => $uid2 ),   0 );
is( $u->has_follow_requests( uid => $uid1 ),        0 );
is( $u->has_follow_requests( uid => $uid2 ),        0 );
is( $u->get( uid => $uid1 )->{notifications},       0 );
is( $u->get( uid => $uid2 )->{notifications},       0 );

$t->app->pg->db->query('drop schema travelynx_test_21 cascade');
done_testing();
