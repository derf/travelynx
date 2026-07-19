package Travelynx::Command::import;

# Copyright (C) 2026 Birte Kristina Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Command';
use DateTime;
use File::Slurp qw(read_file);
use JSON;
use Text::CSV;

has description => 'import stops or user data';

has usage => sub { shift->extract_usage };

sub epoch_to_dt {
	my ($ts) = @_;
	if ( not $ts ) {
		return;
	}
	return DateTime->from_epoch(
		epoch     => $ts,
		time_zone => 'Europe/Berlin',
	);
}

sub import_stops {
	my ( $self, $csv_filename ) = @_;

	my $db = $self->app->pg->db;

	open( my $fh, '<:encoding(utf-8)', $csv_filename )
	  or die("open($csv_filename): $!\n");

	binmode( STDOUT, ':encoding(utf-8)' );

	my $n_bytes = ( stat($fh) )[7];
	printf( "Importing ≈%.f stops, this may take a while ...\n",
		$n_bytes / 80, );
	$| = 1;

	my $csv = Text::CSV->new( { eol => "\r\n" } );
	my %col;
	my $i = 0;
	my @queue;
	my @extId_queue;
	while ( my $row = $csv->getline($fh) ) {
		if ( not %col ) {
			%col = map { $row->[$_] => $_ } ( 0 .. $#{$row} );
		}
		else {

			my %backend_query;
			for my $type (qw(dbris efa hafas motis)) {
				if ( $row->[ $col{ ${type} } ] ) {
					$backend_query{$type} = $row->[ $col{backend} ];
				}
			}
			my $backend_id
			  = $self->app->stations->get_backend_id(%backend_query);

			if ( $row->[ $col{extId} ] ) {
				push( @extId_queue, [ $row, $backend_id ] );
				next;
			}

			push(
				@queue,
				[
					$row->[ $col{name} ],
					$row->[ $col{id} ],
					$row->[ $col{lat} ],
					$row->[ $col{lon} ],
					$backend_id,
				]
			);
		}
		if ( ++$i % 100 == 0 ) {
			printf( "\r\e[2KImporting stop #%d (%5.1f%% done) ...",
				$i, tell($fh) * 100 / $n_bytes );
			$self->app->stations->upsert_import(
				db         => $db,
				stations   => \@queue,
				batch_size => scalar @queue,
			);
			@queue = ();
		}
	}

	if (@queue) {
		$self->app->stations->upsert_import(
			db         => $db,
			stations   => \@queue,
			batch_size => scalar @queue,
		);
		$i += @queue;
		@queue = ();
	}

	say "\r\e[2KImported ${i} stops";

	$i = 0;
	my $num_extIds = scalar @extId_queue;
	say "Importing ${num_extIds} stops with external IDs ...";
	for my $entry (@extId_queue) {
		my ( $row, $backend_id ) = @{$entry};
		my $s = $self->app->stations->get_by_external_id(
			db          => $db,
			external_id => $row->[ $col{extId} ],
			backend_id  => $backend_id
		);
		if ( not $s ) {
			eval {
				$self->app->stations->import_with_external_id(
					db          => $db,
					backend_id  => $backend_id,
					name        => $row->[ $col{name} ],
					eva         => $row->[ $col{id} ],
					external_id => $row->[ $col{extId} ],
					lat         => $row->[ $col{lat} ],
					lon         => $row->[ $col{lon} ],
				);
			};
			if ($@) {
				say q{};
				say STDERR 'Failed to import ' . join( q{,}, @{$row} );
				say STDERR q{};
				say STDERR $@;
				say STDERR q{};
				say STDERR 'Import aborted.';
				exit 1;
			}
		}
		if ( ++$i % 100 == 0 ) {
			printf( "\r\e[2KImporting external ID #%d (%5.1f%% done) ...",
				$i, $i * 100 / @extId_queue );
		}
	}

	close($fh);

}

sub import_journeys {
	my ( $self, $uid, $name, $json_filename ) = @_;

	my $user_data = $self->app->users->get( uid => $uid );

	if ( not $user_data ) {
		say STDERR "UID $uid does not exist.";
		return;
	}

	if ( $user_data->{name} ne $name ) {
		say STDERR "User name $name does not match UID $uid. Import aborted.";
		return;
	}

	my $import = JSON->new->utf8->decode( scalar read_file($json_filename) );

	if ( not $import->{backends} ) {
		say STDERR
"$json_filename has been exported from an incompatible travelynx version";
		return;
	}

	my %backend;
	for my $backend ( @{ $import->{backends} // [] } ) {
		$backend{ $backend->{id} } = $backend;
	}

	# TODO special handling for dep_external_id / arr_external_id
	# → use IDs from database, not IDs from journey entry.

	my @journeys = sort { $a->{journey_id} <=> $b->{journey_id} }
	  @{ $import->{journeys} // [] };

	binmode( STDOUT, ':encoding(utf-8)' );
	my $db           = $self->app->pg->db;
	my $tx           = $db->begin;
	my $num_journeys = @journeys;
	my $i            = 0;

	printf( "Importing %d journeys, this may take a while ...\n",
		$num_journeys );

	for my $journey (@journeys) {

		#printf("Importing journey %8d  %s  →  %s  (%d → %d)\n",
		#	$journey->{journey_id},
		#	$journey->{dep_name},
		#	$journey->{arr_name},
		#	$journey->{dep_eva},
		#	$journey->{arr_eva},
		#);

		my $backend_info = $backend{ $journey->{backend_id} };
		my %backend_query;
		for my $type (qw(dbris efa hafas motis)) {
			if ( $backend_info->{$type} ) {
				$backend_query{$type} = $backend_info->{name};
			}
		}
		my $backend_id = $self->app->stations->get_backend_id(%backend_query);

		my ( $new_journey_id, $error ) = $self->app->journeys->add(
			db              => $db,
			uid             => $uid,
			backend_id      => $backend_id,
			cancelled       => $journey->{cancelled},
			checkin_time    => scalar epoch_to_dt( $journey->{checkin_ts} ),
			edited          => $journey->{edited},
			train_type      => $journey->{train_type},
			train_line      => $journey->{train_line},
			train_no        => $journey->{train_no},
			train_id        => $journey->{train_id},
			dep_station     => $journey->{dep_eva},
			dep_platform    => $journey->{dep_platform},
			sched_departure => scalar epoch_to_dt( $journey->{sched_dep_ts} ),
			rt_departure    => scalar epoch_to_dt( $journey->{real_dep_ts} ),
			arr_station     => $journey->{arr_eva},
			arr_platform    => $journey->{arr_platform},
			sched_arrival   => scalar epoch_to_dt( $journey->{sched_arr_ts} ),
			rt_arrival      => scalar epoch_to_dt( $journey->{real_arr_ts} ),
			json_route      => $journey->{route},
			messages        => $journey->{messages},
			user_data       => $journey->{user_data},
			visibility      => $journey->{visibility},
		);

		if ($error) {
			$self->app->log->error(
				"journeys->add(journey_id => $journey->{journey_id}): $error");
			return;
		}

		if ( $journey->{polyline} ) {
			$self->app->journeys->set_polyline(
				db         => $db,
				uid        => $uid,
				journey_id => $new_journey_id,
				edited     => $journey->{edited},
				from_eva   => $journey->{dep_eva},
				to_eva     => $journey->{dep_eva},
				polyline   => $journey->{polyline},
			);
		}

		if ( $i++ % 100 == 0 ) {
			printf( "%5.1f%% done ...\n", $i * 100 / $num_journeys );
		}
	}
	$tx->commit;
}

sub run {
	my ( $self, $command, @args ) = @_;

	if ( not $command ) {
		$self->help;
	}
	elsif ( $command eq 'stops' ) {
		$self->import_stops(@args);
	}
	elsif ( $command eq 'journeys' ) {
		$self->import_journeys(@args);
	}
	else {
		$self->help;
	}
}

1;

__END__

=head1 SYNOPSIS

  Usage: index.pl import stops <stops.csv>

  Usage: index.pl import userdata <uid> <name> <export.json>
