package Plugins::DRLive::VODProtocolHandler;

# Protocol handler for drvod://<show-id> URLs - always resolves to that show's
# most recently published episode (e.g. drvod://358871 = TVA, DR's flagship
# news programme). Configured via the 'shows' server preference; the
# resolution logic itself is generic to any dr-massive show id.
#
# Unlike drlive:// (a live channel that loops forever), this is a finite VOD
# clip: no repeat, and playback ends normally when the clip does. It has its
# own content type (drvod, see custom-types.conf) separate from drlive's, and
# unlike the live channels it declares the "T" (seek-to-start-time) capability
# as well as "R" (see custom-convert.conf).
#
# Seeking was attempted in v0.1.9-v0.1.11 and reverted in v0.1.12 on the
# belief that a seek on an "R" (remote-fed) transcoded stream tripped a bug in
# LMS's own core: a seek-triggered reopen reliably made
# Slim::Player::Source::_readNextChunk report "end of file or error on socket"
# about a second in. That diagnosis was wrong. Two measurements overturned it:
#
#   - A test build (v0.1.13) kept the "T" profile but streamed Apple's public
#     BipBop HLS VOD sample instead of DR. Seeking through LMS worked
#     perfectly, so LMS's "R"+"T" path was never the problem.
#   - DR's own renditions are byterange fMP4 playlists, which ffmpeg's HLS
#     demuxer truncates (see HLS::byterange_file). ffmpeg exits 0 on the
#     truncation, so LMS saw a stream that had simply ended - it was reporting
#     the symptom accurately. Seeking only made it obvious, by forcing a
#     reopen.
#
# Since v0.1.15 the stream handed to ffmpeg is the underlying .mp4 rather than
# that playlist, which decodes in full and seeks frame-accurately (measured:
# -ss 259.52 into a 748s episode returns exactly the 488.68s remainder). That
# is what makes the "T" capability well-founded here rather than a guess.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Music::Info;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Strings;

use Plugins::DRLive::API;
use Plugins::DRLive::HLS;

my $log = logger('plugin.drlive');

sub isRemote           { 1 }
sub canDirectStream    { 0 }
sub isRepeatingStream  { 0 }
sub audioScrobblerSource { }

sub getFormatForURL { 'drvod' }

# Paired with the "T" capability in custom-convert.conf: LMS only reports the
# track seekable, and only calls this, when both are present.
sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	# Nothing else logs a seek/resume - getNextTrack (and its "stream ->" log
	# line) does not run again for one, since $song->streamUrl() is already
	# resolved. Without this, a misbehaving seek leaves no trace of whether it
	# was even attempted, let alone with what offset - info-level (not warn),
	# matching the rest of this file: an ordinary seek is not an anomaly, and
	# this fires on every one.
	main::INFOLOG && $log->is_info && $log->info("DRLive: seek requested for " . $song->currentTrack()->url . " -> ${newtime}s");
	return { timeOffset => $newtime };
}

sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack());
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->currentTrack()->url;
	my ($showId) = $url =~ m{^drvod://(\d+)}i;

	unless ($showId) {
		return $errorCb->("DRLive: malformed URL '$url'");
	}

	Plugins::DRLive::API->getLatestVod($showId, sub {
		my $info = shift;
		my $master = $info && $info->{url};

		unless ($master) {
			return $errorCb->("DRLive: could not resolve the latest episode for show $showId");
		}

		$song->pluginData(drlive => $info);

		# getMetadataFor's 'duration' key alone does NOT drive the progress bar:
		# for a piped/transcoded remote stream (canDirectStream => 0) LMS has no
		# HTTP response to estimate length from, so $song->duration() falls back
		# to Slim::Music::Info::getDuration($url) - which reads a DB attribute
		# that only setDuration() (below) populates. The drvod://<show-id> URL
		# stays the same across episodes, so this needs to run on every resolve
		# to keep it matching whichever episode is now behind that URL.
		if ($info->{duration}) {
			Slim::Music::Info::setDuration($url, $info->{duration});
		}

		# Fetch the master playlist and prefer a pure audio-only rendition -
		# smaller, and never trips ffmpeg's "Invalid NAL unit size" warnings
		# the way a video rendition demuxed for audio only can. Fall back to
		# the lowest-bandwidth video variant, then the master URL itself, if
		# anything along the way comes up empty.
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http    = shift;
				my $content = $http->content;
				my $variant = Plugins::DRLive::HLS::audio_variant($content, $master)
					|| Plugins::DRLive::HLS::lowest_variant($content, $master)
					|| $master;

				# One more hop: DR's on-demand renditions are byterange
				# playlists over a single .mp4, which ffmpeg's HLS demuxer
				# truncates to a few seconds (see HLS::byterange_file). If this
				# is one, stream that .mp4 directly instead. Any failure here
				# just falls back to the variant playlist - the previous
				# behaviour - rather than failing the whole resolve.
				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $direct = Plugins::DRLive::HLS::byterange_file(shift->content, $variant);
						$song->streamUrl($direct || $variant);
						main::INFOLOG && $log->is_info && $log->info(
							"DRLive: VOD show $showId stream -> " . ($direct || $variant)
							. ($direct ? ' (byterange playlist, using the .mp4 directly)' : ''));
						$successCb->();
					},
					sub {
						my ($http, $error) = @_;
						$log->warn("DRLive: variant playlist fetch failed ($error), using $variant");
						$song->streamUrl($variant);
						$successCb->();
					},
					{ timeout => 15 },
				)->get($variant);
			},
			sub {
				my ($http, $error) = @_;
				$log->warn("DRLive: VOD master playlist fetch failed ($error), using master URL");
				$song->streamUrl($master);
				$successCb->();
			},
			{ timeout => 15 },
		)->get($master);
	});
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my ($showId) = $url =~ m{^drvod://(\d+)}i;
	my $info = $showId ? Plugins::DRLive::API->cachedVod($showId) : undef;

	my $title = ($info && $info->{title})
		|| ($showId && Plugins::DRLive::API->fallbackShowName($showId))
		|| 'DR';
	my $icon = ($info && $info->{logo}) || 'plugins/DRLive/html/images/icon.png';

	return {
		title    => $title,
		artist   => 'DR',
		album    => Slim::Utils::Strings::string('PLUGIN_DRLIVE_VOD_STREAM_TYPE'),
		cover    => $icon,
		icon     => $icon,
		bitrate  => '',
		duration => $info && $info->{duration},
		type     => Slim::Utils::Strings::string('PLUGIN_DRLIVE_VOD_STREAM_TYPE'),
	};
}

1;
