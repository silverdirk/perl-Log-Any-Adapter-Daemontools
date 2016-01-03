package Log::Any::Adapter::Daemontools;
use strict;
use warnings;
use parent 'Log::Any::Adapter::Base';
use Log::Any::Adapter::Util 'numeric_level';
use Log::Any ();
use Try::Tiny;
use Carp 'croak', 'carp';
require Scalar::Util;

our $VERSION= '0.003000';

# ABSTRACT: Logging adapter suitable for use in a Daemontools-style logging chain

=head1 DESCRIPTION

In the daemontools way of thinking, a daemon writes all its logging output
to STDOUT/STDERR, which is a pipe to a logger process.  Doing this instead
of other logging alternatives keeps your program simple and allows you to
capture errors generated by deeper libraries (like libc) which write
debugging info to STDOUT/STDERR.

When logging to a pipe, you lose the log level information.  An elegantly
simple way to preserve this information is to prefix each line with
"error:" or etc. prefixes, which can be re-parsed later.

Another frequent desire is to request that a long-lived daemon change its
logging level on the fly.  One way this is handled is by sending SIGUSR1/SIGUSR2
to tell the daemon to raise/lower the logging level.  Likewise people often
want to use "-v" or "-q" command line options to the same effect.

This module provides a convenient way for you to configure all of that from
a single "use" line.

=head1 VERSION NOTICE

NOTE: Version 0.003 lost some of the features of version 0.002 when the
internals of Log::Any changed in a way that made them impossible.
I don't know if anyone was using them anyway, but pay close attention
if you are upgrading.  This new version adheres more closely to the
specification for a logging adapter.

=head1 SYNOPSIS

  # No "bonus features" are enabled by default, but this gets you the most
  # common Unixy behavior.
  use Log::Any::Adapter 'Daemontools', argv => 1, env => 1, handle_signals => ['USR1','USR2'];
  
  # Above is equivalent to:
  use Log::Any::Adapter 'Daemontools',
    log_level  => 'info',
	argv => { verbose => [ '-v', '--verbose' ], quiet => [ '-q', '--quiet' ], bundle => 1, stop => '--' },
	env  => { debug => 'DEBUG' },
	handle_signals => { verbose => 'USR1', quiet => 'USR2' };
  
  # Above is equivalent to:
  use Log::Any::Adapter::Daemontools 'global_log_level', 'global_debug_level', 'parse_log_level_opts';
  use Log::Any::Adapter;
  if ($ENV{DEBUG}) { global_debug_level($ENV{DEBUG}); }
  if (@ARGV) {
    global_log_level(
      parse_log_level_opts({
        array => \@ARGV,
        verbose => [ '-v', '--verbose' ],
        quiet => [ '-q', '--quiet' ],
        bundle => 1,
        stop => '--'
	  })
    );
  }
  $SIG{USR1}= sub { global_log_level('+1'); };
  $SIG{USR2}= sub { global_log_level('-1'); };
  Log::Any::Adapter->set('Daemontools');
  
  # Example of a differing point of view:
  #
  # (Beware: 'argv', 'env', and 'handle_signals' are a special once-only
  #  startup behavior, so this code must be the *first* created
  #  Log::Any::Adapter::Daemontools instance.)
  #
  use Log::Any::Adapter 'Daemontools',
	argv => {
      bundle  => 1,
      verbose => '-v',  # none of that silly long-option stuff for us!
      quiet   => '-q',
      stop    => qr/^[^-]/, # Stop at the first non-option argument
    };
  # Now use our own signal handler to reload a config file that specifies
  # a log level:
  $SIG{HUP}= sub {
    MyApp->load_my_config_file();
    Log::Any::Adapter::Daemontools->global_log_level( MyApp->config->{log_level} );
  };

=cut

our $global_log_level;       # default for level-filtering
our $show_category;          # whether to show logging category on each message
our $show_file_line;         # Whether to show caller for each message
our $show_file_fullname;     # whether to use full path for caller info
our ($global_log_level, $global_log_level_min, $global_log_level_max);
our (%category_level, %category_min, %category_max);
BEGIN {
	$global_log_level= 6;      # info
	$global_log_level_min= -1; # full squelch
	$global_log_level_max= 8;  # trace
}

our (%env_profile, %argv_profile);
BEGIN {
	$env_profile{1}= { debug => 'DEBUG' };
	$argv_profile{1}= {
		bundle  => 1,
		verbose => qr/^(--verbose|-v)$/,
		quiet   => qr/^(--quiet|-q)$/,
		stop    => '--'
	};
}

=head1 ATTRIBUTES

