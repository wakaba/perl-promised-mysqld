use strict;
use warnings;
use Path::Tiny;
use lib glob path (__FILE__)->parent->parent->child ('t_deps/modules/*/lib');
use Test::More;
use Test::X1;
use Promised::Mysqld;

test {
  my $c = shift;
  my $mysqld = Promised::Mysqld->new;
  $mysqld->start->then (sub {
    return $mysqld->client_connect->then (sub {
      my $client = $_[0];
      return $client->query ('CREATE DATABASE hoge');
    })->then (sub {
      my $got = [];
      return $mysqld->client_connect (dbname => 'hoge')->then (sub {
        my $client = $_[0];
        return $client->query ('SELECT DATABASE() AS db', sub {
          my $row = shift;
          my @col = map { $_->{name} } @{$row->column_packets};
          my $d = $row->packet->{data};
          my $data = {};
          $data->{$col[$_]} = $d->[$_] for 0..$#col;
          push @$got, $data;
        });
      })->then (sub {
        test {
          is_deeply $got, [{'db' => 'hoge'}];
        } $c;
      });
    })->then (sub {
      test {
        ok 1;
      } $c;
    });
  })->then (sub {
    return $mysqld->stop;
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 2;

test {
  my $c = shift;
  my $mysqld = Promised::Mysqld->new;
  $mysqld->start->then (sub {
    return $mysqld->create_db_and_execute_sqls ('fuga', [
      'CREATE TABLE abc (id int)',
      'INSERT INTO abc (id) VALUES (42)',
    ]);
  })->then (sub {
    return $mysqld->client_connect (dbname => 'fuga');
  })->then (sub {
    my $client = $_[0];
    my $got = [];
    return $client->query ('select * from abc', sub {
      my $row = shift;
      my @col = map { $_->{name} } @{$row->column_packets};
      my $d = $row->packet->{data};
      my $data = {};
      $data->{$col[$_]} = $d->[$_] for 0..$#col;
      push @$got, $data;
    })->then (sub {
      test {
        is_deeply $got, [{'id' => 42}];
      } $c;
    });
  })->catch (sub {
    warn $_[0];
    test { ok 0 } $c;
  })->then (sub {
    return $mysqld->stop;
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 1, name => 'create_db_and_execute_sqls';

test {
  my $c = shift;
  my $mysqld = Promised::Mysqld->new;
  $mysqld->start->then (sub {
    return $mysqld->create_db_and_execute_sqls ('fuga', [
      'CREATE TABLE abc (id int)',
      'INSERT INTO abc (id) VALUES (42)',
      'INSERT INTO xyz (id) VALUES (10)',
      'INSERT INTO abc (id) VALUES (10)',
    ]);
  })->catch (sub {
    my $result = $_[0];
    test {
      isa_ok $result, 'AnyEvent::MySQL::Client::Result';
      ok $result->is_failure;
    } $c;
  })->then (sub {
    return $mysqld->client_connect (dbname => 'fuga');
  })->then (sub {
    my $client = $_[0];
    my $got = [];
    return $client->query ('select * from abc', sub {
      my $row = shift;
      my @col = map { $_->{name} } @{$row->column_packets};
      my $d = $row->packet->{data};
      my $data = {};
      $data->{$col[$_]} = $d->[$_] for 0..$#col;
      push @$got, $data;
    })->then (sub {
      test {
        is_deeply $got, [{'id' => 42}];
      } $c;
    });
  })->catch (sub {
    warn $_[0];
    test { ok 0 } $c;
  })->then (sub {
    return $mysqld->stop;
  })->then (sub {
    done $c;
    undef $c;
  });
} n => 3, name => 'create_db_and_execute_sqls failure';

run_tests;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
