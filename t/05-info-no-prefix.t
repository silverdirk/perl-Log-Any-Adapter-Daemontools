#! /usr/bin/perl

use strict;
use warnings;
use Test::More;
use Log::Any '$log';
$SIG{__DIE__}= $SIG{__WARN__}= sub { diag @_; };

use_ok( 'Log::Any::Adapter', 'Daemontools', filter => -1 ) || BAIL_OUT;

my $buf;

sub reset_stderr {
	close STDERR;
	$buf= '';
	open STDERR, '>', \$buf or die "Can't redirect STDERR to a memory buffer: $!";
}

# Info messages should not receive a prefix
reset_stderr;
$log->info("test1");
like( $buf, qr/test1\n/ );

reset_stderr;
$log->info("test2\n");
like( $buf, qr/test2\n/ );

reset_stderr;
$log->info("test2\ntest3\ntest4\n");
like( $buf, qr/test2\ntest3\ntest4\n/ );

done_testing;
