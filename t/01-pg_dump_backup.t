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

my $node       = pgNode->get_new_node('prod');
my $pga_data   = "$TestLib::tmp_check/pga.data";
my $backup_dir = "$TestLib::tmp_check/backups";
my $now        = time;
my $dump       = "$backup_dir/employes_2025-04-03T13:38:48Z.dump";
my $old_dump   = "$backup_dir/employes_2025-04-02T13:38:48Z.dump";
my $globals    = "$backup_dir/pg_globals_2025-04-03T13:38:48Z.sql";

sub write_file {
    my ( $file, $size, $mtime ) = @_;

    open my $fh, '>', $file or die "could not write $file: $!";
    print $fh 'x' x $size;
    close $fh;
    utime $mtime, $mtime, $file;
}

$node->init;
$node->start;

mkdir $backup_dir;

# pg_back v2 like files (rfc3339 format), with checksum files
write_file( $old_dump, 1000, $now - 86400 - 3600 );
write_file( "$old_dump.sha256", 100, $now - 86400 - 3600 );
write_file( $dump, 1000, $now - 3600 );
write_file( "$dump.sha256", 100, $now - 3600 );
write_file( $globals, 500, $now - 3600 );

### Beginning of tests ###

# simple check with the pg_back patterns documented
$node->command_checks_all( [
    './check_pgactivity', '--service'        => 'pg_dump_backup',
                          '--username'       => $ENV{'USER'} || 'postgres',
                          '--format'         => 'human',
                          '--status-file'    => $pga_data,
                          '--dbinclude'      => 'employes',
                          '--path'           => "$backup_dir/*",
                          '--pattern'        => '(\w+)_[0-9TZ:+-]+\.dump$',
                          '--global-pattern' => 'pg_globals_[0-9TZ:+-]+\.sql$',
                          '--warning'        => 'newest=2h,oldest=2d',
                          '--critical'       => 'newest=3h,oldest=3d',
    ],
    0,
    [
      qr/^Service  *: POSTGRES_PGDUMP_BACKUP$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Perfdata *: employes_newest=36\d\ds warn=7200 crit=10800$/m,
      qr/^Perfdata *: employes_oldest=900\d\ds warn=172800 crit=259200$/m,
      qr/^Perfdata *: employes_size=1000.00B$/m,
      qr/^Perfdata *: globals_objects_size=500.00B$/m,
    ],
    [ qr/^$/ ],
    'pg_back rfc3339 check'
);

unlink $pga_data;

# first check with a size threshold: perfdata must be returned anyway
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pg_dump_backup',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--dbinclude'   => 'employes',
                          '--path'        => "$backup_dir/*",
                          '--pattern'     => '(\w+)_[0-9TZ:+-]+\.dump$',
                          '--warning'     => 'newest=2h,size=10%',
                          '--critical'    => 'newest=3h,size=20%',
    ],
    0,
    [
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Perfdata *: employes_newest=36\d\ds warn=7200 crit=10800$/m,
      qr/^Perfdata *: employes_oldest=900\d\ds$/m,
      qr/^Perfdata *: employes_size=1000.00B$/m,
      qr/^Perfdata *: employes_delta=0.00B$/m,
    ],
    [ qr/^$/ ],
    'first check with a size threshold returns perfdata'
);

# the newest dump grows from 1000B to 1500B: the delta must be reported
write_file( $dump, 1500, $now - 3600 );

$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pg_dump_backup',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--dbinclude'   => 'employes',
                          '--path'        => "$backup_dir/*",
                          '--pattern'     => '(\w+)_[0-9TZ:+-]+\.dump$',
                          '--warning'     => 'newest=2h,size=10%',
                          '--critical'    => 'newest=3h,size=20%',
    ],
    2,
    [
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: 'employes_delta'=500B$/m,
      qr/^Perfdata *: employes_size=1.46kB$/m,
      qr/^Perfdata *: employes_delta=500.00B warn=100.00B crit=200.00B$/m,
    ],
    [ qr/^$/ ],
    'size variation is reported in the message'
);

# upper case metric names in thresholds
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'pg_dump_backup',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--status-file' => $pga_data,
                          '--dbinclude'   => 'employes',
                          '--path'        => "$backup_dir/*",
                          '--pattern'     => '(\w+)_[0-9TZ:+-]+\.dump$',
                          '--warning'     => 'NEWEST=1s',
                          '--critical'    => 'NEWEST=2s',
    ],
    2,
    [
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: 'employes_newest'=1h(\d+s)?$/m,
      qr/^Perfdata *: employes_newest=36\d\ds warn=1 crit=2$/m,
    ],
    [ qr/^$/ ],
    'upper case threshold names'
);

# pg_back legacy format
unlink $old_dump, "$old_dump.sha256", $dump, "$dump.sha256", $globals;
write_file( "$backup_dir/employes_2025-04-03_13-38-48.dump", 1000, $now - 3600 );
write_file( "$backup_dir/employes_2025-04-03_13-38-48.dump.sha256", 100, $now - 3600 );
write_file( "$backup_dir/pg_globals_2025-04-03_13-38-48.sql", 500, $now - 3600 );

$node->command_checks_all( [
    './check_pgactivity', '--service'        => 'pg_dump_backup',
                          '--username'       => $ENV{'USER'} || 'postgres',
                          '--format'         => 'human',
                          '--status-file'    => $pga_data,
                          '--dbinclude'      => 'employes',
                          '--path'           => "$backup_dir/*",
                          '--pattern'        => '(\w+)_[0-9_-]+\.dump$',
                          '--global-pattern' => 'pg_globals_[0-9_-]+\.sql$',
    ],
    0,
    [
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Perfdata *: employes_size=1000.00B$/m,
      qr/^Perfdata *: globals_objects_size=500.00B$/m,
    ],
    [ qr/^$/ ],
    'pg_back legacy check'
);

### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
