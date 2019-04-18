#!/usr/bin/env perl
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

# Include application
use FindBin;
require "$FindBin::Bin/../index.pl";

my $t = Test::Mojo->new('Travelynx');

$t->get_ok('/')->status_is(200);
$t->text_like( 'a[href="/register"]' => qr{Registrieren} );
$t->text_like( 'a[href="/login"]'    => qr{Anmelden} );

$t->get_ok('/register')->status_is(200);
$t->element_exists('input[name="csrf_token"]');
$t->element_exists('a[href="/impressum"]');
$t->text_like( 'button' => qr{Registrieren} );

$t->get_ok('/login')->status_is(200);
$t->element_exists('input[name="csrf_token"]');
$t->text_like( 'button' => qr{Anmelden} );

$t->get_ok('/about')->status_is(200);

# Protected sites should redirect to login form

for my $protected (qw(/account /change_password /history /s/EE)) {
	$t->get_ok($protected)->text_like( 'button' => qr{Anmelden} );
}

# Otherwise, we expect a 404
$t->get_ok('/definitelydoesnotexist')->status_is(404);

done_testing();
