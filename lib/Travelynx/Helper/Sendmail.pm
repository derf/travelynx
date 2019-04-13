package Travelynx::Helper::Sendmail;

use strict;
use warnings;

use 5.020;

use Encode qw(encode);
use Email::Sender::Simple qw(try_to_sendmail);
use Email::Simple;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub custom {
	my ( $self, $to, $subject, $body ) = @_;

	my $reg_mail = Email::Simple->create(
		header => [
			To             => $to,
			From           => 'Travelynx <travelynx@finalrewind.org>',
			Subject        => $subject,
			'Content-Type' => 'text/plain; charset=UTF-8',
		],
		body => encode( 'utf-8', $body ),
	);

	if ( $self->{config}->{disabled} ) {

		# Do not send mail in dev mode
		say "sendmail to ${to}: ${subject}\n\n${body}";
		return 1;
	}

	return try_to_sendmail($reg_mail);
}

1;
