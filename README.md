# mac-dlna-mirror

**TVMirror** is a small native macOS app that sends your Mac's screen and system audio to a smart TV over plain DLNA, with about **1 second of latency**. You don't need a cable, AirPlay, a dongle or an app on the TV.

It was built for TVs that don't have AirPlay, such as Samsung models from before 2018 on Tizen 2.x/3.x. macOS can't use their Miracast, so the only built-in way in is the TV's DLNA media player. That player normally buffers 5–8 seconds of video. TVMirror works around this buffering; the details are under [How it works](#how-it-works).

## Features

- **Mirror** the Mac screen, or use the TV as a **second display** (a virtual monitor that you can drag windows onto).
- **System audio** comes along, captured with ScreenCaptureKit. BlackHole and other virtual audio drivers aren't needed.
- **About 1 s latency**, held steady. A plain DLNA stream from other tools usually runs 5–8 s behind.
- **720p/1080p at 30 or 60 fps.**
- **English and Russian interface.** It follows the macOS language, and you can switch it at the top of the window.
- **One self-contained binary** that uses only Apple system frameworks. No ffmpeg and no Xcode project are needed.
- The TV is found automatically with SSDP, and you can also enter its IP address by hand.

## Status

This is a personal project that has been tested on one setup:

| TV | Mac | Result |
|---|---|---|
| Samsung UE43MU6100 (2017, Tizen 3.0) | MacBook Air (Apple Silicon), macOS 26 | Mirror and second display work. Latency is ~1.0 s, 1080p60 is smooth, audio is in sync, and a 16-minute session ran with no rebuffering. |

Other TVs with a DLNA/UPnP MediaRenderer should work at least as a plain stream, but nobody has tested them yet. The latency tricks depend on how the TV's player behaves. **If you try it on another TV, please open an issue** with the model and what happened, and include `~/Library/Logs/TVMirror.log`.

Things to know:

- The app is ad-hoc signed and there's no prebuilt download yet, so you build it yourself, which takes about a minute.
- Second-display mode uses Apple's private `CGVirtualDisplay` API, which tools like DeskPad and BetterDisplay also use. A future macOS update could break it.
- The build targets Apple Silicon (arm64). Intel Macs might work if you change `-target` in `build.sh`, but that hasn't been tested.

## Requirements

- macOS 14 Sonoma or later
- Command Line Tools (run `xcode-select --install`). The full Xcode isn't needed.
- A TV with DLNA/UPnP on the same local network as the Mac

## Build and run

```bash
git clone https://github.com/sdhrny13/mac-dlna-mirror.git
cd mac-dlna-mirror
TVMirror/build.sh
open TVMirror/build/TVMirror.app
```

On first launch, macOS asks for two permissions:

1. **Local Network**, so the app can find the TV. If you miss the prompt, go to System Settings → Privacy & Security → Local Network → TVMirror.
2. **Screen & System Audio Recording**, under System Settings → Privacy & Security. Restart the app after you grant it.

Then pick your TV, choose **Mirror** or **Second display**, and press **Start streaming**. The TV switches to its media player on its own.

## How it works

The Mac does the capturing, encoding and serving:

```
ScreenCaptureKit ──► VideoToolbox H.264 ─┐
 (screen + audio)                        ├─► MPEG-TS muxer ─► HTTP /screen.ts ◄── TV's DLNA player
                 └─► AudioConverter AAC ─┘                         ▲
                                                SOAP SetAVTransportURI + Play
```

