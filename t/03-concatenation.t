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

reset_stderr;
$log->notice("foo","bar");
like( $buf, qr/notice: foobar\n/ );

done_testing;
