use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->child ('t_deps/modules/*/lib');
use Test::More;
use Test::X1;
use Promised::Mysqld;
use Promised::Command;

test {
  my $c = shift;
  my $s = Promised::Mysqld->new;
  $s->start->then (sub {
    test {
      ok 1;
    } $c;
    return $s->stop;
  }, sub { test { ok 0 } $c })->then (sub {
    done $c;
    undef $c;
  });
} n => 1, name => 'start and stop';

test {
  my $c = shift;
  my $cmd = Promised::Command->new (['perl', '-e', q{
    use AnyEvent;
    my $cv = AE::cv;
    use Promised::Mysqld;
    my $s = Promised::Mysqld->new;
    $s->start->then (sub {
      print STDOUT "pid=", $s->{cmd}->pid, "\n";
      return $s->stop;
    })->then (sub {
      $cv->send;
    });
    $cv->recv;
    print STDOUT "end\n";
  }]);
  $cmd->stdout (\my $stdout);
  $cmd->run->then (sub {
    return $cmd->wait;
  })->then (sub {
    test {
      $stdout =~ m{^pid=([0-9]+)$}m;
      my $pid = $1;
      ok not kill 0, $pid;
      like $stdout, qr{\nend\n\z};
      done $c;
      undef $c;
    } $c;
  });
} n => 2, name => 'start and stop';

run_tests;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
