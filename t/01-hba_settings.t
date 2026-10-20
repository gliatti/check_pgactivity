#!/usr/bin/perl
# This program is open source, licensed under the PostgreSQL License.
# For license terms, see the LICENSE file.
#
# Copyright (C) 2012-2026: Open PostgreSQL Monitoring Development Group

use strict;
use warnings;

use lib 't/lib';
use pgNode;
use Test::More;

my $num_tests = 79;

my $node        = pgNode->new('prod'); # declare instance named "prod"

$num_tests = 27 if $node->version < 10;
plan tests => $num_tests;

SKIP: {
    skip "PostgreSQL 10 and above only", 27
        if $node->version <= 10;

# create the instance and start it
$node->init();
$node->start;

### Beginning of tests ###

# simple check (trust everywhere, with initdb -A trust)
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    2,
    [
        qr/^Service  *: POSTGRES_HBA_SETTINGS$/m,
        qr/^Returns  *: 2 \(CRITICAL\)$/m,
        qr/^Message  *: 6 trust method\(s\)$/m,
        qr/^Perfdata *: trust=6 warn=1 crit=1$/m,
    ],
    [ qr/^$/ ],
    'simple issues check'
);


# Add a simple one without error but a warning issue (md5)
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->append_conf('pg_hba.conf', "local all all md5");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    1,
    [
        qr/^Service  *: POSTGRES_HBA_SETTINGS$/m,
        qr/^Returns  *: 1 \(WARNING\)$/m,
        qr/^Message  *: 1 md5 method\(s\)$/m,
        qr/^Perfdata *: md5=1 warn=1 crit=1$/m,
    ],
    [ qr/^$/ ],
    'simple warning-md5 check'
);

# Add another simple one without error but a critical issue (password)
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->append_conf('pg_hba.conf', "local all all password");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    2,
    [
        qr/^Service  *: POSTGRES_HBA_SETTINGS$/m,
        qr/^Returns  *: 2 \(CRITICAL\)$/m,
        qr/^Message  *: 1 password method\(s\)$/m,
        qr/^Perfdata *: password=1 warn=1 crit=1$/m,
    ],
    [ qr/^$/ ],
    'simple critical-password check'
);

# Add another simple one without error but a critical issue (trust)
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->append_conf('pg_hba.conf', "local all all trust");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    2,
    [
        qr/^Service  *: POSTGRES_HBA_SETTINGS$/m,
        qr/^Returns  *: 2 \(CRITICAL\)$/m,
        qr/^Message  *: 1 trust method\(s\)$/m,
        qr/^Perfdata *: trust=1 warn=1 crit=1$/m,
    ],
    [ qr/^$/ ],
    'simple critical-password check'
);

# Add yet another one with an error
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->append_conf('pg_hba.conf', "host all all all 255.255.255.255 scram-sha-256");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    2,
    [
        qr/^Service  *: POSTGRES_HBA_SETTINGS$/m,
        qr/^Returns  *: 2 \(CRITICAL\)$/m,
        qr/^Message  *: 1 error\(s\)$/m,
        qr/^Perfdata *: error=1 warn=1 crit=1$/m,
    ],
    [ qr/^$/ ],
    'simple issues check'
);

# Let's try a complete one
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->append_conf('pg_hba.conf', "local all all trust");
$node->append_conf('pg_hba.conf', "local all all md5");
$node->append_conf('pg_hba.conf', "local all all md5");
$node->append_conf('pg_hba.conf', "local all all password");
$node->append_conf('pg_hba.conf', "local all all trust");
$node->append_conf('pg_hba.conf', "local all all md5");
$node->append_conf('pg_hba.conf', "host all all all 255.255.255.255 scram-sha-256");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    2,
    [
        qr/^Service  *: POSTGRES_HBA_SETTINGS$/m,
        qr/^Returns  *: 2 \(CRITICAL\)$/m,
        qr/^Message  *: 1 error\(s\)$/m,
        qr/^Message  *: 3 md5 method\(s\)$/m,
        qr/^Message  *: 1 password method\(s\)$/m,
        qr/^Message  *: 2 trust method\(s\)$/m,
        qr/^Perfdata *: error=1 warn=1 crit=1$/m,
        qr/^Perfdata *: md5=3 warn=1 crit=1$/m,
        qr/^Perfdata *: password=1 warn=1 crit=1$/m,
        qr/^Perfdata *: trust=2 warn=1 crit=1$/m,
    ],
    [ qr/^$/ ],
    'complete example'
);

