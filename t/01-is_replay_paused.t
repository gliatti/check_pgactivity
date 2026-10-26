#!/usr/bin/perl
# This program is open source, licensed under the PostgreSQL License.
# For license terms, see the LICENSE file.
#
# Copyright (C) 2012-2026: Open PostgreSQL Monitoring Development Group

use strict;
use warnings;

use lib 't/lib';
use pgNode;
use pgSession;
use Test::More tests => 36;
use Time::HiRes qw(usleep gettimeofday tv_interval);

my $prim      = pgNode->get_new_node('prim');
my $stb1      = pgNode->get_new_node('sec1');
my $backup    = 'backup';
my $pgversion = $prim->version;

note "testing on version $pgversion";

# Tests for PostreSQL 9.0 and after
SKIP: {
    skip "these tests requires PostgreSQL 9.1 and after", 36
        unless $pgversion >= '9.0';

# create primary and start it
$prim->init(allows_streaming => 1);
$prim->start;
note("primary started: -h " . $prim->host . " -p " . $prim->port);

# create backup
$prim->backup($backup);
note("backup done");

# create standby from backup and start it
$stb1->init_from_backup($prim, $backup, has_streaming => 1);
$stb1->start;
note("standby 1 started: -h " . $stb1->host . " -p " . $stb1->port);

# checkpoint to avoid waiting long time for the standby to catchup
$prim->safe_psql('template1', 'CHECKPOINT');
$prim->wait_for_catchup($stb1, 'replay', $prim->lsn('insert'));


### Beginning of tests ###

note("Checking master, expecting UNKNOWN");
$prim->command_checks_all( [
    './check_pgactivity', '--service'  => 'is_replay_paused',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--host'     => $prim->host,
                          '--port'     => $prim->port,
    ],
    3,
    [ qr/^Service  *: POSTGRES_REPLICATION_PAUSED$/m,
      qr/^Returns  *: 3 \(UNKNOWN\)$/m,
      qr/^Message  *: Server is not standby./m,
    ],
    [ qr/^$/ ],
    'check on master'
);

note("Checking master perfdata: has_data_delta has no unit");
$prim->command_checks_all( [
    './check_pgactivity', '--service'  => 'is_replay_paused',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--host'     => $prim->host,
                          '--port'     => $prim->port,
    ],
    3,
    [ qr/ lag_time=NaNs /,
      qr/ has_data_delta=NaN$/m,
    ],
    [ qr/^$/ ],
    'perfdata on master'
);

note("Checking secondary (not paused), expecting OK");
$stb1->command_checks_all( [
    './check_pgactivity', '--service'  => 'is_replay_paused',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--host'     => $stb1->host,
                          '--port'     => $stb1->port
    ],
    0,
    [ qr/^Service  *: POSTGRES_REPLICATION_PAUSED$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *:  replay is not paused/m,
    ],
    [ qr/^$/ ],
    'replay not paused'
);

note ("Minimal activity to avoid a null replay timestamp");
my $proc = pgSession->new( $prim, 'postgres' );
$proc->query('CREATE TABLE t1() ; CHECKPOINT', 1);
note("Pausing secondary");
if ($pgversion >= 10) {
    $stb1->safe_psql('template1', 'SELECT pg_sleep(1), pg_wal_replay_pause()');
}
else {
    $stb1->safe_psql('template1', 'SELECT pg_sleep(1), pg_xlog_replay_pause()');
}
note ("Minimal activity to avoid a null data delta");
$proc->query('INSERT INTO t1 SELECT FROM pg_class', 1);

my $t0 = [gettimeofday]; ; usleep(100_000) while tv_interval($t0) < 5.1; # sleep

note("Checking secondary (paused), without -c -w , expecting OK");
$stb1->command_checks_all( [
    './check_pgactivity', '--service'  => 'is_replay_paused',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--host'     => $stb1->host,
                          '--port'     => $stb1->port
    ],
    0,
    [ qr/^Service  *: POSTGRES_REPLICATION_PAUSED$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *:  replay is paused/m,
    ],
    [ qr/^$/ ],
    'replay paused'
);

note("Checking secondary (paused), expecting WARNING");

$stb1->command_checks_all( [
    './check_pgactivity', '--service'  => 'is_replay_paused',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '1s',
                          '--critical' => '10s',
                          '--host'     => $stb1->host,
                          '--port'     => $stb1->port
    ],
    1,
    [ qr/^Service  *: POSTGRES_REPLICATION_PAUSED$/m,
      qr/^Returns  *: 1 \(WARNING\)$/m,
      qr/^Message  *:  replay lag time.*/m,
    ],
    [ qr/^$/ ],
    'replay paused, warning'
);

note("Checking secondary (paused), expecting CRITICAL");
#$proc->query('SELECT pg_sleep(1500)', 1500);
$t0 = [gettimeofday]; ; usleep(100_000) while tv_interval($t0) < 11.1; # sleep
$stb1->command_checks_all( [
    './check_pgactivity', '--service'  => 'is_replay_paused',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '1s',
                          '--critical' => '6s',
                          '--host'     => $stb1->host,
                          '--port'     => $stb1->port
    ],
    2,
    [ qr/^Service  *: POSTGRES_REPLICATION_PAUSED$/m,
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *:  replay lag time.*/m,
    ],
    [ qr/^$/ ],
    'replay paused, critical'
);

note("Checking secondary paused before replaying any transaction");
# no background activity may write a commit record on the primary
$prim->safe_psql('template1', 'ALTER SYSTEM SET autovacuum TO off');
$prim->safe_psql('template1', 'SELECT pg_reload_conf()');
$prim->backup('backup2');
my $stb2 = pgNode->get_new_node('sec2');
$stb2->init_from_backup($prim, 'backup2', has_streaming => 1);
$stb2->start;
$prim->wait_for_catchup($stb2, 'replay', $prim->lsn('insert'));
if ($pgversion >= 10) {
    $stb2->safe_psql('template1', 'SELECT pg_wal_replay_pause()');
}
else {
    $stb2->safe_psql('template1', 'SELECT pg_xlog_replay_pause()');
}
is( $stb2->safe_psql('template1',
        'SELECT pg_last_xact_replay_timestamp() IS NULL'),
    't', 'no transaction replayed on the secondary' );
$proc->query('INSERT INTO t1 SELECT FROM pg_class', 1);
$t0 = [gettimeofday]; ; usleep(100_000) while tv_interval($t0) < 3.1; # sleep

$stb2->command_checks_all( [
    './check_pgactivity', '--service'  => 'is_replay_paused',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '1s',
                          '--critical' => '2s',
                          '--host'     => $stb2->host,
                          '--port'     => $stb2->port
    ],
    3,
    [ qr/^Service  *: POSTGRES_REPLICATION_PAUSED$/m,
      qr/^Returns  *: 3 \(UNKNOWN\)$/m,
      qr/^Message  *:  replay is paused, but no transaction replayed yet/m,
      qr/^Perfdata  *: lag_time=NaNs$/m,
    ],
    [ qr/^$/ ],
    'replay paused, no transaction replayed'
);

$stb2->stop( 'immediate' );

### End of tests ###

# stop immediate to kill any remaining backends
$prim->stop( 'immediate' );

}
### End of tests ###
done_testing();
