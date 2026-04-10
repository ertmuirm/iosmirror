# iosmirror

# function
Screen Mirror — iOS to Chromecast
Mirror your iPhone screen to any Chromecast-enabled device on the same Wi-Fi network.

# How it works
Component	Role
* HomeScreen (React Native)	Discover devices, start/stop mirroring
* MirrorBridge (Swift native module)	Connects RN to Cast SDK + HLS server
* BroadcastExtension (iOS app extension)	Captures screen frames via ReplayKit
* HLSStreamServer (Swift)	Encodes H.264, serves live HLS stream
* Google Cast SDK	Connects to Chromecast and plays stream

# UI
Upon first startup, user to approve required permissions
App should scan wifi for available local devices that are chromecast enabled
UI allows user to select device to cast to
Screen capture requires the user to tap "Start Broadcast" in the iOS system sheet — this is an iOS security requirement that cannot be bypassed (same as Replica).

# Signing
App to be built unsigned. Signing will be completed during installation via SideStore
