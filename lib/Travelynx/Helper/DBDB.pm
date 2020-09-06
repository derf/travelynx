package Travelynx::Helper::DBDB;

use strict;
use warnings;
use 5.020;

use Encode qw(decode);
use Mojo::Promise;
use JSON;

sub new {
	my ( $class, %opt ) = @_;

	my $version = $opt{version};

	$opt{header}
	  = { 'User-Agent' =>
"travelynx/${version} on $opt{root_url} +https://finalrewind.org/projects/travelynx"
	  };

	return bless( \%opt, $class );

}

sub has_wagonorder_p {
	my ( $self, $ts, $train_no ) = @_;
	my $api_ts = $ts->strftime('%Y%m%d%H%M');
	my $url
	  = "https://lib.finalrewind.org/dbdb/has_wagonorder/${train_no}/${api_ts}";
	my $cache   = $self->{cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->get($url) ) {
		if ( $content eq 'y' ) {
			$promise->resolve;
			return $promise;
		}
		elsif ( $content eq 'n' ) {
			$promise->reject;
			return $promise;
		}
	}

	$self->{user_agent}->request_timeout(5)->head_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;
			if ( $tx->result->is_success ) {
				$cache->set( $url, 'y' );
				$promise->resolve;
			}
			else {
				$cache->set( $url, 'n' );
				$promise->reject;
			}
		}
	)->catch(
		sub {
			$cache->set( $url, 'n' );
			$promise->reject;
		}
	)->wait;
	return $promise;
}

sub get_wagonorder_p {
	my ( $self, $ts, $train_no ) = @_;
	my $api_ts = $ts->strftime('%Y%m%d%H%M');
	my $url
	  = "https://www.apps-bahn.de/wr/wagenreihung/1.0/${train_no}/${api_ts}";

	my $cache   = $self->{cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;
			my $body = decode( 'utf-8', $tx->res->body );

			my $json = JSON->new->decode($body);
			$cache->freeze( $url, $json );
			$promise->resolve($json);
		}
	)->catch(
		sub {
			my ($err) = @_;
			$promise->reject($err);
		}
	)->wait;
	return $promise;
}

sub get_stationinfo_p {
	my ( $self, $eva ) = @_;

	my $url = "https://lib.finalrewind.org/dbdb/s/${eva}.json";

	my $cache   = $self->{cache};
	my $promise = Mojo::Promise->new;

	if ( my $content = $cache->thaw($url) ) {
		$promise->resolve($content);
		return $promise;
	}

	$self->{user_agent}->request_timeout(5)->get_p( $url => $self->{header} )
	  ->then(
		sub {
			my ($tx) = @_;

			if ( my $err = $tx->error ) {
				return $promise->reject("HTTP $err->{code} $err->{message}");
			}

			my $json = $tx->result->json;
			$cache->freeze( $url, $json );
			return $promise->resolve($json);
		}
	)->catch(
		sub {
			my ($err) = @_;
			return $promise->reject($err);
		}
	)->wait;
	return $promise;
}

1;