=head2 env

  env => $name_or_args

Convenient passthrough to L<process_env>, called only once the first time
an adaptor is created.

If env is a hashref, it is passed directly.  If it is a scalar, it is
interpreted as a pre-defined "profile" of arguments.

Profiles:

=over

=item 1

  { debug => 'DEBUG' }

=back

=head2 argv

  argv => $name_or_args

Convenient passthrough to L<process_argv>, called only once the first time
an adapter is created.

If argv is a hashref, it is passed directly.  If it is a scalar, it is
interpreted as a pre-defined "profile" of arguments.

Profiles:

=over

=item 1

  {
    bundle  => 1,
    verbose => qr/^(--verbose|-v)$/,
    quiet   => qr/^(--quiet|-q)$/,
    stop    => '--'
  }

=back

=head2 handle_signals

  handle_signals => [ $v, $q ],
  handle_signals => { verbose => $v, quiet => $q },

Convenient passthrough to L<handle_signals>, called only once the first time
an adaptor is created.

If halde_signals is an arrayref of length 2, they are used as the verbose and
quiet parameters, respectively.  If it is a hashref, it is passed directly.

=cut

# init() gets called many times, but we should only perform startup actions once.
# These globals keep track of whether we have done the thing yet.
our ($process_argv_complete, $process_env_complete, $handle_signals_complete);

sub init {
	my $self= shift;
	
	# Optional one-time ENV filtering
	if (!$process_env_complete && $self->{env}) {
		$self->process_env(
			((ref $self->{env})||'') eq 'HASH'? $self->{env}
			: $env_profile{$self->{env}}
				|| croak "Unknown \"env\" value $self->{env}"
		);
		$proces_env_complete= 1;
	}
	
	# Optional one-time ARGV filtering
	if (!$parse_argv_complete && $self->{argv}) {
		$self->process_argv(
			((ref $self->{argv})||'') eq 'HASH'? $self->{argv}
			: $argv_profile{$self->{argv}}
				|| croak "Unknown \"argv\" value $self->{agv}"
		);
		$process_argv_complete= 1;
	}
	
	# Optional one-time installation of signal handlers
	if (!$handle_signals_complete && $self->{handle_signals}) {
		my $reft= ref $self->{handle_signals} || '';
		$self->handle_signals(
			$reft eq 'HASH'? $self->{handle_signals}
			: $reft eq 'ARRAY'? { verbose => $self->{handle_signals}[0], quiet => $self->{handle_signals}[1] }
			: croak "Unknown \"handle_signals\" value $self->{handle_signals}"
		);
		$handle_signals_complete= 1;
	}
}

=head1 ATTRIBUTES

=head1 PACKAGE METHODS

=head2 process_env

  $class->process_env( debug => $ENV_VAR_NAME );
  # and/or
  $class->process_env( log_level => $ENV_VAR_NAME );

Request that this package check for the named variable, and if it exists,
interpret it either as a debug level or a log level, and then set the global
log level used by this adapter.

A "debug level" refers to the typical Unix practice of a environment variable
named DEBUG where increasing integer values results in more debugging output.
This results in the following mapping: 2=trace, 1=debug 0=info -1=notice and
so on.  Larger numbers are clamped to 'trace'.

The other "log level" interpretation of numbers is that they represent the
numeric Log::Any level (identical to numeric syslog levels) which you want
to see.  So the mapping for a LOG_LEVEL variable would be 8=trace, 7=debug,
6=info, etc.

Either type of variable can also be a named log level or alias, in which
case it doesn't matter which type of variable it is.  These are according to
L<Log::Any::Adapter::Util/numeric_level>. 

=cut

my %_process_env_args= ( debug => 1, log_level => 1 );
sub process_env {
	my ($class, %spec)= @_;
	# Warn on unknown arguments
	my @unknown= grep { !$_process_env_args{$_} } keys %$spec;
	carp "Invalid arguments: ".join(', ', @unknown) if @unknown;
	
	if (defined $spec{debug} && defined $ENV{$spec{debug}}) {
		global_debug_level($ENV{$spec{debug}});
	}
	if (defined $spec{log_level} && defined $ENV{$spec{log_level}}) {
		global_log_level($ENV{$spec{log_level}});
	}
}

=head2 process_argv

  $class->process_argv( bundle => ..., verbose => ..., quiet => ..., stop => ..., remove => ... )

Scans (and optionally modifies) @ARGV using method L<parse_log_level_opts>,
with the supplied options, and updates the global log level accordingly.

=cut

