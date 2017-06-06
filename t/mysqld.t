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
  $s->start_timeout (60);
  $s->start->then (sub {
    test {
      my $opts = $s->get_dsn_options;
      is $opts->{host}, undef;
      is $opts->{port}, undef;
      ok -S $opts->{mysql_socket};
      is $opts->{user}, 'root';
      is $opts->{password}, undef;
      is $opts->{dbname}, 'mysql';
      is $s->get_dsn_string, "DBI:mysql:dbname=mysql;mysql_socket=$opts->{mysql_socket};user=root";
      is $s->get_dsn_string (dbname => 'myapp', user => 'foo', password => 'bar'), "DBI:mysql:dbname=myapp;mysql_socket=$opts->{mysql_socket};password=bar;user=foo";
    } $c;
    return $s->stop;
  }, sub { test { ok 0 } $c })->then (sub {
    done $c;
    undef $c;
  });
} n => 8, name => 'start and stop';

test {
  my $c = shift;
  my $cmd = Promised::Command->new (['perl', '-e', q{
    use AnyEvent;
    my $cv = AE::cv;
    use Promised::Mysqld;
    my $s = Promised::Mysqld->new;
    $s->start_timeout (60);
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
  $s->start_timeout (60);
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
  }, sub { test { ok 0 } $c; warn $_[0] } )->then (sub {
    done $c;
    undef $c;
  });
} n => 2, name => 'db_dir removed';

test {
  my $c = shift;
  my $s = Promised::Mysqld->new;
  local $ENV{PROMISED_MYSQLD_DEBUG} = 1;
  $s->start_timeout (60);
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

test {
  my $c = shift;
  my $s = Promised::Mysqld->new;
  my $db_dir = path (__FILE__)->parent->parent->child ('local/test/dbdir/' . $$ . int rand 1000);
  $s->set_db_dir ($db_dir);
  $s->start_timeout (60);
  $s->start->then (sub {
    test {
      ok 1;
    } $c;
    return $s->stop;
  }, sub {
    my $error = $_[0];
    test {
      ok 0;
      is $error, undef;
    } $c, name => 'No exception expected';
  })->then (sub {
    my $dir = Promised::File->new_from_path ($s->{db_dir} || die);
    test {
      is path ($s->{db_dir})->absolute, $db_dir->absolute;
    } $c;
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
} n => 3, name => 'set_db_dir';

test {
  my $c = shift;
  my $s = Promised::Mysqld->new;
  my $db_dir = path (__FILE__)->parent->parent->child ('local/test/dbdir/' . $$ . int rand 1000);
  Promised::File->new_from_path ($db_dir)->write_byte_string ('')->then (sub {
    $s->set_db_dir ($db_dir);
    $s->start_timeout (60);
    return $s->start;
  })->then (sub { test { ok 0 } $c }, sub {
    my $error = $_[0];
    test {
      like $error, qr{\Q$db_dir\E}, $error;
    } $c, name => 'Exception expected';
    return $s->stop;
  })->then (sub {
    test {
      ok -f $db_dir, 'it is still a file';
    } $c;
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 2, name => 'set_db_dir mkdir error';

test {
  my $c = shift;
  my $mysqld = Promised::Mysqld->new;
  $mysqld->stop->then (sub {
    test {
      ok 1;
    } $c;
    done $c;
    undef $c;
  });
} n => 1, name => 'stop before start';

run_tests;

=head1 LICENSE

Copyright 2015-2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
