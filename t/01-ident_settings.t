#!/usr/bin/perl
# This program is open source, licensed under the PostgreSQL License.
# For license terms, see the LICENSE file.
#
# Copyright (C) 2012-2026: Open PostgreSQL Monitoring Development Group

use strict;
use warnings;

use lib 't/lib';
use pgNode;
use Test::More tests => 3;

my $node        = pgNode->new('prod'); # declare instance named "prod"

# create the instance and start it
$node->init();
$node->start;

### Beginning of tests ###

# Tests for PostreSQL 14 and before
subtest pg14 => sub {
    plan tests => 3;

    SKIP: {
        skip "testing incompatibility with PostgreSQL 14 and before", 3
            unless $node->version <= 15.0;

        $node->command_checks_all( [
            './check_pgactivity', '--service'  => 'ident_settings',
                                  '--username' => $ENV{'USER'} || 'postgres',
                                  '--format'   => 'human'
            ],
            1,
            [ qr/^$/ ],
            [ qr/^Service ident_settings is not compatible with host/ ],
            'non compatible PostgreSQL version'
        );
    }
};

subtest pg15 => sub {
    plan tests => 12;

    SKIP: {
        skip "incompatible tests with PostgreSQL < 15", 12
            unless $node->version >= 15.0;

        # simple check
        $node->command_checks_all( [
            './check_pgactivity', '--service'  => 'ident_settings',
                                  '--username' => $ENV{'USER'} || 'postgres',
                                  '--format'   => 'human'
            ],
            0,
            [
                qr/^Service  *: POSTGRES_IDENT_SETTINGS$/m,
                qr/^Returns  *: 0 \(OK\)$/m,
                qr/^Message  *: No errors in ident configuration files$/m,
            ],
            [ qr/^$/ ],
            'simple check with no error'
        );

        # Add a simple one with an error
        $node->append_conf('pg_ident.conf', "foobar");

        $node->command_checks_all( [
            './check_pgactivity', '--service'  => 'ident_settings',
                                  '--username' => $ENV{'USER'} || 'postgres',
                                  '--format'   => 'human'
            ],
            2,
            [
                qr/^Service  *: POSTGRES_IDENT_SETTINGS$/m,
                qr/^Returns  *: 2 \(CRITICAL\)$/m,
                qr/^Message  *: 1 error\(s\)$/m,
                qr/^Long message *: file .*pg_ident\.conf, line \d+, error: .*$/m,
                qr/^Perfdata *: errors=1$/m,
            ],
            [ qr/^$/ ],
            'simple check with error'
        );
    }
};

# PostgreSQL 15+: role with only the privileges documented for the service
subtest 'pg15 unprivileged role' => sub {
    plan tests => 5;

    SKIP: {
        skip "incompatible tests with PostgreSQL < 15", 5
            unless $node->version >= 15.0;

        $node->safe_psql( 'postgres', q{
            CREATE ROLE ident_mon LOGIN;
            GRANT SELECT ON pg_ident_file_mappings TO ident_mon;
            GRANT EXECUTE ON FUNCTION pg_ident_file_mappings TO ident_mon;
        });

        $node->append_conf('pg_ident.conf', "bazqux");

        $node->command_checks_all( [
            './check_pgactivity', '--service'  => 'ident_settings',
                                  '--username' => 'ident_mon',
                                  '--dbname'   => 'postgres',
                                  '--format'   => 'human'
            ],
            2,
            [
                qr/^Returns  *: 2 \(CRITICAL\)$/m,
                qr/^Long message *: .*file .*, line \d+, error: .*$/m,
                qr/^Perfdata *: errors=2$/m,
            ],
            [ qr/^$/ ],
            'check with error as a non-superuser role'
        );

        # cleanup
        my $ident_file = $node->data_dir . '/pg_ident.conf';
        my $content = TestLib::slurp_file($ident_file);
        $content =~ s/^bazqux\n//m;
        open my $fh, '>', $ident_file or die "unable to write $ident_file: $!";
        print $fh $content;
        close $fh;
        $node->reload;

        $node->safe_psql( 'postgres', q{
            REVOKE SELECT ON pg_ident_file_mappings FROM ident_mon;
            REVOKE EXECUTE ON FUNCTION pg_ident_file_mappings FROM ident_mon;
            DROP ROLE ident_mon;
        });
    }
};

done_testing;

### End of tests ###

$node->stop( 'immediate' );
