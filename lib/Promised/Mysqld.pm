package Promised::Mysqld;
use strict;
use warnings;
our $VERSION = '1.0';
use Cwd qw(abs_path);
use File::Temp;
use AnyEvent;
use Promise;
use Promised::Flow;
use Promised::Command;
use Promised::Command::Signals;
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
  for ('/usr/local/opt/mysql/bin', # homebrew
       (split /:/, $ENV{PATH} || ''), '/usr/local/mysql/bin') {
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

sub set_mysqld_and_mysql_install_db ($$$) {
  $_[0]->{mysqld} = $_[1] // die "|mysqld| is not specified";
  $_[0]->{mysql_install_db} = $_[2] // die "|mysql_install_db| is not specified";
} # set_msqld_and_mysql_install_db

sub set_db_dir ($$) {
  $_[0]->{db_dir} = $_[1];
} # set_db_dir

sub my_cnf ($) {
  return $_[0]->{my_cnf} ||= {
    'skip-networking' => undef,
    'innodb_lock_wait_timeout' => 2,
    'max_connections' => 1000,
    sql_mode => '', # old default; 5.6 default is: NO_ENGINE_SUBSTITUTION,STRICT_TRANS_TABLES
  };
} # my_cnf

sub _create_my_cnf ($) {
  my $self = $_[0];
  my $db_dir = $self->{db_dir};
  my $my_cnf = {%{$self->my_cnf}};
  $self->{pid_file} = $my_cnf->{'pid-file'} //= "$db_dir/tmp/mysqld.pid";
  $self->{socket_file} = $my_cnf->{socket} //= "$db_dir/tmp/mysql.sock";
  $self->{datadir} = $my_cnf->{datadir} //= "$db_dir/var";
  $my_cnf->{tmpdir} //= "$db_dir/tmp";
  my $my_cnf_text = join "\x0A", '[mysqld]', (map {
    my $v = $my_cnf->{$_};
    (defined $v) ? "$_=$v" : $_;
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
  return $_[0]->{start_timeout} || 30;
} # start_timeout

sub _create_mysql_db ($) {
  my $self = $_[0];
  my $db_dir = $self->{db_dir};
  return Promise->resolve if -d "$db_dir/var/mysql";

  ## <http://dev.mysql.com/doc/refman/5.7/en/mysql-install-db.html>
  ## XXX "mysql_install_db is deprecated as of MySQL 5.7.6 because its
  ## functionality has been integrated into mysqld, the MySQL server."
  my $base_dir = $self->{mysql_install_db};
  $base_dir =~ s{[^/]+\z}{};
  $base_dir =~ s{[^/]*/\z}{} or $base_dir =~ s{/?\z}{/..};
  $base_dir =~ s{(?!^)/\z}{};
  my $temp;
  my $run; $run = sub {
    my $with_insecure = shift;
    my $cmd = Promised::Command->new ([
      $self->{mysql_install_db},
      '--defaults-file=' . $self->{my_cnf_file},
      '--basedir=' . $base_dir,
      '--datadir=' . $self->{datadir}, # set by _create_mysql_cnf
      ($with_insecure ? ('--insecure') : ()),
      '--verbose',
    ]);
    ## In some environment, |mysql_install_db| is a Perl script, which
    ## might depend on system's Perl XS modules.
    $cmd->envs->{PERL5LIB} = '';
    $cmd->envs->{PERL5OPT} = '';
    my $stdout = '';
    my $stderr = '';
    $cmd->stdout (sub {
      return unless defined $_[0];
      print STDERR $_[0];
      $stdout .= $_[0];
    });
    $cmd->stderr (sub {
      return unless defined $_[0];
      print STDERR $_[0];
      $stderr .= $_[0];
    });
    return $cmd->run->then (sub { $cmd->wait })->catch (sub {
      return $_[0] if UNIVERSAL::isa ($_[0], 'Promised::Command::Result');
      die $_[0];
    })->then (sub {
      if ($with_insecure and
          ($stdout =~ /unknown option '--insecure'/ or
           $stderr =~ /unknown option '--insecure'/)) {
        warn "Retry |mysql_install_db| without |--insecure| option...\n";
        return $run->(0);
      }
      if (not defined $temp and
          ($stdout =~ /FATAL ERROR: Could not find my-default.cnf/ or
           $stderr =~ /FATAL ERROR: Could not find my-default.cnf/)) {
        $temp = File::Temp->newdir;
        return Promised::File->new_from_path ("$temp/my-default.cnf")->write_byte_string ('')->then (sub {
          my $abs_base_dir = abs_path $base_dir;
          my $ln = sub {
            my $cmd = Promised::Command->new
                (['ln', '-s', "$abs_base_dir/$_[0]"]);
            $cmd->wd ($temp);
            return $cmd->run->then (sub {
              return $cmd->wait;
            })->then (sub {
              my $result = $_[0];
              die $result unless $result->exit_code == 0;
            });
          }; # $ln
          return Promise->all ([
            $ln->("bin"),
            $ln->("sbin"),
            $ln->("share"),
          ]);
        })->then (sub {
          warn "Retrying with virtual basedir |$temp| (instead of |$base_dir|)...\n";
          $base_dir = $temp;
          return $run->($with_insecure);
        });
      }
      unless ($_[0]->is_success and $_[0]->exit_code == 0) {
        die "|mysql_install_db| failed: $_[0]";
      }
    });
  }; # $run;
  return $run->(1)->then (sub {
    undef $run;
  }, sub {
    undef $run;
    die $_[0];
  });
} # _create_mysql_db

sub start ($) {
  my $self = $_[0];
  return Promise->new (sub {
    die "mysqld already started" if defined $self->{cmd};

    $self->{db_dir_debug} = $ENV{PROMISED_MYSQLD_DEBUG};
    $self->_find_mysql or die "|mysqld| and/or |mysql_install_db| not found";
    my $db_dir = defined $self->{db_dir} ? $self->{db_dir} : do {
      $self->{tempdir} = File::Temp->newdir (CLEANUP => !$self->{db_dir_debug});
      ''.$self->{tempdir};
    };
    my $dir = Promised::File->new_from_path ($db_dir);
    $_[0]->($dir->mkpath->then (sub {
      $self->{db_dir} = abs_path $db_dir;
    }));
  })->then (sub {
    $self->{start_pid} = $$;
    $self->{my_cnf_file} = "$self->{db_dir}/etc/my.cnf";

    if ($self->{db_dir_debug}) {
      AE::log alert => "Promised::Mysqld: Database directory is: $self->{db_dir}";
    }
    
    ## <http://dev.mysql.com/doc/refman/5.7/en/server-options.html>
    $self->{cmd} = Promised::Command->new
        ([$self->{mysqld},
          '--defaults-file=' . $self->{my_cnf_file},
          '--user=root']);
    my $stop_code = sub { return $self->stop };
    $self->{signals}->{$_} = Promised::Command::Signals->add_handler
        ($_ => $stop_code) for qw(TERM QUIT INT);
    $self->{cmd}->signal_before_destruction ('TERM');
    
    return $self->_create_my_cnf;
  })->then (sub {
    return $self->_create_mysql_db; # invoke after _create_my_cnf
  })->then (sub {
    my $pid_file = Promised::File->new_from_path ($self->{pid_file});
    return $pid_file->is_file->then (sub {
      if ($_[0]) {
        return $pid_file->read_byte_string->then (sub {
          my $pid = $_[0];
          $pid =~ s/[\x0D\x0A]+\z//g;
          if (eval { kill 0, $pid }) {
            kill 2, $pid; # SIGINT
            return promised_wait_until {
              kill 0, $pid;
            } timeout => 60;
          } else {
            return $pid_file->remove_tree;
          }
        });
      }
    });
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
          push @chk, Promised::File->new_from_path ($self->{socket_file})->stat->then (sub { -S $_[0] }, sub { 0 })
              if length $self->{socket_file};
          Promise->all (\@chk)->then (sub {
            unless (grep { not $_ } @{$_[0]}) {
              $ok->();
              undef $timer;
            } else {
              if ($try_count++ > $self->start_timeout / $interval) {
                $ng->("|mysqld| server failed to start (timeout)");
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
    })->catch (sub {
      my $error = $_[0];
      return $self->{cmd}->wait->then (sub { delete $self->{cmd}; die "$error - $_[0]" });
    });
  });
} # start

sub disconnect_clients ($) {
  my $self = $_[0];
  return Promise->all ([map {
    my $key = $_;
    $self->{client}->{$key}->disconnect->then (sub {
      delete $self->{client}->{$key};
    });
  } keys %{$self->{client} or {}}]);
} # disconnect_clients

sub stop ($) {
  my $self = $_[0];
  return $self->{stopped} ||= $self->disconnect_clients->then (sub {
    my $cmd = $self->{cmd};
    return unless defined $cmd;
    return Promise->resolve->then (sub {
      return $cmd->send_signal ('TERM');
    })->then (sub { return $cmd->wait })->then (sub {
      die "Failed to stop mysqld - $_[0]" unless $_[0]->exit_code == 0;
      delete $self->{cmd};
      delete $self->{signals};
      if ($self->{db_dir_debug}) {
        AE::log alert => "Promised::Mysqld: Database directory was: $self->{db_dir}";
      } else {
        return Promised::File->new_from_path ($self->{tempdir})->remove_tree
            if $self->{tempdir};
      }
      return;
    }, sub {
      die "Failed to stop mysqld - $_[0]";
    });
  });
} # stop

sub get_dsn_options ($) {
  my $self = $_[0];
  my $my_cnf = $self->my_cnf;
  my %args;
  $args{port} = $my_cnf->{port} if defined $my_cnf->{port};
  if (defined $args{port}) {
    $args{host} = $my_cnf->{'bind-address'} // '127.0.0.1';
  } else {
    $args{mysql_socket} = $self->{socket_file} if defined $self->{socket_file};
  }
  $args{user} ='root';
  #$args{password}
  $args{dbname} = 'mysql';
  return \%args;
} # get_dsn_options

sub get_dsn_string ($;%) {
  my ($self, %args) = @_;
  my %opt = %{$self->get_dsn_options};
  for (keys %args) {
    $opt{$_} = $args{$_} if defined $args{$_};
  }
  return 'DBI:mysql:' . join ';', map { "$_=$opt{$_}" } sort { $a cmp $b } keys %opt;
} # get_dsn_string

sub client_connect ($;%) {
  my ($self, %args) = @_;
  my $dbname = $args{dbname} // 'mysql';
  return Promise->resolve ($self->{client}->{$dbname})
      if defined $self->{client}->{$dbname};
  my $dsn = $self->get_dsn_options;
  return Promise->new (sub {
    my ($ok, $ng) = @_;
    require AnyEvent::MySQL::Client;
    require AnyEvent::MySQL::Client::ShowLog if $ENV{SQL_DEBUG};
    $self->{client}->{$dbname} = my $client = AnyEvent::MySQL::Client->new;
    my %connect;
    if (defined $dsn->{port}) {
      $connect{hostname} = $dsn->{host};
      $connect{port} = $dsn->{port};
    } else {
      $connect{hostname} = 'unix/';
      $connect{port} = $dsn->{mysql_socket};
    }
    $ok->($client->connect (
      %connect,
      username => $dsn->{user},
      password => $dsn->{password},
      database => $dbname,
    )->then (sub { return $client }));
  });
} # client_connect

sub create_db_and_execute_sqls ($$$) {
  my ($self, $dbname, $sqls) = @_;
  return $self->client_connect->then (sub {
    my $client_mysql = $_[0];
    my $escaped = $dbname;
    $escaped =~ s/`/``/g;
    return $client_mysql->query ("CREATE DATABASE IF NOT EXISTS `$escaped`");
  })->then (sub {
    return $self->client_connect (dbname => $dbname);
  })->then (sub {
    my $client = $_[0];
    my $p = Promise->resolve;
    for my $sql (@$sqls) {
      next unless $sql =~ /[^\x09\x0A\x0C\x0D\x20]/;
      $p = $p->then (sub {
        die $_[0] if defined $_[0] and not $_[0]->is_success;
        return $client->query ($sql);
      });
    }
    return $p->then (sub {
      die $_[0] if defined $_[0] and not $_[0]->is_success;
    });
  });
} # create_db_and_execute_sqls

sub DESTROY ($) {
  my $cmd = $_[0]->{cmd};
  if (defined $cmd and $cmd->running and
      defined $_[0]->{start_pid} and $_[0]->{start_pid} == $$) {
    $cmd->send_signal ('TERM');
  }
} # DESTROY

1;

=head1 LICENSE

Copyright 2015-2017 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
