# DRLive — DR live‑TV audio for Lyrion Music Server

Play the **audio** of DR's live TV channels (DR1, DR2, DR Ramasjang) on your
Squeezebox / Lyrion players, and save them as one‑tap presets. Also plays the
latest episode of configured on-demand shows - by default TVA, DR's news
programme - always resolving to whatever DR most recently published.

The channels are plain HLS (AAC, no DRM). The plugin resolves the current stream
URL from DR's own catalogue API, picks the lowest‑bandwidth rendition, and lets
`ffmpeg` transcode it to FLAC on the server.

## Requirements

- Lyrion Music Server 8.0+ (a.k.a. Logitech Media Server).
- **`ffmpeg`, installed on the server.** LMS does *not* bundle it — the Linux
  packages in particular do not — and everything here transcodes through it, so
  without it nothing will play. On Debian/Ubuntu:

  ```
  sudo apt install ffmpeg && sudo systemctl restart lyrionmusicserver
  ```

  LMS finds binaries on the system path, so no further configuration is normally
  needed. If yours lives somewhere unusual, point the `[ffmpeg]` entries in
  `custom-convert.conf` at an absolute path instead.
- The server must be in **Denmark / the EU** — DR geo‑restricts the media
  (the catalogue lookup works anywhere, the stream bytes do not).

## Install

**Manual**

1. Copy the `Plugins/DRLive/` folder into your server's plugin directory.
   The path is shown at `Settings → Information → Plugin folders`
   (commonly `/var/lib/squeezeboxserver/Plugins` or
   `<prefs>/Plugins`).
2. Restart Lyrion Music Server.
3. `Settings → Plugins` → enable **DR Live** if it isn't already.

**Via a repository**

Add this URL under `Settings → Plugins → Additional Repositories`:

```
https://raw.githubusercontent.com/NikolajChristensen/lyrion-drlive/main/repo.xml
```

