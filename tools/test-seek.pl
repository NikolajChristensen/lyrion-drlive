#!/usr/bin/env perl
# Unit test for Plugins::DRLive::VODProtocolHandler::getSeekData.
#
# This return shape was confirmed by tracing LMS's own Slim::Player::Song
# source: getSeekData()'s 'timeOffset' key flows through $song->seekdata,
# $song->startOffset, and $transcoder->{start} into the %s/%t placeholder
# substitution in custom-convert.conf's T:{START=...} capability template.
# A 'sourceStreamOffset' key instead selects the OTHER (byte-offset,
# direct-stream) seek path this handler does not implement - it must be
# absent, not just falsy.
use strict;
use warnings;
use FindBin qw($Bin);

my $STUB = "$Bin/.test-seek-stub";
system('rm', '-rf', $STUB);
for my $dir (qw(Slim/Plugin Slim/Utils Slim/Player/Protocols Slim/Networking Slim/Music JSON)) {
	system('mkdir', '-p', "$STUB/$dir");
}

my %files = (
	'Slim/Player/Protocols/HTTP.pm' => "package Slim::Player::Protocols::HTTP; sub new { bless {}, shift } 1;\n",
	'Slim/Utils/Log.pm' => <<'EOF',
package Slim::Utils::Log; use Exporter 'import'; our @EXPORT = qw(logger);
sub logger { bless {}, 'Slim::Utils::Log::L' }
package Slim::Utils::Log::L;
sub is_info {0} sub info {} sub warn {} sub error {} sub debug {}
package Slim::Utils::Log; 1;
EOF
	'Slim/Utils/Strings.pm' => "package Slim::Utils::Strings; sub string {''} 1;\n",
	'Slim/Music/Info.pm' => "package Slim::Music::Info; sub setDuration {1} sub getDuration {undef} 1;\n",
	'Slim/Networking/SimpleAsyncHTTP.pm' => "package Slim::Networking::SimpleAsyncHTTP; sub new { bless {}, shift } sub get {} sub post {} 1;\n",
	'Slim/Utils/Cache.pm' => "package Slim::Utils::Cache; sub new { bless {}, shift } sub get {} sub set {} 1;\n",
	'JSON/XS.pm' => "package JSON::XS; use Exporter 'import'; our \@EXPORT_OK = qw(decode_json encode_json);\nsub decode_json {} sub encode_json {} 1;\n",
);
for my $path (keys %files) {
	open my $fh, '>', "$STUB/$path" or die $!;
	print $fh $files{$path};
	close $fh;
}

BEGIN { *main::INFOLOG = sub () { 1 }; *main::DEBUGLOG = sub () { 1 }; }
unshift @INC, $STUB, "$Bin/..";
require Plugins::DRLive::VODProtocolHandler;

my $ok = 1;
my $sd = Plugins::DRLive::VODProtocolHandler->getSeekData(undef, undef, 90);

if (ref $sd eq 'HASH' && defined $sd->{timeOffset} && $sd->{timeOffset} == 90) {
	print "ok   - getSeekData returns a hash with the requested timeOffset\n";
} else {
	$ok = 0;
	print "FAIL - getSeekData did not return {timeOffset => 90}\n";
}

if (!exists $sd->{sourceStreamOffset}) {
	print "ok   - no sourceStreamOffset key (that selects the byte-offset seek path, which this handler does not implement)\n";
} else {
	$ok = 0;
	print "FAIL - sourceStreamOffset should not be present\n";
}

# canSeek must stay un-overridden: forcing it true would make LMS treat this
# as a byte-offset (direct-stream) seek instead of the transcoder-based one
# getSeekData actually implements - see VODProtocolHandler's header comment.
if (!Plugins::DRLive::VODProtocolHandler->can('canSeek')) {
	print "ok   - canSeek is not overridden by this package\n";
} else {
	no strict 'refs';
	my $owner = *{"Plugins::DRLive::VODProtocolHandler::canSeek"}{CODE};
	if ($owner) {
		$ok = 0;
		print "FAIL - canSeek is defined directly on VODProtocolHandler - it must be inherited, not overridden\n";
	} else {
		print "ok   - canSeek resolves via inheritance, not a local override\n";
	}
}

system('rm', '-rf', $STUB);
exit($ok ? 0 : 1);
