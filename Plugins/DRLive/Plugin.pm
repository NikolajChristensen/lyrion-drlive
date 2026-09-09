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
use Slim::Utils::Prefs;
use Slim::Utils::Strings;
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

	main::INFOLOG && $log->is_info && $log->info('DRLive initialised');
}

sub getDisplayName { 'PLUGIN_DRLIVE' }

sub playerMenu { 'RADIO' }

sub feed {
	my ($client, $cb, $args) = @_;

	my $channels = $prefs->get('channels');
	$channels = [ @DEFAULT_CHANNELS ] unless ref $channels eq 'ARRAY' && @$channels;

	my @items = map {
		my $ch   = $_;
		my $info = Plugins::DRLive::API->cachedInfo($ch->{id});

		# warm the cache so metadata/logo are ready on the next render
		Plugins::DRLive::API->getStreamInfo($ch->{id}, sub { }) unless $info;

		{
			name  => ($info && $info->{title}) || $ch->{name},
			type  => 'audio',
			url   => 'drlive://' . $ch->{id},
			image => ($info && $info->{logo}) || 'html/images/radio.png',
		}
	} @$channels;

	$cb->({
		type  => 'opml',
		title => Slim::Utils::Strings::string('PLUGIN_DRLIVE'),
		items => \@items,
	});
}

1;
