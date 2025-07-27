#!/usr/bin/env perl

# Copyright (C) 2020 Birte Kristina Friesel <derf@finalrewind.org>
#
# SPDX-License-Identifier: MIT

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

# Include application
use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new('Travelynx');

$t->ua->on( start => sub { $_[1]->req->headers->accept_language('en-GB') } );

$t->get_ok('/')->status_is(200);
$t->text_like( 'a[href="/register"]' => qr{Register} );
$t->text_like( 'a[href="/login"]'    => qr{Login} );

$t->get_ok('/about')->status_is(200);
$t->get_ok('/api')->status_is(200);
$t->get_ok('/changelog')->status_is(200);
$t->get_ok('/legend')->status_is(200);
$t->get_ok('/offline.html')->status_is(200);

$t->get_ok('/login')->status_is(200);
$t->element_exists('input[name="csrf_token"]');
$t->text_like( 'button' => qr{Login} );

$t->get_ok('/recover')->status_is(200);

$t->get_ok('/register')->status_is(200);
$t->element_exists('input[name="csrf_token"]');
$t->element_exists('a[href="/impressum"]');
$t->text_like( 'button' => qr{Register} );

# Protected sites should redirect to login form

for my $protected (qw(/account /account/password /history /s/EE)) {
	$t->get_ok($protected)->text_like( 'button' => qr{Login} );
}

# Otherwise, we expect a 404
$t->get_ok('/definitelydoesnotexist')->status_is(404);

done_testing();
