package Plugins::DRLive::VODProtocolHandler;

# Protocol handler for drvod://<show-id> URLs - always resolves to that show's
# most recently published episode (e.g. drvod://358871 = TVA, DR's flagship
# news programme). Configured via the 'shows' server preference; the
# resolution logic itself is generic to any dr-massive show id.
#
# Unlike drlive:// (a live channel that loops forever), this is a finite VOD
# clip: no repeat, and playback ends normally when the clip does. DR ships it
# as a genuinely seekable file, so - unlike drlive:// - it has its own content
# type (drvod, see custom-types.conf) with custom-convert.conf profiles
# declaring the "T" (seek-to-start-time) capability, plus getSeekData below.
#
# Deliberately NOT overriding canSeek: the inherited default (from
# Slim::Player::Protocols::HTTP) does byte-offset math for a directly-streamed
# file, which does not apply here (canDirectStream => 0) and correctly returns
# false since no bitrate is known at the handler level. Seekability instead
# comes from Slim::Player::Song's own, separate check for a convert.conf
# profile declaring "T" for this content type - forcing canSeek to true here
# would make LMS treat this as the byte-offset kind of seek instead, which
# getSeekData below does not implement.

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

# Called by Slim::Player::Song::getSeekData for both an explicit seek and a
# resume-after-pause (LMS closes the stream on pause, then re-opens it at the
# elapsed position on resume - the same mechanism as a user-initiated seek).
# The returned 'timeOffset' flows through to the "T" capability's %s
# substitution in custom-convert.conf, becoming ffmpeg's -ss argument -
# ffmpeg then fast-seeks within the HLS manifest to that position rather than
# decoding from the start. $song->streamUrl() is already resolved from the
# original getNextTrack call and is not re-fetched here.
sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
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
				$song->streamUrl($variant);
				main::INFOLOG && $log->is_info && $log->info("DRLive: VOD show $showId stream -> $variant");
				$successCb->();
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
