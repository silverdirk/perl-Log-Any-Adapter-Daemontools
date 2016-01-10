package Log::Any::Adapter::Daemontools;
use 5.008; # need weak reference support
our @ISA; BEGIN { require Log::Any::Adapter::Base; @ISA= 'Log::Any::Adapter::Base' };
use strict;
use warnings;
use Log::Any::Adapter::Util 'numeric_level';
use Log::Any 1.03;
use Log::Any::Adapter::Daemontools::Config;
use Carp 'croak', 'carp';

our $VERSION= '0.0900000_002';

# ABSTRACT: Logging adapter suitable for use in a Daemontools-style logging chain

=head1 SYNOPSIS

  # Log to STDOUT with log-level-name prefixes for all but 'info'
  # Default log level is 'info'
  use Log::Any::Adapter 'Daemontools';
  
  # As above, but log level 'notice'
  use Log::Any::Adapter 'Daemontools', init => { level => 'notice' };
  
  # As above, but process @ARGV -v/-q and $ENV{DEBUG} to adjust the level
  use Log::Any::Adapter 'Daemontools', init => { argv => 1, env => 1 };
  
  # Direct edits to shared config
  my $cfg= Log::Any::Adapter::Daemontools->global_config;
  $cfg->log_level('debug');
  $cfg->init( argv => 1, env => 1 );
  
  # Change log level on the fly
  $SIG{USR1}= sub { $cfg->log_level_adjust(1); };
  $SIG{USR2}= sub { $cfg->log_level_adjust(-1); };
  
  # Signal handlers can also be installed by the config:
  $cfg->init( handle_signals => ['USR1','USR2'] );
  
  # Create a second config independent of the global config
  my $cfg2= Log::Any::Adapter::Daemontools->new_config;
  
  # Multiple adapter configurations, tracking different config instances
  Log::Any::Adapter->set({ category => qr/^Noisy::Package.*/ }, 'Daemontools', config => $cfg2 );
  Log::Any::Adapter->set('Daemontools'); # config defaults to global_config
  $cfg2->log_level('warn'); # lower log level for messages from Noisy::Package::*
  
  # Like above, but limit the verbosity instead of creating a second config
  Log::Any::Adapter->set({ category => qr/^Noisy::Package.*/ }, 'Daemontools', log_level_max => 'warn' );
  Log::Any::Adapter->set('Daemontools'); # config defaults to global_config

See L<Log::Any::Adapter::Daemontools::Config> for most of the details.

=head1 DESCRIPTION

The measure of good software is low learning curve, low complexity, few
dependencies, high efficiency, and high flexibility.  (choose two.  haha)

In the daemontools way of thinking, a daemon writes all its logging output
to STDOUT (or STDERR), which is a pipe to a logger process.
Doing this instead of other logging alternatives keeps your program simple
and allows you to capture errors generated by deeper libraries (like libc)
which aren't aware of your logging API.  If you want complicated logging you
can keep those details in the logging process and not bloat each daemon you
write.

This module aims to be the easiest, simplest, most efficent way to get
Log::Any messages to a file handle while still being flexible enough for the
needs of the typical unix daemon or utility script.

Problems solved by this module are:

=over

=item Preserve log level

The downside of logging to a pipe is you don't get the log-level that you
could have had with syslog or Log4perl.  An simple way to preserve this
information is to prefix each line with "error:" or etc, which can be
re-parsed later (or by the logger process). See L<prefix>.

=item Efficiently squelch log levels

Trace logging is a great thing, but the methods can get a bit "hot" and you
don't want it to impact performance.  Log::Any provides the syntax

  $log->trace(...) if $log->is_trace

which is great as long as "is_trace" is super-efficient.  This module does
subclassing/caching tricks so that suppressed log levels are effectively
C<sub is_trace { 0 }>
(although as of Log::Any 1.03 there is still another layer of method call
from the Log::Any::Proxy, which is unfortunate)

=item Dynamically adjust log levels

Log::Any::Adapter allows you to replace the current adapters with new ones
with a different configuration, which you can use to adjust log_level,
but it isn't terribly efficient, and if you are also using the regex feature
(where different categories get different loggers) it's even worse.

This module uses shared configurations on the back-end so you can alter the
configuration in many ways without having to re-attach the adapters.
(there is a small re-caching penalty, but it's done lazily)

=item --verbose / --quiet / $ENV{DEBUG}

My scripts usually end up with a chunk of boilerplate in the option processing
to raise or lower the log level.  This module provides an option to get you
common UNIX behavior in as little as 7 characters :-)
It's flexible enough to give you many other common varieties, or you can ignore
it because it isn't enabled by default.

=item Display caller() or category, or custom formatting

