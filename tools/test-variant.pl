#!/usr/bin/env perl
# Unit test for Plugins::DRLive::HLS, the shared HLS master-playlist parser.
#
# Loaded directly - no Slim::* stubbing needed, because that module is
# deliberately dependency-free (see its own header comment).
use strict;
use warnings;
use FindBin qw($Bin);

require "$Bin/../Plugins/DRLive/HLS.pm";

my $ok = 1;
sub is {
	my ($got, $exp, $name) = @_;
	if (defined $got && $got eq $exp) { print "ok   - $name\n" }
	else { $ok = 0; print "FAIL - $name\n     got: ", $got // '(undef)', "\n     exp: $exp\n" }
}
sub is_undef {
	my ($got, $name) = @_;
	if (!defined $got) { print "ok   - $name\n" }
	else { $ok = 0; print "FAIL - $name\n     got: $got\n     exp: (undef)\n" }
}

my $base = 'https://cdn.example.net/hls/live/123/chan/master.m3u8';

my $master = <<'M3U8';
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=6050368,RESOLUTION=1280x720
5.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=767784,RESOLUTION=640x360
1.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2300392,RESOLUTION=1024x576
3.m3u8
M3U8

is(Plugins::DRLive::HLS::lowest_variant($master, $base),
   'https://cdn.example.net/hls/live/123/chan/1.m3u8',
   'lowest_variant: picks lowest BANDWIDTH, resolves relative URI');

my $absMaster = <<'M3U8';
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=999
https://other.cdn.net/a/low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000
https://other.cdn.net/a/high.m3u8
M3U8
is(Plugins::DRLive::HLS::lowest_variant($absMaster, $base),
   'https://other.cdn.net/a/low.m3u8',
   'lowest_variant: keeps absolute variant URI');

my $rooted = <<'M3U8';
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=100
/abs/path/v1.m3u8
M3U8
is(Plugins::DRLive::HLS::lowest_variant($rooted, $base),
   'https://cdn.example.net/abs/path/v1.m3u8',
   'lowest_variant: resolves root-relative URI against scheme+host');

is_undef(Plugins::DRLive::HLS::lowest_variant("#EXTM3U\n", $base),
   'lowest_variant: undef when there are no variants');

# --- audio_variant -----------------------------------------------------------

my $vodMaster = <<'M3U8';
#EXTM3U
#EXT-X-VERSION:6
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="AUDIO",NAME="Danish",LANGUAGE="da",AUTOSELECT=YES,DEFAULT=YES,CHANNELS="2",URI="audio_192kbps.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Dansk",URI="../subtitles/playlist.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=771054,CODECS="avc1.42C01E,mp4a.40.2",AUDIO="AUDIO"
video_500.m3u8
M3U8

is(Plugins::DRLive::HLS::audio_variant($vodMaster, $base),
   'https://cdn.example.net/hls/live/123/chan/audio_192kbps.m3u8',
   'audio_variant: finds the AUDIO group URI, ignores SUBTITLES');

is_undef(Plugins::DRLive::HLS::audio_variant($master, $base),
   'audio_variant: undef when the manifest has no AUDIO group (the live-channel case)');

is_undef(Plugins::DRLive::HLS::audio_variant(undef, $base),
   'audio_variant: undef on empty content');

# --- abs_url -------------------------------------------------------------

is(Plugins::DRLive::HLS::abs_url('4.m3u8', 'https://h.net/a/b/master.m3u8?token=x'),
   'https://h.net/a/b/4.m3u8',
   'abs_url: strips query and last segment');

# A "/" inside the query string must not be taken for the last path separator.
is(Plugins::DRLive::HLS::abs_url('4.m3u8', 'https://h.net/a/b/master.m3u8?p=x/y&q=1'),
   'https://h.net/a/b/4.m3u8',
   'abs_url: ignores a slash inside the query string');

is(Plugins::DRLive::HLS::abs_url('4.m3u8', 'https://h.net/a/b/master.m3u8#frag/ment'),
   'https://h.net/a/b/4.m3u8',
   'abs_url: ignores a slash inside the fragment');

is(Plugins::DRLive::HLS::abs_url('/abs/v.m3u8', 'https://h.net/a/b/master.m3u8?p=x/y'),
   'https://h.net/abs/v.m3u8',
   'abs_url: resolves root-relative against scheme+host, query ignored');

is(Plugins::DRLive::HLS::abs_url('  4.m3u8  ', 'https://h.net/a/b/master.m3u8'),
   'https://h.net/a/b/4.m3u8',
   'abs_url: trims surrounding whitespace');

# --- is_archive_url ---------------------------------------------------------

# Real cases from a live server: both a 6-hour bad window AND a correctly-sized
# one (matching the episode's own 840s catalogue duration almost exactly)
# still came from this same "live-channel archive" delivery style, and the
# correctly-sized one still failed moments later with an HTTP 403 - so both
# must be rejected, not just implausibly-sized ones.
my $archiveUrlBadWindow  = 'https://drlivedr1hls.akamaized.net/hls/live/2113625/drlivedr1/master-archive.m3u8?startTime=1789016399&endTime=1789037999';
my $archiveUrlGoodWindow = 'https://drlivedr1hls.akamaized.net/hls/live/2113625/drlivedr1/master-archive.m3u8?startTime=1789016399&endTime=1789017240';

if (Plugins::DRLive::HLS::is_archive_url($archiveUrlBadWindow)) {
	print "ok   - is_archive_url: detects the 6-hour-window archive URL\n";
} else {
	$ok = 0;
	print "FAIL - is_archive_url: should have detected the archive URL\n";
}

if (Plugins::DRLive::HLS::is_archive_url($archiveUrlGoodWindow)) {
	print "ok   - is_archive_url: detects a correctly-sized archive URL too (rejected regardless of size)\n";
} else {
	$ok = 0;
	print "FAIL - is_archive_url: should reject archive URLs regardless of window size\n";
}

if (!Plugins::DRLive::HLS::is_archive_url('https://drod20j.akamaized.net/all/clear/none/a2/x/00122625240/stream_fmp4/master_manifest.m3u8')) {
	print "ok   - is_archive_url: a plain on-demand manifest URL (no startTime/endTime) passes\n";
} else {
	$ok = 0;
	print "FAIL - is_archive_url: a plain on-demand URL should not be flagged as an archive URL\n";
}

if (!Plugins::DRLive::HLS::is_archive_url(undef)) {
	print "ok   - is_archive_url: undef URL is not an archive URL\n";
} else {
	$ok = 0;
	print "FAIL - is_archive_url: undef should not be flagged as an archive URL\n";
}

exit($ok ? 0 : 1);
