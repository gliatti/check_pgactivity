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
use Test::More tests => 41;

my $node = pgNode->get_new_node('prod');
my $pga_data = "$TestLib::tmp_check/pga.data";

$node->init;

$node->append_conf('postgresql.conf', 'stats_block_level = on')
    if $node->version < 8.3;

# A small cache, so that scanning a bigger table reads blocks outside of it
$node->append_conf('postgresql.conf', 'shared_buffers = 128kB');

$node->start;

# A table far bigger than shared_buffers: scanning it reads blocks outside of
# the cache, so the hit ratio is below 100%.
$node->psql('postgres',
    'CREATE TABLE t AS SELECT i, repeat(\'x\', 100) AS v FROM generate_series(1, 100000) i');

sub read_blocks {
    $node->psql('postgres', 'SELECT count(*) FROM t;' x shift);
}

### Beginning of tests ###

# Check thresholds only accept percentages
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '101',
                          '--critical'    => '0'
    ],
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: critical and warning thresholds only accept percentages between 0 and 100.$/m ],
    'Check percentage thresholds'
);

# Thresholds above 100%
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '150%',
                          '--critical'    => '90%'
    ],
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: critical and warning thresholds only accept percentages between 0 and 100.$/m ],
    'Check thresholds above 100%'
);

# Malformed percentage
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '95%',
                          '--critical'    => '1.2.3%'
    ],
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: critical and warning thresholds only accept percentages between 0 and 100.$/m ],
    'Check malformed percentage'
);

# Warning lower than critical: an alert is raised below the threshold
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '80%',
                          '--critical'    => '90%'
    ],
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: warning threshold must be greater than or equal to the critical one.$/m ],
    'Check warning lower than critical'
);

# First check. Returns no perfdata
# Even with strict thresholds, no alert is possible during the first call
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '100%',
                          '--critical'    => '100%'
    ],
    0,
    [
      qr/^Service  *: POSTGRES_HIT_RATIO$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: 1 database\(s\) checked$/m,
    ],
    [ qr/^$/ ],
    'first basic check'
);

read_blocks(3);

# Strict warning threshold to trigger a warning
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '100%',
                          '--critical'    => '0%'
    ],
    1,
    [ qr/^Service  *: POSTGRES_HIT_RATIO$/m,
      qr/^Returns  *: 1 \(WARNING\)$/m,
      qr/^Message  *: postgres: [\d.]+%$/m,
      qr/^Perfdata *: postgres=[\d.]+% warn=100 crit=0$/m,
    ],
    [ qr/^$/ ],
    'Warning check'
);

read_blocks(3);

# Strict critical threshold to trigger a critical
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '100%',
                          '--critical'    => '100%'
    ],
    2,
    [ qr/^Service  *: POSTGRES_HIT_RATIO$/m,
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: postgres: [\d.]+%$/m,
      qr/^Perfdata *: postgres=[\d.]+% warn=100 crit=100$/m,
    ],
    [ qr/^$/ ],
    'Critical check'
);

# A database whose statistics were reset since last call is ignored, even
# with strict thresholds
$node->psql('postgres', 'SELECT pg_stat_reset()');

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '100%',
                          '--critical'    => '100%'
    ],
    0,
    [ qr/^Returns  *: 0 \(OK\)$/m,
      qr/\A(?!.*postgres=)/s,
    ],
    [ qr/^$/ ],
    'statistics reset since last call'
);

# A statistics reset is detected even if the counters went beyond their
# previous values since then
$node->psql('postgres', 'SELECT pg_stat_reset()');
read_blocks(10);

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '100%',
                          '--critical'    => '100%'
    ],
    0,
    [ qr/^Returns  *: 0 \(OK\)$/m,
      qr/\A(?!.*postgres=)/s,
    ],
    [ qr/^$/ ],
    'statistics reset with counters beyond their previous values'
);

read_blocks(3);

# The database is checked again on the next call
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'hit_ratio',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--warning'     => '100%',
                          '--critical'    => '100%'
    ],
    2,
    [ qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Perfdata *: postgres=[\d.]+% warn=100 crit=100$/m,
    ],
    [ qr/^$/ ],
    'checked again after a statistics reset'
);

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
