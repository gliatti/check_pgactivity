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
use Test::More tests => 31;

my $node = pgNode->get_new_node('prod');
my $pga_data = "$TestLib::tmp_check/pga.data";

$node->init;
$node->start;

### Beginning of tests ###

# First check. Returns no perfdata
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'extensions_versions',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
    ],
    0,
    [
      qr/^Service  *: POSTGRES_CHECK_EXT_VERSIONS$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
    ],
    [ qr/^$/ ],
    'first basic check'
);

# Outdated extensions, in a database whose name contains an extension name
$node->psql('postgres', 'CREATE DATABASE hstoredb');
$node->psql('postgres', q{CREATE EXTENSION pg_trgm VERSION '1.3'});
$node->psql('postgres', q{CREATE EXTENSION hstore VERSION '1.4'});
$node->psql('hstoredb', q{CREATE EXTENSION pg_trgm VERSION '1.3'});

# Summary message, detailed message sorted by extension name
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'extensions_versions',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
    ],
    2,
    [
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: 3 outdated extension\(s\)$/m,
      qr/^Long message *: postgres\.hstore: 1\.4 \(should be: [0-9.]+\)\n^Long message *: postgres\.pg_trgm: 1\.3 /m,
    ],
    [ qr/^$/ ],
    'outdated extensions'
);

# An exclusion without '/' only applies to the extension name
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'extensions_versions',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--exclude'     => 'hstore',
    ],
    2,
    [
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: 2 outdated extension\(s\)$/m,
      qr/^Long message *: hstoredb\.pg_trgm: 1\.3 /m,
    ],
    [ qr/^$/ ],
    'exclusion on the extension name'
);

# An exclusion with '/' applies to 'dbname/extension'
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'extensions_versions',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--exclude'     => '^hstoredb/pg_trgm$',
    ],
    2,
    [
      qr/^Message  *: 2 outdated extension\(s\)$/m,
      qr/\A(?!.*hstoredb\.pg_trgm)/s,
    ],
    [ qr/^$/ ],
    'exclusion on dbname/extension'
);

# OK message
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'extensions_versions',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--exclude'     => '^(hstore|pg_trgm)$',
    ],
    0,
    [
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: [0-9]+ database\(s\) checked$/m,
    ],
    [ qr/^$/ ],
    'OK message'
);

# A database the role cannot connect to does not prevent checking the
# other ones
$node->psql('postgres', 'CREATE DATABASE lockeddb');
$node->psql('postgres', 'REVOKE CONNECT ON DATABASE lockeddb FROM PUBLIC');
$node->psql('postgres', 'CREATE ROLE check_pga LOGIN');

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'extensions_versions',
                          '--username'    => 'check_pga',
                          '--format'      => 'human',
    ],
    2,
    [
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: 3 outdated extension\(s\)$/m,
      qr/^Message  *: 1 database\(s\) could not be checked: lockeddb$/m,
    ],
    [ qr/^$/ ],
    'unreachable database with outdated extensions elsewhere'
);

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'extensions_versions',
                          '--username'    => 'check_pga',
                          '--format'      => 'human',
                          '--exclude'     => '^(hstore|pg_trgm)$',
    ],
    3,
    [
      qr/^Returns  *: 3 \(UNKNOWN\)$/m,
      qr/^Message  *: 1 database\(s\) could not be checked: lockeddb$/m,
    ],
    [ qr/^$/ ],
    'unreachable database only'
);

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