then enable **DR Live** from the plugin list. The repository points at the zip
attached to the matching [release](https://github.com/NikolajChristensen/lyrion-drlive/releases).

## Use

1. On a player (or the web UI): `Radio → DR Live → DR2`, press play.
2. To make a preset: open the context menu on `DR2` (press‑and‑hold / the `+`
   menu) → **Add to Favourites**. The favourite stores `drlive://20876`, so it
   keeps working even when DR rotates the CDN URL.

The menu also includes `TVA` by default (DR's flagship news programme,
<https://www.dr.dk/drtv/serie/tva_358871>), which plays whatever episode DR
most recently published - TVA airs several times a day on no fixed schedule,
so this always tracks the actual latest, not a specific timeslot. A `drvod://`
favourite works the same way: it re-resolves to the current latest episode
every time it's played, rather than replaying whatever was latest when the
favourite was saved.

### Adding or changing channels

The channel list is a server preference `plugin.drlive:channels`, an array of
`{ id => '<dr-massive item id>', name => '<label>' }`. Defaults:

| id      | channel        |
|---------|----------------|
| `20876` | DR2            |
| `20875` | DR1            |
| `20892` | DR Ramasjang   |

To find another channel's id, open it on <https://www.dr.dk/drtv> and read the
number at the end of the URL (`/kanal/dr2_20876` → `20876`).

### Adding or changing on-demand shows

Similarly, `plugin.drlive:shows` is an array of the same
`{ id => '<dr-massive show id>', name => '<label>' }` shape, resolved to each
show's latest episode rather than a fixed stream. Default:

| id       | show  |
|----------|-------|
| `358871` | TVA   |

Find a show's id the same way, from its `/drtv/serie/<name>_<id>` URL. Only
free, unencrypted (`drm: None`) shows work this way - DR's paid content
(behind DR Ekstra) does not expose a usable manifest through this anonymous
API and is out of scope for this plugin.

## Artwork

The plugin ships its own icon for the `DR Live` entry in the Radio menu, and
uses DR's own channel logos everywhere else — menu rows, Now Playing, and
Favourites.

Two details make that work, both of which fail silently if you get them wrong:

- DR publishes those logos at **2160×2160**. LMS's image proxy does not merely
  resize those slowly, it *times out* without logging an error, so the artwork
  simply never appears. The plugin rewrites the `Width`/`Height` parameters in
  DR's image URL to ask DR's own resizer for a 300px image instead — that drops
  a logo from ~23 KB to ~1.7 KB and takes the proxy from a 60 s timeout to
  0.2 s. The literal `$value` path segment and the single-quoted parameters in
  those URLs must survive untouched; `tools/test-logo.pl` guards that.
- The menu resolves every channel *before* it answers, so logos and real
  channel titles are present on the first render rather than appearing only on
  the second visit.

## How it works

```
drlive://20876                              drvod://358871
   │                                            │
   ├─ ProtocolHandler.getNextTrack              ├─ VODProtocolHandler.getNextTrack
   │     ├─ API: anonymous token (shared)       │     ├─ API: anonymous token (shared)
   │     ├─ API: items/20876                    │     ├─ API: items/358871 (show)
   │     │     → customFields.hlsURL,           │     │     → seasons.items[0].id
   │     │       title, logo                    │     ├─ API: items/<seasonId>
   │     └─ fetch master.m3u8                   │     │     → episodes.items[], newest-first,
   │           → HLS.lowest_variant()           │     │       tries each "Available" one until
   │           (lowest-BANDWIDTH variant)        │     │       one has a usable resource (max 5)
   │                                             │     ├─ API: account/items/<id>/videos
   │                                             │     │     → first resource with drm=="None"
   │                                             │     │       that isn't a live-channel
   │                                             │     │       "archive" URL
   │                                             │     └─ fetch master.m3u8
   │                                             │           → HLS.audio_variant()
   │                                             │           (pure audio-only rendition,
   │                                             │            falling back to
   │                                             │            HLS.lowest_variant())
   │                                             │
   └─ getFormatForURL → "drlive"                 └─ getFormatForURL → "drvod"
         └─ custom-convert.conf:                       └─ custom-convert.conf:
            drlive → flc [ffmpeg -i $URL$ ...]             drvod → flc [ffmpeg -i $URL$ ...]
```

Both protocol handlers share `Plugins::DRLive::HLS` for master-playlist parsing
and `Plugins::DRLive::API` for the anonymous token and all DR HTTP calls.
`drvod://` has its own content type, separate from `drlive`'s, purely to keep
the two independently configurable - both currently declare the identical `R`
(remote URL, so LMS hands the playlist to `ffmpeg` instead of a socket)
capability and nothing else. `drvod` briefly also declared `T`
(seek-to-start-time); see the Troubleshooting section for why that was
reverted.

If the catalogue API is unreachable, the live-channel handler falls back to a
bundled static URL per channel. The on-demand handler has no such fallback - a
stale specific-episode URL isn't something a static table can usefully cover -
so a catalogue outage means that entry's playback fails and logs why, rather
than playing something wrong.

## Development / testing

```
perl tools/test-variant.pl      # unit test for the playlist-parsing helpers
perl tools/test-logo.pl         # unit test for the logo-URL rewriting
perl tools/test-vod-fallback.pl # unit test for the on-demand episode-fallback chain
perl tools/test-convert-conf.pl # validates capability lines against LMS's actual parsing grammar
tools/test-compile.sh        # compile + load every module against stubbed Slim::* classes
tools/test-resolve.sh [id]   # end-to-end: token → item → variant → ffmpeg (needs curl, python3, ffmpeg)
```

`test-compile.sh` generates throwaway stubs for the `Slim::*` classes and
`JSON::XS`, so it catches syntax errors and load-order mistakes without a
running server. It cannot check behaviour against the real LMS API — for that,
load the plugin into a real server and watch `server.log` with the
`plugin.drlive` category at DEBUG.

### Cutting a release

```
tools/release.sh 0.1.2             # test, bump, rebuild zip, rewrite repo.xml
tools/release.sh 0.1.2 --publish   # ...then commit, tag and create the GitHub release
```

The plugin version, the zip URL and its sha1 must always move together: LMS
downloads the zip named in `repo.xml`'s `<url>` and rejects it if the checksum
doesn't match `<sha>`, so a partial bump ships a plugin that silently fails to
install. The script rewrites all three and refuses to finish if any didn't take.

## Troubleshooting

**`Error: Couldn't create command line for drlive playback` in `server.log`**

LMS could not build a transcode command — almost always because it cannot find
`ffmpeg`. Confirm it in `Settings → Advanced → File Types`: find the `drlive`
rows (FLAC / MP3 / PCM). If the dropdowns are greyed out and offer only
"Disabled", the binary is missing; a working profile offers a selectable option
instead. Install `ffmpeg` and restart the server.

From v0.1.2 the plugin checks for `ffmpeg` at startup and logs an explicit error
rather than leaving you with the message above, and the `DR Live` menu shows the
reason instead of an unplayable channel list.

**Nothing plays, but `ffmpeg` is installed**

Raise the `plugin.drlive` log category to DEBUG under
`Settings → Advanced → Logging` and retry. The handler logs the resolved channel
id and the exact variant URL it handed to ffmpeg; that URL can be pasted
straight into `ffmpeg -i` on the server to test in isolation.

Remember the media itself is geo-restricted to Denmark / the EU — the catalogue
lookup succeeds anywhere, but the stream bytes do not.

**TVA fails to play right after a new episode is published ("can't open file")**

Fixed in v0.1.7, hardened further in v0.1.8. Right after a new episode
publishes, DR sometimes serves it not as the usual discrete on-demand file,
but as a slice of the *live channel's* catch-up/restart buffer instead (a
`master-archive.m3u8?startTime=...&endTime=...` URL). v0.1.6 rejected only an
implausibly wide window from this style of resource (one observed case: a full
6-hour block instead of the ~14-minute episode) - but a correctly-sized one
turned out to still fail moments later with an HTTP 403 from Akamai, its
per-variant tokens apparently short-lived in a way their outer `exp=` field
(claiming ~1 day validity) doesn't reveal. v0.1.7 declines this delivery style
outright, regardless of window size, and falls back to the next-newest episode
that DR has already packaged as a proper file - matching what every other
episode already uses. In practice this means a brand new episode may not be
playable for the first few minutes after publishing; the previous one plays
instead until DR finishes repackaging it.

v0.1.7's fallback logic was verified correct in isolation
(`tools/test-vod-fallback.pl`), but a real server log showed it stopping after
exactly one rejection on three separate occasions - never falling through to
an older episode, and never logging why. The most plausible explanation:
each fallback attempt costs a full round trip to DR's `videos` endpoint, and
several archive-only episodes in a row (plausible on a busy news day) could
add up to longer than LMS is willing to wait for a track to resolve, silently
abandoning the attempt with nothing further logged. v0.1.8 bounds the fallback
to 5 episodes and wraps the recursive retry in an `eval` so any unexpected
failure is logged instead of silently ending the resolution - independent of
whether that theory is the exact cause, both changes are cheap insurance
against it.

**Seeking and pause/resume on TVA do not work, and are not implemented (tried and reverted in v0.1.9-v0.1.12)**

The on-demand progress bar shows the correct total length, but cannot be
scrubbed, and pausing for a while then resuming restarts the episode from the
beginning rather than continuing. This is a deliberate, known limitation, not
an oversight - a working implementation was built, shipped, and reverted after
live testing pointed at a bug in LMS's own core rather than anything in this
plugin. The full story, in case anyone picks this up again later:

- v0.1.9 added a `T` (seek-to-start-time) capability to a new `drvod` content
  type, plus a `getSeekData` implementation, following the exact pattern
  LMS's own stock `convert.conf` uses for this (e.g. the built-in flac/faad
  profiles' `T:{START=--skip=%t}` style). It shipped with a capability-line
  syntax error (`R T:{START=-ss %s}` - LMS requires capability letters to run
  together with **no space**, `RT:{START=...}`) that broke *all* on-demand
  playback, not just seeking, because it left `drvod` with no working
  transcoder profile at all.
- v0.1.10 fixed the syntax (confirmed against LMS's actual parsing regex, not
  just working examples this time) and restored normal playback.
  `tools/test-convert-conf.pl` now validates every capability line in
  `custom-convert.conf` against that regex, so this exact mistake can't ship
  silently again.
- v0.1.11 added logging inside `getSeekData`, since nothing else logs a seek
  (it doesn't re-run `getNextTrack`, the only place that already logged
  anything).
- With logging in place, live testing on a real server showed: `getSeekData`
  fires correctly, `canSeek=2` (the transcoder-based path, not the
  byte-offset one), the constructed command line correctly includes
  `-ss <offset>` - all confirmed via LMS's own `server.log` (raise the
  built-in `player.source` category to INFO to see the `Tokenized command:`
  line yourself). And yet, about a second after a seek-triggered reopen,
  LMS's own pipe-reading code
  (`Slim::Player::Source::_readNextChunk`) logged
  `end of file or error on socket`, causing either a stop (single player) or
  a repeating restart loop (players synced together - ruled out as the root
  cause, since a single isolated player failed too, just differently). The
  exact same command - same URL, same `-ss` offset, same reconnect flags -
  decoded the **entire rest of the episode with zero errors** when run
  directly outside LMS. That combination - correct inputs confirmed at every
  step, ffmpeg provably fine in isolation, failure specifically inside LMS's
  own pipe-reading code right after a seek-triggered reopen of an `R`
  (remote-fed) transcoded stream - points at a bug or limitation in LMS's
  core handling of that specific combination, not at anything this plugin
  controls.
- v0.1.12 reverted the `T` capability and `getSeekData`, back to the
  known-reliable `R`-only profile every other stream here uses.

## Status

v0.1.12 — works for the three default channels and the TVA on-demand show;
resolution and playback verified end to end against the live API (both the
live-channel and on-demand chains), and against a real Lyrion 9.1.1 server. The
on-demand progress bar shows the episode's real length, and a live-channel
"archive" resource for a just-published episode is declined outright in favour
of the next-newest properly-packaged episode, with the fallback bounded and
exception-safe. Seeking and pause/resume on TVA were attempted and reverted
after live testing pointed at an LMS-core bug, not a bug here (see
Troubleshooting). Not yet done: a settings page, now‑playing EPG text, DR
radio (P1–P8).
