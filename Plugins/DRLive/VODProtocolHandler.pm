package Plugins::DRLive::VODProtocolHandler;

# Protocol handler for drvod://<show-id> URLs - always resolves to that show's
# most recently published episode (e.g. drvod://358871 = TVA, DR's flagship
# news programme). Configured via the 'shows' server preference; the
# resolution logic itself is generic to any dr-massive show id.
#
# Unlike drlive:// (a live channel that loops forever), this is a finite VOD
# clip: no repeat, and playback ends normally when the clip does. It shares
# the drlive-*-*-* ffmpeg profiles in custom-convert.conf - see getFormatForURL
# below and the matching line in custom-types.conf.

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
sub canSeek            { 0 }
sub isRepeatingStream  { 0 }
sub audioScrobblerSource { }

# Reuses the "drlive" content type - see custom-types.conf - so the existing
# drlive-flc/mp3/pcm-*-* profiles in custom-convert.conf apply here too. There
# is nothing live-specific about those profiles: "(R)" + a plain ffmpeg command
# line, which is exactly what a VOD manifest also needs.
sub getFormatForURL { 'drlive' }

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