1. The app finds the TV with SSDP and calls `SetAVTransportURI` and `Play` on the TV's AVTransport service. The TV then pulls an endless MPEG-TS stream over HTTP from the Mac, at a per-session random path that only the TV's address can open. The project has its own TS muxer for PAT/PMT, PES, PCR and ADTS.
2. **Latency catch-up.** At startup the TV's player fills a buffer of about 4 s and then plays at exactly 1×, so that delay never goes away by itself. TVMirror measures the real delay by polling `GetPositionInfo` (Samsung reports `RelTime` with millisecond precision). It then briefly runs the stream clock at 0.75–0.85×: the TV receives content slightly faster than real time, plays it at 1× and drains the extra buffer until about 1 s is left. Audio is muted during the catch-up, which takes a few seconds.
3. **Null-packet padding.** The TV decides when to rebuffer based on bytes, not seconds. A static desktop encodes to only a few dozen kbit/s, so the buffer looks empty and the TV pauses to rebuffer. TVMirror pads the stream with TS null packets up to 8 Mbit/s. Without the padding, the TV rebuffers at around 2 s of latency. With it, the latency holds at about 1 s.
4. **60 fps fix.** VideoToolbox doesn't write `timing_info` into the H.264 SPS. Without it, the Samsung player plays at about 30 fps even when the stream carries 60. TVMirror rewrites the SPS to add VUI timing (`SPS.swift`).
5. **Decoder-safe H.264.** The encoder uses low-latency rate control and Constrained High profile with no B-frames, and long-term reference frames are disabled. With LTR on, the TV's decoder fails.
6. **Audio clock drift.** The audio clock and the video clock drift apart slowly. TVMirror corrects small drift by resampling by up to ±0.5%. It does a hard resync only when the drift goes above 200 ms.
7. **Second display.** The app creates a virtual 1920×1080 monitor with `CGVirtualDisplay`. It waits until the monitor really becomes active and retries with a new vendor/product/serial if it doesn't, because some identities are accepted but never come up.
8. **VPN-friendly discovery.** SSDP is sent separately on every LAN interface with `IP_MULTICAST_IF`, so TV discovery still works when a VPN takes over the default route.

## Troubleshooting

- **The TV isn't found.** Check the Local Network permission. If you rebuilt the app while it was running, quit and reopen it, because macOS revokes Local Network access from a running binary that changed on disk. You can also type the TV's IP address by hand.
- **The screen recording permission seems ignored.** Run `tccutil reset ScreenCapture local.tvmirror.app`, start the app and grant the permission again.
- **The latency creeps up.** If the TV rebuffers, TVMirror raises its latency target by 0.25 s and catches up again. A weak Wi-Fi link to the TV is the usual cause.
- **The Mac runs warm.** Switch to 30 fps, which halves capture and encoding work.
- Logs are in `~/Library/Logs/TVMirror.log`.

## Security

- The stream is served over HTTP on port 8090 (or the next free port), but **only the selected TV's IP address and the Mac itself can connect**. Any other device is disconnected before the server reads its request.
- The stream address contains a random token that changes with every session (`/screen-<token>.ts`). It only works while streaming.
- The server limits how many connections it accepts at once, drops clients that don't send a request within 5 seconds, and accepts only short `GET`/`HEAD` requests.
- During discovery, a device description is accepted only if it comes over plain `http` from the same private IP address that answered SSDP. Its control URL must point to that same address, and redirects are refused.
- The stream itself is **not encrypted**: TV DLNA players don't support HTTPS. Someone who can capture traffic on your Wi-Fi could still record it, so don't stream sensitive content on networks you don't trust.

## Command line

The same binary has a headless mode for testing:

```bash
APP=TVMirror/build/TVMirror.app/Contents/MacOS/TVMirror
$APP --discover                                   # list TVs
$APP --headless --tv 192.168.1.50 --catchup --pad-kbps 8000 --fps 60 --duration 60
$APP --headless --test-pattern --tv 192.168.1.50 --catchup --pad-kbps 8000
$APP --headless --test-pattern                    # no TV: prints a local URL for ffprobe or VLC
```

Other flags: `--height 720|1080`, `--no-audio`, `--extend` (second display), `--target 1.0` (latency target in seconds), `--catch-rate 0.85`, `--no-fps-sps` and `--profile main|high`.

## License

[MIT](LICENSE)