# Perfdata always contain the four kinds of issue, even at 0
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    0,
    [
        qr/^Returns  *: 0 \(OK\)$/m,
        qr/^Message  *: No issue on hba files$/m,
        qr/^Perfdata *: error=0 warn=1 crit=1$/m,
        qr/^Perfdata *: trust=0 warn=1 crit=1$/m,
        qr/^Perfdata *: password=0 warn=1 crit=1$/m,
        qr/^Perfdata *: md5=0 warn=1 crit=1$/m,
    ],
    [ qr/^$/ ],
    'perfdata at 0'
);

# Thresholds are used: 2 trust lines
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->append_conf('pg_hba.conf', "local all all trust");
$node->append_conf('pg_hba.conf', "local all all trust");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '3',
                          '--critical' => '5'
    ],
    0,
    [
        qr/^Returns  *: 0 \(OK\)$/m,
        qr/^Message  *: 2 trust method\(s\)$/m,
        qr/^Perfdata *: trust=2 warn=3 crit=5$/m,
    ],
    [ qr/^$/ ],
    'trust lines under the thresholds'
);

$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '2',
                          '--critical' => '3'
    ],
    1,
    [
        qr/^Returns  *: 1 \(WARNING\)$/m,
        qr/^Message  *: 2 trust method\(s\)$/m,
    ],
    [ qr/^$/ ],
    'trust lines over the warning threshold'
);

$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '1',
                          '--critical' => '2'
    ],
    2,
    [
        qr/^Returns  *: 2 \(CRITICAL\)$/m,
        qr/^Message  *: 2 trust method\(s\)$/m,
    ],
    [ qr/^$/ ],
    'trust lines over the critical threshold'
);

# md5 lines never raise a critical
truncate $node->data_dir . '/' . 'pg_hba.conf', 0;
$node->append_conf('pg_hba.conf', "local all all peer");
$node->append_conf('pg_hba.conf', "local all all md5");
$node->append_conf('pg_hba.conf', "local all all md5");
$node->append_conf('pg_hba.conf', "local all all md5");
$node->reload;
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '1',
                          '--critical' => '2'
    ],
    1,
    [
        qr/^Returns  *: 1 \(WARNING\)$/m,
        qr/^Message  *: 3 md5 method\(s\)$/m,
    ],
    [ qr/^$/ ],
    'md5 lines over the critical threshold'
);

# Invalid thresholds
foreach my $thresholds ( [ 'abc', '2' ], [ '0', '1' ], [ '1.5', '2' ] ) {
    $node->command_checks_all( [
        './check_pgactivity', '--service'  => 'hba_settings',
                              '--username' => $ENV{'USER'} || 'postgres',
                              '--format'   => 'human',
                              '--warning'  => $thresholds->[0],
                              '--critical' => $thresholds->[1]
        ],
        127,
        [ qr/^$/ ],
        [ qr/FATAL: critical and warning thresholds only accept a raw number of lines greater than 0\./ ],
        "invalid thresholds -w $thresholds->[0] -c $thresholds->[1]"
    );
}

$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'hba_settings',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '3',
                          '--critical' => '2'
    ],
    127,
    [ qr/^$/ ],
    [ qr/FATAL: warning threshold must not be greater than the critical one\./ ],
    'warning threshold greater than the critical one'
);

### End of tests ###

$node->stop( 'immediate' );

}
