use strict;
use warnings;
use Promised::Mysqld;
use AnyEvent;

my $mysql = Promised::Mysqld->new;
$mysql->my_cnf->{'pid-file'} = '/tmp/hoge.pid';
$mysql->my_cnf->{'socket'} = '/tmp/hoge.sock';

my $cv = AE::cv;
$mysql->start->then (sub {
  warn "started";
}, sub {
  warn "Error: $_[0]";
})->then (sub {
  $mysql->stop;
})->catch (sub {
  warn "error: $_[0]";
})->then (sub {
  warn "stopped";
  $cv->send;
});

$cv->recv;
