package Travelynx::Helper::Sendmail;

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
		From     => $from,
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

1;
