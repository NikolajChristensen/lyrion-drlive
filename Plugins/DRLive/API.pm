package Plugins::DRLive::API;

# Resolves DR content to a playable HLS master URL using DR's public
# "dr-massive" catalogue API - the same anonymous, unauthenticated API DR's
# own web player (play.dr.dk) uses for its free content.
#
# Two independent things are resolved here:
#
# LIVE CHANNELS (getStreamInfo) - a fixed channel id (e.g. DR2) to its current
# live HLS master URL:
#   1. POST https://isl.dr-massive.com/api/authorization/anonymous-sso
#      -> anonymous bearer token (cached ~50 min)
#   2. GET  https://production-cdn.dr-massive.com/api/items/<id>?expand=all...
#      -> .customFields.hlsURL, .title, .images.logo  (cached ~1 h)
#   Falls back to a bundled static URL if the API is unavailable.
#
# ON-DEMAND SHOWS (getLatestVod) - a show id (e.g. TVA, DR's news programme)
# to its most recently published episode:
#   1. same anonymous token as above
#   2. GET items/<showId>  -> seasons.items[0].id (the current season)
#   3. GET items/<seasonId> -> episodes.items[] that DR marks "Available"
#      (the list is already newest-first)
#   4. GET isl.dr-massive.com/api/account/items/<episodeId>/videos
#      -> the first resource explicitly marked drm=None, excluding a
#         live-channel "archive" resource (see HLS::is_archive_url) - if the
#         newest episode offers only that, falls back to the next-newest
#   No static fallback here: unlike a live channel, a specific past episode's
#   URL going stale is not something a fixed table can meaningfully cover.

use strict;
use warnings;

use JSON::XS qw(decode_json);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

use Plugins::DRLive::HLS;

use constant SSO_URL    => 'https://isl.dr-massive.com/api/authorization/anonymous-sso?device=web_browser&lang=da&supportFallbackToken=true';
use constant ITEM_URL   => 'https://production-cdn.dr-massive.com/api/items/%s?device=web_browser&expand=all&ff=idp,ldp,rpt&geoLocation=dk&isDeviceAbroad=false&lang=da&segments=drtv,optedout&sub=Anonymous';

# Anonymous, DRM-aware manifest lookup for a single on-demand item. Only used
# for VOD (getLatestVod) - live channel items already carry their HLS URL
# directly in customFields.
use constant VIDEOS_URL => 'https://isl.dr-massive.com/api/account/items/%s/videos?delivery=stream&device=web_browser&ff=idp,ldp,rpt&lang=da&resolution=HD-1080&sub=Anonymous';

# DR serves channel logos at 2160x2160. LMS's image proxy does not merely run
# slow on those - it times out without erroring, so artwork silently never
# appears. DR's own resizer answers instantly, so ask it for a menu-sized image.
use constant LOGO_PX   => 300;

use constant TOKEN_TTL => 50 * 60;
use constant INFO_TTL  => 60 * 60;

# TVA publishes roughly five times a day (early morning, noon, 16:00, 18:30,
# 21:00) but not on a fixed schedule DR guarantees, so "latest" is re-checked
# often enough to catch a new episode within minutes, not once an hour.
use constant VOD_TTL   => 10 * 60;

# Seed table - id => { name, fallback }. Kept in sync with Plugin.pm's defaults.
# The fallback URLs were verified on 2026-09-08; the API path is preferred.
my %FALLBACK = (
	'20875' => { name => 'DR1',          url => 'https://drlivedr1hls.akamaized.net/hls/live/2113625/drlivedr1/master.m3u8' },
	'20876' => { name => 'DR2',          url => 'https://drlivedr2hls.akamaized.net/hls/live/2113623/drlivedr2/master.m3u8' },
	'20892' => { name => 'DR Ramasjang', url => 'https://drlivedrrhls.akamaized.net/hls/live/2113621/drlivedrr/master.m3u8' },
);

# Show id => display name, used only as a last-resort label before the first
# successful resolution. Kept in sync with Plugin.pm's defaults.
my %SHOW_FALLBACK = (
	'358871' => { name => 'TVA' },
);

my $log   = logger('plugin.drlive');
my $cache = Slim::Utils::Cache->new();

sub fallbackName {
	my ($class, $id) = @_;
	return $FALLBACK{$id} ? $FALLBACK{$id}->{name} : undef;
}

sub fallbackShowName {
	my ($class, $id) = @_;
	return $SHOW_FALLBACK{$id} ? $SHOW_FALLBACK{$id}->{name} : undef;
}

# The cache key carries a version: Slim::Utils::Cache persists across restarts,
# so an upgrade that changes the shape or content of $info (v2 shrank the logo
# URL) must not keep serving entries written by the previous version.
# Synchronous cache read only - safe to call from getMetadataFor / menu build.
sub cachedInfo {
	my ($class, $id) = @_;
	return $cache->get("drlive_info_v2_$id");
}

