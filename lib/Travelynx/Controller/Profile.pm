package Travelynx::Controller::Profile;

# Copyright (C) 2020-2023 Daniel Friesel
#
# SPDX-License-Identifier: AGPL-3.0-or-later
use Mojo::Base 'Mojolicious::Controller';

use DateTime;

# Internal Helpers

sub compute_effective_visibility {
	my ( $self, $default_visibility, $journey_visibility ) = @_;
	if ( $journey_visibility eq 'default' ) {
		return $default_visibility;
	}
	return $journey_visibility;
}

sub status_token_ok {
	my ( $self, $status, $ts2_ext ) = @_;
	my $token = $self->param('token') // q{};

	my ( $eva, $ts, $ts2 ) = split( qr{-}, $token );
	if ( not $ts ) {
		return;
	}

	$ts2 //= $ts2_ext;

	if (    $eva == $status->{dep_eva}
		and $ts == $status->{timestamp}->epoch % 337
		and $ts2 == $status->{sched_departure}->epoch )
	{
		return 1;
	}
	return;
}

sub journey_token_ok {
	my ( $self, $journey, $ts2_ext ) = @_;
	my $token = $self->param('token') // q{};

	my ( $eva, $ts, $ts2 ) = split( qr{-}, $token );
	if ( not $ts ) {
		return;
	}

	$ts2 //= $ts2_ext;

	if (    $eva == $journey->{from_eva}
		and $ts == $journey->{checkin_ts} % 337
		and $ts2 == $journey->{sched_dep_ts} )
	{
		return 1;
	}
	return;
}

# Controllers

sub profile {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $user = $self->users->get_privacy_by_name( name => $name );

	if ( not $user ) {
		$self->render('not_found');
		return;
	}

	my $status = $self->get_user_status( $user->{id} );
	my $visibility;
	if ( $status->{checked_in} or $status->{arr_name} ) {
		$visibility
		  = $self->compute_effective_visibility(
			$user->{default_visibility_str},
			$status->{visibility_str} );
		if (
			not(
				$visibility eq 'public'
				or (    $visibility eq 'unlisted'
					and $self->status_token_ok($status) )
				or (
					$visibility eq 'travelynx'
					and (  $self->is_user_authenticated
						or $self->status_token_ok($status) )
				)
			)
		  )
		{
			$status->{checked_in} = 0;
			$status->{arr_name}   = undef;
		}
	}
	if (    not $status->{checked_in}
		and $status->{arr_name}
		and not $user->{past_status} )
	{
		$status->{arr_name} = undef;
	}

	my @journeys;

	if ( $user->{past_visible} == 2
		or ( $user->{past_visible} == 1 and $self->is_user_authenticated ) )
	{

		my %opt = (
			uid           => $user->{id},
			limit         => 10,
			with_datetime => 1
		);

		if ( not $user->{past_all} ) {
			my $now = DateTime->now( time_zone => 'Europe/Berlin' );
			$opt{before} = DateTime->now( time_zone => 'Europe/Berlin' );
			$opt{after}  = $now->clone->subtract( weeks => 4 );
		}

		if (
			$user->{default_visibility_str} eq 'public'
			or (    $user->{default_visibility_str} eq 'travelynx'
				and $self->is_user_authenticated )
		  )
		{
			$opt{with_default_visibility} = 1;
		}
		else {
			$opt{with_default_visibility} = 0;
		}

		if ( $self->is_user_authenticated ) {
			$opt{min_visibility} = 'travelynx';
		}
		else {
			$opt{min_visibility} = 'public';
		}

		@journeys = $self->journeys->get(%opt);
	}

	$self->render(
		'profile',
		name               => $name,
		uid                => $user->{id},
		public_level       => $user->{public_level},
		journey            => $status,
		journey_visibility => $visibility,
		journeys           => [@journeys],
		version            => $self->app->config->{version} // 'UNKNOWN',
	);
}

