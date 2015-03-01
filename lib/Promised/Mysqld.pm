package Promised::Mysqld;
use strict;
use warnings;
our $VERSION = '1.0';
use Cwd qw(abs_path);
use File::Temp;
use AnyEvent;
use Promise;
use Promised::Command;
use Promised::File;

sub new ($) {
  return bless {}, $_[0];
} # new

# /usr/sbin/mysqld             /usr/bin/mysql_install_db
# /usr/local/opt/mysql/bin/mysqld
# /usr/local/mysql/bin/mysqld /usr/local/mysql/bin/mysql_install_db
#                             /usr/local/mysql/scripts/mysql_install_db
# /usr/local/Cellar/mysql/5.../bin/mysql_install_db /usr/local/Cellar/mysql/5.../bin/mysql_install_db
sub _find_mysql ($) {
  my $self = $_[0];
  return 1 if defined $self->{mysqld} and defined $self->{mysql_install_db};
  for ((split /:/, $ENV{PATH} || ''), '/usr/local/mysql/bin') {
    my $dir = $_;
    $dir =~ s{[^/]*$}{};
    $dir = "." unless length $dir;
    my $mysqld;
    my $mysql_install_db;
    for (qw(sbin bin libexec scripts)) {
      $mysqld ||= "$dir$_/mysqld" if -x "$dir$_/mysqld";
      $mysql_install_db ||= "$dir$_/mysql_install_db"
          if -x "$dir$_/mysql_install_db";
    }
    if (defined $mysqld and defined $mysql_install_db) {
      $self->{mysqld} = $mysqld;
      $self->{mysql_install_db} = $mysql_install_db;
      return 1;
    }
  }
  return 0;
} # _find_mysql

sub mysqld ($$) {
  if (@_ > 1) {
    $_[0]->{mysqld} = $_[1];
  }
  die "Not implemented" if defined wantarray;
} # mysqld

sub mysql_install_db ($$) {
  if (@_ > 1) {
    $_[0]->{mysql_install_db} = $_[1];
  }
  die "Not implemented" if defined wantarray;
} # mysql_install_db

sub db_dir ($;$) {
  if (@_ > 1) {
    $_[0]->{db_dir} = $_[1];
  }
  die "Not implemented" if defined wantarray;
} # db_dir

sub my_cnf ($) {
  return $_[0]->{my_cnf} ||= {};
} # my_cnf

sub _create_my_cnf ($) {
  my $self = $_[0];
  my $db_dir = $self->{db_dir};
  my $my_cnf = {%{$self->my_cnf}};
  $self->{pid_file} = $my_cnf->{'pid-file'} //= "$db_dir/tmp/mysqld.pid";
  $self->{socket_file} = $my_cnf->{socket} //= "$db_dir/tmp/mysql.sock";
  $my_cnf->{datadir} //= "$db_dir/var";
  $my_cnf->{tmpdir} //= "$db_dir/tmp";
  my $my_cnf_text = join "\x0A", '[mysqld]', (map {
    my $v = $my_cnf->{$_};
    (defined $v and length $v) ? "$_=$v" : $_;
  } sort { $a cmp $b } keys %$my_cnf), '';

  my @p;
  for ($my_cnf->{'pid-file'}, $my_cnf->{socket}) {
    my $path = $_;
    $path =~ s{/[^/]+\z}{};
    push @p, Promised::File->new_from_path ($path)->mkpath;
  }
  push @p, Promised::File->new_from_path ($_)->mkpath
      for $my_cnf->{datadir}, $my_cnf->{tmpdir};
  push @p, Promised::File->new_from_path ($self->{my_cnf_file})
      ->write_char_string ($my_cnf_text);
  return Promise->all (\@p);
} # _create_my_cnf

sub start_timeout ($;$) {
  if (@_ > 1) {
    $_[0]->{start_timeout} = $_[1];
  }
  return $_[0]->{start_timeout} || 10;
} # start_timeout

sub _create_mysql_db ($) {
  my $self = $_[0];
  my $db_dir = $self->{db_dir};
  return Promise->resolve if -d "$db_dir/var/mysql";

  ## <http://dev.mysql.com/doc/refman/5.7/en/mysql-install-db.html>
  ## XXX "mysql_install_db is deprecated as of MySQL 5.7.6 because its
  ## functionality has been integrated into mysqld, the MySQL server."
  my $cmd = Promised::Command->new ([$self->{mysql_install_db}, '--defaults-file=' . $self->{my_cnf_file}]);
  return $cmd->run->then (sub { $cmd->wait })->then (sub {
    die "|mysql_install_db| failed: $_[0]"
        unless $_[0]->is_success and $_[0]->exit_code == 0;
  });
} # _create_mysql_db

sub start ($) {
  my $self = $_[0];
  return Promise->new (sub {
    die "mysqld already started" if defined $self->{cmd};

    $self->_find_mysql or die "|mysqld| and/or |mysql_install_db| not found";
    my $db_dir = defined $self->{db_dir} ? $self->{db_dir} : do {
      $self->{tempdir} = File::Temp->newdir (CLEANUP => !$ENV{PROMISED_MYSQLD_DEBUG});
      ''.$self->{tempdir};
    };
    $db_dir = abs_path ($db_dir);
    $self->{db_dir} = $db_dir;
    $self->{my_cnf_file} = "$db_dir/etc/my.cnf";
    $self->{mysqld_user} = getpwuid $>;

    if ($ENV{PROMISED_MYSQLD_DEBUG}) {
      AE::log alert => "Promised::Mysqld: Database directory is: $self->{db_dir}";
    }
    
    ## <http://dev.mysql.com/doc/refman/5.7/en/server-options.html>
    $self->{cmd} = Promised::Command->new
        ([$self->{mysqld},
          '--defaults-file=' . $self->{my_cnf_file},
          '--user=' . $self->{mysqld_user}]);
    
    $_[0]->($self->_create_my_cnf);
  })->then (sub {
    return $self->_create_mysql_db;
  })->then (sub {
    return $self->{cmd}->run;
  })->then (sub {
    return Promise->new (sub {
      my ($ok, $ng) = @_;
      my $try_count = 0;
      my $interval = 0.5;
      my $timer; $timer = AE::timer 0, $interval, sub {
        if ($self->{cmd}->running) {
          my @chk;
          push @chk, Promised::File->new_from_path ($self->{pid_file})->is_file;
          push @chk, Promised::File->new_from_path ($self->{socket_file})->stat->then (sub { -s $_[0] }, sub { 0 })
              if length $self->{socket_file};
          Promise->all (\@chk)->then (sub {
            unless (grep { not $_ } @{$_[0]}) {
              $ok->();
              undef $timer;
            } else {
              if ($try_count++ > $self->start_timeout / $interval) {
                $ng->("|mysqld| server failed to start");
              } else {
                #
              }
            }
          }, $ng);
        } else {
          $ng->("|mysqld| server failed to start");
          undef $timer;
        }
      };
    })->catch (sub { return $self->{cmd}->wait });
  });
} # start

sub stop ($) {
  my $self = $_[0];
  my $cmd = $self->{cmd};
  return Promise->reject ("Not yet started") unless defined $cmd;
  return $cmd->send_signal ('TERM')->then (sub { return $cmd->wait })->then (sub {
    if ($ENV{PROMISED_MYSQLD_DEBUG}) {
      AE::log alert => "Promised::Mysqld: Database directory was: $self->{db_dir}";
    } else {
      delete $self->{tempdir};
    }
  });
} # stop

1;

=head1 LICENSE

Copyright 2015 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
