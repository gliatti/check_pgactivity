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
use Time::HiRes qw(usleep gettimeofday tv_interval);
use Test::More tests => 19;

my $node = pgNode->get_new_node('prod');

$node->init;
$node->start;

### Beginning of tests ###

# basic check => Returns OK
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'configuration',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
    ],
    2,
    [ qr/^Service  *: POSTGRES_CONFIGURATION$/m,
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: fsync=off$/m,
    ],
    [ qr/^$/ ],
    'basic check'
);

# warnings are reported along with criticals
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'configuration',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--work_mem' => 1000000,
    ],
    2,
    [ qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: fsync=off$/m,
      qr/\bwork_mem=4096$/m,
    ],
    [ qr/^$/ ],
    'warnings along with criticals'
);

# C.* and POSIX are accepted for lc_messages
foreach my $lc ( 'C.UTF-8', 'POSIX' ) {
    $node->psql('postgres', "ALTER SYSTEM SET lc_messages = '$lc'");
    $node->reload;

    $node->command_checks_all( [
        './check_pgactivity', '--service'  => 'configuration',
                              '--username' => $ENV{'USER'} || 'postgres',
                              '--format'   => 'human',
                              '--exclude'  => '^(fsync|data_checksums)$',
        ],
        1,
        [ qr/\A(?!.*lc_messages)/s ],
        [ qr/^$/ ],
        "lc_messages=$lc"
    );
}

# negative thresholds are rejected
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'configuration',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--work_mem' => -1,
    ],
    127,
    [ qr/^$/ ],
    [ qr/FATAL: argument of --work_mem must be a positive integer/ ],
    'negative threshold'
);

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop( 'immediate' );
