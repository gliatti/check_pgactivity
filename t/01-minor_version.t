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
use Time::HiRes qw(usleep gettimeofday tv_interval);
use File::Spec;
use Test::More tests => 53;

my $node = pgNode->get_new_node('prod');

$node->init;
$node->start;

### Beginning of tests ###

# Get current version
my $version_output = $node->safe_psql('postgres', q{
    SELECT to_char(setting::int, 'fm000000')
    FROM pg_settings
    WHERE name = 'server_version_num'
});

my ($v1, $v2, $v3) = $version_output =~ /(\d{2})(\d{2})(\d{2})/;

my $current_version;
if ($v1 >= 10) {
    $current_version = sprintf "%d.%d", $v1, $v3;
}
else {
    $current_version = sprintf "%d.%d.%d", $v1, $v2, $v3;
}

# versions relative to the running one
my $newer_version = $v1 >= 10 ? sprintf("%d.%d", $v1, $v3 + 1)
                              : sprintf("%d.%d.%d", $v1, $v2, $v3 + 1);
my $older_version;
$older_version = $v1 >= 10 ? sprintf("%d.%d", $v1, $v3 - 1)
                           : sprintf("%d.%d.%d", $v1, $v2, $v3 - 1)
    if $v3 > 0;

my $url    = 'http://www.postgresql.org/versions.rss';
my $bindir = `pg_config --bindir`;
chomp $bindir;
my $psql   = "$bindir/psql";

# Create a fake retrieval tool in $dir. It writes its arguments in
# "$dir/$name.args" and returns a fake RSS feed announcing $version.
sub fake_tool {
    my ($dir, $name, $version) = @_;
    my $file = "$dir/$name";

    open my $fh, '>', $file or die "could not create $file: $!";
    print $fh <<"SCRIPT";
#!/bin/sh
printf '%s\\n' "\$@" > '$dir/$name.args'
printf '%s\\n' '<?xml version="1.0"?><rss version="2.0"><channel>'
printf '%s\\n' '<title>PostgreSQL latest versions</title>'
printf '%s\\n' '<item><title>$version</title></item>'
printf '%s\\n' '</channel></rss>'
SCRIPT
    close $fh;
    chmod 0755, $file;

    return $file;
}

sub read_args {
    my $file = shift;
    my $content = '';

    return '' unless -f $file;
    open my $fh, '<', $file or die "could not read $file: $!";
    { local $/; $content = <$fh> }
    close $fh;

    return $content;
}

# links and links2 must receive the URL
foreach my $tool ( 'links', 'links2' ) {
    my $dir = File::Spec->rel2abs( TestLib::tempdir("fake_$tool") );

    fake_tool( $dir, $tool, $current_version );

    {
        local $ENV{'PATH'} = $dir;

        $node->command_checks_all( [
            './check_pgactivity', '--service'  => 'minor_version',
                                  '--username' => $ENV{'USER'} || 'postgres',
                                  '--format'   => 'human',
                                  '--psql'     => $psql,
            ],
            0,
            [ qr/^Service  *: POSTGRES_MINOR_VERSION$/m,
              qr/^Returns  *: 0 \(OK\)$/m,
            ],
            [ qr/^$/ ],
            "online check using $tool"
        );
    }

    like( read_args("$dir/$tool.args"), qr/^\Q$url\E$/m,
        "$tool receives the URL" );
}

