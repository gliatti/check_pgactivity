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
use TestLib ();
use IPC::Run ();
use Test::More tests => 18;

my $node = pgNode->get_new_node('prod');
my @timer;
my @in;
my @out;
my @procs;

$node->init;
$node->start;

### Beginning of tests ###

# basic check
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'max_freeze_age',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--dbname'   => 'template1',
    ],
    0,
    [ qr/^Service  *: POSTGRES_MAX_FREEZE_AGE$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: oldest database is .* with age .*$/m,
      qr/^Perfdata *: postgres=.*$/m,
    ],
    [ qr/^$/ ],
    'basic check'
);


# all databases excluded: no database checked
$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'max_freeze_age',
                          '--username'  => $ENV{'USER'} || 'postgres',
                          '--format'    => 'human',
                          '--dbname'    => 'template1',
                          '--dbexclude' => 'postgres',
                          '--dbexclude' => 'template1',
    ],
    3,
    [ qr/^Service  *: POSTGRES_MAX_FREEZE_AGE$/m,
      qr/^Returns  *: 3 \(UNKNOWN\)$/m,
      qr/^Message  *: No database checked$/m,
    ],
    [ qr/^$/ ],
    'all databases excluded'
);

# percentage thresholds
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'max_freeze_age',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--dbname'   => 'template1',
                          '--warning'  => '105%',
                          '--critical' => '110%',
    ],
    0,
    [ qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Perfdata *: postgres=.* warn=210000000 crit=220000000$/m,
    ],
    [ qr/^$/ ],
    'percentage thresholds'
);

# decimal percentage thresholds are rejected
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'max_freeze_age',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--dbname'   => 'template1',
                          '--warning'  => '105.5%',
                          '--critical' => '110.5%',
    ],
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: critical and warning thresholds only accept raw numbers or %/m ],
    'decimal percentage thresholds rejected'
);



### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
