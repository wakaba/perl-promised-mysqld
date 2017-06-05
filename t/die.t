use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->child ('t_deps/modules/*/lib');
use Test::More;
use Test::X1;
use Promised::Flow;
use Promised::Command;

test {
  my $c = shift;
  my $cmd = Promised::Command->new (['perl', '-e', q{
    use AnyEvent;
    use Promised::Mysqld;
    my $mysqld = Promised::Mysqld->new;
    my $cv = AE::cv;
    $mysqld->start->then (sub {
      warn "\npid=@{[$mysqld->{cmd}->pid]}\n";
      exit 0;
    }, sub {
      exit 1;
    });
    $cv->recv;
  }]);
  $cmd->stderr (\my $stderr);
  $cmd->run->then (sub {
    return $cmd->wait->then (sub {
      my $run = $_[0];
      test {
        is $run->exit_code, 0;
      } $c;
      return promised_sleep 3;
    });
  })->then (sub {
    $stderr =~ /\npid=([0-9]+)\n/;
    my $pid = $1;
    test {
      ok not kill 0, $pid;
    } $c;
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 2;

test {
  my $c = shift;
  my $cmd = Promised::Command->new (['perl', '-e', q{
    use AnyEvent;
    use Promised::Mysqld;
    our $mysqld = Promised::Mysqld->new;
    my $cv = AE::cv;
    $mysqld->start->then (sub {
      warn "\npid=@{[$mysqld->{cmd}->pid]}\n";
      $cv->send;
    }, sub {
      exit 1;
    });
    $cv->recv;
  }]);
  $cmd->stderr (\my $stderr);
  $cmd->run->then (sub {
    return $cmd->wait->then (sub {
      my $run = $_[0];
      test {
        is $run->exit_code, 0;
      } $c;
      return promised_sleep 3;
    });
  })->then (sub {
    $stderr =~ /\npid=([0-9]+)\n/;
    my $pid = $1;
    test {
      ok not kill 0, $pid;
    } $c;
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 2;

for my $signal (qw(INT TERM QUIT)) {
  test {
    my $c = shift;
    my $cmd = Promised::Command->new (['perl', '-e', q{
      use AnyEvent;
      use Promised::Mysqld;
      my $mysqld = Promised::Mysqld->new;
      my $cv = AE::cv;
      $mysqld->start->then (sub {
        warn "\npid=@{[$mysqld->{cmd}->pid]}\n";
        return $mysqld->{cmd}->wait->then (sub {
          $cv->send;
        }, sub {
          exit 2;
        });
      }, sub {
        exit 3;
      });
      $cv->recv;
    }]);
    $cmd->stderr (\my $stderr);
    $cmd->run->then (sub {
      return promised_wait_until {
        return (defined $stderr and $stderr =~ /^pid=[0-9]+$/m);
      } timeout => 60*3;
    })->catch (sub {
      test { ok 0 } $c;
      done $c;
      undef $c;
      die $_[0];
    })->then (sub {
      return $cmd->send_signal ($signal);
    })->then (sub {
      return $cmd->wait->catch (sub { });
    })->then (sub {
      $stderr =~ /^pid=([0-9]+)$/m;
      my $pid = $1;
      test {
        ok not kill 0, $pid;
      } $c;
    })->then (sub {
      done $c;
      undef $c;
    });
  } n => 1, name => $signal, timeout => 60*4;
}

run_tests;

=head1 LICENSE

Copyright 2015-2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
