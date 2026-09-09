# DRLive — DR live‑TV audio for Lyrion Music Server

Play the **audio** of DR's live TV channels (DR1, DR2, DR Ramasjang) on your
Squeezebox / Lyrion players, and save them as one‑tap presets.

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
drlive://20876
   │
   ├─ ProtocolHandler.getNextTrack
   │     ├─ API: anonymous token  (isl.dr-massive.com)
   │     ├─ API: items/20876      → customFields.hlsURL, title, logo
   │     └─ fetch master.m3u8     → lowest-BANDWIDTH variant playlist
   │           └─ song->streamUrl(variant)
   │
   └─ getFormatForURL → "drlive"
         └─ custom-convert.conf:  drlive → flc   [ffmpeg -i $URL$ -vn -c:a flac -f flac -]
```

`custom-convert.conf` declares only the `R` (remote URL) capability so LMS hands
the playlist URL to `ffmpeg` instead of trying to feed it through a socket.

If the catalogue API is unreachable, the handler falls back to a bundled static
URL per channel.

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

## Status

v0.1.3 — works for the three default channels; resolution and playback verified
end to end against the live API, and against a real Lyrion 9.1.1 server. Not yet done: a settings page, now‑playing EPG
text, DR radio (P1–P8).
