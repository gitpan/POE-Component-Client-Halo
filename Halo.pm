package POE::Component::Client::Halo;

use strict;

use vars qw($VERSION);
$VERSION = '0.1';

use Carp qw(croak);
use Socket;
use Time::HiRes qw(time);
use Data::Dumper;
use POE qw(Session Wheel::SocketFactory);

sub DEBUG ()  { 0 };

sub new {
    my $type = shift;
    my $self = bless {}, $type;

    croak "$type requires an event number of parameters" if @_ % 2;

    my %params = @_;

    my $alias = delete $params{Alias};
    $alias = 'halo' unless defined $alias;

    my $timeout = delete $params{Timeout};
    $timeout = 15 unless defined $timeout and $timeout >= 0;

    my $retry = delete $params{Retry};
    $retry = 2 unless defined $retry and $retry >= 0;

    croak "$type doesn't know these parameters: ", join(', ', sort(keys(%params))) if scalar(keys(%params));

    POE::Session->create(
        inline_states => {
            _start            => \&_start,
            info            => \&info,
            detail          => \&detail,

            got_socket        => \&got_socket,
            got_response        => \&got_response,
            response_timeout    => \&response_timeout,
            debug_heap        => \&debug_heap,

            got_error        => \&got_error,
        },
        args => [ $timeout, $retry, $alias ],
    );

    return $self;
}

sub got_error {
    my ($operation, $errnum, $errstr, $wheel_id, $heap) = @_[ARG0..ARG3,HEAP];
    warn "Wheel $wheel_id generated $operation error $errnum: $errstr\n";
    delete $heap->{w_jobs}->{$wheel_id}; # shut down that wheel
}

sub debug_heap {
    my ($kernel, $heap) = @_[KERNEL, HEAP];
    open(F, ">/tmp/halo-debug") || return;
    print F Dumper($heap);
    close(F) || return;
    $kernel->delay('debug_heap', 10);
}

sub _start {
    my ($kernel, $heap, $timeout, $retry, $alias) = @_[KERNEL, HEAP, ARG0..ARG3];
    $heap->{timeout} = $timeout;
    $heap->{retry} = $retry;
    $kernel->alias_set($alias);
    print STDERR "Halo object started.\n" if DEBUG;
    $kernel->yield('debug_heap') if DEBUG;
}

sub info {
    my ($kernel, $heap, $sender, $ip, $port, $postback) = @_[KERNEL, HEAP, SENDER, ARG0..ARG2];
    my ($identifier) = defined($_[ARG3]) ? $_[ARG3] : undef;
    print STDERR "Got request for $ip:$port info with postback $postback\n" if DEBUG;
    croak "IP address required to execute a query" unless defined $ip;
    croak "Port requred to execute a query" if !defined $port || $port !~ /^\d+$/;
    my $wheel = POE::Wheel::SocketFactory->new(
            RemoteAddress    => $ip,
            RemotePort    => $port,
            SocketProtocol    => 'udp',
            SuccessEvent    => 'got_socket',
            FailureEvent    => 'got_error',
    );
    $heap->{w_jobs}->{$wheel->ID()} = {
        ip        => $ip,
        port        => $port,
        postback    => $postback,
        session        => $sender->ID(),
        wheel        => $wheel,
        identifier    => $identifier,
        try        => 1,    # number of tries...
        action        => 'info',
    };
    return undef;
}

sub detail {
    my ($kernel, $heap, $sender, $ip, $port, $postback) = @_[KERNEL, HEAP, SENDER, ARG0..ARG2];
    my ($identifier) = defined($_[ARG3]) ? $_[ARG3] : undef;
    print STDERR "Got request for $ip:$port players with postback $postback\n" if DEBUG;
    croak "IP address required to execute a query" unless defined $ip;
    croak "Port requred to execute a query" if !defined $port || $port !~ /^\d+$/;
    my $wheel = POE::Wheel::SocketFactory->new(
            RemoteAddress    => $ip,
            RemotePort    => $port,
            SocketProtocol    => 'udp',
            SuccessEvent    => 'got_socket',
            FailureEvent    => 'got_error',
    );
    $heap->{w_jobs}->{$wheel->ID()} = {
        ip        => $ip,
        port        => $port,
        postback    => $postback,
        session        => $sender->ID(),
        wheel        => $wheel,
        identifier    => $identifier,
        try        => 1,    # number of tries...
        action        => 'detail',
    };
    return undef;
}

