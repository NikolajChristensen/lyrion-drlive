package Plugins::DRLive::Plugin;

# DR Live - play the audio of DR's live TV channels, and the latest episode of
# configured on-demand shows, on Lyrion players.
#
# Adds a "DR Live" menu under Radio with one playable item per channel (a
# drlive://<id> URL, Plugins::DRLive::ProtocolHandler) and one per configured
# show (a drvod://<id> URL, Plugins::DRLive::VODProtocolHandler, always
# resolving to that show's most recently published episode - e.g. TVA, DR's
# news programme). Add an item to your Favourites to get a durable one-tap
# preset - the favourite stores the drlive:// or drvod:// URL, so it keeps
# working even when DR rotates the CDN URL or publishes a new episode.

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
use Slim::Utils::Timers;
use Slim::Player::ProtocolHandlers;

# Register the log category BEFORE the two submodules are compiled: both call
# logger('plugin.drlive') at file scope, and that runs during the `use`
# statements below. Registering afterwards would leave them on an unconfigured
# category inheriting the root level.
my $log;
BEGIN {
	$log = Slim::Utils::Log->addLogCategory({
		category     => 'plugin.drlive',
		defaultLevel => 'WARN',
		description  => 'PLUGIN_DRLIVE',
	});
}

use Plugins::DRLive::ProtocolHandler;
use Plugins::DRLive::VODProtocolHandler;
use Plugins::DRLive::API;

my $prefs = preferences('plugin.drlive');

# Shipped with the plugin; also declared as <icon> in install.xml so the entry
# in the Radio menu uses it instead of LMS's generic radio symbol.
use constant ICON => 'plugins/DRLive/html/images/icon.png';

# DR's current linear TV line-up. ids are stable dr-massive catalogue item ids.
my @DEFAULT_CHANNELS = (
	{ id => '20876', name => 'DR2' },
	{ id => '20875', name => 'DR1' },
	{ id => '20892', name => 'DR Ramasjang' },
);

# On-demand shows whose latest episode gets its own menu entry. 358871 is TVA
# (DR's flagship news programme, https://www.dr.dk/drtv/serie/tva_358871),
# which publishes several times a day on no fixed schedule; the entry always
# points at whatever DR most recently published, not a specific timeslot.
my @DEFAULT_SHOWS = (
	{ id => '358871', name => 'TVA' },
);

sub initPlugin {
	my $class = shift;

	$prefs->init({
		channels => [ @DEFAULT_CHANNELS ],
		shows    => [ @DEFAULT_SHOWS ],
	});

	Slim::Player::ProtocolHandlers->registerHandler(
		drlive => 'Plugins::DRLive::ProtocolHandler'
	);
	Slim::Player::ProtocolHandlers->registerHandler(
		drvod => 'Plugins::DRLive::VODProtocolHandler'
	);

	$class->SUPER::initPlugin(
		feed   => \&feed,
		tag    => 'drlive',
		menu   => 'radios',
		weight => 55,
	);

	# Everything here transcodes through ffmpeg (see custom-convert.conf), and a
	# missing binary only shows up later as LMS's opaque "Couldn't create command
	# line for drlive playback". Say so plainly at startup instead.
	unless (_haveFFmpeg()) {
		$log->error(
			'DRLive: ffmpeg was not found, so playback WILL fail. Install it on '
			. 'this server (e.g. "apt install ffmpeg") and restart, or set an '
			. 'absolute path in the plugin\'s custom-convert.conf. '
			. 'Settings -> Advanced -> File Types lists the drlive rows as '
			. 'greyed out while it is missing.'
		);
	}

	# Resolve the channels a little after startup so Favourites and Now Playing
	# have titles and artwork before the DR Live menu is ever opened. Delayed
	# rather than immediate because outbound networking is not necessarily up
	# yet when plugins initialise.
	Slim::Utils::Timers::setTimer(undef, time() + 15, \&_warmCache);

	main::INFOLOG && $log->is_info && $log->info('DRLive initialised');
}

sub _warmCache {
	return unless _haveFFmpeg();
	Plugins::DRLive::API->getStreamInfo($_->{id}, sub { }) for @{ _channels() };
	Plugins::DRLive::API->getLatestVod($_->{id}, sub { })  for @{ _shows() };
}

sub _channels {
	my $channels = $prefs->get('channels');
	return (ref $channels eq 'ARRAY' && @$channels) ? $channels : [ @DEFAULT_CHANNELS ];
}

sub _shows {
	my $shows = $prefs->get('shows');
	return (ref $shows eq 'ARRAY' && @$shows) ? $shows : [ @DEFAULT_SHOWS ];
}

# Cached per server run - findbin() hits the filesystem.
my $haveFFmpeg;
sub _haveFFmpeg {
	$haveFFmpeg = Slim::Utils::Misc::findbin('ffmpeg') ? 1 : 0
		unless defined $haveFFmpeg;
	return $haveFFmpeg;
}

sub getDisplayName { 'PLUGIN_DRLIVE' }

sub playerMenu { 'RADIO' }

sub feed {
	my ($client, $cb, $args) = @_;

	# A channel list that cannot play is worse than an explanation.
	unless (_haveFFmpeg()) {
		return $cb->({
			type  => 'opml',
			title => Slim::Utils::Strings::string('PLUGIN_DRLIVE'),
			items => [ {
				name => Slim::Utils::Strings::string('PLUGIN_DRLIVE_NO_FFMPEG'),
				type => 'text',
			} ],
		});
	}

	my $channels = _channels();
	my $shows    = _shows();

	my @items;
	my $pending = @$channels + @$shows;

	my $respond = sub {
		$cb->({
			type  => 'opml',
			title => Slim::Utils::Strings::string('PLUGIN_DRLIVE'),
			items => \@items,
		});
	};

	return $respond->() unless $pending;

	# Resolve everything before answering, so the menu carries real titles and
	# logos on the FIRST render rather than a row of placeholders that only
	# fill in next time. Both getStreamInfo and getLatestVod always call back
	# and cache their result, so this costs at most one request per entry per
	# cache period, and nothing at all once warm.
	for my $i (0 .. $#$channels) {
		my $ch = $channels->[$i];

		Plugins::DRLive::API->getStreamInfo($ch->{id}, sub {
			my $info = shift;

			# Indexed, not pushed: the callbacks finish in arbitrary order and
			# the menu should keep the configured order.
			$items[$i] = {
				name  => ($info && $info->{title}) || $ch->{name},
				type  => 'audio',
				url   => 'drlive://' . $ch->{id},
				image => ($info && $info->{logo}) || ICON,
			};

			$respond->() if --$pending == 0;
		});
	}

	my $offset = scalar @$channels;
	for my $j (0 .. $#$shows) {
		my $sh  = $shows->[$j];
		my $idx = $offset + $j;

		Plugins::DRLive::API->getLatestVod($sh->{id}, sub {
			my $info = shift;

			$items[$idx] = {
				name  => ($info && $info->{title}) || $sh->{name},
				type  => 'audio',
				url   => 'drvod://' . $sh->{id},
				image => ($info && $info->{logo}) || ICON,
			};

			$respond->() if --$pending == 0;
		});
	}
}

1;
