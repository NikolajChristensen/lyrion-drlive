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
# "master-archive.m3u8?startTime=...&endTime=..." URL. DR's own catalogue
# backend has been observed to briefly return an implausibly wide window (a
# full 6-hour programming block instead of the ~14-minute episode) in the
# minutes right after a new episode is published, before its metadata has
# fully settled; re-querying the same episode id minutes later returns a
# correctly-sized window. Returns false only when the window is clearly wrong
# relative to the catalogue's own expected duration - a non-archive URL (no
# startTime/endTime at all) or a missing expected duration both pass, since
# there's nothing to sanity-check against.
sub archive_window_is_sane {
	my ($url, $expectedDuration) = @_;
	return 1 unless $expectedDuration;

	my ($start) = $url =~ /[?&]startTime=(\d+)/;
	my ($end)   = $url =~ /[?&]endTime=(\d+)/;
	return 1 unless defined $start && defined $end;

	my $window = $end - $start;
	# Generous tolerance - a real episode can run a bit long or short of the
	# catalogue's stated duration; only reject windows wildly out of range.
	return $window <= $expectedDuration + 600;
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
