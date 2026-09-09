package Plugins::DRLive::Plugin;

# DR Live - play the audio of DR's live TV channels on Lyrion players.
#
# Adds a "DR Live" menu under Radio with one playable item per channel. Each
# item is a drlive://<id> URL handled by Plugins::DRLive::ProtocolHandler.
# Add an item to your Favourites to get a durable one-tap preset - the favourite
# stores drlive://<id>, so it keeps working even when DR rotates the CDN URL.

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

sub initPlugin {
	my $class = shift;

	$prefs->init({
		channels => [ @DEFAULT_CHANNELS ],
	});

	Slim::Player::ProtocolHandlers->registerHandler(
		drlive => 'Plugins::DRLive::ProtocolHandler'
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
}

sub _channels {
	my $channels = $prefs->get('channels');
	return (ref $channels eq 'ARRAY' && @$channels) ? $channels : [ @DEFAULT_CHANNELS ];
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

	my @items;
	my $pending = scalar @$channels;

	my $respond = sub {
		$cb->({
			type  => 'opml',
			title => Slim::Utils::Strings::string('PLUGIN_DRLIVE'),
			items => \@items,
		});
	};

	return $respond->() unless $pending;

	# Resolve every channel before answering, so the menu carries real titles and
	# logos on the FIRST render rather than a row of placeholders that only fill
	# in next time. getStreamInfo always calls back (it falls back to the static
	# table) and caches for an hour, so this costs one request per channel per
	# hour at worst, and nothing at all once warm.
	for my $i (0 .. $#$channels) {
		my $ch = $channels->[$i];

		Plugins::DRLive::API->getStreamInfo($ch->{id}, sub {
			my $info = shift;

			# Indexed, not pushed: the callbacks finish in arbitrary order and
			# the menu should keep the configured channel order.
			$items[$i] = {
				name  => ($info && $info->{title}) || $ch->{name},
				type  => 'audio',
				url   => 'drlive://' . $ch->{id},
				image => ($info && $info->{logo}) || ICON,
			};

			$respond->() if --$pending == 0;
		});
	}
}

1;
