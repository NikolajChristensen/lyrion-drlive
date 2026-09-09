package Plugins::DRLive::API;

# Resolves a DR live-TV channel id to its current HLS master URL, channel
# title and logo, using DR's public "dr-massive" catalogue API.
#
#   1. POST https://isl.dr-massive.com/api/authorization/anonymous-sso
#      -> anonymous bearer token (cached ~50 min)
#   2. GET  https://production-cdn.dr-massive.com/api/items/<id>?expand=all...
#      -> .customFields.hlsURL, .title, .images.logo  (cached ~1 h)
#
# Every lookup falls back to a bundled static URL if the API is unavailable.

use strict;
use warnings;

use JSON::XS qw(decode_json);

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;

use constant SSO_URL   => 'https://isl.dr-massive.com/api/authorization/anonymous-sso?device=web_browser&lang=da&supportFallbackToken=true';
use constant ITEM_URL  => 'https://production-cdn.dr-massive.com/api/items/%s?device=web_browser&expand=all&ff=idp,ldp,rpt&geoLocation=dk&isDeviceAbroad=false&lang=da&segments=drtv,optedout&sub=Anonymous';

use constant TOKEN_TTL => 50 * 60;
use constant INFO_TTL  => 60 * 60;

# Seed table - id => { name, fallback }. Kept in sync with Plugin.pm's defaults.
# The fallback URLs were verified on 2026-09-08; the API path is preferred.
my %FALLBACK = (
	'20875' => { name => 'DR1',          url => 'https://drlivedr1hls.akamaized.net/hls/live/2113625/drlivedr1/master.m3u8' },
	'20876' => { name => 'DR2',          url => 'https://drlivedr2hls.akamaized.net/hls/live/2113623/drlivedr2/master.m3u8' },
	'20892' => { name => 'DR Ramasjang', url => 'https://drlivedrrhls.akamaized.net/hls/live/2113621/drlivedrr/master.m3u8' },
);

my $log   = logger('plugin.drlive');
my $cache = Slim::Utils::Cache->new();

sub fallbackName {
	my ($class, $id) = @_;
	return $FALLBACK{$id} ? $FALLBACK{$id}->{name} : undef;
}

# Synchronous cache read only - safe to call from getMetadataFor / menu build.
sub cachedInfo {
	my ($class, $id) = @_;
	return $cache->get("drlive_info_$id");
}

# Async: $cb->({ url => <hls master>, title => ..., logo => ... })
# Always calls back with something usable (falls back to the static table).
sub getStreamInfo {
	my ($class, $id, $cb) = @_;

	if (my $cached = $cache->get("drlive_info_$id")) {
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

				$cache->set("drlive_info_$id", $info, INFO_TTL);
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
	# DR image URLs contain a literal "$value" segment that must survive as-is.
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
