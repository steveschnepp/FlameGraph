#!/usr/bin/perl -w
#
# stackcollapse-jstack.pl	collapse jstack samples into single lines.
#
# Parses Java stacks generated by jstack(1) and outputs RUNNABLE stacks as
# single lines, with methods separated by semicolons, and then a space and an
# occurrence count. This also filters some other "RUNNABLE" states that we
# know are probably not running, such as epollWait. For use with flamegraph.pl.
#
# You want this to process the output of at least 100 jstack(1)s. ie, run it
# 100 times with a sleep interval, and append to a file. This is really a poor
# man's Java profiler, due to the overheads of jstack(1), and how it isn't
# capturing stacks asynchronously. For a better profiler, see:
# http://www.brendangregg.com/blog/2014-06-12/java-flame-graphs.html
#
# USAGE: ./stackcollapse-jstack.pl infile > outfile
#
# Example input:
#
# "MyProg" #273 daemon prio=9 os_prio=0 tid=0x00007f273c038800 nid=0xe3c runnable [0x00007f28a30f2000]
#    java.lang.Thread.State: RUNNABLE
#        at java.net.SocketInputStream.socketRead0(Native Method)
#        at java.net.SocketInputStream.read(SocketInputStream.java:121)
#        ...
#        at java.lang.Thread.run(Thread.java:744)
#
# Alternate input (from jstat -F)

# Thread 117034: (state = IN_JAVA)
#  - java.lang.reflect.Array.newInstance(java.lang.Class, int) @bci=2, line=75 (Compiled frame; information may be imprecise)
#  - java.util.Arrays.copyOf(java.lang.Object[], int, java.lang.Class) @bci=21, line=3212 (Compiled frame)
#  - java.util.Arrays.copyOf(java.lang.Object[], int) @bci=6, line=3181 (Compiled frame)
#  - com.google.common.collect.ImmutableMap$Builder.ensureCapacity(int) @bci=23, line=235 (Compiled frame)
#  - com.google.common.collect.ImmutableMap$Builder.put(java.lang.Object, java.lang.Object) @bci=7, line=247 (Compiled frame)
#  ...
#  - java.lang.Thread.run() @bci=11, line=748 (Interpreted frame)
#
# Example output:
#
#  MyProg;java.lang.Thread.run;java.net.SocketInputStream.read;java.net.SocketInputStream.socketRead0 1
#
# Input may be created and processed using:
#
#  i=0; while (( i++ < 200 )); do jstack PID >> out.jstacks; sleep 10; done
#  cat out.jstacks | ./stackcollapse-jstack.pl > out.stacks-folded
#
# WARNING: jstack(1) incurs overheads. Test before use, or use a real profiler.
#
# Copyright 2014 Brendan Gregg.  All rights reserved.
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
#  (http://www.gnu.org/copyleft/gpl.html)
#
# 14-Sep-2014	Brendan Gregg	Created this.

use strict;

use Getopt::Long;

# tunables
my $include_tname = 1;		# include thread names in stacks
my $include_tid = 0;		# include thread IDs in stacks
my $shorten_pkgs = 0;		# shorten package names
my @collapse_frames = ();	# frames to collapse.
my @states = qw(RUNNABLE);	# thread states to consider
my $help = 0;
my $statistics = 0;
my $quiet = 0;

sub usage {
	die <<USAGE_END;
USAGE: $0 [options] infile > outfile\n
	--include-tname
	--no-include-tname # include/omit thread names in stacks (default: include)
	--include-tid
	--no-include-tid   # include/omit thread IDs in stacks (default: omit)
	--collapse-frame   # frames to by collapsing them into "...". (default: none)
	--shorten-pkgs
	--no-shorten-pkgs  # (don't) shorten package names (default: don't shorten)
	--state            # Include this thread state. Can be multiple (default: RUNNABLE)
	                   # Note that there is are special states named "BACKGROUND" & "NETWORK"
	--stats            # Emits some statistics about the threaddumps
	--quiet            # Remove any warning, only emits errors

	eg,
	$0 --no-include-tname stacks.txt > collapsed.txt
USAGE_END
}

GetOptions(
	'include-tname!'  => \$include_tname,
	'include-tid!'    => \$include_tid,
	'collapse-frame=s' => \@collapse_frames,
	'shorten-pkgs!'   => \$shorten_pkgs,
	'state=s'         => \@states,
	'stats!'          => \$statistics,
	'quiet!'          => \$quiet,
	'help'            => \$help,
) or usage();
$help && usage();


