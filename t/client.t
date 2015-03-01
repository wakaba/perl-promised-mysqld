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

run_tests;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
