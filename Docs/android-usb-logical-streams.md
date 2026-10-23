# Android USB logical streams: Apple integration

Status, 2026-10-23: shared Swift wire/state implementation and Kotlin/Swift
process interoperability verified. Native AOA ownership, product admission and
audio integration remain open. No new USB capability is advertised.

The existing `SkyBridgeCore.USBMultiplexTransport` speaks Apple's usbmuxd
protocol. It stays the Apple-device route; it is not an Android AOA implementation.
The new `SkyBridgeProtocolCore.USBLogicalStreamWire` and
`USBLogicalStreamProtocol` implement the bounded Yamux v0 contract used by the
Android carrier. They add no Network.framework, IOKit, account or cryptographic
runtime to the shared protocol layer.

## Ownership contract

One protocol object belongs to one physical attachment generation. It serializes
protocol transitions with a private lock, without performing I/O, callbacks or
waits inside that lock. Default limits are eight retained owners, two pending
accepts, 4,096 non-reused identifiers and 32 session control frames. Each stream
has a fixed 256 KiB receive window and one pending write of at most 16,372 bytes;
the twelve-byte header keeps an outgoing wire frame within a 16 KiB transfer.
The receive ring is updated without retaining a second dictionary alias that
would force a full-window copy on each frame. This is a storage/ownership
property, not a measured memory, CPU or USB throughput claim.

`pollOutbound` commits exactly one immutable dispatch token. Only its matching
completion can finish it. `written` means local native dispatch, never peer
receipt. Reset fails both logical directions; releasing an owner waits for its
committed dispatch and reset. Before native I/O starts, only the exact retired
DATA dispatch can be discarded. Physical failure retires all streams and never
becomes a normal per-stream FIN. Half-close preserves the reverse direction.
Late frames remain bounded by both count and outstanding credit. Current ping
replies must match a dispatched, strictly increasing challenge; they grant no
identity, account validity or playback permission.

The future `SkyBridgeAppleTransport` AOA owner must own the real reader/writer,
whole-frame and operation deadlines, attachment replacement, silent-peer expiry,
purpose admission and native cleanup. The protocol object has no timer and
cannot certify a driver or worker has stopped. It must feed the existing
PIB/SKR, MAIN/Finished and authenticated file/audio paths, without a local TCP
forwarder, fake IP endpoint, new trust store or crypto fallback. Strict original
format output remains unchanged.

## Reproducible checks

From this repository, with the selected Xcode installed:

```sh
python3 Scripts/check_usb_logical_streams.py --output /absolute/new/evidence-directory
```

The script builds the actual `SkyBridgeProtocolCore` target with one build job,
Swift 6 and warnings as errors. It links the focused XCTest suite and local peer
against the current aggregate module object, with linker warnings treated as
errors. It does not copy protocol sources into a parallel package. A legacy
`libSkyBridgeProtocolCore.a` may coexist in Products; it is not used as evidence
for the completed target. The initial manual link encountered such a stale
archive, and that failure is retained in the local record. The script also uses
Xcode's Swift XCTest overlay, rather than only the Objective-C framework headers.

Twenty XCTest cases cover header vectors and malformed frames, bounded credit
and queues, wrapped/tiny receive frames, sliced input ownership, identifier
reuse, half-close, reset, physical failure, late data, go-away, exact dispatch
completion and matching liveness challenges. Test discovery and execution
counts must match the checked-in test methods; no test is skipped.

The produced `swift-yamux-peer` is a test executable, outside product targets.
It listens for exactly one connection on 127.0.0.1, has bounded waits, emits byte
and hash receipts, and confirms its reader exit after closure. It is not a
native USB adapter. In the Android repository, select it explicitly:

```sh
./gradlew --no-daemon --no-configuration-cache --max-workers=1 \
  -I scripts/audio_usb_probe/stream_reference/interop.gradle \
  -PusbYamuxReferencePeer=/absolute/verified/yamux-reference-peer \
  -PusbYamuxSwiftPeer=/absolute/new/evidence-directory/swift-yamux-peer \
  :core:testDebugUnitTest --tests '*UsbYamuxReferenceInteropTest' \
  --tests '*UsbYamuxAppleInteropTest'
```

Quote each complete `-P...` argument when its path contains spaces. Both peer
executables are registered as Gradle test inputs, so replacing one invalidates
cached test results. The Apple fixture verifies the Swift implementation marker
and its final cleanup receipt; a missing peer does not fall back or skip.

Six Kotlin↔Swift cases passed: protocol-state and actual Android pump variants
each cover a blocked file window with a separate control exchange, a 262,145-byte
echo, reverse early data with a 65,579-byte echo and FINs, and reset followed by
another stream. Both sides and an independent digest agree. The six official Go
reference cases remain separate; their known late-credit warning is preserved
and has an official-to-official reproduction in the Android experiment.

The two new shared Swift files also pass an ARM64 iOS 17 source type check with
the installed device SDK. This is not an iOS app build, installation or runtime
test. Mac and iOS product builds, physical AOA, Samsung driver coexistence,
consumer startup without ADB, account/offline grants and original-format audio
acceptance remain independent gates. Q-Periapt was not upgraded.

Local evidence is under the Android workspace's
`artifacts/apple-usb-logical-streams-20261023/`. Existing Apple working-tree
changes were preserved; only the new protocol, focused test, peer, check script
and this integration record belong to this addition.
