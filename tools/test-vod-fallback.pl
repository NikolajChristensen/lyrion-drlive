#!/usr/bin/env perl
# Exercises Plugins::DRLive::API::getLatestVod's fallback path against canned
# responses, without depending on DR's API happening to be in the "newest
# episode is archive-only" state at the moment this runs (it usually isn't -
# that only lasts a few minutes after a new episode publishes).
#
# Stubs Slim::Networking::SimpleAsyncHTTP to synchronously dispatch a fake
# response based on which URL is requested, simulating: episode A (newest) has
# only a live-channel archive resource; episode B (next-newest) has a proper
# standalone file. A working fallback resolves to B; a broken one resolves to
# nothing, or to A.
use strict;
use warnings;
no warnings 'once';
use FindBin qw($Bin);
use JSON::PP ();

my $STUB = "$Bin/.test-vod-fallback-stub";
system('rm', '-rf', $STUB);
for my $dir (qw(Slim/Plugin Slim/Utils Slim/Player/Protocols Slim/Networking Slim/Music JSON)) {
	system('mkdir', '-p', "$STUB/$dir");
}

open my $fh, '>', "$STUB/Slim/Utils/Log.pm" or die $!;
print $fh <<'EOF';
package Slim::Utils::Log; use Exporter 'import'; our @EXPORT = qw(logger);
sub addLogCategory { bless {}, 'Slim::Utils::Log::L' }
sub logger         { bless {}, 'Slim::Utils::Log::L' }
package Slim::Utils::Log::L;
our @WARNINGS;
sub is_info {0} sub is_debug {0} sub info {}
sub warn  { shift; push @WARNINGS, "@_" }
sub error { shift; push @WARNINGS, "@_" }
sub debug {}
package Slim::Utils::Log; 1;
EOF
close $fh;

open $fh, '>', "$STUB/Slim/Utils/Cache.pm" or die $!;
print $fh <<'EOF';
package Slim::Utils::Cache;
our %STORE;
sub new { bless {}, shift }
sub get { $STORE{$_[1]} }
sub set { $STORE{$_[1]} = $_[2] }
1;
EOF
close $fh;

open $fh, '>', "$STUB/JSON/XS.pm" or die $!;
print $fh <<'EOF';
package JSON::XS; use Exporter 'import'; our @EXPORT_OK = qw(decode_json encode_json);
use JSON::PP ();
sub decode_json { JSON::PP::decode_json(@_) }
sub encode_json { JSON::PP::encode_json(@_) }
1;
EOF
close $fh;

# The heart of the test: dispatches a canned JSON body per requested URL.
open $fh, '>', "$STUB/Slim/Networking/SimpleAsyncHTTP.pm" or die $!;
print $fh <<'EOF';
package Slim::Networking::SimpleAsyncHTTP;
our @REQUESTS;   # every URL requested, in order - lets the test assert on call sequence
our %RESPONSES;  # url-substring => JSON body string

sub new {
	my ($class, $successCb, $errorCb, $opts) = @_;
	return bless { success => $successCb, error => $errorCb }, $class;
}

sub _dispatch {
	my ($self, $url) = @_;
	push @REQUESTS, $url;
	for my $pattern (keys %RESPONSES) {
		if ($url =~ /\Q$pattern\E/) {
			my $body = $RESPONSES{$pattern};
			my $http = bless { content => $body }, 'Slim::Networking::SimpleAsyncHTTP::Response';
			return $self->{success}->($http);
		}
	}
	$self->{error}->(bless({}, 'Slim::Networking::SimpleAsyncHTTP::Response'), 'no canned response for ' . $url);
}

sub get  { my $self = shift; $self->_dispatch($_[0]); }
sub post { my $self = shift; $self->_dispatch($_[0]); }

package Slim::Networking::SimpleAsyncHTTP::Response;
sub content { $_[0]->{content} }
1;
EOF
close $fh;

# Everything else API.pm needs, unused by this test's logic but required to
# compile/load.
open $fh, '>', "$STUB/Slim/Utils/Prefs.pm" or die $!;
print $fh "package Slim::Utils::Prefs; use Exporter 'import'; our \@EXPORT = qw(preferences);\nsub preferences { bless {}, 'Slim::Utils::Prefs::P' }\npackage Slim::Utils::Prefs::P; sub init {} sub get {} sub set {}\npackage Slim::Utils::Prefs; 1;\n";
close $fh;

# --- canned data -------------------------------------------------------------
package main;

$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'anonymous-sso'} = JSON::PP::encode_json(
	[ { type => 'UserAccount', value => 'fake-token' } ]
);

