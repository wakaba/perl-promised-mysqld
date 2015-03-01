use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->child ('t_deps/modules/*/lib');
use Test::More;
use Test::X1;
use Promised::Mysqld;
use Promised::Command;
use Promised::File;

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
    }, sub {
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
      ok defined $pid && not kill 0, $pid, $pid;
      like $stdout, qr{\nend\n\z};
    } $c;
  }, sub { test { ok 0 } $c })->then (sub {
    done $c;
    undef $c;
  });
} n => 2, name => 'start and stop';

test {
  my $c = shift;
  my $s = Promised::Mysqld->new;
  $s->set_mysqld_and_mysql_install_db ('mysqld/not/found', 'mysql_install_db');
  $s->start->then (sub {
    test {
      ok 0;
    } $c;
    return $s->stop;
  }, sub {
    my $error = $_[0];
    test {
      ok $error;
    } $c;
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 1, name => 'start - mysqld not found';

test {
  my $c = shift;
  my $s = Promised::Mysqld->new;
  $s->start->then (sub {
    test {
      ok 1;
    } $c;
    return $s->stop;
  }, sub { test { ok 0 } $c })->then (sub {
    my $dir = Promised::File->new_from_path ($s->{db_dir} || die);
    return $dir->is_directory->then (sub {
      my $result = $_[0];
      test {
        ok not $result;
      } $c;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 2, name => 'db_dir removed';

test {
  my $c = shift;
  my $s = Promised::Mysqld->new;
  local $ENV{PROMISED_MYSQLD_DEBUG} = 1;
  $s->start->then (sub {
    test {
      ok 1;
    } $c;
    return $s->stop;
  }, sub { test { ok 0 } $c })->then (sub {
    my $dir = Promised::File->new_from_path ($s->{db_dir} || die);
    return $dir->is_directory->then (sub {
      my $result = $_[0];
      test {
        ok $result;
      } $c;
      return $dir->remove_tree if $result;
    });
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 2, name => 'debug - db_dir not removed';

run_tests;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