# --path must execute the given program, not the one found in PATH
{
    my $dir   = File::Spec->rel2abs( TestLib::tempdir('fake_path') );
    my $empty = File::Spec->rel2abs( TestLib::tempdir('empty_path') );
    my $curl  = fake_tool( $dir, 'curl', $current_version );

    local $ENV{'PATH'} = $empty;

    $node->command_checks_all( [
        './check_pgactivity', '--service'  => 'minor_version',
                              '--username' => $ENV{'USER'} || 'postgres',
                              '--format'   => 'human',
                              '--psql'     => $psql,
                              '--path'     => $curl,
        ],
        0,
        [ qr/^Service  *: POSTGRES_MINOR_VERSION$/m,
          qr/^Returns  *: 0 \(OK\)$/m,
        ],
        [ qr/^$/ ],
        'online check using --path'
    );

    like( read_args("$dir/curl.args"), qr/^\Q$url\E$/m,
        '--path program receives the URL' );

    # program name must exactly match a supported one
    my $curl_real = fake_tool( $dir, 'curl.real', $current_version );

    $node->command_checks_all( [
        './check_pgactivity', '--service'  => 'minor_version',
                              '--username' => $ENV{'USER'} || 'postgres',
                              '--format'   => 'human',
                              '--psql'     => $psql,
                              '--path'     => $curl_real,
        ],
        127,
        [ qr/^$/ ],
        [ qr/FATAL: "\Q$curl_real\E" is not a supported program\./ ],
        '--path with an unsupported program name'
    );
}

# retrieval tools must be tried in a deterministic order: GET first
{
    my $dir = File::Spec->rel2abs( TestLib::tempdir('fake_order') );

    fake_tool( $dir, 'GET', $current_version );
    fake_tool( $dir, $_, $newer_version )
        foreach qw(wget curl fetch lynx links links2);

    local $ENV{'PATH'} = $dir;

    for my $i ( 1 .. 5 ) {
        $node->command_checks_all( [
            './check_pgactivity', '--service'  => 'minor_version',
                                  '--username' => $ENV{'USER'} || 'postgres',
                                  '--format'   => 'human',
                                  '--psql'     => $psql,
            ],
            0,
            [ qr/^Returns  *: 0 \(OK\)$/m ],
            [ qr/^$/ ],
            "retrieval tools order, run $i"
        );
    }
}

# offline: running a more recent version than the given one is fine
SKIP: {
    skip 'minor version 0, no older minor version', 8
        unless defined $older_version;

    foreach my $level ( 'warning', 'critical' ) {
        $node->command_checks_all( [
            './check_pgactivity', '--service'  => 'minor_version',
                                  '--username' => $ENV{'USER'} || 'postgres',
                                  '--format'   => 'human',
                                  "--$level"   => $older_version,
            ],
            0,
            [ qr/^Message  *: PostgreSQL version [^(]*$/m,
              qr/^Returns  *: 0 \(OK\)$/m,
            ],
            [ qr/^$/ ],
            "instance newer than the given $level version"
        );
    }
}

# basic check => Returns OK
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'minor_version',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => $current_version,
    ],
    0,
    [ qr/^Service  *: POSTGRES_MINOR_VERSION$/m,
      qr/^Message  *: PostgreSQL version .*$/m,
      qr/^Perfdata *: version=.*$/m,
      qr/^Returns  *: 0 \(OK\)$/m,
    ],
    [ qr/^$/ ],
    'basic check'
);

$v3 += 1;
if ($v1 >= 10) {
    $current_version = sprintf "%d.%d", $v1, $v3;
}
else {
    $current_version = sprintf "%d.%d.%d", $v1, $v2, $v3;
}

# minor version change => Returns WARNING
$node->command_checks_all( [
    './check_pgactivity', '--service'  => 'minor_version',
                          '--username' => $ENV{'USER'} || 'postgres',
                          '--format'   => 'human',
                          '--warning'  => $current_version,
    ],
    1,
    [ qr/^Service  *: POSTGRES_MINOR_VERSION$/m,
      qr/^Message  *: PostgreSQL version .*\(should be .*\)$/m,
      qr/^Perfdata *: version=.*$/m,
      qr/^Returns  *: 1 \(WARNING\)$/m,
    ],
    [ qr/^$/ ],
    'minor version upgrade needed'
);


### End of tests ###

# stop immediate to kill any remaining backends
$node->stop( 'immediate' );
