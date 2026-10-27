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
use Test::More tests => 26;

my $node = pgNode->get_new_node('prod');

$node->init;
$node->start;

### Beginning of tests ###


# First check.
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'replication_slots',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
    ],
    0,
    [
      qr/^Service  *: POSTGRES_REPLICATION_SLOTS$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
      qr/^Message  *: Replication slots OK$/m,
    ],
    [ qr/^$/ ],
    'first basic check'
);

$node->stop;
$node->append_conf('postgresql.conf', "wal_level = logical");
$node->append_conf('postgresql.conf', "max_slot_wal_keep_size = 1GB")
    if $node->version >= 13;
$node->start;

# create a logical slot and fake one spill file in its directory
$node->safe_psql('postgres', q{
    SELECT pg_create_logical_replication_slot('slot_logical', 'test_decoding')
});
$node->safe_psql('postgres', q{ SELECT pg_create_physical_replication_slot('slot_physical', true) });
$node->switch_wal;

{
    my $spill = $node->data_dir .'/pg_replslot/slot_logical/xid-1234-lsn-0-1000000.spill';
    open my $fh, '>', $spill or die "could not create $spill: $!";
    close $fh;
}

# threshold names are case insensitive
$node->command_checks_all( [
    './check_pgactivity', '--service'     => 'replication_slots',
                          '--username'    => $ENV{'USER'} || 'postgres',
                          '--format'      => 'human',
                          '--dbname'      => 'postgres',
                          '--warning'     => 'WAL=0,SPILLED=0',
                          '--critical'    => 'WAL=0,SPILLED=0',
    ],
    2,
    [
      qr/^Service  *: POSTGRES_REPLICATION_SLOTS$/m,
      qr/^Returns  *: 2 \(CRITICAL\)$/m,
      qr/^Message  *: .*slot_logical spilled files : 1/m,
      qr/^Message  *: .*slot_physical wal files : [1-9]/m,
    ],
    [ qr/^$/ ],
    'uppercase threshold names'
);

SKIP: {
    skip "pg_ls_dir can be granted only from v11", 4
        if $node->version < 11;

    # non-superuser role with the documented privilege
    $node->safe_psql('postgres', q{
        CREATE ROLE check_pga LOGIN;
        GRANT EXECUTE ON FUNCTION pg_ls_dir(text) TO check_pga;
    });

    $node->command_checks_all( [
        './check_pgactivity', '--service'     => 'replication_slots',
                              '--username'    => 'check_pga',
                              '--format'      => 'human',
                              '--dbname'      => 'postgres',
        ],
        0,
        [
          qr/^Returns  *: 0 \(OK\)$/m,
          qr/^Perfdata  *: slot_logical_spilled=1File$/m,
        ],
        [ qr/^$/ ],
        'spilled files counted by non-superuser with pg_ls_dir granted'
    );
}

SKIP: {
    skip "safe_wal_size is available from v13", 11
        if $node->version < 13;

    # mock pg_replication_slots to report safe_wal_size = 0 for a role
    # looking in public before pg_catalog
    $node->safe_psql('postgres', q{
        CREATE ROLE check_pga_mock LOGIN SUPERUSER;
        ALTER ROLE check_pga_mock SET search_path TO public, pg_catalog;
        CREATE VIEW public.pg_replication_slots AS
            SELECT slot_name, slot_type, restart_lsn,
                'extended'::text AS wal_status, 0::bigint AS safe_wal_size
            FROM pg_catalog.pg_replication_slots
            WHERE slot_name = 'slot_physical';
    });

    $node->command_checks_all( [
        './check_pgactivity', '--service'     => 'replication_slots',
                              '--username'    => 'check_pga_mock',
                              '--format'      => 'human',
                              '--dbname'      => 'postgres',
                              '--warning'     => 'remaining=2MB',
                              '--critical'    => 'remaining=1MB',
        ],
        2,
        [
          qr/^Returns  *: 2 \(CRITICAL\)$/m,
          qr/^Message  *: slot slot_physical not safe$/m,
          qr/^Perfdata  *: slot_physical_remaining=0 warn=2097152 crit=1048576$/m,
        ],
        [ qr/^$/ ],
        'safe_wal_size equal to zero'
    );

    # lost slot: safe_wal_size is NULL
    $node->safe_psql('postgres', q{
        CREATE OR REPLACE VIEW public.pg_replication_slots AS
            SELECT slot_name, slot_type, restart_lsn,
                'lost'::text AS wal_status, NULL::bigint AS safe_wal_size
            FROM pg_catalog.pg_replication_slots
            WHERE slot_name = 'slot_physical';
    });

    $node->command_checks_all( [
        './check_pgactivity', '--service'     => 'replication_slots',
                              '--username'    => 'check_pga_mock',
                              '--format'      => 'human',
                              '--dbname'      => 'postgres',
                              '--warning'     => 'remaining=2MB',
                              '--critical'    => 'remaining=1MB',
        ],
        2,
        [
          qr/^Returns  *: 2 \(CRITICAL\)$/m,
          qr/^Message  *: slot_physical lost$/m,
          qr/\A(?!.*_remaining)/s,
          qr/\A(?!.*not safe)/s,
        ],
        [ qr/^$/ ],
        'safe_wal_size is NULL for lost slot'
    );
}



### End of tests ###

# stop immediate to kill any remaining backends
$node->stop('immediate');