sub got_socket {
    my ($kernel, $heap, $socket, $wheelid) = @_[KERNEL, HEAP, ARG0, ARG3];

    $heap->{jobs}->{$socket} = delete($heap->{w_jobs}->{$wheelid});
    $kernel->select_read($socket, 'got_response');
    my $query = '';
    if($heap->{jobs}->{$socket}->{action} eq 'info') {
        $query = "\x9c\xb7\x70\x02\x0a\x01\x03\x08\x0a\x05\x06\x13\x33\x36\x0c\x00\x00";
    } elsif($heap->{jobs}->{$socket}->{action} eq 'detail') {
        $query = "\x33\x8f\x02\x00\xff\xff\xff";
    } else {
        die("Unknown action!");
    }
    send($socket, "\xFE\xFD\x00" . $query, 0);
    $heap->{jobs}->{$socket}->{timer} = $kernel->delay_set('response_timeout', $heap->{timeout}, $socket);
    print STDERR "Wheel $wheelid got socket and sent request\n" if DEBUG;
}

sub got_response {
    my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];

    my $action = $heap->{jobs}->{$socket}->{action};

    $kernel->select_read($socket);
    $kernel->alarm_remove($heap->{jobs}->{$socket}->{timer}) if defined $heap->{jobs}->{$socket}->{timer};
    delete $heap->{jobs}->{$socket}->{timer};
    my $rsock = recv($socket, my $response = '', 16384, 0);

    my %data;
    if($response eq '') {
        $data{ERROR} = 'DOWN';
    } elsif($action eq 'info') {
        $response = substr($response, 5);
        my @parts = split(/\x00/, $response);
        $data{'Hostname'} = $parts[0];
        $data{'Version'} = $parts[1];
        $data{'Players'} = $parts[2];
        $data{'MaxPlayers'} = $parts[3];
        $data{'Map'} = $parts[4];
        $data{'Mode'} = $parts[5];
        $data{'Password'} = $parts[6];
        $data{'Dedicated'} = $parts[7];
        $data{'Classic'} = $parts[8];
        $data{'Teamplay'} = $parts[9];
    } elsif($action eq 'detail') {
        $response =~ s/\x00+$//;
        my ($rules, $players, $score) = ($response =~ /^.{5}(.+?)\x00{3}[\x00-\x10](.+)\x00{2}[\x02\x00](.+$)/);
        my @parts = split(/\x00/, $response);
        %{$data{'Rules'}} = split(/\x00/, $rules);
        $data{'Players'} = process_segment($players);
        $data{'Score'} = process_segment($score);
    } else {
        die("Unknown request!");
    }

    $kernel->post($heap->{jobs}->{$socket}->{session}, 
              $heap->{jobs}->{$socket}->{postback}, 
              $heap->{jobs}->{$socket}->{ip},
              $heap->{jobs}->{$socket}->{port},
              $heap->{jobs}->{$socket}->{action},
              $heap->{jobs}->{$socket}->{identifier},
              \%data);
    delete($heap->{jobs}->{$socket});
}

sub response_timeout {
    my ($kernel, $heap, $socket) = @_[KERNEL, HEAP, ARG0];
    if($heap->{jobs}->{$socket}->{try} > ($heap->{retry} + 1)) {
        $kernel->post($heap->{jobs}->{$socket}->{session}, $heap->{jobs}->{$socket}->{postback},
                $heap->{jobs}->{$socket}->{ip},
                $heap->{jobs}->{$socket}->{port},
                $heap->{jobs}->{$socket}->{action},
                $heap->{jobs}->{$socket}->{identifier},
                { 'ERROR' => 'Timed out waiting for a response.'});
        delete($heap->{jobs}->{$socket});
    } else {
        print STDERR "Query timed out for $socket.  Retrying.\n" if DEBUG;
        my $query = '';
        if($heap->{jobs}->{$socket}->{action} eq 'info') {
            $query = "\x9c\xb7\x70\x02\x0a\x01\x03\x08\x0a\x05\x06\x13\x33\x36\x0c\x00\x00";
        } elsif($heap->{jobs}->{$socket}->{action} eq 'detail') {
            $query = "\x33\x8f\x02\x00\xff\xff\xff";
        } else {
            die("Unknown action!");
        }
        send($socket, "\xFE\xFD\x00" . $query, 0);
        $heap->{jobs}->{$socket}->{timer} = $kernel->delay_set('response_timeout', $heap->{timeout}, $socket);
        $heap->{jobs}->{$socket}->{try}++;
    }
}

sub process_segment {
    my $str = shift;

    my @parts = split(/\x00/, $str);
    my @fields = ();
    foreach(@parts) {
        last if $_ eq '';
        s/_.*$//;
        push(@fields, $_);
    }
    my $info = {};
    my $ctr = 0;
    my $cur_item = '';
    foreach(splice(@parts, scalar(@fields) + 1)) {
        if($ctr % scalar(@fields) == 0) {
            $cur_item = $_;
            $info->{$cur_item}->{$fields[0]} = $cur_item;
        } else {
            $info->{$cur_item}->{$fields[$ctr % scalar(@fields)]} = $_;
        }
        $ctr++;
    }
    return $info;
}

1;

__END__