my %_process_argv_args= ( bundle => 1, verbose => 1, quiet => 1, stop => 1, array => 1, remove => 1 );
sub process_argv {
	my $class= shift;
	my $ofs= $class->parse_log_level_opts(array => \@ARGV, @_);
	$class->global_log_level($ofs >= 0 ? "+$ofs" : $ofs)
		if $ofs;
}

=head2 parse_log_level_opts

  $level_offset= $class->parse_log_level_opts(
    array   => $arrayref, # required
    verbose => $strings_or_regexes,
    quiet   => $strings_or_regexes,
    stop    => $strings_or_regexes,
    bundle  => $bool, # defaults to false
    remove  => $bool, # defaults to false
  );

Scans the elements of 'array' looking for patterns listed in 'verbose', 'quiet', or 'stop'.
Each match of a pattern in 'quiet' adds one to the return value, and each match
of a pattern in 'verbose' subtracts one.  Stops iterating the array if any pattern
in 'stop' matches.

If 'bundle' is true, then this routine will also split apart "bundled options",
so for example

  --foo -wbmvrcd --bar

is processed as if it were

  --foo -w -b -m -v -r -c -d --bar

If 'remove' is true, then this routine will alter the array to remove matching
elements for 'quiet' and 'verbose' patterns.  It can also remove the bundled
arguments if bundling is enabled:

  @array= ( '--foo', '-qvvqlkj', '--verbose' );
  my $n= parse_log_level_opts(
    array => \@array,
    quiet => [ '-q', '--quiet' ],
    verbose => [ '-v', '--verbose' ],
    bundle => 1,
    remove => 1
  );
  # $n = -1
  # @array = ( '--foo', '-lkj' );

=cut

sub _make_regex_list {
	return () unless defined $_[0];
	return qr/^\Q$_[0]\E$/ unless ref $_[0];
	return map { _make_regex_list($_) } @{ $_[0] } if ref $_[0] eq 'ARRAY';
	return $_[0] if ref $_[0] eq 'Regexp';
	croak "Not a regular expression, string, or array: $_[0]"
}
sub _combine_regex {
	my @list= _make_regex_list(@_);
	return @list == 0? qr/\0^/  # a regex that doesn't match anything
		: @list == 1? $list[0]
		: qr/@{[ join '|', @list ]}/;
}
sub parse_log_level_opts {
	my ($class, %spec)= @_;
	# Warn on unknown arguments
	my @unknown= grep { !$_process_argv_args{$_} } keys %$spec;
	carp "Invalid arguments: ".join(', ', @unknown) if @unknown;
	
	defined $spec->{array} or croak "Parameter 'array' is required";
	my $stop=    _combine_regex( $spec->{stop} );
	my $verbose= _combine_regex( $spec->{verbose} );
	my $quiet=   _combine_regex( $spec->{quiet} );
	my $level_ofs= 0;
	
	my $parse;
	$parse= sub {
		my $array= $_[0];
		for (my $i= 0; $i < @$array; $i++) {
			last if $array->[$i] =~ $stop;
			if ($array->[$i] =~ /^-[^-=]+$/ and $spec->{bundle}) {
				# Un-bundle the arguments
				my @un_bundled= map { "-$_" } split //, substr($array->[$i], 1);
				my $len= @un_bundled;
				# Then filter them as usual
				$parse->(\@un_bundled);
				# Then re-bundle them, if altered
				if ($spec->{remove} && $len != @un_bundled) {
					if (@un_bundled) {
						$array->[$i]= '-' . join('', map { substr($_,1) } @un_bundled);
					} else {
						splice( @$array, $i--, 1 );
					}
				}
			}
			elsif ($array->[$i] =~ $verbose) {
				$level_ofs--;
				splice( @$array, $i--, 1 ) if $spec->{remove};
			}
			elsif ($array->[$i] =~ $quiet) {
				$level_ofs++;
				splice( @$array, $i--, 1 ) if $spec->{remove};
			}
		}
	};

	$parse->( $spec->{array} );
	return $level_ofs;
}

=head2 handle_signals

  $class->handle_signals( verbose => $signal_name, quiet => $signal_name );

Install signal handlers (probably USR1, USR2) which increase or decrease
the log level.

Basically:

  $SIG{ $verbose_name }= sub { Log::Any::Adapter::Daemontools->global_log_level('-1'); }
    if $verbose_name;
  
  $SIG{ $quiet_name   }= sub { Log::Any::Adapter::Daemontools->global_log_level('+1'); }
    if $quiet_name;

=cut

