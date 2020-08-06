package Travelynx::Helper::IRIS;

use strict;
use warnings;
use 5.020;

use Travel::Status::DE::IRIS;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub get_departures {
	my ( $self, %opt ) = @_;
	my $station      = $opt{station};
	my $lookbehind   = $opt{lookbehind} // 180;
	my $lookahead    = $opt{lookahead} // 30;
	my $with_related = $opt{with_related} // 0;

	my @station_matches
	  = Travel::Status::DE::IRIS::Stations::get_station($station);

	if ( @station_matches == 1 ) {
		$station = $station_matches[0][0];
		my $status = Travel::Status::DE::IRIS->new(
			station        => $station,
			main_cache     => $self->{main_cache},
			realtime_cache => $self->{realtime_cache},
			keep_transfers => 1,
			lookbehind     => 20,
			datetime       => DateTime->now( time_zone => 'Europe/Berlin' )
			  ->subtract( minutes => $lookbehind ),
			lookahead   => $lookbehind + $lookahead,
			lwp_options => {
				timeout => 10,
				agent   => 'travelynx/'
				  . $self->{version}
				  . ' +https://travelynx.de',
			},
			with_related => $with_related,
		);
		return {
			results => [ $status->results ],
			errstr  => $status->errstr,
			station_ds100 =>
			  ( $status->station ? $status->station->{ds100} : undef ),
			station_eva =>
			  ( $status->station ? $status->station->{uic} : undef ),
			station_name =>
			  ( $status->station ? $status->station->{name} : undef ),
			related_stations => [ $status->related_stations ],
		};
	}
	elsif ( @station_matches > 1 ) {
		return {
			results => [],
			errstr  => 'Mehrdeutiger Stationsname. Mögliche Eingaben: '
			  . join( q{, }, map { $_->[1] } @station_matches ),
		};
	}
	else {
		return {
			results => [],
			errstr  => 'Unbekannte Station',
		};
	}
}

1;
