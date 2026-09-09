package Plugins::DRLive::ProtocolHandler;

# Protocol handler for drlive://<channel-id> URLs (e.g. drlive://20876 = DR2).
#
# It never streams bytes itself: getNextTrack() resolves the channel to an HLS
# variant playlist and stores it in $song->streamUrl(). getFormatForURL()
# returns 'drlive', so LMS matches the "drlive -> flc/pcm/mp3" rules in
# custom-convert.conf and runs ffmpeg on that URL.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Strings;

use Plugins::DRLive::API;

my $log = logger('plugin.drlive');

sub isRemote           { 1 }
sub canDirectStream    { 0 }
sub canSeek            { 0 }
sub canSkip            { 0 }
sub isRepeatingStream  { 1 }
sub audioScrobblerSource { }

# no rewind / no "next track" for a live stream
sub canDoAction {
	my ($class, $client, $url, $action) = @_;
	return 0 if $action eq 'rew';
	return 1;
}

# Tells Slim::Music::Info the content type -> selects the custom-convert profile.
sub getFormatForURL { 'drlive' }

# Nothing to scan - hand the track straight back.
sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->($args->{song}->currentTrack());
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $url = $song->currentTrack()->url;
	my ($id) = $url =~ m{^drlive://(\d+)}i;

	unless ($id) {
		return $errorCb->("DRLive: malformed URL '$url'");
	}

	Plugins::DRLive::API->getStreamInfo($id, sub {
		my $info = shift;
		my $master = $info && $info->{url};

		unless ($master) {
			return $errorCb->("DRLive: could not resolve a stream for channel $id");
		}

		$song->pluginData(drlive => $info);

		# Fetch the master playlist and pick the lowest-bandwidth variant so
		# ffmpeg does not pull the 8 Mbit/s 1080p rendition just to throw the
		# video away. Fall back to the master URL if anything goes wrong.
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $variant = _lowestVariant($http->content, $master) || $master;
				$song->streamUrl($variant);
				main::INFOLOG && $log->is_info && $log->info("DRLive: channel $id stream -> $variant");
				$successCb->();
			},
			sub {
				my ($http, $error) = @_;
				$log->warn("DRLive: master playlist fetch failed ($error), using master URL");
				$song->streamUrl($master);
				$successCb->();
			},
			{ timeout => 15 },
		)->get($master);
	});
}

sub getMetadataFor {
	my ($class, $client, $url) = @_;

	my ($id) = $url =~ m{^drlive://(\d+)}i;
	my $info = $id ? Plugins::DRLive::API->cachedInfo($id) : undef;

	my $title = ($info && $info->{title})
		|| ($id && Plugins::DRLive::API->fallbackName($id))
		|| 'DR Live';
	my $icon = ($info && $info->{logo}) || 'plugins/DRLive/html/images/icon.png';

	return {
		title   => $title,
		artist  => 'DR',
		album   => 'DR Live',
		cover   => $icon,
		icon    => $icon,
		bitrate => '',
		type    => Slim::Utils::Strings::string('PLUGIN_DRLIVE_STREAM_TYPE'),
	};
}

# --- helpers -----------------------------------------------------------------

sub _lowestVariant {
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
	return _absUrl($bestUri, $baseUrl);
}

sub _absUrl {
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
