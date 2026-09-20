package Plugins::DRLive::VODProtocolHandler;

# Protocol handler for drvod://<show-id> URLs - always resolves to that show's
# most recently published episode (e.g. drvod://358871 = TVA, DR's flagship
# news programme). Configured via the 'shows' server preference; the
# resolution logic itself is generic to any dr-massive show id.
#
# Unlike drlive:// (a live channel that loops forever), this is a finite VOD
# clip: no repeat, and playback ends normally when the clip does. It has its
# own content type (drvod, see custom-types.conf) separate from drlive's,
# but - deliberately - the SAME "R"-only capability (see custom-convert.conf).
#
# Seeking (a "T" capability profile + getSeekData) was attempted in
# v0.1.9-v0.1.11 and reverted: live testing (real server.log, both a 4-player
# sync group and a single isolated player) showed a seek-triggered reopen
# reliably making LMS's OWN pipe-reading code (Slim::Player::Source::
# _readNextChunk) report "end of file or error on socket" about a second in,
# even though the identical ffmpeg command - same URL, same -ss offset, same
# reconnect flags - decoded the entire rest of the episode with zero errors
# when run directly, outside LMS. The seek value, getSeekData's return shape,
# canSeek's type (2 = transcoder-based, confirmed via LMS's own "seek=true
# time=... canSeek=2" log line), and the constructed command line were all
# independently confirmed correct. That combination of evidence points at a
# bug in LMS's own core handling of a seek on an "R" (remote-fed) transcoded
# stream, not in this plugin's code, ffmpeg, or the DR content, and it is not
# something fixable from a plugin. See the README's Troubleshooting section
# before re-attempting this.

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

# No getSeekData: without a "T" capability profile in custom-convert.conf,
# Slim::Player::Song's own capability check never reports this seekable, so
# LMS never calls it - see the header comment for why seeking was reverted.

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
