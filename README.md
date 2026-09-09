# DRLive — DR live‑TV audio for Lyrion Music Server

Play the **audio** of DR's live TV channels (DR1, DR2, DR Ramasjang) on your
Squeezebox / Lyrion players, and save them as one‑tap presets.

The channels are plain HLS (AAC, no DRM). The plugin resolves the current stream
URL from DR's own catalogue API, picks the lowest‑bandwidth rendition, and lets
`ffmpeg` transcode it to FLAC on the server.

## Requirements

- Lyrion Music Server 8.0+ (a.k.a. Logitech Media Server).
- `ffmpeg` available to the server. LMS bundles it on most platforms
  (Synology / QNAP / Docker / the Linux packages). If yours doesn't, install
  `ffmpeg` and make sure `Settings → Information` lists it, or point the
  `[ffmpeg]` entries in `custom-convert.conf` at a full path.
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
tools/test-resolve.sh [id]   # end-to-end: token → item → variant → ffmpeg (needs curl, python3, ffmpeg)
perl tools/test-variant.pl   # unit test for the playlist-parsing helpers
```

There is no way to fully compile the Perl outside a running LMS (it needs the
server's bundled XS modules); load it into a real server and watch
`server.log` with the `plugin.drlive` category at DEBUG.

## Status

v0.1.0 — works for the three default channels. Not yet done: a settings page,
now‑playing EPG text, DR radio (P1–P8), channel logos in the menu before the
first play.