# Async: $cb->({ url => <hls master>, title => ..., logo => ... })
# Always calls back with something usable (falls back to the static table).
sub getStreamInfo {
	my ($class, $id, $cb) = @_;

	if (my $cached = $cache->get("drlive_info_v2_$id")) {
		return $cb->($cached);
	}

	my $fallback = sub {
		my $fb = $FALLBACK{$id};
		if ($fb && $fb->{url}) {
			$log->warn("DRLive: using fallback stream URL for channel $id");
			return $cb->({ url => $fb->{url}, title => $fb->{name}, logo => undef });
		}
		return $cb->(undef);
	};

	$class->_getToken(sub {
		my $token = shift or return $fallback->();

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $data = eval { decode_json($http->content) };

				if ($@ || ref $data ne 'HASH') {
					$log->error("DRLive: bad item response for $id: " . ($@ || 'not a hash'));
					return $fallback->();
				}

				my $cf  = $data->{customFields} || {};
				my $url = $cf->{hlsURL} || $cf->{hlsURLEu} || $cf->{hlsAlternativeURL};

				unless ($url) {
					$log->warn("DRLive: no hlsURL in item $id");
					return $fallback->();
				}

				my $info = {
					url   => $url,
					title => $data->{title} || $class->fallbackName($id) || "DR ($id)",
					logo  => _logo($data->{images}),
				};

				$cache->set("drlive_info_v2_$id", $info, INFO_TTL);
				main::INFOLOG && $log->is_info && $log->info("DRLive: resolved channel $id -> $url");
				$cb->($info);
			},
			sub {
				my ($http, $error) = @_;
				$log->error("DRLive: item request failed for $id: $error");
				$fallback->();
			},
			{ timeout => 15 },
		)->get(sprintf(ITEM_URL, $id), 'Authorization' => "Bearer $token");
	});
}

sub cachedVod {
	my ($class, $showId) = @_;
	return $cache->get("drlive_vod_v1_$showId");
}

# Async: $cb->({ url => <hls master>, title, logo, duration }), or $cb->(undef)
# if nothing could be resolved. Unlike getStreamInfo, there is deliberately no
# fallback table - a stale specific-episode URL is not something worth caching
# against an outage.
sub getLatestVod {
	my ($class, $showId, $cb) = @_;

	if (my $cached = $cache->get("drlive_vod_v1_$showId")) {
		return $cb->($cached);
	}

	$class->_getToken(sub {
		my $token = shift or return $cb->(undef);

		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $show = eval { decode_json($http->content) };

				if ($@ || ref $show ne 'HASH') {
					$log->error("DRLive: bad show response for $showId: " . ($@ || 'not a hash'));
					return $cb->(undef);
				}

				my $seasons  = ($show->{seasons} || {})->{items} || [];
				my $seasonId = $seasons->[0] && $seasons->[0]{id};

				unless ($seasonId) {
					$log->warn("DRLive: show $showId has no seasons");
					return $cb->(undef);
				}

				$class->_fetchSeasonEpisode($showId, $seasonId, $token, $cb);
			},
			sub {
				my ($http, $error) = @_;
				$log->error("DRLive: show request failed for $showId: $error");
				$cb->(undef);
			},
			{ timeout => 15 },
		)->get(sprintf(ITEM_URL, $showId), 'Authorization' => "Bearer $token");
	});
}

sub _fetchSeasonEpisode {
	my ($class, $showId, $seasonId, $token, $cb) = @_;

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $season = eval { decode_json($http->content) };

			if ($@ || ref $season ne 'HASH') {
				$log->error("DRLive: bad season response for $seasonId: " . ($@ || 'not a hash'));
				return $cb->(undef);
			}

			my $episodes = ($season->{episodes} || {})->{items} || [];

			# Already newest-first; keep only the ones DR marks actually
			# available - it's free to list an upcoming one ahead of release.
			my @available = grep {
				grep { ($_->{availability} || '') eq 'Available' } @{ $_->{offers} || [] }
			} @$episodes;

			unless (@available) {
				$log->warn("DRLive: no available episode in season $seasonId");
				return $cb->(undef);
			}

			$class->_tryEpisodes($showId, \@available, $token, $cb);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("DRLive: season request failed for $seasonId: $error");
			$cb->(undef);
		},
		{ timeout => 15 },
	)->get(sprintf(ITEM_URL, $seasonId), 'Authorization' => "Bearer $token");
}

# Each fallback attempt costs a full round trip to DR's videos endpoint. On a
# busy news day, several episodes in a row can be archive-only at once, and
# there is no way to know from here how long LMS is willing to wait for a
# track to resolve before giving up on the whole attempt - a long chain of
# sequential round trips silently exceeding that timeout would look exactly
# like a single failed attempt with nothing further logged. Capping this is
# cheap insurance against that, independent of whether it is the real cause.
use constant MAX_EPISODE_ATTEMPTS => 5;

