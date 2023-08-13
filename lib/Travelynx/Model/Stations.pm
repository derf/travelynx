package Travelynx::Model::Stations;

# Copyright (C) 2022 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub add_or_update {
	my ( $self, %opt ) = @_;
	my $stop   = $opt{stop};
	my $source = 1;
	my $db     = $opt{db} // $self->{pg}->db;

	if ( my $s = $self->get_by_eva( $stop->eva, db => $db ) ) {
		if ( $source == 1 and $s->{source} == 0 and not $s->{archived} ) {
			return;
		}
		$db->update(
			'stations',
			{
				name     => $stop->name,
				lat      => $stop->lat,
				lon      => $stop->lon,
				source   => $source,
				archived => 0
			},
			{ eva => $stop->eva }
		);
		return;
	}
	$db->insert(
		'stations',
		{
			eva      => $stop->eva,
			name     => $stop->name,
			lat      => $stop->lat,
			lon      => $stop->lon,
			source   => $source,
			archived => 0
		}
	);
}

# Fast
sub get_by_eva {
	my ( $self, $eva, %opt ) = @_;

	if ( not $eva ) {
		return;
	}

	my $db = $opt{db} // $self->{pg}->db;

	return $db->select( 'stations', '*', { eva => $eva } )->hash;
}

# Fast
sub get_by_evas {
	my ( $self, @evas ) = @_;

	my @ret
	  = $self->{pg}->db->select( 'stations', '*', { eva => { '=', \@evas } } )
	  ->hashes->each;
	return @ret;
}

# Slow
sub get_latlon_by_name {
	my ( $self, %opt ) = @_;

	my $db = $opt{db} // $self->{pg}->db;

	my %location;
	my $res = $db->select( 'stations', [ 'name', 'lat', 'lon' ] );
	while ( my $row = $res->hash ) {
		$location{ $row->{name} } = [ $row->{lat}, $row->{lon} ];
	}
	return \%location;
}

# Slow
sub get_by_name {
	my ( $self, $name, %opt ) = @_;

	my $db = $opt{db} // $self->{pg}->db;

	return $db->select( 'stations', '*', { name => $name }, { limit => 1 } )
	  ->hash;
}

# Slow
sub get_by_names {
	my ( $self, @names ) = @_;

	my @ret
	  = $self->{pg}->db->select( 'stations', '*', { name => { '=', \@names } } )
	  ->hashes->each;
	return @ret;
}

# Slow
sub get_by_ds100 {
	my ( $self, $ds100, %opt ) = @_;

	my $db = $opt{db} // $self->{pg}->db;

	return $db->select( 'stations', '*', { ds100 => $ds100 }, { limit => 1 } )
	  ->hash;
}

# Can be slow
sub search {
	my ( $self, $identifier, %opt ) = @_;

	if ( $identifier =~ m{ ^ \d+ $ }x ) {
		return $self->get_by_eva( $identifier, %opt )
		  // $self->get_by_ds100( $identifier, %opt )
		  // $self->get_by_name( $identifier, %opt );
	}

	return $self->get_by_ds100( $identifier, %opt )
	  // $self->get_by_name( $identifier, %opt );
}

# Slow
sub grep_unknown {
	my ( $self, @stations ) = @_;

	my %station = map { $_->{name} => 1 } $self->get_by_names(@stations);
	my @unknown_stations = grep { not $station{$_} } @stations;

	return @unknown_stations;
}

1;