# internals
my %collapsed;

sub remember_stack {
	my ($stack, $count) = @_;
	$collapsed{$stack} += $count;
}

my @stack;
my $tname;
my $state = "?";

my %states_map = map {$_ => 1} @states;
my %states_counter;

while (<>) {
	next if m/^#/;
	chomp;

	if (m/^$/) {
		$states_counter{$state}++ if $state ne "?";

		# only include RUNNABLE states
		goto clear unless $states_map{ $state };

		# save stack
		if (defined $tname) { unshift @stack, $tname; }
		remember_stack(join(";", @stack), 1) if @stack;
clear:
		undef @stack;
		undef $tname;
		$state = "?";
		next;
	}

	#
	# While parsing jstack output, the $state variable may be altered from
	# RUNNABLE to other states. This causes the stacks to be filtered later,
	# since only RUNNABLE stacks are included.
	#

	if (/^"([^"]*)/) {
		my $name = $1;

		if ($include_tname) {
			$tname = $name;
			unless ($include_tid) {
				$tname =~ s/-\d+$//;
			}
		}

		# set state for various background threads
		$state = "BACKGROUND" if $name =~ /C. CompilerThread/;
		$state = "BACKGROUND" if $name =~ /Surrogate Locker Thread/;
		$state = "BACKGROUND" if $name =~ /Signal Dispatcher/;
		$state = "BACKGROUND" if $name =~ /Service Thread/;
		$state = "BACKGROUND" if $name =~ /Attach Listener/;
		$state = "BACKGROUND" if $name =~ /DestroyJavaVM/;

	} elsif (/java.lang.Thread.State: (\S+)/) {
		$state = $1 if $state eq "?";
	} elsif (/(Thread \d+): \(state = (\S+)\)/) {
		my $name = $1;
		$state = $2 if $state eq "?";

		# fix state for "jstack -F"
		$state = "WAITING"  if $state eq "BLOCKED";
		$state = "RUNNABLE" if $state eq "IN_JAVA";
		$state = "RUNNABLE" if $state eq "IN_NATIVE";
		$state = "RUNNABLE" if $state eq "IN_NATIVE_TRANS";
		$state = "RUNNABLE" if $state eq "IN_VM";

	} elsif (/^\s*(?:at|-) ([^\(]*)/) {
		my $func = $1;
		my $should_collapse;
		for my $collapse_frame (@collapse_frames) {
			if ($func =~ m/$collapse_frame/) {
				$should_collapse = $collapse_frame;
				last; # No need to test other patterns
			}
		}
		my $processes_func = $func;
		if ($shorten_pkgs) {
			my ($pkgs, $clsFunc) = ( $func =~ m/(.*\.)([^.]+\.[^.]+)$/ );
			$pkgs =~ s/(\w)\w*/$1/g;
			$processes_func = $pkgs . $clsFunc;
		}

		if ($should_collapse) {
			$processes_func = $should_collapse ."...";
		}

		# Enqueue only if not already collapsed
		unshift @stack, $processes_func unless $should_collapse && @stack && $stack[0] eq $processes_func;

		# fix state for epollWait
		$state = "WAITING" if $func =~ /epollWait/;

		# Accepting a socket is waiting. No CPU is used anywhere.
		$state = "NETWORK_WAITING" if $func =~ /socketAccept$/;
		$state = "NETWORK_WAITING" if $func =~ /Socket.*accept0$/;

		# This is "used CPU".... elsewhere, but still used
		$state = "NETWORK" if $func =~ /SocketImpl.*receive0$/;
		$state = "NETWORK" if $func =~ /socketRead0$/;

	} elsif (/^\s*-/ or /^2\d\d\d-/ or /^Full thread dump/ or
		 /^\s*Locked ownable synchronizers:/ or
		 /^JNI global references:/) {
		# skip these info lines
		next;
	} else {
		warn "Unrecognized line: $_" unless $quiet;
	}
}

foreach my $k (sort { $a cmp $b } keys %collapsed) {
	print "$k $collapsed{$k}\n";
}

if ($statistics) {
	foreach my $k (sort { $a cmp $b } keys %states_counter) {
		print STDERR "$k: $states_counter{$k}\n";
	}
}
