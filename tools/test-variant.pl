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

# --- archive_window_is_sane ------------------------------------------------

# Real case: DR's catalogue briefly returned this exact 6-hour window for an
# episode whose own duration was 840s, minutes after it was published.
my $badArchiveUrl  = 'https://drlivedr1hls.akamaized.net/hls/live/2113625/drlivedr1/master-archive.m3u8?startTime=1789016399&endTime=1789037999';
my $goodArchiveUrl = 'https://drlivedr1hls.akamaized.net/hls/live/2113625/drlivedr1/master-archive.m3u8?startTime=1789016399&endTime=1789017240';

if (!Plugins::DRLive::HLS::archive_window_is_sane($badArchiveUrl, 840)) {
	print "ok   - archive_window_is_sane: rejects a 6-hour window for an 840s episode\n";
} else {
	$ok = 0;
	print "FAIL - archive_window_is_sane: should have rejected the 6-hour window\n";
}

if (Plugins::DRLive::HLS::archive_window_is_sane($goodArchiveUrl, 840)) {
	print "ok   - archive_window_is_sane: accepts a window matching the episode duration\n";
} else {
	$ok = 0;
	print "FAIL - archive_window_is_sane: should have accepted the correctly-sized window\n";
}

if (Plugins::DRLive::HLS::archive_window_is_sane('https://cdn.example.net/plain/master.m3u8', 840)) {
	print "ok   - archive_window_is_sane: a non-archive URL (no startTime/endTime) always passes\n";
} else {
	$ok = 0;
	print "FAIL - archive_window_is_sane: a non-archive URL should always pass\n";
}

if (Plugins::DRLive::HLS::archive_window_is_sane($badArchiveUrl, undef)) {
	print "ok   - archive_window_is_sane: passes when there's no expected duration to compare against\n";
} else {
	$ok = 0;
	print "FAIL - archive_window_is_sane: should pass when expected duration is unknown\n";
}

exit($ok ? 0 : 1);
