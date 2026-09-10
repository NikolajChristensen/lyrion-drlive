package Plugins::DRLive::HLS;

# Pure HLS master-playlist parsing helpers, shared by the live-channel
# (ProtocolHandler.pm) and on-demand (VODProtocolHandler.pm) handlers.
#
# Deliberately free of any Slim::* dependency, so it can be loaded and unit
# tested outside a running server - see tools/test-variant.pl.

use strict;
use warnings;

# Picks the lowest-BANDWIDTH #EXT-X-STREAM-INF variant in a master playlist.
# Used when a manifest has no separate audio-only rendition (all three live
# channels): ffmpeg still has to fetch that variant's video to get at its
# audio, so the lowest bitrate one wastes the least.
sub lowest_variant {
	my ($content, $baseUrl) = @_;
	return undef unless $content;

	my @lines = split /\r?\n/, $content;
	my ($bestBw, $bestUri);

	for (my $i = 0; $i < @lines; $i++) {
		next unless $lines[$i] =~ /^#EXT-X-STREAM-INF:/;
		my ($bw) = $lines[$i] =~ /[:,]BANDWIDTH=(\d+)/;
		$bw ||= 0;

		# the URI is the next non-comment, non-blank line
		my $uri;
		for (my $j = $i + 1; $j < @lines; $j++) {
			next if $lines[$j] =~ /^\s*$/ || $lines[$j] =~ /^#/;
			$uri = $lines[$j];
			last;
		}
		next unless $uri;

		if (!defined $bestBw || $bw < $bestBw) {
			$bestBw  = $bw;
			$bestUri = $uri;
		}
	}

	return undef unless $bestUri;
	return abs_url($bestUri, $baseUrl);
}

# Picks the URI of the first #EXT-X-MEDIA:TYPE=AUDIO rendition in a master
# playlist, if the manifest carries one. DR's on-demand (VOD) manifests often
# do; the live channels never have - only a video-embedded audio track. A
# genuine audio-only rendition is both smaller and, unlike a video rendition
# demuxed for audio only, never trips ffmpeg's "Invalid NAL unit size"
# warnings (harmless in practice, but worth avoiding when a clean option
# exists).
sub audio_variant {
	my ($content, $baseUrl) = @_;
	return undef unless $content;

	for my $line (split /\r?\n/, $content) {
		next unless $line =~ /^#EXT-X-MEDIA:TYPE=AUDIO\b/;
		my ($uri) = $line =~ /\bURI="([^"]+)"/;
		return abs_url($uri, $baseUrl) if $uri;
	}

	return undef;
}

# Some TVA episodes aren't delivered as a discrete on-demand file at all, but
# as a slice of the live channel's own catch-up/restart buffer - a
# "master-archive.m3u8?startTime=...&endTime=..." URL, typically in the
# minutes right after a new episode is published and before DR has finished
# repackaging it as a proper file. This has proven unreliable for programmatic
# (non-browser) playback in two separate, independent ways:
#
#   - DR's own catalogue backend has been observed to briefly return an
#     implausibly wide window (a full 6-hour programming block instead of the
#     ~14-minute episode) before its metadata settles.
#   - Even a correctly-sized window (matching the episode's own catalogue
#     duration almost exactly) can fail moments later with an HTTP 403 from
#     Akamai - the per-variant tokens embedded in its manifest appear to be
#     short-lived in a way their outer exp= field (which claims ~1 day
#     validity) doesn't reveal, and there's no reliable way from here to
#     verify the actual window, or whether a bare HTTP fetch's minimal
#     overhead succeeds only because it beats a timeout that ffmpeg's own
#     startup/probing overhead does not.
#
# Rather than gamble against an unknown, unverifiable timeout, this delivery
# style is declined outright; the caller falls back to an older episode that
# DR has already packaged as a proper file, like every other episode is.
sub is_archive_url {
	my $url = shift;
	return 0 unless defined $url;
	return $url =~ /[?&]startTime=\d+/ && $url =~ /[?&]endTime=\d+/;
}

sub abs_url {
	my ($ref, $base) = @_;
	$ref =~ s/^\s+|\s+$//g;
	return $ref if $ref =~ m{^https?://}i;

	if ($ref =~ m{^/}) {
		my ($schemeHost) = $base =~ m{^(https?://[^/]+)}i;
		return ($schemeHost || '') . $ref;
	}

	# Strip query/fragment first. Doing both in one pass lets a "/" inside a
	# query string be mistaken for the final path separator, because the regex
	# engine takes the leftmost match rather than the last slash of the path.
	(my $path = $base) =~ s/[?#].*\z//s;
	(my $dir  = $path) =~ s{[^/]*\z}{};
	return $dir . $ref;
}

1;
