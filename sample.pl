#!/usr/bin/perl -w

use strict;
use Data::Dumper;
use POE qw(Component::Client::Halo);

if(scalar(@ARGV) < 2) {
	print STDERR "Usage: $0 ip[:port] (info|detail)\n";
	exit 1;
}

my ($ip, $port) = split(/\:/, $ARGV[0]);
$port = 2302 unless defined $port;
my $cmd = $ARGV[1];

POE::Session->create(
	inline_states => {
		_start	=> sub {
			my $heap = $_[HEAP];
			$heap->{halo} = new POE::Component::Client::Halo(
				Alias => 'halo',
				Timeout => 15,
				Retry => 1);
			$poe_kernel->post('halo', $cmd, $ip, $port, 'pb');
			},
		pb	=> sub {
			print Dumper($_[ARG4]), "\n";
		}
	}
);
$poe_kernel->run();