# Tries episodes newest-first, falling through to the next one if the newest
# has no usable resource yet - see HLS::is_archive_url for why that happens
# and why we don't just use what DR offers in the meantime.
sub _tryEpisodes {
	my ($class, $showId, $episodes, $token, $cb, $attempt) = @_;
	$attempt ||= 1;

	my $episode = shift @$episodes;
	unless ($episode) {
		$log->warn("DRLive: no episode with a usable video resource for show $showId");
		return $cb->(undef);
	}

	if ($attempt > MAX_EPISODE_ATTEMPTS) {
		$log->warn("DRLive: gave up on show $showId after " . MAX_EPISODE_ATTEMPTS . ' episodes with no usable resource');
		return $cb->(undef);
	}

	$class->_resolveEpisodeVideo($showId, $episode, $token, sub {
		my $info = shift;
		return $cb->($info) if $info;

		# _resolveEpisodeVideo already logged why. An exception here (from
		# LMS's own networking code, not ours - see tools/test-vod-fallback.pl,
		# which proves this recursion is correct in isolation) must surface
		# loudly rather than silently end the whole resolution.
		eval {
			$class->_tryEpisodes($showId, $episodes, $token, $cb, $attempt + 1);
			1;
		} or do {
			$log->error("DRLive: exception while trying the next episode for show $showId: $@");
			$cb->(undef);
		};
	});
}

sub _resolveEpisodeVideo {
	my ($class, $showId, $episode, $token, $cb) = @_;
	my $id = $episode->{id};

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $resources = eval { decode_json($http->content) };

			if ($@ || ref $resources ne 'ARRAY') {
				$log->error("DRLive: bad videos response for episode $id: " . ($@ || 'not an array'));
				return $cb->(undef);
			}

			# Only ever accept a resource explicitly marked unencrypted. This
			# endpoint can in principle return a DRM'd resource (DR's paid
			# content works the same way); never assume "None" just because
			# the field is missing - default to treating that as protected.
			#
			# A candidate can also be a live-channel "archive" URL - see
			# HLS::is_archive_url for why those are declined outright rather
			# than used. A loop (not grep) so a rejection gets logged: this is
			# the one part of the chain most likely to need a second look.
			my $video;
			for my $candidate (@$resources) {
				next unless ($candidate->{accessService} || '') eq 'StandardVideo';
				next unless ($candidate->{drm} || '') eq 'None';
				next unless $candidate->{url};

				if (Plugins::DRLive::HLS::is_archive_url($candidate->{url})) {
					$log->warn("DRLive: episode $id offers only a live-channel archive resource, skipping: $candidate->{url}");
					next;
				}

				$video = $candidate;
				last;
			}

			unless ($video) {
				$log->warn("DRLive: no usable video resource for episode $id");
				return $cb->(undef);
			}

			my $info = {
				url      => $video->{url},
				title    => $episode->{title} || $class->fallbackShowName($showId) || "DR ($showId)",
				logo     => _logo($episode->{images}),
				duration => $episode->{duration},
			};

			$cache->set("drlive_vod_v1_$showId", $info, VOD_TTL);
			main::INFOLOG && $log->is_info && $log->info("DRLive: resolved show $showId -> episode $id -> $video->{url}");
			$cb->($info);
		},
		sub {
			my ($http, $error) = @_;
			$log->error("DRLive: videos request failed for episode $id: $error");
			$cb->(undef);
		},
		{ timeout => 15 },
	)->get(sprintf(VIDEOS_URL, $id), 'Authorization' => "Bearer $token");
}

sub _getToken {
	my ($class, $cb) = @_;

	if (my $token = $cache->get('drlive_token')) {
		return $cb->($token);
	}

	my $deviceId = _uuid();
	my $body = qq({"deviceId":"$deviceId","scopes":["Catalog"],"optout":true});

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			my $data = eval { decode_json($http->content) };

			my $token;
			if (ref $data eq 'ARRAY') {
				($token) = map { $_->{value} } grep { ($_->{type} || '') eq 'UserAccount' && $_->{value} } @$data;
			}

			if ($token) {
				$cache->set('drlive_token', $token, TOKEN_TTL);
				$cb->($token);
			}
			else {
				$log->error("DRLive: no anonymous token in SSO response");
				$cb->(undef);
			}
		},
		sub {
			my ($http, $error) = @_;
			$log->error("DRLive: SSO request failed: $error");
			$cb->(undef);
		},
		{ timeout => 15 },
	)->post(SSO_URL, 'Content-Type' => 'application/json', $body);
}

sub _logo {
	my $images = shift or return undef;
	my $u = $images->{logo} || $images->{square} || $images->{tile} || $images->{wallpaper} or return undef;

	# Rewrite only the size parameters: the literal "$value" path segment and
	# the single-quoted values around it must survive untouched, or DR's image
	# service returns nothing. See LOGO_PX above for why this matters.
	my $px = LOGO_PX;
	$u =~ s/([?&])Width=\d+/${1}Width=$px/;
	$u =~ s/([?&])Height=\d+/${1}Height=$px/;

	return $u;
}

sub _uuid {
	my @h = map { sprintf '%04x', int(rand(65536)) } 1 .. 8;
	return sprintf '%s%s-%s-4%s-%x%s-%s%s%s',
		$h[0], $h[1], $h[2], substr($h[3], 1),
		(8 + int(rand(4))), substr($h[4], 1),
		$h[5], $h[6], $h[7];
}

1;
