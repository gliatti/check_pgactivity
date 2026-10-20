#!/usr/bin/perl
# This program is open source, licensed under the PostgreSQL License.
# For license terms, see the LICENSE file.
#
# Copyright (C) 2012-2026: Open PostgreSQL Monitoring Development Group

use strict;
use warnings;

use lib 't/lib';
use TestLib ();
use pgNode;
use Test::More;

my $node      = pgNode->get_new_node('prod');
my $pga_data = "$TestLib::tmp_check/pga.data";
my $wal;
my @stdout;
my $num_tests = 43;

$node->init(has_archiving => 1);

if ( $node->version >= 9.6 ) {
    $node->append_conf('postgresql.conf', "wal_level = replica");
}
elsif ( $node->version >= 9.0 ) {
    $node->append_conf('postgresql.conf', "wal_level = archive");
}

$node->start;

$num_tests-- if $node->version < 11;
plan tests => $num_tests;

### Beginning of tests ###

# generate one archive
# split create table and insert to produce more data in WAL
$node->psql('template1', 'create table t (i int primary key)');
$node->psql('template1', 'insert into t select generate_series(1,10000) as i');
$wal = $node->switch_wal;


# The WAL sequence starts at 000000010000000000000000 up to v8.4, then
# 000000010000000000000001 starting from v9.0.
# Make sure we have the exact same archive sequence whatever the version so
# following tests apply no matter the version.
if ($node->version < 9.0) {
    $node->psql('template1', 'insert into t select generate_series(-1000,0) as i');
    $wal = $node->switch_wal;
}

# FIXME: there's a race condition in archiver check when it get the mtime
# of the next WAL to archive while it hasn't been created yet.
# Write a checkpoint to force the creation of the new WAL.
$node->psql('template1', 'checkpoint');

$node->wait_for_archive($wal);

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'archiver',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--status-file' => $pga_data,
                          '--format'      => 'human'
    ],
    0,
    [
        qr/^Service  *: POSTGRES_ARCHIVER$/m,
        qr/^Returns  *: 0 \(OK\)$/m,
        qr/^Message  *: 0 WAL files ready to archive$/m,
        qr/^Perfdata *: ready_archive=0 min=0$/m,
        qr/^Perfdata *: oldest_ready_wal=0s min=0$/m
    ],
    [ qr/^$/ ],
    'basic check without thresholds with superuser'
);

# thresholds must both be raw numbers
foreach my $thresholds ( [ '50%', '10' ], [ '5', '10%' ] ) {
    $node->command_checks_all( [
        './check_pgactivity', '--service'     => 'archiver',
                              '--username'    => $ENV{'USER'} || 'postgres',
                              '--status-file' => $pga_data,
                              '--format'      => 'human',
                              '--warning'     => $thresholds->[0],
                              '--critical'    => $thresholds->[1]
        ],
        127,
        [ qr/^$/ ],
        [ qr/^FATAL: critical and warning thresholds only accept raw numbers\.$/m ],
        "reject non raw threshold: -w $thresholds->[0] -c $thresholds->[1]"
    );
}

# archiver failing

$node->append_conf('postgresql.conf', "archive_command = 'false'");
$node->reload;

$node->psql('template1', 'insert into t select generate_series(10001,20000) as i');
$wal = $node->switch_wal;
# avoid same race condition
$node->psql('template1', 'checkpoint');

# FIXME: arbitrary sleep time to wait for archiver to fail at least one time
sleep 1;

# for 9.6 and before, the alert is raised on second call.
TestLib::system_or_bail('./check_pgactivity',
    '--service'     => 'archiver',
    '--username'    => $ENV{'USER'} || 'postgres',
    '--host'        => $node->host,
    '--port'        => $node->port,
    '--status-file' => $pga_data,
    '--format'      => 'human'
) if $node->version < 10;

@stdout = (
    qr/^Service      *: POSTGRES_ARCHIVER$/m,
    qr/^Returns      *: 2 \(CRITICAL\)$/m,
    qr/^Message      *: 1 WAL files ready to archive$/m,
    qr/^Message      *: archiver failing on 000000010000000000000002$/m,
    qr/^Long message *: 000000010000000000000002 not archived since (?:\ds|last check)$/m,
    qr/^Perfdata     *: ready_archive=1 min=0$/m,
    qr/^Perfdata     *: oldest_ready_wal=\ds min=0$/m
);

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'archiver',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--status-file' => $pga_data,
                          '--format'      => 'human'
    ],
    2,
    \@stdout,
    [ qr/^$/ ],
    'failing archiver with superuser'
);

