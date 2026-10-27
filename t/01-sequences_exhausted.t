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
use Test::More;
use PostgresVersion;

my $node = pgNode->get_new_node('prod');
my @timer;
my @in;
my @out;
my @procs;
my $pgversion;

$node->init;
$node->start;

### Beginning of tests ###


# basic check without thresholds
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'sequences_exhausted',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human'
    ],
    127,
    [ qr/^$/ ],
    [ qr/^FATAL: you must specify critical and warning thresholds.$/m ],
    'failing without thresholds'
);

TestLib::system_or_bail('createdb',
    '--host' => $node->host,
    '--port' => $node->port,
    'testdb'
);

$node->psql('testdb', 'CREATE TABLE test1 (i smallint PRIMARY KEY)');
$node->psql('testdb', 'CREATE SEQUENCE test1seq INCREMENT BY 8000 START WITH 16000 OWNED BY test1.i');

# As the sequence is new, set its first value
$node->psql('testdb', "SELECT nextval('test1seq')") ;

$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'sequences_exhausted',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '50%',
                          '--critical' => '90%'
    ],
    0,
    [
        qr/^Service *: POSTGRES_CHECK_SEQ_EXHAUSTED$/m,
        qr/^Returns *: 0 \(OK\)$/m,
    ],
    [ qr/^$/ ],
    'basic check'
);

$node->psql('testdb', "SELECT nextval('test1seq')");

$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'sequences_exhausted',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '50%',
                          '--critical' => '90%'
    ],
    1,
    [
        qr/^Service *: POSTGRES_CHECK_SEQ_EXHAUSTED$/m,
        qr/^Returns *: 1 \(WARNING\)$/m,
    ],
    [ qr/^$/ ],
    'check warning'
);

$node->psql('testdb', "SELECT nextval('test1seq')");

$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'sequences_exhausted',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => '50%',
                          '--critical' => '90%'
    ],
    2,
    [
        qr/^Service *: POSTGRES_CHECK_SEQ_EXHAUSTED$/m,
        qr/^Returns *: 2 \(CRITICAL\)$/m,
    ],
    [ qr/^$/ ],
    'check critical'
);

# decreasing sequences: the usable range must be computed from MAXVALUE
# down to MINVALUE (or the column type limit), not twice the range.
foreach my $db (qw(descdb1 descdb2 descdb3)) {
    TestLib::system_or_bail('createdb',
        '--host' => $node->host,
        '--port' => $node->port,
        $db
    );
}

# decreasing sequence not owned by any column: 100 usable values
$node->psql('descdb1', 'CREATE SEQUENCE descseq INCREMENT BY -1 MINVALUE -100 MAXVALUE -1');
$node->psql('descdb1', "SELECT setval('descseq', -30)");

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => $ENV{'USER'} || 'postgres',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb1$',
                          '--warning'   => '50%',
                          '--critical'  => '90%'
    ],
    0,
    [
        qr/^Service *: POSTGRES_CHECK_SEQ_EXHAUSTED$/m,
        qr/^Returns *: 0 \(OK\)$/m,
    ],
    [ qr/^$/ ],
    'decreasing sequence: 30% used is OK'
);

$node->psql('descdb1', "SELECT setval('descseq', -60)");

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => $ENV{'USER'} || 'postgres',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb1$',
                          '--warning'   => '50%',
                          '--critical'  => '90%'
    ],
    1,
    [
        qr/^Returns *: 1 \(WARNING\)$/m,
        qr/^Perfdata *: descdb1\.public\.descseq=40 warn=50 crit=10 min=0 max=100$/m,
    ],
    [ qr/^$/ ],
    'decreasing sequence: 60% used is WARNING'
);

# decreasing sequence owned by a smallint column: limited by the type
$node->psql('descdb2', 'CREATE TABLE desctbl (i smallint PRIMARY KEY)');
$node->psql('descdb2', 'CREATE SEQUENCE desctblseq INCREMENT BY -1 OWNED BY desctbl.i');
$node->psql('descdb2', "SELECT setval('desctblseq', -24001)");

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => $ENV{'USER'} || 'postgres',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb2$',
                          '--warning'   => '50%',
                          '--critical'  => '90%'
    ],
    1,
    [ qr/^Returns *: 1 \(WARNING\)$/m ],
    [ qr/^$/ ],
    'decreasing sequence owned by smallint: WARNING'
);

$node->psql('descdb2', "SELECT setval('desctblseq', -32001)");

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => $ENV{'USER'} || 'postgres',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb2$',
                          '--warning'   => '50%',
                          '--critical'  => '90%'
    ],
    2,
    [ qr/^Returns *: 2 \(CRITICAL\)$/m ],
    [ qr/^$/ ],
    'decreasing sequence owned by smallint: CRITICAL'
);

# decimal thresholds
$node->psql('descdb3', 'CREATE SEQUENCE decseq MINVALUE 1 MAXVALUE 1000');
$node->psql('descdb3', "SELECT setval('decseq', 756)");

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => $ENV{'USER'} || 'postgres',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb3$',
                          '--warning'   => '75.5%',
                          '--critical'  => '90.5%'
    ],
    1,
    [
        qr/^Returns *: 1 \(WARNING\)$/m,
        qr/^Perfdata *: descdb3\.public\.decseq=244 warn=245 crit=95 min=0 max=1000$/m,
    ],
    [ qr/^$/ ],
    'decimal thresholds: WARNING'
);

$node->psql('descdb3', "SELECT setval('decseq', 754)");

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => $ENV{'USER'} || 'postgres',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb3$',
                          '--warning'   => '75.5%',
                          '--critical'  => '90.5%'
    ],
    0,
    [ qr/^Returns *: 0 \(OK\)$/m ],
    [ qr/^$/ ],
    'decimal thresholds: OK'
);

# sequences the role is not allowed to read
$node->psql('postgres', 'CREATE ROLE noseqpriv LOGIN');

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => 'noseqpriv',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb1$',
                          '--warning'   => '50%',
                          '--critical'  => '90%'
    ],
    3,
    [
        qr/^Returns *: 3 \(UNKNOWN\)$/m,
        qr/^Long message *: descdb1\.public\.descseq: no SELECT or USAGE privilege$/m,
    ],
    [ qr/^$/ ],
    'no privilege on any sequence: UNKNOWN'
);

$node->psql('descdb3', 'GRANT SELECT ON SEQUENCE decseq TO noseqpriv');

$node->command_checks_all( [
    './check_pgactivity', '--service'   => 'sequences_exhausted',
                          '--username'  => 'noseqpriv',
                          '--format'    => 'human',
                          '--dbinclude' => '^descdb[13]$',
                          '--warning'   => '90%',
                          '--critical'  => '95%'
    ],
    0,
    [
        qr/^Returns *: 0 \(OK\)$/m,
        qr/^Long message *: descdb1\.public\.descseq: no SELECT or USAGE privilege$/m,
    ],
    [ qr/^$/ ],
    'no privilege on some sequences: reported in long message'
);


# stop immediate to kill any remaining backends
$node->stop('immediate');

done_testing();

