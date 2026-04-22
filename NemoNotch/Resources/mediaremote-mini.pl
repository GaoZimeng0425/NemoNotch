#!/usr/bin/perl
use strict;
use warnings;
use DynaLoader;

my $daemon = 0;
my @filtered;
for (@ARGV) {
    $_ eq '--daemon' ? ($daemon = 1) : push @filtered, $_;
}

my $lib = shift @filtered or die "Usage: mediaremote-mini.pl <dylib> [symbol]\n";
my $symbol = shift @filtered // 'adapter_get_env';

my $handle = DynaLoader::dl_load_file($lib, 0)
  or die "Failed to load dylib: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($handle, $symbol)
  or die "Failed to find symbol '$symbol'\n";
my $func = DynaLoader::dl_install_xsub("main::$symbol", $sym);

if ($daemon) {
    $| = 1;
    while (my $line = <STDIN>) {
        &$func();
    }
} else {
    &$func();
}