# For PostgreSQL 10+, we now create a non-superuser monitoring role
SKIP: {
    skip "checking with non superuser role is not supported before v10", 8
        if $node->version < 10;

    $node->psql('postgres', 'create role check_pga login');
    $node->psql('postgres', 'grant pg_monitor to check_pga');
    $node->psql('postgres', 'grant execute on function pg_catalog.pg_stat_file(text,boolean) to check_pga');

    # With pg10, the perfdata oldest_ready_wal cannot be computed, thus is not
    # present in the perfdata.
    @stdout = (
        qr/^Service      *: POSTGRES_ARCHIVER$/m,
        qr/^Returns      *: 2 \(CRITICAL\)$/m,
        qr/^Message      *: 1 WAL files ready to archive$/m,
        qr/^Message      *: archiver failing on 000000010000000000000002$/m,
        qr/^Long message *: 000000010000000000000002 not archived since (?:\ds|last check)$/m,
        qr/^Perfdata     *: ready_archive=1 min=0$/m,
    );

    # For pg11+, oldest_ready_wal is always present.
    push @stdout, ( qr/^Perfdata     *: oldest_ready_wal=\ds min=0$/m )
      unless $node->version < 11;

    $node->command_checks_all( [
        './check_pgactivity', '--service'     => 'archiver',
                              '--username'    => 'check_pga',
                              '--status-file' => $pga_data,
                              '--format'      => 'human'
        ],
        2,
        \@stdout,
        [ qr/^$/ ],
        'failing archiver with non-superuser'
    );
}

# Specific tests for PG9.4+, edge cases with pg_stat_archiver
# Covers issue #358 and #384
SKIP: {
    skip "checking with non superuser role is not supported before v10", 4
        if $node->version < '10';

    # repair archiving
    $node->append_conf('postgresql.conf', "archive_command = 'true'");
    $node->reload;
    sleep(1);
    # Turn archiving off, pg_stat_archiver remains
    # see issue #358 and #384
    $node->stop;
    $node->append_conf('postgresql.conf', "archive_mode = 'off'");
    $node->start;
    $node->psql('template1', 'insert into t select generate_series(20001,30000) as i');
    $wal = $node->switch_wal;

    # Current behavior is to bail out an error "could not stat file"

    $node->command_checks_all( [
        './check_pgactivity', '--service'     => 'archiver',
                              '--username'    => $ENV{'USER'} || 'postgres',
                              '--status-file' => $pga_data,
                              '--format'      => 'human'
        ],
        0,
        [
          # Should not return an error in this case
          qr/^Service  *: POSTGRES_ARCHIVER$/m,
          qr/^Returns  *: 0 \(OK\)$/m,
        ],
        [ qr/^$/ ],
        'do not bail out when archiver is off'
    );

}

# Archiving failing since the very beginning: pg_stat_archiver has no
# last_archived_wal, the number of WAL files ready to archive must be computed
# from last_failed_wal.
SKIP: {
    skip "pg_stat_archiver based check is only used from v10", 8
        if $node->version < 10;

    my $node2 = pgNode->get_new_node('never_archived');

    $node2->init(has_archiving => 1);
    $node2->append_conf('postgresql.conf', "wal_level = replica");
    $node2->append_conf('postgresql.conf', "archive_command = 'false'");
    $node2->start;

    $node2->psql('template1', 'create table t (i int primary key)');
    $node2->psql('template1', 'insert into t select generate_series(1,10000) as i');
    $node2->switch_wal;
    $node2->psql('template1', 'insert into t select generate_series(10001,20000) as i');
    $node2->switch_wal;
    # avoid same race condition
    $node2->psql('template1', 'checkpoint');

    # FIXME: arbitrary sleep time to wait for archiver to fail at least one time
    sleep 1;

    $node2->command_checks_all( [
        './check_pgactivity', '--service'     => 'archiver',
                              '--username'    => $ENV{'USER'} || 'postgres',
                              '--status-file' => "$TestLib::tmp_check/pga2.data",
                              '--format'      => 'human'
        ],
        2,
        [
            qr/^Service      *: POSTGRES_ARCHIVER$/m,
            qr/^Returns      *: 2 \(CRITICAL\)$/m,
            qr/^Message      *: 2 WAL files ready to archive$/m,
            qr/^Message      *: archiver failing on 000000010000000000000001$/m,
            qr/^Perfdata     *: ready_archive=2 min=0$/m,
            qr/^Perfdata     *: oldest_ready_wal=\d+s min=0$/m
        ],
        [ qr/^$/ ],
        'failing archiver without any WAL ever archived'
    );

    $node2->stop( 'immediate' );
}

### End of tests ###

$node->stop( 'immediate' );
