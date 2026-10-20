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
use Test::More tests => 29;

my $node = pgNode->get_new_node('prod');
my $pga_data = "$TestLib::tmp_check/pga.data";

$node->init;
$node->start;

### Beginning of tests ###

# First check. Returns no perfdata
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'database_size',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
    ],
    0,
    [
      qr/^Service  *: POSTGRES_DB_SIZE$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: [0-9]+ database\(s\) checked$/m,
      qr/^Perfdata *: template1=.*$/m,
    ],
    [ qr/^$/ ],
    'first basic check'
);

# build the command line with the given status file and extra arguments
sub pga_cmd {
    my $status_file = shift;
    return [
        './check_pgactivity', '--service'     => 'database_size',
                              '--username'    => $ENV{'USER'} || 'postgres',
                              '--format'      => 'human',
                              '--status-file' => $status_file,
                              @_
    ];
}

# The size threshold is checked on first call too
$node->command_checks_all(
    pga_cmd( "$TestLib::tmp_check/pga_first.data",
        '--warning' => 'size=1', '--critical' => 'size=1TB' ),
    1,
    [
      qr/^Returns  *: 1 \(WARNING\)$/m,
      qr/^Message  *: template1 \(size: /m,
    ],
    [ qr/^$/ ],
    'size threshold on first call'
);

# "o" is accepted as a unit, as "B"
$node->command_checks_all(
    pga_cmd( $pga_data,
        '--warning' => 'size=1o', '--critical' => 'size=1099511627776o' ),
    1,
    [ qr/^Returns  *: 1 \(WARNING\)$/m ],
    [ qr/^$/ ],
    'size threshold with "o" unit'
);

# Labels are case insensitive
$node->command_checks_all(
    pga_cmd( $pga_data, '--warning' => 'Size=1', '--critical' => 'SIZE=1TB' ),
    1,
    [ qr/^Returns  *: 1 \(WARNING\)$/m ],
    [ qr/^$/ ],
    'case insensitive labels'
);

# Non integer delta thresholds are refused, with or without label
$node->command_checks_all(
    pga_cmd( $pga_data, '--warning' => 'delta=0.5%', '--critical' => 'delta=1%' ),
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: Delta threshold only accept an integer/m ],
    'non integer delta threshold'
);

$node->command_checks_all(
    pga_cmd( $pga_data, '--warning' => '0.5%', '--critical' => '1%' ),
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: Delta threshold only accept an integer/m ],
    'non integer delta threshold without label'
);

# A null delta threshold does not raise an alert without variation...
$node->command_checks_all(
    pga_cmd( $pga_data, '--warning' => 'delta=0', '--critical' => 'delta=1TB' ),
    0,
    [ qr/^Returns  *: 0 \(OK\)$/m ],
    [ qr/^$/ ],
    'null delta threshold without variation'
);

# ...but raises one on any variation
$node->psql('postgres', 'CREATE TABLE t AS SELECT generate_series(1, 10000) AS i');

$node->command_checks_all(
    pga_cmd( $pga_data, '--warning' => 'delta=0', '--critical' => 'delta=1TB' ),
    1,
    [
      qr/^Returns  *: 1 \(WARNING\)$/m,
      qr/^Message  *: postgres \(delta: /m,
    ],
    [ qr/^$/ ],
    'null delta threshold with variation'
);

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
