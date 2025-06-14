package Travelynx::Model::Stations;

# Copyright (C) 2022 Birte Kristina Friesel
# Copyright (C) 2025 networkException <git@nwex.de>
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub get_backend_id {
	my ( $self, %opt ) = @_;

	if ( $opt{iris} ) {

		# special case
		return 0;
	}
	if ( $opt{dbris} and $self->{backend_id}{dbris}{ $opt{dbris} } ) {
		return $self->{backend_id}{dbris}{ $opt{dbris} };
	}
	if ( $opt{efa} and $self->{backend_id}{efa}{ $opt{efa} } ) {
		return $self->{backend_id}{efa}{ $opt{efa} };
	}
	if ( $opt{hafas} and $self->{backend_id}{hafas}{ $opt{hafas} } ) {
		return $self->{backend_id}{hafas}{ $opt{hafas} };
	}
	if ( $opt{motis} and $self->{backend_id}{motis}{ $opt{motis} } ) {
		return $self->{backend_id}{motis}{ $opt{motis} };
	}

	my $db         = $opt{db} // $self->{pg}->db;
	my $backend_id = 0;

	if ( $opt{dbris} ) {
		$backend_id = $db->select(
			'backends',
			['id'],
			{
				dbris => 1,
				name  => $opt{dbris}
			}
		)->hash->{id};
		$self->{backend_id}{dbris}{ $opt{dbris} } = $backend_id;
	}
	elsif ( $opt{efa} ) {
		$backend_id = $db->select(
			'backends',
			['id'],
			{
				efa  => 1,
				name => $opt{efa}
			}
		)->hash->{id};
		$self->{backend_id}{efa}{ $opt{efa} } = $backend_id;
	}
	elsif ( $opt{hafas} ) {
		$backend_id = $db->select(
			'backends',
			['id'],
			{
				hafas => 1,
				name  => $opt{hafas}
			}
		)->hash->{id};
		$self->{backend_id}{hafas}{ $opt{hafas} } = $backend_id;
	}
	elsif ( $opt{motis} ) {
		$backend_id = $db->select(
			'backends',
			['id'],
			{
				motis => 1,
				name  => $opt{motis}
			}
		)->hash->{id};
		$self->{backend_id}{motis}{ $opt{motis} } = $backend_id;
	}

	return $backend_id;
}

sub get_backend {
	my ( $self, %opt ) = @_;

	if ( $self->{backend_cache}{ $opt{backend_id} } ) {
		return $self->{backend_cache}{ $opt{backend_id} };
	}

	my $db  = $opt{db} // $self->{pg}->db;
	my $ret = $db->select(
		'backends',
		'*',
		{
			id => $opt{backend_id},
		}
	)->hash;

	$self->{backend_cache}{ $opt{backend_id} } = $ret;

	return $ret;
}

sub get_backends {
	my ( $self, %opt ) = @_;

	$opt{db} //= $self->{pg}->db;

	my $res = $opt{db}->select( 'backends',
		[ 'id', 'name', 'dbris', 'efa', 'hafas', 'iris', 'motis' ] );
	my @ret;

	while ( my $row = $res->hash ) {
		push(
			@ret,
			{
				id    => $row->{id},
				name  => $row->{name},
				dbris => $row->{dbris},
				efa   => $row->{efa},
				hafas => $row->{hafas},
				iris  => $row->{iris},
				motis => $row->{motis},
			}
		);
	}

	return @ret;
}

# Slow for MOTIS backends
sub add_or_update {
	my ( $self, %opt ) = @_;
	my $stop = $opt{stop};
	$opt{db} //= $self->{pg}->db;

	$opt{backend_id} //= $self->get_backend_id(%opt);

	if ( $opt{dbris} ) {
		if (
			my $s = $self->get_by_eva(
				$stop->eva,
				db         => $opt{db},
				backend_id => $opt{backend_id}
			)
		  )
		{
			$opt{db}->update(
				'stations',
				{
					name     => $stop->name,
					lat      => $stop->lat,
					lon      => $stop->lon,
					archived => 0
				},
				{
					eva    => $stop->eva,
					source => $opt{backend_id}
				}
			);
			return;
		}
		$opt{db}->insert(
			'stations',
			{
				eva      => $stop->eva,
				name     => $stop->name,
				lat      => $stop->lat,
				lon      => $stop->lon,
				source   => $opt{backend_id},
				archived => 0
			}
		);
		return;
	}

	if ( $opt{efa} ) {
		if (
			my $s = $self->get_by_eva(
				$stop->id_num,
				db         => $opt{db},
				backend_id => $opt{backend_id}
			)
		  )
		{
			$opt{db}->update(
				'stations',
				{
					name     => $stop->full_name,
					lat      => $stop->latlon->[0],
					lon      => $stop->latlon->[1],
					archived => 0
				},
				{
					eva    => $stop->id_num,
					source => $opt{backend_id}
				}
			);
			return;
		}
		$opt{db}->insert(
			'stations',
			{
				eva      => $stop->id_num,
				name     => $stop->full_name,
				lat      => $stop->latlon->[0],
				lon      => $stop->latlon->[1],
				source   => $opt{backend_id},
				archived => 0
			}
		);
		return;
	}

	if ( $opt{motis} ) {
		if (
			my $s = $self->get_by_external_id(
				external_id => $stop->id,
				db          => $opt{db},
				backend_id  => $opt{backend_id}
			)
		  )
		{
			$opt{db}->update(
				'stations',
				{
					name     => $stop->name,
					lat      => $stop->lat,
					lon      => $stop->lon,
					archived => 0
				},
				{
					eva    => $s->{eva},
					source => $opt{backend_id}
				}
			);

			# MOTIS backends do not provide a numeric ID, so we set our ID here.
			$stop->{eva} = $s->{eva};
			return;
		}

		my $s = $opt{db}->query(
			qq {
				with new_station as (
					insert into stations_external_ids (backend_id, external_id)
					values (?, ?)
					returning eva, backend_id
				)

				insert into stations (eva, name, lat, lon, source, archived)
				values ((select eva from new_station), ?, ?, ?, (select backend_id from new_station), ?)
				returning *
			},
			(
				$opt{backend_id}, $stop->id,  $stop->name,
				$stop->lat,       $stop->lon, 0,
			)
		);

		# MOTIS backends do not provide a numeric ID, so we set our ID here.
		$stop->{eva} = $s->hash->{eva};
		return;
	}

	my $loc = $stop->loc;
	if (
		my $s = $self->get_by_eva(
			$loc->eva,
			db         => $opt{db},
			backend_id => $opt{backend_id}
		)
	  )
	{
		$opt{db}->update(
			'stations',
			{
				name     => $loc->name,
				lat      => $loc->lat,
				lon      => $loc->lon,
				archived => 0
			},
			{
				eva    => $loc->eva,
				source => $opt{backend_id}
			}
		);
		return;
	}
	$opt{db}->insert(
		'stations',
		{
			eva      => $loc->eva,
			name     => $loc->name,
			lat      => $loc->lat,
			lon      => $loc->lon,
			source   => $opt{backend_id},
			archived => 0
		}
	);

	return;
}

