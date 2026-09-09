#!/usr/bin/env perl
# Unit test for the playlist helpers in Plugins::DRLive::ProtocolHandler,
# loaded in isolation (no Lyrion runtime).
use strict;
use warnings;

# Pull just the helper subs out of the module.
my $src = do {
	local $/;
	open my $fh, '<', 'Plugins/DRLive/ProtocolHandler.pm' or die $!;
	<$fh>;
};
my ($helpers) = $src =~ /(sub _lowestVariant\b.*)\n1;/s;
die "could not extract helpers\n" unless $helpers;
eval "package T; $helpers 1;" or die "compile: $@";

my $ok = 1;
sub is {
	my ($got, $exp, $name) = @_;
	if (defined $got && $got eq $exp) { print "ok   - $name\n" }
	else { $ok = 0; print "FAIL - $name\n     got: ", $got // '(undef)', "\n     exp: $exp\n" }
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

is(T::_lowestVariant($master, $base),
   'https://cdn.example.net/hls/live/123/chan/1.m3u8',
   'picks lowest BANDWIDTH, resolves relative URI');

my $absMaster = <<'M3U8';
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=999
https://other.cdn.net/a/low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=5000
https://other.cdn.net/a/high.m3u8
M3U8
is(T::_lowestVariant($absMaster, $base),
   'https://other.cdn.net/a/low.m3u8',
   'keeps absolute variant URI');

my $rooted = <<'M3U8';
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=100
/abs/path/v1.m3u8
M3U8
is(T::_lowestVariant($rooted, $base),
   'https://cdn.example.net/abs/path/v1.m3u8',
   'resolves root-relative URI against scheme+host');

is(T::_lowestVariant("#EXTM3U\n#EXT-X-ENDLIST\n", $base), undef,
   'returns undef when there are no variants')
	if 0; # is() can't assert undef==eq; check manually
{
	my $r = T::_lowestVariant("#EXTM3U\n", $base);
	if (!defined $r) { print "ok   - undef when no variants\n" }
	else { $ok = 0; print "FAIL - undef when no variants (got $r)\n" }
}

is(T::_absUrl('4.m3u8', 'https://h.net/a/b/master.m3u8?token=x'),
   'https://h.net/a/b/4.m3u8',
   '_absUrl strips query and last segment');

exit($ok ? 0 : 1);
