#!/usr/bin/perl
# This program is open source, licensed under the PostgreSQL License.
# For license terms, see the LICENSE file.
#
# Copyright (C) 2012-2026: Open PostgreSQL Monitoring Development Group

use strict;
use warnings;

use lib 't/lib';
use pgNode;
use TestLib ();
use Test::More tests => 28;

my $node = pgNode->get_new_node('prod');
my $pga_data = "$TestLib::tmp_check/pga.data";

$node->init;
$node->start;

### Beginning of tests ###

# First check. Returns no perfdata
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'commit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
    ],
    0,
    [
      qr/^Service  *: POSTGRES_COMMIT_RATIO$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: First call$/m,
    ],
    [ qr/^$/ ],
    'first basic check'
);

# Second check. Returns OK
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'commit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
    ],
    0,
    [
      qr/^Service  *: POSTGRES_COMMIT_RATIO$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: Commits: [0-9]+ - Rollbacks: [0-9]+$/m,
    ],
    [ qr/^$/ ],
    'second basic check'
);

# Labels are case insensitive
$node->psql('postgres', 'BEGIN; SELECT 1; ROLLBACK');

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'commit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => 'Rollbacks=0',
                          '--critical'    => 'ROLLBACKS=1000',
    ],
    1,
    [
      qr/^Service  *: POSTGRES_COMMIT_RATIO$/m,
      qr/^Returns  *: 1 \(WARNING\)$/m,
      qr/'postgres_rollbacks'=[1-9]/m,
    ],
    [ qr/^$/ ],
    'case insensitive labels'
);

# A database created since last call is ignored
$node->psql('postgres', 'CREATE DATABASE newdb');

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'commit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
    ],
    0,
    [
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/\A(?!.*newdb_)/s,
    ],
    [ qr/^$/ ],
    'database created since last call'
);

# A database whose statistics were reset since last call is ignored
$node->psql('postgres', 'SELECT pg_stat_reset()');

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'commit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
    ],
    0,
    [
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/\A(?!.*postgres_commit_rate)/s,
      qr/\A(?!.*=-)/s,
    ],
    [ qr/^$/ ],
    'statistics reset since last call'
);

# A statistics reset is detected even if the counters went beyond their
# previous values since then
$node->psql('postgres', 'SELECT pg_stat_reset()');
$node->psql('postgres', 'BEGIN; COMMIT; ' x 500 . 'BEGIN; ROLLBACK; ' x 50);

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'commit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
    ],
    0,
    [
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/\A(?!.*postgres_commit_rate)/s,
    ],
    [ qr/^$/ ],
    'statistics reset with counters beyond their previous values'
);

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