=head1 NAME

  POE::Component::Client::Halo -- an implementation of the Halo query 
  protocol.

=head1 SYNOPSIS

  use Data::Dumper; # for the sample below
  use POE qw(Component::Client::Halo);

  my $halo = new POE::Component::Client::Halo(
        Alias => 'halo',
        Timeout => 15,
        Retry => 2,
  );

  $kernel->post('halo', 'info', '127.0.0.1', 2302, 'pbhandler', 'ident');

  $kernel->post('halo', 'detail', '127.0.0.1', 2302, 'pbhandler', 'ident');

  sub postback_handler {
      my ($ip, $port, $command, $identifier, $response) = @_;
      print "Halo query $command_executed on ";
      print " at $ip:$port";
      print " had a identifier of $identifier" if defined $identifier;
      print " returned from the server with:";
      print Dumper($response), "\n\n";
  }

=head1 DESCRIPTION

POE::Component::Client::Halo is an implementation of the Halo query 
protocol.  It was reverse engineered with a sniffer and two cups of 
coffee.  This is a preliminary release, based version 1.00.01.0580
of the dedicated server (the first public release).  It is capable
of handling multiple requests of different types in parallel.

PoCo::Client::Halo C<new> can take a few parameters:

=over 2

=item Alias => $alias_name

C<Alias> sets the name of the Halo component with which you will post events to.  By
default, this is 'halo'.

=item Timeout => $timeout_in_seconds

C<Timeout> specifies the number of seconds to wait for each step of the query procedure.
The number of steps varies depending on the server being accessed.

=item Retry => $number_of_times_to_retry

C<Retry> sets the number of times PoCo::Client::Halo should retry query requests.  Since
queries are UDP based, there is always the chance of your packets being dropped or lost.
After the number of retries has been exceeded, an error is posted back to the session
you specified to accept postbacks.

=back

=head1 EVENTS

You can send two types of events to PoCo::Client::Halo.

=over 2

=item info

This will request the basic info block from the Halo server.  In the 
postback, you will get 4 or 5 arguments, depending on whether or not
you had a postback.  ARG0 is the IP, ARG1 is the port, ARG3 is the
command (for info queries, this will always be 'info'), ARG4 is a
hashref with the returned data, and ARG5 is your unique identifier
as set during your original post.  Here are the fields you'll get 
back in ARG4:

=over 3

=item Map
=item Teamplay
=item Classic
=item Mode
=item MaxPlayers
=item Hostname
=item Password
=item Version
=item Dedicated
=item Players

=over 2

=item detail

This request more detailed information about the server, as well as
its rules, player information, and team score.  Like 'info', you'll 
get 4-5 arguments passed to your postback function.  ARG4 contains 
a HoHoH's:
  {
      'Score' => {
          'Red' => {
              'team' => 'Red',
              'score' => '17'
          },
          'Blue' => {
              'team' => 'Blue',
              'score' => '17'
          }
      },
      'Players' => {
          'ZETA' => {
              'score' => '0',
              'team' => '0',
              'ping' => '',
              'player' => 'ZETA'
          },
          'badmofo' => {
              'score' => '3',
              'team' => '0',
              'ping' => '',
              'player' => 'badmofo'
          },
      },
      'Rules' => {
          'gametype' => 'Slayer',
          'hostport' => '',
          'fraglimit' => '50',
          'mapname' => 'dangercanyon',
          'gamever' => '01.00.01.0580',
          'teamplay' => '1',
          'password' => '0',
          'game_flags' => '26',
          'player_flags' => '1941966980,2',
          'game_classic' => '0',
          'gamevariant' => 'Team Slayer',
          'gamemode' => 'openplaying',
          'hostname' => 'DivoNetworks',
          'maxplayers' => '16',
          'dedicated' => '1',
          'numplayers' => '2'
      }
  };
At the time of this module's release, ping information was not
available within the info packets.  They might be made public
later on, so I left them in the response.  I also haven't figured
how to decode the "player_flags" info yet.

=head1 ERRORS

The errors listed below are ones that will be posted back to you 
in the 'response' field.

=over 2

=item ERROR: Timed out waiting for response

Even after retrying, there was no response to your request command.

=back

There are other fatal errors that are handled with croak().

=head1 BUGS

=item
No tests are distributed with the module yet.  There is a sample,
though.

=head1 ACKNOWLEDGEMENTS

=item Rocco Caputo

Yay!

=item Divo Networks

Thanks for loaning me servers to test against.  They rent game servers
and can be found at http://www.divo.net/ .

=head1 AUTHOR & COPYRIGHTS

POE::Component::Client::Halo is Copyright 2001-2003 by Andrew A. Chen 
<achen-poe-halo@divo.net>.  All rights are reserved.  
POE::Component::Client::Halo is free software; you may redistribute it 
and/or modify it under the same terms as Perl itself.

=cut
