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
use Test::More tests => 13;

my $node = pgNode->get_new_node('prod');

$node->init;
$node->start;

### Beginning of tests ###

# basic check => Returns OK
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'invalid_indexes',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '1',
                          '--critical' => '2',
    ],
    0,
    [ qr/^Service  *: POSTGRES_INVALID_INDEXES$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: No invalid index$/m,
    ],
    [ qr/^$/ ],
    'basic check'
);

SKIP: {
    skip "partitioned indexes are only available from v11", 8
        if $node->version < 11;

    # an index created with ON ONLY on a partitioned table stays invalid
    # until an index is attached for each partition
    $node->safe_psql( 'postgres', 'CREATE DATABASE app' );
    $node->safe_psql( 'app', q{
        CREATE TABLE p (i int) PARTITION BY RANGE (i);
        CREATE TABLE p1 PARTITION OF p FOR VALUES FROM (0) TO (10);
        CREATE INDEX p_idx ON ONLY p (i);
    });

    $node->command_checks_all( [
        './check_pgactivity', '--service'  => 'invalid_indexes',
                              '--username' => $ENV{'USER'} || 'postgres',
                              '--format'   => 'human',
        ],
        2,
        [ qr/^Returns  *: 2 \(CRITICAL\)$/m,
          qr/^Long message *: Invalid index = app\.public\.p_idx ; $/m,
        ],
        [ qr/^$/ ],
        'invalid partitioned index'
    );

    $node->command_checks_all( [
        './check_pgactivity', '--service'  => 'invalid_indexes',
                              '--username' => $ENV{'USER'} || 'postgres',
                              '--format'   => 'human',
                              '--exclude'  => '^app\.public\.p_idx$',
        ],
        0,
        [ qr/^Returns  *: 0 \(OK\)$/m,
          qr/^Long message *: 1 index\(es\) excluded from check$/m,
        ],
        [ qr/^$/ ],
        'excluded invalid partitioned index'
    );
}

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop( 'immediate' );
