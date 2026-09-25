package Travelynx::Helper::Sendmail;

# Copyright (C) 2020-2023 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use feature 'try';

use 5.040;

use DateTime;
use Encode                qw(encode);
use Email::Sender::Simple qw(sendmail);
use MIME::Entity;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub custom {
	my ( $self, $to, $subject, $body ) = @_;

	my $reg_mail = MIME::Entity->build(
		To             => $to,
		From           => $self->{config}{from},
		Subject        => encode( 'MIME-Header', $subject ),
		Type           => 'text/plain;format=flowed',
		Charset        => 'UTF-8',
		Encoding       => 'quoted-printable',
		Data           => encode( 'utf-8', $body ),
		"MIME-Version" => '1.0',
		"Date"         => DateTime->now->strftime("%a, %d %b %Y %H:%M:%S %z"),
	);

	if ( $self->{config}->{disabled} ) {

		# Do not send mail in dev mode
		$self->{log}->info("sendmail to ${to}: ${subject}\n\n${body}");
		return 1;
	}

	try {
		return sendmail($reg_mail);
	}
	catch ($e) {
		$self->{log}->error("Sendmail.pm: sendmail error ${e}");
		return 0;
	}
}

sub age_deletion_notification {
	my ( $self, %opt ) = @_;
	my $name        = $opt{name};
	my $email       = $opt{email};
	my $last_seen   = $opt{last_seen};
	my $login_url   = $opt{login_url};
	my $account_url = $opt{account_url};
	my $imprint_url = $opt{imprint_url};

	my $body = "Hallo ${name},\n\n";
	$body
	  .= "Dein travelynx-Account wurde seit dem ${last_seen} nicht verwendet.\n";
	$body
	  .= "Im Sinne der Datensparsamkeit wird er daher in vier Wochen gelöscht.\n";
	$body
	  .= "Falls du den Account weiterverwenden möchtest, kannst du dich unter\n";
	$body .= "<$login_url> anmelden.\n";
	$body
	  .= "Durch die Anmeldung wird die Löschung automatisch abgebrochen.\n\n";
	$body
	  .= "Falls du den Account löschen, aber zuvor deine Daten exportieren möchtest,\n";
	$body .= "kannst du dich unter obiger URL anmelden, unter <$account_url>\n";
	$body
	  .= "deine Daten exportieren und anschließend den Account löschen lassen.\n\n\n";
	$body .= "Impressum: ${imprint_url}\n";

	return $self->custom( $email,
		'travelynx: Löschung deines Accounts', $body );
}

1;
