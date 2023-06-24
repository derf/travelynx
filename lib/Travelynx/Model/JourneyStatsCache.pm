package Travelynx::Model::JourneyStatsCache;

# Copyright (C) 2020-2023 Birthe Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later

use strict;
use warnings;
use 5.020;
use utf8;

import JSON;

sub new {
	my ( $class, %opt ) = @_;

	return bless( \%opt, $class );
}

sub add {
	my ( $self, %opt ) = @_;

	my $db = $opt{db} // $self->{pg}->db;

	eval {
		$db->insert(
			'journey_stats',
			{
				user_id => $opt{uid},
				year    => $opt{year},
				month   => $opt{month},
				data    => JSON->new->encode( $opt{stats} ),
			}
		);
	};
	if ( my $err = $@ ) {
		if ( $err =~ m{duplicate key value violates unique constraint} ) {

			# If a user opens the same history page several times in
			# short succession, there is a race condition where several
			# Mojolicious workers execute this helper, notice that there is
			# no up-to-date history, compute it, and insert it using the
			# statement above. This will lead to a uniqueness violation
			# in each successive insert. However, this is harmless, and
			# thus ignored.
		}
		else {
			# Otherwise we probably have a problem.
			die($@);
		}
	}
}

sub get {
	my ( $self, %opt ) = @_;

	my $db = $opt{db} // $self->{pg}->db;

	my $stats = $db->select(
		'journey_stats',
		['data'],
		{
			user_id => $opt{uid},
			year    => $opt{year},
			month   => $opt{month}
		}
	)->expand->hash;

	return $stats->{data};
}

# Statistics are partitioned by real_departure, which must be provided
# when calling this function e.g. after journey deletion or editing.
# If a joureny's real_departure has been edited, this function must be
# called twice: once with the old and once with the new value.
sub invalidate {
	my ( $self, %opt ) = @_;

	my $ts  = $opt{ts};
	my $db  = $opt{db} // $self->{pg}->db;
	my $uid = $opt{uid};

	$db->delete(
		'journey_stats',
		{
			user_id => $uid,
			year    => $ts->year,
			month   => $ts->month,
		}
	);
	$db->delete(
		'journey_stats',
		{
			user_id => $uid,
			year    => $ts->year,
			month   => 0,
		}
	);
}

sub get_yyyymm_having_stats {
	my ( $self, %opt ) = @_;
	my $uid = $opt{uid};
	my $db  = $opt{db} // $self->{pg}->db;
	my $res = $db->select(
		'journey_stats',
		[ 'year', 'month' ],
		{ user_id  => $uid },
		{ order_by => { -asc => [ 'year', 'month' ] } }
	);

	my @ret;
	for my $row ( $res->hashes->each ) {
		if ( $row->{month} != 0 ) {
			push( @ret, [ $row->{year}, $row->{month} ] );
		}
	}

	return @ret;
}

1;