my %_handle_signal_args= ( debug => 1, log_level => 1 );
sub handle_signals {
	my ($class, %spec)= @_;
	# Warn on unknown arguments
	my @unknown= grep { !$_handle_signal_args{$_} } keys %$spec;
	carp "Invalid arguments: ".join(', ', @unknown) if @unknown;
	
	$SIG{ $spec{verbose} }= sub { $class->global_log_level('-1'); }
		if $spec{verbose};
  
	$SIG{ $spec{quiet}   }= sub { $class->global_log_level('+1'); }
		if $spec{quiet};
}

=head2 global_log_level

  $class->global_log_level            # returns level number
  $class->global_log_level( 'info' ); # 6
  $class->global_log_level( 3 );      # 3
  $class->global_log_level( 99 );     # 8 (clamped to max)
  $class->global_log_level( '+= 1' ); # 4
  $class->global_log_level( '-= 9' ); # -1 (clamped to min)
  $class->global_log_level( -1 );     # disable all logging

Log::Any::Adapter::Daemontools has a global variable that determines the
logging level.  This method gets or sets the default level.
Level names are converted to numbers by L<Log::Any::Adapter::Util/numeric_level>.
If the level has a + or - prefix it will be added to the current level.

=head2 global_log_level_min

  # Our app should never have 'fatal' squelched no matter how many '-q' the user gives us
  use Log::Any::Adapter 'Daemontools' log_level_min => 'fatal';
  # or
  Log::Any::Adapter::Daemontools->global_log_level_min(2);

This accessor lets you get/set the minimum log level used to clamp the values of
global_log_level.

=head2 global_log_level_max

  # We've hacked around on our logging infrastructure and actually have trace2..trace5
  Log::Any::Adapter::Daemontools->global_log_level_max(12);

Get/Sets the value used for clamping global_log_level.

=cut

sub global_log_level {
	my $class= shift;
	if (@_) {
		croak "extra arguments" if @_ > 1;
		my $lev= shift;
		$lev= $lev =~ /^-?\d+$/?          $lev
			: $lev =~ /^([-+])= (\d+)$/?  $global_log_level + "$1$2"
			: numeric_level($lev);
		
		$global_log_level= _clamp($global_log_level_min, $lev, $global_log_level_max);
		$class->_squelch_uncache_all;
	}
	$global_log_level;
}

sub global_log_level_min {
	my $class= shift;
	if (@_) {
		croak "extra arguments" if @_ > 1;
		my $lev= shift;
		$global_log_level_min= ($lev =~ /^-?\d+$/)? $lev : numeric_level($lev);
		$global_log_level= _clamp($global_log_level_min, $global_log_level, $global_log_level_max);
		$class->_squelch_uncache_all;
	}
	$global_log_level_min;
}

sub global_log_level_max {
	my $class= shift;
	if (@_) {
		croak "extra arguments" if @_ > 1;
		my $lev= shift;
		$global_log_level_max= ($lev =~ /^-?\d+$/)? $lev : numeric_level($lev);
		$global_log_level= _clamp($global_log_level_min, $global_log_level, $global_log_level_max);
		$class->_squelch_uncache_all;
	}
	$global_log_level_max;
}	

