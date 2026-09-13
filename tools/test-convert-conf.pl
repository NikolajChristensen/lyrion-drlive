#!/usr/bin/env perl
# Validates every capability line in custom-convert.conf against LMS's actual
# parsing grammar (Slim::Player::TranscodingHelper::_getCapabilities).
#
# This exists because a capability line can look plausible and still be
# silently rejected by LMS at startup with nothing worse than a log line
# ("syntax error in ...") - the profile then has no working transcoder at
# all, and every play attempt fails with the generic, unhelpful "Couldn't
# create command line" error. v0.1.9 shipped exactly this bug (a stray space
# in "R T:{START=-ss %s}" - LMS requires capability letters run together with
# no space, e.g. "RT:{START=-ss %s}") because it was checked against WORKING
# EXAMPLES rather than the actual grammar. This test checks the grammar
# directly so that mistake cannot ship silently again.
use strict;
use warnings;
use FindBin qw($Bin);

# Verbatim from Slim::Player::TranscodingHelper::_getCapabilities.
my $CAPABILITY_RE = qr/^([A-Z](\:\{\w+=[^}]+\})?)+$/;

my $path = "$Bin/../Plugins/DRLive/custom-convert.conf";
open my $fh, '<', $path or die "can't open $path: $!";
my @lines = <$fh>;
close $fh;

my $ok = 1;
my $checked = 0;

for (my $i = 0; $i < @lines; $i++) {
	# A profile line looks like "drvod flc * *" - the capability line is
	# always the very next non-blank line, starting with '#'.
	next unless $lines[$i] =~ /^\S+\s+\S+\s+\*\s+\*\s*$/;

	my $capLine = $lines[$i + 1] // '';
	$capLine =~ s/^\s*#\s*//;
	$capLine =~ s/\s+$//;

	$checked++;
	if ($capLine =~ $CAPABILITY_RE) {
		print "ok   - line ", $i + 2, ": '$capLine' is valid\n";
	} else {
		$ok = 0;
		print "FAIL - line ", $i + 2, ": '$capLine' does not match LMS's capability grammar\n";
		print "       (capability letters must run together with no space, e.g. 'RT:{...}' not 'R T:{...}')\n";
	}
}

unless ($checked) {
	$ok = 0;
	print "FAIL - found no profile lines to check in $path - did the file format change?\n";
}

exit($ok ? 0 : 1);
