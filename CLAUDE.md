# iosmirror

Mirror iOS screen to Chromecast over local WiFi.

## Project Goal

Stream an iOS device's screen to a Chromecast device on the same local network using ReplayKit for screen capture and a custom Chromecast receiver.

## Architecture

- **iOS App** (`ios/`) — Swift app with ReplayKit Broadcast Upload Extension. Captures screen frames, encodes to H.264 via VideoToolbox, serves HLS over a local HTTP server, and uses the Google Cast iOS SDK to tell Chromecast where to load the stream.
- **Chromecast Receiver** (`receiver/`) — HTML5 custom Web Receiver app hosted on a static server. Uses the Cast Application Framework (CAF) SDK to play the HLS stream from the iOS device.

## Branch

Development happens on `claude/general-work-0Eamh`.

## Key Constraints

- iOS system-wide screen capture requires a **Broadcast Upload Extension** (separate process, uses `RPBroadcastSampleHandler`).
- iOS device and Chromecast must be on the **same WiFi network**.
- Chromecast loads content via URL — the iOS device acts as an HLS origin server.
- No cloud relay or external server required.
