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
   │     └─ fetch master.m3u8                   │     │     → episodes.items[0] where
   │           → HLS.lowest_variant()           │     │       an offer is "Available"
   │           (lowest-BANDWIDTH variant)        │     ├─ API: account/items/<id>/videos
   │                                             │     │     → first resource with
   │                                             │     │       drm == "None"
   │                                             │     └─ fetch master.m3u8
   │                                             │           → HLS.audio_variant()
   │                                             │           (pure audio-only rendition,
   │                                             │            falling back to
   │                                             │            HLS.lowest_variant())
   │                                             │
   └─ getFormatForURL → "drlive"                 └─ getFormatForURL → "drlive"
         └─ custom-convert.conf:  drlive → flc   [ffmpeg -i $URL$ -vn -c:a flac -f flac -]
```

Both protocol handlers share `Plugins::DRLive::HLS` for master-playlist parsing
and `Plugins::DRLive::API` for the anonymous token and all DR HTTP calls, and
both end up handing ffmpeg a plain HLS URL - `drvod://` is a second URL scheme
mapped to the *same* `drlive` content type (see `custom-types.conf`), so it
reuses the existing `custom-convert.conf` profiles rather than needing its own.

`custom-convert.conf` declares only the `R` (remote URL) capability so LMS hands
the playlist URL to `ffmpeg` instead of trying to feed it through a socket.

If the catalogue API is unreachable, the live-channel handler falls back to a
bundled static URL per channel. The on-demand handler has no such fallback - a
stale specific-episode URL isn't something a static table can usefully cover -
so a catalogue outage means that entry's playback fails and logs why, rather
than playing something wrong.

## Development / testing

```
perl tools/test-variant.pl   # unit test for the playlist-parsing helpers
perl tools/test-logo.pl      # unit test for the logo-URL rewriting
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

Fixed in v0.1.6. DR's own catalogue backend has been observed to briefly
return an implausible resource for a just-published episode: instead of the
usual discrete on-demand file, it returns a slice of the *live channel's*
catch-up/restart buffer with a wildly-wide time window (one observed case: a
full 6-hour block instead of the ~14-minute episode). Because this plugin
re-checks "latest" every 10 minutes, it's more likely than a casual viewer to
catch DR's API in that inconsistent state. The plugin now checks that an
archive-style resource's window is a plausible size for the episode's own
catalogue duration and rejects it otherwise - a rejection isn't cached, so the
next play attempt (or the next 10-minute cache-warm cycle, by which point DR's
own metadata has typically settled) tries again fresh rather than repeating the
same bad answer for the rest of the cache window.

**On-demand shows (TVA) show a progress bar but can't be scrubbed**

Expected for now. LMS gets total duration from a database attribute
(`Slim::Music::Info::setDuration`), which the plugin sets from DR's own episode
metadata - that's a straightforward lookup, and the progress bar reflects it.
Actual seeking is a different mechanism: for a transcoded remote stream, LMS
restarts the ffmpeg process at a new `-ss` offset, which requires a dedicated
`custom-convert.conf` profile declaring the `T` capability plus a protocol-level
`getSeekData` implementation. Deliberately not done yet - it would need to live
on a content type separate from the live channels, since offering a scrubber on
a 24/7 live stream doesn't make sense.

## Status

v0.1.6 — works for the three default channels and the TVA on-demand show;
resolution and playback verified end to end against the live API (both the
live-channel and on-demand chains), and against a real Lyrion 9.1.1 server. The
on-demand progress bar shows the episode's real length, and an implausible
live-channel "archive" resource for a just-published episode is rejected
rather than played (see Troubleshooting). Still open: a rare premature stop a
few minutes into some on-demand playback, not yet reproduced with debug logs
(tracked at https://github.com/NikolajChristensen/lyrion-drlive/issues/1). Not
yet done: a settings page, now‑playing EPG text, DR radio (P1–P8), and actual
seeking on on-demand content (see Troubleshooting).