$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'items/999'} = JSON::PP::encode_json(
	{ seasons => { items => [ { id => 'season1' } ] } }
);

$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'items/season1'} = JSON::PP::encode_json({
	episodes => { items => [
		{ id => 'epA', title => 'Newest (archive-only)', duration => 900,
		  offers => [ { availability => 'Available' } ] },
		{ id => 'epB', title => 'Next-newest (proper file)', duration => 900,
		  offers => [ { availability => 'Available' } ] },
	] }
});

$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'items/epA/videos'} = JSON::PP::encode_json([
	{ accessService => 'StandardVideo', drm => 'None',
	  url => 'https://cdn.example.net/live/chan/master-archive.m3u8?startTime=100&endTime=200' },
]);

$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'items/epB/videos'} = JSON::PP::encode_json([
	{ accessService => 'StandardVideo', drm => 'None',
	  url => 'https://cdn.example.net/vod/epB/master.m3u8' },
]);

BEGIN { *main::INFOLOG = sub () { 1 }; *main::DEBUGLOG = sub () { 1 }; }
unshift @INC, $STUB, "$Bin/..";
require Plugins::DRLive::API;

my $ok = 1;
my $result;
Plugins::DRLive::API->getLatestVod('999', sub { $result = shift });

unless ($result) {
	$ok = 0;
	print "FAIL - getLatestVod returned nothing; expected a fallback to episode B\n";
	print "       warnings logged: ", join('; ', @Slim::Utils::Log::L::WARNINGS), "\n";
} elsif ($result->{url} eq 'https://cdn.example.net/vod/epB/master.m3u8') {
	print "ok   - getLatestVod fell back from the archive-only newest episode to the next one\n";
} else {
	$ok = 0;
	print "FAIL - getLatestVod resolved to the wrong URL: $result->{url}\n";
	print "       (expected episode B's proper file - did it use the archive URL instead?)\n";
}

my @requested_videos = grep { /\/videos/ } @Slim::Networking::SimpleAsyncHTTP::REQUESTS;
if (grep { /epA\/videos/ } @requested_videos and grep { /epB\/videos/ } @requested_videos) {
	print "ok   - both episode A and episode B's video resources were actually requested\n";
} else {
	$ok = 0;
	print "FAIL - expected requests for both epA/videos and epB/videos, got: @requested_videos\n";
}

# --- attempt cap: 5 archive-only episodes in a row, a 6th that would work ---
# The cap must win: give up rather than chase an unbounded run of bad luck.
$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'items/998'} = JSON::PP::encode_json(
	{ seasons => { items => [ { id => 'season2' } ] } }
);
$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'items/season2'} = JSON::PP::encode_json({
	episodes => { items => [
		map +{ id => "epC$_", title => "Episode $_", duration => 900,
		       offers => [ { availability => 'Available' } ] }, (1 .. 6)
	] }
});
for my $n (1 .. 5) {
	$Slim::Networking::SimpleAsyncHTTP::RESPONSES{"items/epC$n/videos"} = JSON::PP::encode_json([
		{ accessService => 'StandardVideo', drm => 'None',
		  url => "https://cdn.example.net/live/chan/master-archive.m3u8?startTime=$n&endTime=" . (100 + $n) },
	]);
}
$Slim::Networking::SimpleAsyncHTTP::RESPONSES{'items/epC6/videos'} = JSON::PP::encode_json([
	{ accessService => 'StandardVideo', drm => 'None', url => 'https://cdn.example.net/vod/epC6/master.m3u8' },
]);

@Slim::Networking::SimpleAsyncHTTP::REQUESTS = ();
my $capResult = 'not called';
Plugins::DRLive::API->getLatestVod('998', sub { $capResult = shift });

if (!defined $capResult) {
	print "ok   - gives up after the attempt cap rather than trying every episode\n";
} else {
	$ok = 0;
	print "FAIL - expected the cap to stop resolution, got: ", (ref $capResult ? $capResult->{url} : $capResult), "\n";
}

my @cap_video_requests = grep { /\/videos/ } @Slim::Networking::SimpleAsyncHTTP::REQUESTS;
if (@cap_video_requests == 5 && !grep { /epC6/ } @cap_video_requests) {
	print "ok   - tried exactly 5 episodes, never reaching the 6th (working) one\n";
} else {
	$ok = 0;
	print "FAIL - expected exactly 5 video requests (epC1-epC5), got: @cap_video_requests\n";
}

system('rm', '-rf', $STUB);
exit($ok ? 0 : 1);