sub add_meta {
	my ( $self, %opt ) = @_;
	my $eva  = $opt{eva};
	my @meta = @{ $opt{meta} };

	$opt{db}         //= $self->{pg}->db;
	$opt{backend_id} //= $self->get_backend_id(%opt);

	for my $meta (@meta) {
		if ( $meta != $eva ) {
			$opt{db}->insert(
				'related_stations',
				{
					eva        => $eva,
					meta       => $meta,
					backend_id => $opt{backend_id},
				},
				{ on_conflict => undef }
			);
		}
	}
}

sub get_db_iterator {
	my ($self) = @_;

	return $self->{pg}->db->select( 'stations_str', '*' );
}

sub get_meta {
	my ( $self, %opt ) = @_;
	my $db  = $opt{db} // $self->{pg}->db;
	my $eva = $opt{eva};

	$opt{backend_id} //= $self->get_backend_id( %opt, db => $db );

	my $res = $db->select(
		'related_stations',
		['meta'],
		{
			eva        => $eva,
			backend_id => $opt{backend_id}
		}
	);
	my @ret;

	while ( my $row = $res->hash ) {
		push( @ret, $row->{meta} );
	}

	return @ret;
}

sub get_for_autocomplete {
	my ( $self, %opt ) = @_;

	$opt{backend_id} //= $self->get_backend_id(%opt);

	my $res = $self->{pg}
	  ->db->select( 'stations', ['name'], { source => $opt{backend_id} } );
	my %ret;

	while ( my $row = $res->hash ) {
		$ret{ $row->{name} } = undef;
	}

	return \%ret;
}

# Fast
sub get_by_eva {
	my ( $self, $eva, %opt ) = @_;

	if ( not $eva ) {
		return;
	}

	$opt{db}         //= $self->{pg}->db;
	$opt{backend_id} //= $self->get_backend_id(%opt);

	return $opt{db}->select(
		'stations',
		'*',
		{
			eva    => $eva,
			source => $opt{backend_id}
		}
	)->hash;
}

# Slow
sub get_by_external_id {
	my ( $self, %opt ) = @_;

	if ( not $opt{external_id} ) {
		return;
	}

	$opt{db}         //= $self->{pg}->db;
	$opt{backend_id} //= $self->get_backend_id(%opt);

	return $opt{db}->select(
		'stations_with_external_ids',
		'*',
		{
			external_id => $opt{external_id},
			source      => $opt{backend_id},
		}
	)->hash;
}

# Fast
sub get_by_evas {
	my ( $self, %opt ) = @_;

	$opt{db}         //= $self->{pg}->db;
	$opt{backend_id} //= $self->get_backend_id(%opt);

	my @ret = $self->{pg}->db->select(
		'stations',
		'*',
		{
			eva    => { '=', $opt{evas} },
			source => $opt{backend_id}
		}
	)->hashes->each;
	return @ret;
}

# Slow
sub get_by_name {
	my ( $self, $name, %opt ) = @_;

	$opt{db}         //= $self->{pg}->db;
	$opt{backend_id} //= $self->get_backend_id(%opt);

	return $opt{db}->select(
		'stations',
		'*',
		{
			name   => $name,
			source => $opt{backend_id}
		},
		{ limit => 1 }
	)->hash;
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

	$opt{db}         //= $self->{pg}->db;
	$opt{backend_id} //= $self->get_backend_id(%opt);

	return $opt{db}->select(
		'stations',
		'*',
		{
			ds100  => $ds100,
			source => $opt{backend_id}
		},
		{ limit => 1 }
	)->hash;
}

# Can be slow
sub search {
	my ( $self, $identifier, %opt ) = @_;

	$opt{db}         //= $self->{pg}->db;
	$opt{backend_id} //= $self->get_backend_id(%opt);

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
