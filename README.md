# Spinaural

Turn any song or video into 8D or 16D audio: the sound circles your head when you listen on headphones.

Live at **https://spinaural.rennko.tech**

- Drop in an MP3, M4A, WAV, FLAC, MP4, MOV or WebM file, or play the built-in demo loop.
- Hear the effect live and flip between the 8D version and the original (press `B`).
- **16D mode** splits the song into layers. The bass stays in the middle, the mids orbit one way, and the highs orbit the other way, faster and farther out.
- 12 presets, including Classic 8D, Slow Dream, Fast Spin, 16D Classic, Crossfire and Swarm.
- Bass boost up to +12 dB, kept separate from the presets.
- Shape the motion: Orbit, Spiral, Ear to ear or Wander paths. You can also set the direction, lap time, distance, rise and fall, and room echo, and keep the bass centered.
- Save the result as an MP3 (320 kbps) or a WAV. Videos can also be saved with the picture untouched and the 8D sound swapped in.

It all runs in the browser, so files are never uploaded.

## How it works

- The sound goes through a Web Audio `PannerNode` in HRTF mode, which moves along the chosen path around a listener at the center.
- A low-pass filter darkens the sound when it passes behind your head.
- A generated convolution reverb adds the room.
- A Linkwitz-Riley crossover at 140 Hz can keep the bass in the middle.
- Exports are rendered offline with the same graph (`OfflineAudioContext`).
- MP3s are encoded with [lamejs](https://github.com/zhuker/lamejs).
- Videos are remuxed with [Mediabunny](https://mediabunny.dev). The video packets are copied as they are, and the new audio is encoded as AAC (or Opus for WebM).

## Spinaural for Mac (live)

A menu bar app that spins **everything your Mac plays** (Spotify, YouTube, games, calls) into live 8D or 16D sound. It has the same presets, paths, room echo and bass boost as the web app.

- Download the DMG from [Releases](https://github.com/learningnihongo934-byte/Spinaural/releases). It needs macOS 14.4 or later. The first time you open it, right-click the app and choose Open, because it isn't notarized.
- Click the orbit icon in the menu bar, then **Spin my Mac**. The first time, macOS asks to let Spinaural record system audio.
- It uses a Core Audio process tap that mutes the original sound while Spinaural is on, so you only hear the spun version. Stop or quit, and your Mac sounds normal again.
- The spatializer is native Swift: a spherical-head HRTF model (interaural time delay plus a Brown & Duda head-shadow shelf), a darker tone behind your head, Freeverb for the room, and the same LR4 crossovers as the web app.

```bash
cd mac
./build.sh            # build mac/build.noindex/Spinaural.app
./build.sh install    # copy to /Applications and open
./build.sh dmg        # universal DMG for releases
./build.sh selftest   # offline DSP check, no audio devices needed
```

## Build (web)

```bash
./build.sh          # build dist/
./build.sh serve    # serve at http://localhost:8830
./build.sh deploy   # publish to Cloudflare Workers
```

Made by **Virat Reddy Kaukuntla** ([@learningnihongo934-byte](https://github.com/learningnihongo934-byte))
