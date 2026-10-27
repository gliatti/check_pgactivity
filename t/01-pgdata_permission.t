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
use Test::More tests => 22;

my $node = pgNode->get_new_node('prod');

$node->init;
$node->start;

### Beginning of tests ###
# First check.
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pgdata_permission',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
    ],
    0,
    [
      qr/^Service  *: POSTGRES_CHECK_PGDATA_PERMISSION$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: Permission is ok on .*$/m,
      qr/^Message  *: Owner of .* is \(.*\)$/m,
    ],
    [ qr/^$/ ],
    'first basic check'
);

# Role without privileges: data_directory is not visible.
$node->psql('postgres', 'CREATE ROLE nopriv LOGIN');

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pgdata_permission',
                          '--username'    => 'nopriv',
                          '--format'      => 'human',
    ],
    3,
    [
      qr/^Returns  *: 3 \(UNKNOWN\)$/m,
      qr/^Message  *: .*cannot read data_directory.*$/m,
    ],
    [ qr/^$/ ],
    'role without privileges to read data_directory'
);

# Wrong permission on PGDATA (changed while the instance is running).
my $pgdata    = $node->data_dir;
my $orig_mode = (stat $pgdata)[2] & 07777;

chmod 0755, $pgdata;

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pgdata_permission',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
    ],
    2,
    [
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: Permission is 0755 on .*$/m,
    ],
    [ qr/^$/ ],
    'wrong permission on PGDATA'
);

chmod $orig_mode, $pgdata;

# Expected owner given with --uid does not match the actual owner.
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pgdata_permission',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--uid'         => 'root',
    ],
    2,
    [
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: .* is owned by UID \d+, expected UID 0 \(--uid root\)$/m,
    ],
    [ qr/^$/ ],
    'owner does not match --uid'
);

# PGDATA cannot be stat()ed: parent directory not searchable.
my $parent      = $node->basedir;
my $orig_pmode  = (stat $parent)[2] & 07777;

chmod 0000, $parent;

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pgdata_permission',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
    ],
    3,
    [
      qr/^Returns  *: 3 \(UNKNOWN\)$/m,
      qr/^Message  *: .*cannot stat PGDATA.*$/m,
    ],
    [ qr/^$/ ],
    'PGDATA cannot be stat()ed'
);

chmod $orig_pmode, $parent;

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
