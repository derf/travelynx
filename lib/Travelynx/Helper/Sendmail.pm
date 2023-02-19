package Travelynx::Helper::Sendmail;

# Copyright (C) 2020-2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;

use 5.020;

use Encode qw(encode);
use Email::Sender::Simple qw(try_to_sendmail);
use MIME::Entity;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub custom {
	my ( $self, $to, $subject, $body ) = @_;

	my $reg_mail = MIME::Entity->build(
		To       => $to,
		From     => $self->{config}{from},
		Subject  => encode( 'MIME-Header', $subject ),
		Type     => 'text/plain',
		Charset  => 'UTF-8',
		Encoding => 'quoted-printable',
		Data     => encode( 'utf-8', $body ),
	);

	if ( $self->{config}->{disabled} ) {

		# Do not send mail in dev mode
		$self->{log}->info("sendmail to ${to}: ${subject}\n\n${body}");
		return 1;
	}

	return try_to_sendmail($reg_mail);
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