sub journey_details {
	my ($self)     = @_;
	my $name       = $self->stash('name');
	my $journey_id = $self->stash('id');
	my $user       = $self->users->get_privacy_by_name( name => $name );

	$self->param( journey_id => $journey_id );

	if ( not( $user and $journey_id and $journey_id =~ m{ ^ \d+ $ }x ) ) {
		$self->render(
			'journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $journey = $self->journeys->get_single(
		uid             => $user->{id},
		journey_id      => $journey_id,
		verbose         => 1,
		with_datetime   => 1,
		with_polyline   => 1,
		with_visibility => 1,
	);

	if ( not $journey ) {
		$self->render(
			'journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $is_past;
	if ( not $user->{past_all} ) {
		my $now = DateTime->now( time_zone => 'Europe/Berlin' );
		if ( $journey->{sched_dep_ts} < $now->subtract( weeks => 4 )->epoch ) {
			$is_past = 1;
		}
	}

	my $visibility
	  = $self->compute_effective_visibility( $user->{default_visibility_str},
		$journey->{visibility_str} );

	if (
		not(
			( $visibility eq 'public' and not $is_past )
			or (    $visibility eq 'unlisted'
				and $self->journey_token_ok($journey) )
			or (
				$visibility eq 'travelynx'
				and ( ( $self->is_user_authenticated and not $is_past )
					or $self->journey_token_ok($journey) )
			)
		)
	  )
	{
		$self->render(
			'journey',
			status  => 404,
			error   => 'notfound',
			journey => {}
		);
		return;
	}

	my $title = sprintf( 'Fahrt von %s nach %s am %s',
		$journey->{from_name}, $journey->{to_name},
		$journey->{rt_arrival}->strftime('%d.%m.%Y') );
	my $delay = 'pünktlich ';
	if ( $journey->{rt_arrival} != $journey->{sched_arrival} ) {
		$delay = sprintf(
			'mit %+d ',
			(
				    $journey->{rt_arrival}->epoch
				  - $journey->{sched_arrival}->epoch
			) / 60
		);
	}
	my $description = sprintf( 'Ankunft mit %s %s %s',
		$journey->{type}, $journey->{no},
		$journey->{rt_arrival}->strftime('um %H:%M') );
	if ( $journey->{km_route} > 0.1 ) {
		$description = sprintf( '%.0f km mit %s %s – Ankunft %sum %s',
			$journey->{km_route}, $journey->{type}, $journey->{no},
			$delay, $journey->{rt_arrival}->strftime('%H:%M') );
	}
	my %tw_data = (
		card  => 'summary',
		site  => '@derfnull',
		image => $self->url_for('/static/icons/icon-512x512.png')
		  ->to_abs->scheme('https'),
		title       => $title,
		description => $description,
	);
	my %og_data = (
		type        => 'article',
		image       => $tw_data{image},
		url         => $self->url_for->to_abs,
		site_name   => 'travelynx',
		title       => $title,
		description => $description,
	);

	my $map_data = $self->journeys_to_map_data(
		journeys       => [$journey],
		include_manual => 1,
	);
	if ( $journey->{user_data}{comment}
		and not $user->{comments_visible} )
	{
		delete $journey->{user_data}{comment};
	}
	$self->render(
		'journey',
		error              => undef,
		journey            => $journey,
		with_map           => 1,
		username           => $name,
		readonly           => 1,
		twitter            => \%tw_data,
		opengraph          => \%og_data,
		journey_visibility => $visibility,
		%{$map_data},
	);
}

sub user_status {
	my ($self) = @_;

	my $name = $self->stash('name');
	my $ts   = $self->stash('ts') // 0;
	my $user = $self->users->get_privacy_by_name( name => $name );

	if ( not $user ) {
		$self->render('not_found');
		return;
	}

	my $status = $self->get_user_status( $user->{id} );

	if (
		$ts
		and ( not $status->{checked_in}
			or $status->{sched_departure}->epoch != $ts )
	  )
	{
		for my $journey (
			$self->journeys->get(
				uid             => $user->{id},
				sched_dep_ts    => $ts,
				limit           => 1,
				with_visibility => 1,
			)
		  )
		{
			my $visibility
			  = $self->compute_effective_visibility(
				$user->{default_visibility_str},
				$journey->{visibility_str} );
			if (
				$visibility eq 'public'
				or (    $visibility eq 'unlisted'
					and $self->journey_token_ok( $journey, $ts ) )
				or (
					$visibility eq 'travelynx'
					and (  $self->is_user_authenticated
						or $self->journey_token_ok( $journey, $ts ) )
				)
			  )
			{
				my $token = $self->param('token') // q{};
				$self->redirect_to(
					"/p/${name}/j/$journey->{id}?token=${token}-${ts}");
			}
			else {
				$self->render('not_found');
			}
			return;
		}
		$self->render('not_found');
		return;
	}

	my %tw_data = (
		card  => 'summary',
		site  => '@derfnull',
		image => $self->url_for('/static/icons/icon-512x512.png')
		  ->to_abs->scheme('https'),
	);
	my %og_data = (
		type      => 'article',
		image     => $tw_data{image},
		url       => $self->url_for("/status/${name}")->to_abs->scheme('https'),
		site_name => 'travelynx',
	);

	my $visibility;
	if ( $status->{checked_in} or $status->{arr_name} ) {
		$visibility
		  = $self->compute_effective_visibility(
			$user->{default_visibility_str},
			$status->{visibility_str} );
		if (
			not(
				$visibility eq 'public'
				or (    $visibility eq 'unlisted'
					and $self->status_token_ok( $status, $ts ) )
				or (
					$visibility eq 'travelynx'
					and (  $self->is_user_authenticated
						or $self->status_token_ok( $status, $ts ) )
				)
			)
		  )
		{
			$status = {};
		}
	}
	if (    not $status->{checked_in}
		and $status->{arr_name}
		and not $user->{past_status} )
	{
		$status = {};
	}

	if ( $status->{checked_in} ) {
		$og_data{url} .= '/' . $status->{sched_departure}->epoch;
		$og_data{title}       = $tw_data{title}       = "${name} ist unterwegs";
		$og_data{description} = $tw_data{description} = sprintf(
			'%s %s von %s nach %s',
			$status->{train_type}, $status->{train_line} // $status->{train_no},
			$status->{dep_name},   $status->{arr_name}   // 'irgendwo'
		);
		if ( $status->{real_arrival}->epoch ) {
			$tw_data{description} .= $status->{real_arrival}
			  ->strftime(' – Ankunft gegen %H:%M Uhr');
			$og_data{description} .= $status->{real_arrival}
			  ->strftime(' – Ankunft gegen %H:%M Uhr');
		}
	}
	else {
		$og_data{title} = $tw_data{title}
		  = "${name} ist gerade nicht eingecheckt";
		$og_data{description} = $tw_data{description} = q{};
	}

	$self->respond_to(
		json => {
			json => {
				name   => $name,
				status => $self->get_user_status_json_v1(
					status => $status,
					public => 1
				),
				version => $self->app->config->{version} // 'UNKNOWN',
			},
		},
		any => {
			template           => 'user_status',
			name               => $name,
			public_level       => $user->{public_level},
			journey            => $status,
			journey_visibility => $visibility,
			twitter            => \%tw_data,
			opengraph          => \%og_data,
			version            => $self->app->config->{version} // 'UNKNOWN',
		},
	);
}

sub status_card {
	my ($self) = @_;

	my $name = $self->stash('name');
	$name =~ s{[.]html$}{};
	my $user = $self->users->get_privacy_by_name( name => $name );

	delete $self->stash->{layout};

	if ( not $user ) {
		$self->render('not_found');
		return;
	}

	my $status = $self->get_user_status( $user->{id} );
	my $visibility;
	if ( $status->{checked_in} or $status->{arr_name} ) {
		$visibility
		  = $self->compute_effective_visibility(
			$user->{default_visibility_str},
			$status->{visibility_str} );
		if (
			not(
				$visibility eq 'public'
				or (    $visibility eq 'unlisted'
					and $self->status_token_ok($status) )
				or (
					$visibility eq 'travelynx'
					and (  $self->is_user_authenticated
						or $self->status_token_ok($status) )
				)
			)
		  )
		{
			$status->{checked_in} = 0;
			$status->{arr_name}   = undef;
		}
	}
	if (    not $status->{checked_in}
		and $status->{arr_name}
		and not $user->{past_status} )
	{
		$status->{arr_name} = undef;
	}

	$self->render(
		'_public_status_card',
		name               => $name,
		public_level       => $user->{public_level},
		journey            => $status,
		journey_visibility => $visibility,
	);
}

1;