=head2 category_log_level

  $class->category_log_level($name);           # returns level number
  $class->category_log_level($name => 1)       # 1
  $class->category_log_level($name => 'info'); # 6
  $class->category_log_level($name => undef);  # back to global default
  $class->category_log_level($name => 
  
  # And the API wouldn't be complete if you couldn't set your own
  # upper/lower bounds on the logging level...
  $class->category_log_level_min($name => $min)
  $class->category_log_level_max($name => $max)

Log::Any::Adapter::Daemontools can override the global logging level on a
per-category basis.  Once set to a value, this category will no longer see
changes to the default global level.  You can restore it to the default by
setting the category level to undef.

=head2 category_log_level_min

See category_log_level

=head2 category_log_level_max

See category_log_level

=cut

sub category_log_level {
	my $class= shift;
	my $name= shift;
	if (@_) {
		croak "extra arguments" if @_ > 1;
		my $lev= shift;
		if (!defined $lev) {
			delete $category_level{$name};
		} else {
			$lev= $lev =~ /^-?\d+$/?          $lev
				: $lev =~ /^([-+])= (\d+)$/?  category_log_level($name) + "$1$2"
				: numeric_level($lev);
			$category_level{$name}= $lev;
		}
		$class->_squelch_uncache_all;
	}
	# Have to clamp the categories on the fly, because the global level
	# could change beyond the min/max set for the category.
	_clamp(
		__PACKAGE__->category_log_level_min($name),
		(defined $category_level{$name}? $category_level{$name} : $global_log_level),
		__PACKAGE__->category_log_level_max($name)
	);
}

sub category_log_level_min {
	my $class= shift;
	my $name= shift;
	if (@_) {
		croak "extra arguments" if @_ > 1;
		my $lev= shift;
		if (!defined $lev) {
			delete $category_level_min{$name};
		} else {
			$category_level_min{$name}= ($lev =~ /^-?\d+$/)? $lev : numeric_level($lev);
		}
		$class->_squelch_uncache_all;
	}
	# return $category_level_min{$name} // $global_log_level_min -x- be compatible with older perls
	my $r= $category_level_min{$name};
	$r= $global_log_level_min unless defined $r;
	return $r;
}

sub category_log_level_max {
	my $class= shift;
	my $name= shift;
	if (@_) {
		croak "extra arguments" if @_ > 1;
		my $lev= shift;
		if (!defined $lev) {
			delete $category_level_max{$name};
		} else {
			$category_level_max{$name}= ($lev =~ /^-?\d+$/)? $lev : numeric_level($lev);
		}
		$class->_squelch_uncache_all;
	}
	# return $category_level_max{$name} // $global_log_level_max -x- be compatible with older perls
	my $r= $category_level_max{$name};
	$r= $global_log_level_max unless defined $r;
	return $r;
}

=head1 METHODS

Adapter instances support all the standard logging methods of Log::Any::Adapter

See L<Log::Any::Adapter>

=cut

BEGIN {
	foreach my $method ( Log::Any->logging_methods(), 'fatal' ) {
		# TODO: Make prefix and output handle customizable
		my $prefix= $method eq 'info'? '' : "$method: ";
		my $m= sub {
			my $self= shift;
			print $output_handle join('', $prefix, @_);
		};
		no strict 'refs';
		*{__PACKAGE__ . "::$method"}= $m;
		*{__PACKAGE__ . "::is_$method"}= sub { 1 };
	}
	__PACKAGE__->_build_squelch_subclasses();
}

sub _squelch_base_class { ref($_[0]) || $_[0] }

# Create per-squelch-level subclasses of a given package
# This is an optimization for minimizing overhead when using disabled levels
sub _build_squelch_subclasses {
	my $class= shift;
	my %numeric_levels= ( map { $_ => 1 } -1, map { numeric_level($_) } Log::Any->logging_methods() );
	my %subclass;
	foreach my $level_num (keys %numeric_levels) {
		my $package= $class.'::L'.($level_num >= 0? $level_num : '_');
		$subclass{$package}{_squelch_base_class}= sub { $class };
		foreach my $method (Log::Any->logging_methods(), 'fatal') {
			if ($level_num > numeric_level($method)) {
				$subclass{$package}{$method}= sub {};
				$subclass{$package}{"is_$method"}= sub { 0 };
			}
		}
	}
	$subclass{"${class}::Unsquelched"}{_squelch_base_class}= sub { $class };
	foreach my $method (Log::Any->logging_and_detection_methods(), 'fatal', 'is_fatal') {
		# Trampoline code that lazily re-caches an adaptor the first time it is used
		$subclass{"${class}::Unsquelched"}{$method}= sub {
			$_[0]->_squelch_recache;
			goto shift->can($method)
		};
	}
	
	# Create subclasses and install methods
	for my $s (keys %subclass) {
		push @{$s.'::ISA'}, $class unless defined @{$s.'::ISA'} && @{$s.'::ISA'};
		for my $method (keys %{ $subclass{$s} }) {
			no strict 'refs';
			*{$s . '::' . $_}= $subclass{$s}{$method};
		}
	}
	1;
}

# The set of adapters which have been "squelch-cached"
# (i.e. blessed into a subclass)
our %_squelch_cached_adapters;

# Bless an adapter into an appropriate squelch level
sub _squelch_recache {
	my $self= shift;
	my $lev= $self->category_log_level($self->category);
	my $package= $self->_squelch_base_class.'::L'.($level_num >= 0? $level_num : '_');
	# TODO: future overrides for prefix-per-category and handle-per-category
	# would go here.
	Scalar::Util::weaken( $_squelch_cached_adapters{Scalar::Util::refaddr $self}= $self );
	bless $self, $package;
}

# Re-bless all squelch-cached adapters back to their natural class
sub _squelch_uncache_all {
	bless $_, $_->_squelch_base_class
		for values %_squelch_cached_adapters;
	%_squelch_cached_adapters= ();
}

# _clamp( $min, $number, $max )
sub _clamp { $_[1] < $_[0]? $_[0] : $_[1] > $_[2]? $_[2] : $_[1] }

1;