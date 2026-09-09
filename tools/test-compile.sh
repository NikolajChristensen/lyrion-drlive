#!/usr/bin/env bash
# Compile-and-load check for the DRLive modules without a running Lyrion server.
#
# The plugin's modules `use` a handful of Slim::* classes plus JSON::XS, none of
# which exist outside LMS. This generates throwaway stubs for exactly those, then
# loads each module for real - which catches syntax errors, bad `use` lines and
# load-order mistakes (e.g. calling logger() before the category is registered).
#
# It does NOT check behaviour against the real LMS API; only that the code parses
# and loads. Usage: tools/test-compile.sh
set -euo pipefail

cd "$(dirname "$0")/.."

STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT

mkdir -p "$STUB"/Slim/{Plugin,Utils,Player/Protocols,Networking} "$STUB"/JSON

cat > "$STUB/Slim/Plugin/OPMLBased.pm" <<'EOF'
package Slim::Plugin::OPMLBased; sub initPlugin {1} 1;
EOF
cat > "$STUB/Slim/Utils/Log.pm" <<'EOF'
package Slim::Utils::Log; use Exporter 'import'; our @EXPORT = qw(logger);
sub addLogCategory { bless {}, 'Slim::Utils::Log::L' }
sub logger         { bless {}, 'Slim::Utils::Log::L' }
package Slim::Utils::Log::L;
sub is_info {0} sub is_debug {0} sub info {} sub warn {} sub error {} sub debug {}
package Slim::Utils::Log; 1;
EOF
cat > "$STUB/Slim/Utils/Prefs.pm" <<'EOF'
package Slim::Utils::Prefs; use Exporter 'import'; our @EXPORT = qw(preferences);
sub preferences { bless {}, 'Slim::Utils::Prefs::P' }
package Slim::Utils::Prefs::P; sub init {} sub get {} sub set {}
package Slim::Utils::Prefs; 1;
EOF
cat > "$STUB/Slim/Utils/Misc.pm" <<'EOF'
package Slim::Utils::Misc; sub findbin { undef } 1;
EOF
cat > "$STUB/Slim/Utils/Timers.pm" <<'EOF'
package Slim::Utils::Timers; sub setTimer {1} sub killTimers {1} 1;
EOF
cat > "$STUB/Slim/Utils/Strings.pm" <<'EOF'
package Slim::Utils::Strings; sub string {''} 1;
EOF
cat > "$STUB/Slim/Utils/Cache.pm" <<'EOF'
package Slim::Utils::Cache; sub new { bless {}, shift } sub get {} sub set {} 1;
EOF
cat > "$STUB/Slim/Player/ProtocolHandlers.pm" <<'EOF'
package Slim::Player::ProtocolHandlers; sub registerHandler {1} 1;
EOF
cat > "$STUB/Slim/Player/Protocols/HTTP.pm" <<'EOF'
package Slim::Player::Protocols::HTTP; sub new { bless {}, shift } 1;
EOF
cat > "$STUB/Slim/Networking/SimpleAsyncHTTP.pm" <<'EOF'
package Slim::Networking::SimpleAsyncHTTP; sub new { bless {}, shift } sub get {} sub post {} 1;
EOF
cat > "$STUB/JSON/XS.pm" <<'EOF'
package JSON::XS; use Exporter 'import'; our @EXPORT_OK = qw(decode_json encode_json);
sub decode_json {} sub encode_json {} 1;
EOF

rc=0
for m in Plugins::DRLive::API Plugins::DRLive::ProtocolHandler Plugins::DRLive::Plugin; do
	printf '%-38s ' "$m"
	# main::INFOLOG / main::DEBUGLOG are constants LMS defines before plugins load.
	if perl -I"$STUB" -I. -e "
		BEGIN { *main::INFOLOG = sub(){1}; *main::DEBUGLOG = sub(){1}; }
		eval qq{use $m; 1} or do { print qq{FAIL\n}; print \$@; exit 1 };
		print qq{ok\n};
	"; then :; else rc=1; fi
done

exit $rc