And of course, you often want to see additional details about the message or
perform some of your own tweaks.  This module provides quick options to enable
caller() info and/or category name where the message originated, and allows
full customization with coderefs.

=back

=head1 VERSION NOTICE

NOTE: Version 0.1 lost some of the features of version 0.002 when the
internals of Log::Any changed in a way that made them impossible.
I don't know if anyone was using them anyway, but pay close attention
if you are upgrading.  This new version adheres more closely to the
specification for a logging adapter.

=cut

our $global_config;
sub global_config {
	$global_config ||= shift->new_config;
}

sub new_config {
	my $class= shift;
	$class= ref($class) || $class;
	my $cfg= "${class}::Config"->new;
	$cfg->init(@_);
	return $cfg;
}

=head1 ATTRIBUTES

=head2 category

The category of the L<Log::Any> logger attached to this adapter.  Read-only.

=head2 config

The L<Log::Any::Adapter::Daemontools::Config> object which this adapter is
tracking.  Read-only reference ( but the config can be altered ).

=cut

sub category { shift->{category} }
sub config   { shift->{config} }

=head2 -init

  Log::Any::Adapter 'Daemontools', -init => { ... };

Not actually an attribute!  If you pass this to the Daemontools adapter,
the first time an instance of the Adapter is created it will call ->init on
the adapter's configuration.  This allows you to squeeze things onto one line.

The more proper way to write the above example is:

  use Log::Any::Adapter 'Daemontools';
  Log::Any::Adapter::Daemontools->global_config->init( ... );

The implied init() call will happen exactly once per config object.
(but you can call the init() method yourself as much as you like)

See L<Log::Any::Adapter::Daemontools::Config/init> for the complete list
of initialization options.

=cut

# Log::Any::Adapter constructor, also named 'init'
sub init {
	my $self= shift;
	
	$self->{config} ||= $self->global_config;
	
	$self->config->init( %{$self->{'-init'}} )
		if $self->{'-init'} && !$self->config->_init_called;
	
	# Set up our lazy caching system (re-blesses current object)
	$self->_uncache_config;
}

=head1 METHODS

Adapter instances support all the standard logging methods of Log::Any::Adapter

See L<Log::Any::Adapter>

=cut

sub _squelch_base_class { ref($_[0]) || $_[0] }

# Create per-squelch-level subclasses of a given package
# This is an optimization for minimizing overhead when using disabled levels
sub _build_squelch_subclasses {
	my $class= shift;
	my %numeric_levels= ( map { $_ => 1 } -1, map { numeric_level($_) } Log::Any->logging_methods() );
	my %subclass;
	foreach my $level_num (keys %numeric_levels) {
		my $package= $class.'::Squelch'.($level_num+1);
		$subclass{$package}{_squelch_base_class}= sub { $class };
		foreach my $method (Log::Any->logging_methods(), 'fatal') {
			if ($level_num < numeric_level($method)) {
				$subclass{$package}{$method}= sub {};
				$subclass{$package}{"is_$method"}= sub { 0 };
			}
		}
	}
	$subclass{"${class}::Lazy"}{_squelch_base_class}= sub { $class };
	foreach my $method (Log::Any->logging_and_detection_methods(), 'fatal', 'is_fatal') {
		# Trampoline code that lazily re-caches an adaptor the first time it is used
		$subclass{"${class}::Lazy"}{$method}= sub {
			$_[0]->_cache_config;
			goto $_[0]->can($method)
		};
	}
	
	# Create subclasses and install methods
	for my $pkg (keys %subclass) {
		no strict 'refs';
		@{$pkg.'::ISA'}= ( $class );
		for my $method (keys %{ $subclass{$pkg} }) {
			*{$pkg.'::'.$method}= $subclass{$pkg}{$method};
		}
	}
	1;
}

# The set of adapters which have been "squelch-cached"
# (i.e. blessed into a subclass)
our %_squelch_cached_adapters;

BEGIN {
	foreach my $method ( Log::Any->logging_methods() ) {
		my $m= sub { my $self= shift; $self->{_writer}->($self, $method, @_); };
		no strict 'refs';
		*{__PACKAGE__ . "::$method"}= $m;
		*{__PACKAGE__ . "::is_$method"}= sub { 1 };
	}
	__PACKAGE__->_build_squelch_subclasses();
}

# Cache the ->config settings into this adapter, which also
# re-blesses it based on the current log level.
sub _cache_config {
	my $self= shift;
	$self->{_writer}= $self->config->compiled_writer;
	my $lev= $self->config->log_level_num;
	bless $self, $self->_squelch_base_class.'::Squelch'.($lev+1);
	$self->config->_register_cached_adapter($self);
}

# Re-bless adapter back to its "Lazy" config cacher class
sub _uncache_config {
	bless $_[0], $_[0]->_squelch_base_class . '::Lazy';
}

1;
