# Android USB logical streams: Apple integration

Status, 2026-10-24: the epoch-v2 native fixture has bounded clean-reopen and
live-peer-replacement evidence; raw-v1 still has the physical stale-frame
counterexample below. The source candidate now selects product-v2 explicitly;
installed USB audio remains unqualified. The original-file receiver has a captured
MAIN/file admission path and local playback-consumer checks; its optional
capability remains off for any raw-v1 carrier. Earlier sections
retain their historical candidate and scope; native fixture recovery is not
product reconnect or playback acceptance.

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

The native byte and multiplex owners described below supply reader/writer lifetime,
whole-frame deadlines, attachment checks and silent-peer expiry. Authenticated
purpose admission remains an explicit integration gate. The protocol object has no timer and
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

## Native Mac byte owner

`SkyBridgeAppleTransport.USBHostByteTransport` owns one reader, one writer and a
cleanup supervisor. `CSkyBridgeUSBHost` is a narrow macOS-only IOKit dependency;
it is not introduced into `SkyBridgeProtocolCore` or the iOS dependency graph.
The C boundary opens only the selected current registry entry in AOA accessory
mode (`18d1:2d00` or `18d1:2d01`), interface zero, with one bulk endpoint in each
direction. It uses ordinary public IOUSBLib190 operations. It does not seize,
switch USB modes, reset the device, stop a service, disable another driver or
fall back to a network endpoint. Registry IDs and descriptors are not identity.

Raw reads always provide a 16 KiB native buffer and retain its unused tail.
Successful zero-length USB transfers are packet boundaries, not EOF; they do
not extend the operation deadline. Writes are bounded to 16 KiB, preserve the
exact supplied bytes and check captured effect authority before and after the
native operation. A failed `WritePipeTO` has no known partial byte count and is
never retried as an unwritten packet. Attachment/authority callbacks must be
bounded, thread-safe and non-reentrant.

Cancellation retires C admission before waking the supervisor. The caller is
not blocked on native abort/close. The supervisor waits for the actual reader
and writer `Thread.isFinished` states before release. Opening that completes
after cancellation never becomes ready. The observer's bounded cleanup wait
does not terminate or abandon an unresolved native call. `shutdownState`
exposes retirement, actual worker exit, reference release and cleanup error as
separate facts. A native close error remains visible after COM reference release;
an unconfirmed `IOObjectRelease` leaves the owner unresolved. No automatic
release retry guesses whether the reference is still valid. Idle ownership has
no fixed polling timer; active deadlines are checked against the current request
under the same lock as completion/admission, so an old snapshot cannot expire a
new request.

Run focused checks serially:

```sh
python3 Scripts/check_usb_host.py --output /absolute/new/native-evidence-directory
```

The script builds the real C and Swift targets. Fourteen C cases run separately
with address/undefined-behaviour and thread sanitizers. Sixteen Swift cases run
against the actual thread-sanitized `SkyBridgeAppleTransport`, protocol and C
objects; the script verifies instrumentation, input hashes and exit statuses.
They exercise cancellation during acquisition and I/O, simultaneous directions,
bounded admission, sliced writes, packet tails/ZLP, attachment and effect
revocation, replaced deadlines, close errors, unresolved cleanup and deinit.
Native registry-absence checks use the real IOKit boundary. These tests inject
native outcomes and do not establish physical device data behaviour.

Local evidence is in the Android workspace's
`artifacts/apple-usb-native-carrier-20261023/`. A separate negative check selected
the actual USB-connected Samsung phone while it remained in normal
charging/ADB mode: it was rejected as not an accessory, and the Swift owner
confirmed worker exit/reference release. No USB mode, permission, driver, app
installation or playback setting was changed. SamsungAOA remains enabled; the
earlier physical ordinary-open conflict is still an open integration gate.
The earlier successful experimental AOA transfers are not proof for this new
carrier. An actual current-carrier round trip, PIB/SKR/MAIN consumers, launch
without ADB and authenticated audio remain pending.

## Native multiplex lifecycle

`USBHostMultiplexConnection` connects the shared protocol to the actual
`USBHostByteTransport`. A single reader pump keeps one whole-frame deadline
across header/body reads and validates the header before allocating its body.
A single writer pump binds each committed DATA dispatch to its captured write
lease. One event-driven deadline task owns pending-accept, half-close and current
ping expiry; audio data does not renew the liveness challenge. Matching pings
prove only transport progress, not identity or account validity.

Public stream operations allow one reader and one writer. The existing four-byte
big-endian control framing and 1 MiB policy ceiling are reused. One read lease
covers both prefix and body, so a second caller cannot interleave frame parsing.
Large writes split into bounded wire frames and wait for credit and their exact
dispatch completion within the original deadline. They preserve the supplied
bytes; `written` remains local dispatch evidence, not a peer file/audio receipt.

Revocation before native dispatch discards only that exact retired DATA frame
and resets its logical stream. Once raw writing is entered, a failure retires
the physical connection because bytes may already have left. The original
authority failure is published before native cleanup can block or another
reader reports a secondary disconnect. FIN preserves the reverse direction;
physical EOF is never synthesized as a successful logical FIN. Cancelled reads,
credit timeouts and pending/half-close expiry do not implicitly cancel siblings.

Dropping a public stream view resets it and transfers cleanup to the connection;
the handle table does not keep the view alive in an ARC cycle. Removed owners
still wake their registered cleanup observers. Connection cleanup waits for
native reference/worker evidence, actual pump task completion and logical
operations, with one cleanup observer at a time. A timed-out observer retains
unresolved ownership. The lifetime helper coalesces notifications, removes only
the exact cancelled waiter and joins the losing timeout/notification task.

```sh
python3 Scripts/check_usb_multiplex.py --sanitize --output /absolute/new/multiplex-evidence-directory
```

Twenty cases pass against the actual thread-sanitized native-byte, multiplex and
protocol modules. They include a 600,007-byte framed body, a blocked 700,011-byte
bulk write while a sibling control stream remains usable, scoped read/write
timeouts, queued/native revocation, reverse FIN, pending/half-close expiry,
dropped views, partial-frame EOF, ping expiry, cancellation during open/accept,
concurrent parent/stream cleanup, notification reuse, oversize headers and close
errors after confirmed release. Native I/O in these cases is a bounded synthetic
pipe; they are not physical USB or audio acceptance.

The same check script builds `swift-yamux-native-peer`, an isolated loopback
fixture that substitutes only native acquisition/I/O beneath the real byte owner
and pumps. Select it in Android with the additional argument
`-PusbYamuxSwiftNativePeer=/absolute/evidence/swift-yamux-native-peer` and run
`UsbYamuxAppleNativeInteropTest`. Its executable is a Gradle test input; there is
no fallback to a different peer. Six native-owner cases and six official Go
reference cases pass. The 262,145-byte and 65,579-byte echoes and 23-byte control
receipt agree with independent SHA-256 recomputation. Native-owner cleanup must
report worker exit, reference release, pump completion and zero logical owners.
Reverse tests prove data/FIN exchange; the native owner's public open waits for
ACK, so those cases do not add an early-DATA-before-ACK claim.

The first cross-language attempt failed its two reset cases. Kotlin's immediate
reset can clear a pending ACK and send RST directly; the old state-only fixture
returned a stream ID immediately, whereas the native owner's open waits for ACK.
The new fixture originally caught RST only in the later read. It now requires
an explicit RST during open or read, confirms the old owner is released, and
verifies the next stream's bytes/FINs. Both final reset receipts identify `open`.
No product admission, protocol validation or failure assertion was relaxed.
The failed receipts and matching candidate are retained separately.

Evidence is under `artifacts/apple-usb-multiplex-lifecycle-20261023/` in Android.
The expanded Android test-source lint run retains the same 125 errors and two
hints, compared by issue ID, message and source location; no new issue was added.
That existing lint debt, fresh published-branch/full-app builds, current physical
AOA data and the product authentication/file/audio consumers are not qualified
by these focused checks. Existing worktree changes and strict output policy
remain intact; Q-Periapt is unchanged.

## Owned MAIN frame carrier and session integration

`USBHostControlFrameTransport` owns one already-open logical MAIN stream. Its
FIFO defaults to eight frames and 2,097,160 retained wire bytes, counting the
active write. It validates the existing four-byte prefix/1 MiB ceiling before
admission. One writer and one deadline pump service the queue; there is no
unbounded task per frame. Queued cancellation/expiry removes that request.
Each frame retains its original deadline and effect authority, checked again
before dispatch and by the native owner for each chunk. Completion means local
write completion, not remote acceptance or audible playback.

An authorization failure before entering logical/native writing cannot submit
the stale frame. Cancelling an active partial MAIN frame retires that stream.
If cancellation races an already-entered raw write, the underlying carrier may
have an incomplete Yamux frame and must retire the physical link. Cleanup joins
the actual writer/deadline tasks, any reader and the native stream release;
an observer timeout does not discard the unresolved owner. Async public methods
retain the owning view for their whole operation.

```sh
python3 Scripts/check_usb_multiplex.py --sanitize --control-frames --output /absolute/new/main-frame-evidence
```

The actual thread-sanitized modules pass the existing 20 multiplex cases and
eight additional frame-carrier groups: FIFO bytes/completions, frame/byte bounds,
queued expiry, queued revocation/cancellation, active deadline/cancellation,
committed-write cleanup, single-reader cancellation and malformed input.
Cancellation during a credit wait is distinguished from cancellation inside a
raw write. The initial cleanup fixture incorrectly demanded a working sibling
after native-entry cancellation; the retained failure reports `disconnected`.
The final fixture instead requires physical retirement, preservation of its
original failure and complete release. It does not relax the carrier's safety
policy. The first failing harness aborted at top-level error; the second wrote
the failure and ended with SIGKILL, whose source was not established. Final
checks exit normally with zero and no sanitizer diagnostic.

The current Apple worktree also connects this carrier to `P2PConnection`'s
existing handshake, framing, pairing and encrypted sends. USB has no fabricated
`NWConnection`; the legacy network-only file engine rejects an unsupported route.
Handshake operation tokens, captured keys, message authority and audio effect
leases are checked at deferred dispatch. A positive audio capability publication
captures the receiver and peer generations so removing/replacing a receiver
cannot leave an old queued capability announcement valid. Network enqueue keeps
its existing synchronous preparation boundary. The native attachment runtime
must retain its frame carrier until `closeAndAwait` confirms release.

Those product changes are preserved as a patch relative to this task's original
working-tree files, rather than importing unrelated pre-existing modifications
into the carrier commit. The strict Mac core build and 138 selected session,
audio-publication, inbound-audio and file-route tests pass. The test command also
builds the app/test targets; it does not launch or qualify the installed app.
An existing duplicate product-root rpath in the test target was removed from
the manifest. The resulting Mach-O has the same ordered runtime search paths,
including exactly one product-root entry supplied by SwiftPM. The same 138
cases pass with compiler warnings treated as errors and linker warnings fatal;
no warning was suppressed.
The initial compiler rejected the nested non-escaping preparation callback; its
lifetime is now explicit and the existing closed-preparation fence is tested
against late submission. No unsafe escaping conversion or diagnostic suppression
is used. Input hashes and failed/current receipts are in the Android worktree's
`artifacts/apple-main-control-carrier-20261023/`.

The carrier branch contains the frame owner, its focused tests/script, the
scoped test-linker configuration fix and this documentation. The product patch
remains in the existing Apple worktree.
A fresh checkout build of that branch is not asserted. Product USB discovery and
bootstrap-route wiring, Android accessory/application adoption, current physical
AOA interchange/driver coexistence, native PQC over USB, account/offline grants,
the separate file service and strict audio output remain open. No app or device
was installed or reconfigured by this stage; Q-Periapt is unchanged.

## Selected Android accessory startup

`USBHostAccessoryPreparation` owns a separate device-control worker before any
native acquisition. Query sends AOA request 51 only. Start validates a fresh
nonzero canonical UUID, queries version 1/2, sends the six fixed product strings
with request 52, then sends request 53 once. The metadata matches the Android
product handler (`SkyBridge`, `SkyBridge USB Link`, version `1`); URI and serial
contain the same attachment nonce. This selects a handler and physical generation,
not a trusted peer. The existing signed MAIN handshake and account/effect
permissions are still required.

The selected IORegistry generation is checked before acquiring the public
IOUSBLib device-control interface. This path never opens or seizes a USB
interface, resets a device, stops ADB, disables a driver or creates an IP route.
An already-active AOA attachment is rejected before its metadata is overwritten.
Each native request has at most two seconds; one 18-second elapsed budget covers
acquisition plus requests and is never renewed by a partial response. Exact known
byte counts are required. Acquisition and release themselves have no universal
OS hard deadline, so cancellation retires only the in-memory attempt; a bounded
cleanup observer cannot abandon a live worker or assert reference release.

The receipt keeps identification attempts/completions, request-53 submission,
request-53 completion, operation failure and cleanup failure separately. A
cancelled attempt may still have completed its mode change, which the receipt
must preserve. The driver stays owned after unconfirmed release. Completed
release with an error remains an error. A closed preparation cannot start a
worker later. No ambiguous mode change is automatically retried.

`USBCConnectionManager.prepareAndroidUSB` uses the selected device's actual
registry and location IDs and a fresh nonce. Its application-level owner remains
admitted through worker cleanup and caller completion. A parallel cleanup
observer cannot admit a replacement while that caller is still completing, nor
clear a newer owner. Missing routing metadata, revocation and unconfirmed cleanup
fail explicitly. This is an app integration API; the Mac UI and native Android
bootstrap-route wiring are not completed by adding it.

The 53 C boundary cases pass under Address/UndefinedBehaviorSanitizer and
ThreadSanitizer. Eight Swift ownership groups pass using the instrumented actual
module. The first Swift run exposed retirement-before-run admitting a new worker;
its source snapshot and failing result are retained beside the passing revision.
These are boundary/ownership checks, not physical data-transfer or playback proof.
Source-bound receipts are under the Android worktree's
`artifacts/apple-android-usb-startup-20261023/`.

Protocol and platform references:
[Android Open Accessory 1.0](https://source.android.com/docs/core/interaction/accessories/aoa),
[Apple DeviceRequestTO](https://developer.apple.com/documentation/iokit/iousbdeviceinterface182/1559217-devicerequestto).
The local SDK declaration and actual native calls determine the implementation;
accessory negotiation alone never qualifies the later bulk/authentication/audio path.

On the connected SM-S948U1, the compiled public preparation owner queried version
2, completed all six metadata writes and completed request 53 once, with worker
exit and native reference release confirmed. IORegistry then showed a new
`18d1:2d01` device at the same location. Android reported the exact product
manufacturer/model/version and matching URI/serial nonce, with USB permission
assigned to the installed product application's UID. The installed APK hash
matches the Android product-entry revision. The app's Devices page was observed,
then its listener reported a socket timeout while no Mac MAIN peer was running.
This is not secure-session acceptance or observed playback.

The public byte owner then failed ordinary `USBInterfaceOpen` with
`kIOReturnExclusiveAccess` (`0xe00002c5`, phase OPEN). Its workers exited and its
native references were released. The selected interface 0 had SamsungAOA attached;
ADB clients were under interface 1. This locates the blocking native boundary and
shows a competing driver on the selected interface; no driver-removal comparison
was performed, so sole causation is not asserted. No interface was seized and no
driver was disabled. An attempted Android UI retry is excluded from evidence
because the foreground changed between observations. No ready-state screenshot
or stop/replay acceptance is claimed. Unrelated UI captures were discarded with
an invalid-observation record retained. The phone was returned to
`sec_charging,adb`; the initial restore command lost its transport, and a fresh
read via the other existing ADB server confirmed the restored mode.

The strict normal build and 15 selected Core preparation/discovery tests pass,
with no source drift, compiler warnings treated as errors and linker warnings
fatal. Current physical bulk data, native MAIN bootstrap/cryptography, account
grants and audio remain unverified. Mac UI startup wiring is still open. The
original authentication and strict-output requirements and Q-Periapt version
are unchanged.

## Native Android MAIN bootstrap integration

`USBHostBootstrapChannel` exchanges the existing MAIN JSON messages over a
fresh logical stream per request on an already-started, externally owned native
multiplexer. It bounds each request/response at 64 KiB, admits one exchange per
channel, and has one elapsed deadline across stream ACK, write, response and FIN.
It does not finish the requester's half while the responder may be waiting for
consent. After reading the complete response, it sends FIN and requires peer EOF;
extra trailing bytes fail. Cancellation closes the exact stream. Unconfirmed
cleanup retains that stream, retires further channel admission and exposes an
explicit cleanup-only retry. No request is automatically replayed by this class.

The current Core worktree routes native Android PIB and SKR through this channel
using `P2PUSBControlRoute`. The established signing, request/response validation,
pin checks, SAS confirmation, final acknowledgement and KEM-store signature
verification remain in their existing code paths. The route digest includes the
attachment nonce and MAIN purpose; it is not a new identity proof. Apple usbmuxd
keeps its existing digest bytes. A native Android exchange rejects network
endpoint candidates and has no `NWEndpoint`; a missing endpoint in this result
is an explicit route fact, not a network failure disguised as success. Opening
latency is measured by the actual logical-stream opening, not set to a guessed
network latency. `prepareAndroidUSBHandshake` is a preflight integration API;
it does not by itself publish an authenticated connection or audio capability.

The prior physical enabled/disabled/restored driver experiment is retained at
`artifacts/android-usb-coexistence-native-20261023`. Its results establish that
SamsungAOA blocks ordinary IOUSBLib opening in that tested environment. The newer
product-native owner has not yet been qualified with that driver condition
removed. No additional phone or driver mutation is part of this bootstrap stage.
Apple's local SDK documents `IOUSBHostObjectInitOptionsDeviceCapture` as requiring
`com.apple.vm.device-access` and IOServiceAuthorize (or root), terminating other
device clients/drivers and resetting/rematching on destroy. It is not adopted as
a silent fallback. Cooperative seize had already been refused by the isolated
probe; repeating that attempt is not new verification.

Sources: [IOUSBHost device capture](https://developer.apple.com/documentation/iousbhost/iousbhostobjectinitoptions/devicecapture),
[IOUSB interface cooperative opening](https://developer.apple.com/de/documentation/iokit/iousbinterfaceinterface183/1559513-usbinterfaceopenseize).

The bounded logical deadline now permits 315 seconds to match the existing MAIN
confirmation policy (up to 300 seconds of approval plus response allowance).
The native operation deadlines, physical keepalive and cleanup limits are not
extended. The legacy wire `routeScope = "lan"` remains the existing control
protocol scope, not evidence of an IP route or a grant to the LAN file service.
The actual transport route remains native USB and the separate non-IP file/audio
admission gates remain closed until their integration is verified.

Twenty multiplex checks, eight ordered MAIN frame groups and ten bootstrap
groups pass with the actual modules instrumented by ThreadSanitizer. The native
I/O boundary is synthetic in these checks. They cover a full 64-KiB response,
fresh streams, consent-time half-close behavior, cancellation, response deadlines,
trailing bytes, revocation, the 315-second admission bound and retained cleanup
without request replay. The first new check compilation used OptionSet syntax
for an integer wire bitfield; that test-only failure and source are preserved.
An initial Core run executed 68 cases and failed four pre-existing source-text
contract assertions whose markers no longer matched the saved pre-turn code.
Their current fixes preserve ordering, authority and deadline checks; results of
the final Core run are recorded separately, never substituted into the failed run.

This work does not establish current physical bulk transfer, native-device PQC
exchange, account/offline grant acceptance or audio playback. Mac user-interface
startup, re-enumeration ownership and MAIN session publication still need to be
connected to this preflight API and verified. No installed application, driver,
phone setting, account identity or Q-Periapt dependency was changed in this stage.

The final strict normal build and all 76 selected Core cases pass, including
three new native-route cases and the existing USB reconnect checks. The four
stale markers and one newly stale visibility marker were updated without
removing their ordering/diagnostic assertions. Compiler warnings are errors and
linker warnings are fatal; no test is skipped. Final source-bound results and
both failed Core source snapshots remain under
`artifacts/apple-android-usb-bootstrap-20261023/` in the Android worktree.
The native bootstrap channel, logical deadline adjustment, focused checker and
this documentation are published as a separate native-component branch. The
four-file Core integration is preserved in the current Apple worktree plus a
hash-bound, round-trip-verified patch relative to the original worktree snapshot.
It is not represented as a fresh-checkout Core build or hosted CI result.

## Native Android product session and Mac USB entry

The current Core worktree now connects preparation, same-port re-enumeration,
native multiplexing, signed PIB/SKR bootstrap and the existing MAIN handshake.
AndroidUSBConnectionCoordinator, retained by P2PDiscoveryService, owns one
Android physical connection across view navigation. It retains the exact run and
cleanup tasks after an observation timeout. Another connection is admitted only
after those tasks exit and the session, stream owners, native workers and
references are confirmed released. A cleanup retry acts on that retained owner;
it never repeats mode switching, bootstrap or authentication.

Re-enumeration requires the selected nonzero physical location, AOA vendor/product
and a new nonzero registry ID. Duplicate candidates are rejected, not deduplicated
using optional serials. Reusing the cached attachment nonce was initially allowed
for the same registry generation. The physical reopen counterexample below
invalidates that assumption: the cache has been removed and an already-active
AOA source is rejected before another runtime is created. Enumeration errors
remain errors; the device page labels a retained old snapshot instead of recording
a successful empty scan. Exact attempt IDs prevent cleanup of an older owner
from cancelling a newer preparation.

The Mac USB page uses existing eligible paired identities. The native Android
entry does not yet support Apple's signed automatic cable-peer inspection.
It verifies the selected identity through the existing trust and handshake
paths, including both the final signing algorithm and fingerprint, and publishes
only an authenticated PQC connection. Trust revocation, a superseding attempt,
disconnect and application stop retire the native owner. There is no IP fallback,
automatic driver removal or implicit trust based on a cable, name or serial.

The page provides cancellation, disconnect and explicit cleanup continuation.
Only native OPEN/IOKit exclusive-access errors receive the driver-occupancy
explanation; other errors preserve their own context. The non-IP file/audio
capability gates remain closed. This entry is not a claim of USB playback.
Validation and local-device receipts for this stage are recorded under
artifacts/apple-android-usb-session-20261023/ in the Android worktree. The dirty
Apple checkout and existing index remain the integration source; this is not a
fresh-checkout build or a release.

The current local integration passed 106 selected Core tests with compiler
warnings treated as errors and linker warnings fatal. These include native
attempt ownership, cancellation and retained cleanup, exact trust identity,
non-IP capability rejection, and UInt64 Ping/Pong JSON boundaries. The USB page
now uses the application's outer navigation container; nesting another split
view previously squeezed its controls into a narrow sidebar. A remote stream
failure remains visible after cleanup, while intentional disconnect stays a
normal stop.

On the attached API 37 Android phone, the native AOA product path completed
PIB/SKR and strict Q-Periapt ABI2 MAIN authentication. This exposed an Android
wire incompatibility: Apple generates the full UInt64 Ping range, but the
Android payload used signed Long. A diagnostic-only Android build reproduced
`malformed_ping`; changing the Android field to ULong preserves Apple's wire
contract. The first revised-device run no longer failed that parser, but is
**not accepted as a sustained session**: a replaced pairing request remained
hidden behind the obsolete review and declined at its configured deadline.
The corresponding Android navigation repair and physical rerun are separate
gates. Neither an authenticated MAIN nor these checks establish USB audio.

SamsungAOA coexistence remains a real native boundary. Some opens succeed while
the extension is enabled; later opens fail with exclusive access. Enabled state
alone does not prove interface ownership. A bounded diagnostic disabled only
SamsungAOA, then restored all six Samsung extensions and the phone's original
`sec_charging,adb` mode. Product code does not seize the interface or change
drivers. The original failed candidate, source manifests, diagnostic events,
and restoration receipts remain separate from later successful runs.

After the Android review-lifecycle fix, a product run held the authenticated USB
session for 123 seconds, including navigation away and back on both devices.
Mac-side disconnect completed cleanup. All six Samsung drivers were enabled
throughout that run. Same-attachment reconnect then failed before authentication;
it remains an open gate. A fresh AOA generation initially hit driver exclusive
access; temporarily disabling SamsungAOA allowed that fresh generation to
authenticate and receive its own one-time approval. Phone-side stop ended the
Mac connection, with a retained native-read deadline rather than a successful
continuation. All driver settings and the original phone USB mode were restored.
This does not establish automatic reconnect or native audio. The follow-up
evidence is in `artifacts/android-main-unsigned-ping-20261023/product-rerun/`.


## Native reopen boundary and containment

The isolated physical probe sent one Yamux SYN for stream 1, received its ACK,
and closed the Mac byte owner. After the phone's old listener ended and its
product retry started, two zero-write host reopens received old PING/SYN and
WINDOW_UPDATE/RST (stream 1) headers. Worker exit and native reference release
were confirmed for each observer. This directly disproves the assumption that
local close/reopen creates a fresh reliable byte stream on the tested accessory.
It does not weaken or bypass the existing MAIN authentication contract.

The coordinator now rejects both supported AOA product IDs before creating a
runtime, reserving an authentication attempt or replacing a peer session. The
runtime constructor enforces the same source precondition. Its obsolete cached
nonce/reopen branch was removed. The USB page explains that the cable must be
reinserted and disables connect for that source; a native byte timeout also has
an actionable message instead of an internal enum code. This is a protection
against a known-invalid route, not completion of seamless USB recovery. Android's
unchanged retry listener is not qualified as a fresh transport epoch.

Ordinary whole-device open was also tested with all six Samsung drivers enabled
in both normal and accessory mode; both returned `kIOReturnExclusiveAccess`.
The diagnostic never called reset or seized a device. System mode and driver
state were verified restored. No audio was played. Root-cause commands, headers,
strict builds and pre-change failing regressions are retained under
`artifacts/android-usb-reconnect-20261023/` in the Android worktree. The shared
Android decision record contains the corresponding native API references and
requirements for a future bounded link-epoch synchronization mechanism.


The containment revision passed 108 selected local Swift/Core cases with strict
compiler/linker warning settings, zero failures/skips/warnings, and unchanged
source inputs during the run. Its two new regressions failed on the previous
implementation before the repair. The task-relative patch was applied to the
saved starting files and checked byte-for-byte, and the pre-existing Apple index
was unchanged. The final source remains a dirty-worktree integration; it is not
an independently reproduced clean-checkout, native recovery, or audio acceptance.


The signed local containment candidate was also checked in the real Mac UI:
with the same paired Android choice, connect was enabled in ordinary USB mode,
then disabled with the reinsertion message after a real AOA mode transition.
Restoring ordinary mode restored the enabled button. This check did not start
MAIN or audio, and its diagnostic ADB mode restoration is not a consumer
physical-replug acceptance. The candidate exited and the original phone mode
and six enabled Samsung drivers were verified afterwards.


## Candidate link record boundary

The [v2 record profile](usb-link-record-profile-v2.md) now has bounded Kotlin and
shared Swift codecs with independent vectors and real cross-language process
checks. It handles partial old reads and explicitly reports a bounded set of
partial/damaged old records during startup; normal decoding remains strict.
A synthetic interrupted-write counterexample failed with the first candidate and
now recovers the next OFFER only in explicit startup mode. Complete stale DATA
still requires a fresh epoch owner to reject it before the inner parser.

The final Android/JVM selection passed 50 cases (17 record, 28 existing logical
protocol, 5 Kotlin/Swift process cases), with zero Core lint issues. The Swift
selection passed 37 cases (17 record and 20 existing logical protocol), with
strict compiler/linker warnings and no failures or skips. Initial fixture compile
failures and the original interrupted-write counterexample are retained in
`artifacts/android-usb-link-records-20261023/` in the Android worktree. No native
wire producer, profile marker, authentication gate or audio capability is enabled
by this codec. Fresh epoch negotiation, original USB I/O integration and physical
recovery/playback remain required; the current reattachment guard stays in place.

## Original-file receive carrier boundary, 2026-10-24

`ClassicFileTransferByteChannel` carries the existing classic-file protocol over
Network.framework or one admitted epoch-v2 logical stream. The non-IP entry
requires an already-approved `AudioOriginalFileTransfer`; it cannot authorize
general files, resume, an arbitrary endpoint or a new MAIN owner. The existing
metadata MAC, receiver approval, encrypted chunks, scan, durable private commit,
verified reader and receipt remain the common implementation. No new wire
format, account grant or output permission is introduced.

The logical adapter checks the exact native carrier/stream ownership and parent
lifetime, with a separate bounded effect predicate at native submission. After
writing the receipt it exchanges both FIN directions under one deadline and
joins file-stream cleanup before publishing the artifact. Reset/abort discards
unread queues, so receipt-write completion alone cannot be treated as peer
consumption. Missing FIN, extra bytes, cancellation and cleanup uncertainty
remain failures; other streams retain their owners.

The strict working-tree selection passed 86 tests without failures or compiler/
linker warnings. It includes a 600,068-byte encrypted WAVE transfer through the
actual native-byte/multiplex owners over substituted physical I/O, exact private
artifact readback and a surviving control stream. Raw-v1/foreign-owner rejection,
write-time grant revocation, completion timeout, trailing bytes, cancellation and
cleanup failure are covered. A regression initially failed because a late file
consumer received generic cancellation instead of the producer's cleanup error;
the actor now preserves that first cause for both early and late consumers.

The canonical native fixture moved to `Tests/SkyBridgeCoreTests`; the standalone
USB check script points to the same source and passed all 32 multiplex, nine
control-frame and 13 bootstrap groups, without ThreadSanitizer in this round.
Evidence, including failed compile/
test attempts, is in the Android workspace's
`artifacts/apple-original-file-carrier-20261024/`. Kotlin's companion completion
selection passed 99 tests and Core lint with zero issues. These separate local
fixtures do not establish cross-language physical file transfer or sound output.

The product dispatcher still must bind a BULK stream to its exact Finished-
verified MAIN session and approved offer. Consumer startup, default Samsung
driver coexistence and strict output hardware remain open. This receiver was
validated in the existing dirty Apple worktree; the isolated component branch
does not yet include the preceding audio dependencies. No clean-branch, installed
application or release acceptance is claimed.

## Approved MAIN and dedicated file admission, 2026-10-24

The optional logical-file acquisition now belongs to the exact native parent
of an admitted USB MAIN carrier. It requires epoch-v2 READY, Finished, committed
pairing capabilities and the current captured mailbox. The native write witness
checks that mailbox without reentering the connection/pairing locks. New MAIN
publication retires the old witness synchronously. A foreign parent, raw-v1,
missing send/approval capability or stale epoch cannot acquire a file route.

The existing dedicated original-file receiver handles either the Apple usbmuxd
return connection or the Android logical stream. It acquires only after the
audio offer, account lease and playback approval; retains the acquired owner
before checking authorization again; and requires receipt/FIN/cleanup completion
before the private artifact reaches strict playback. Failures retain their cause
and cleanup ownership. General-file admission cannot claim a dedicated grant.

The strict working-tree selection passed 173 tests with no compiler/linker
warnings. Concrete native fixtures cover parent matching and stale write denial;
the file tests include the dedicated receiver's encrypted 600,068-byte WAVE and
the complete playback consumer for both WAVE and FLAC with exact PCM comparison.
Test identities, keys and approved grants are supplied by fixtures; physical I/O
and the audio-output boundary are substituted. Evidence is in
the Android workspace's `artifacts/apple-file-main-binding-20261024/`, with source
snapshots and task-relative patches. The real Apple HEAD/index remain unchanged;
earlier audio dependencies are still missing from the isolated component branch.

In that binding-only candidate, product selection remained raw-v1 and did not
advertise the logical-file capability. Coordinated v2 activation, cross-language file
checks, installed startup/default-driver coexistence and physical playback are
still required. No device or installed application changed during these checks.

## Explicit application profile in product startup, 2026-10-24

Product preparation now requests application profile v2 and writes exact `2` in
the AOA identification version field. This is independent of the AOA protocol
version returned by request 51. The requested profile survives in the native
receipt and prepared attachment; the runtime configures the native owner from
that attachment rather than its raw-v1 default. A mismatched preparation result
fails with cleanup facts preserved. Legacy diagnostic C/Swift entry points keep
their explicit v1 default; no downgrade or retry is inferred from failed v2.

Android accepts only supported descriptor versions and binds the selected
profile to the same canonical attachment nonce and actual permission check.
The marker selects framing and does not authorize identity, account membership
or audio. Existing Finished/pairing, file grant, exact output and cleanup gates
remain mandatory. Product startup still rejects unowned/reopened accessory
generations; the prior stale-frame counterexample is not erased by this change.

The native C suite passed 92 boundary cases under both Address/Undefined
Behavior Sanitizer and ThreadSanitizer. The actual Swift transport modules and
their ownership checks also passed with ThreadSanitizer. The strict application
and Core selection passed 194 tests without compiler/linker warnings. Evidence
is in the Android workspace's `artifacts/apple-usb-product-profile-20261024/`.
These are source/fixture checks; no installed application or physical USB state
changed. Cross-language encrypted-file service and device playback still need
qualification, and the isolated Apple branch still needs its audio dependencies.

The current native peer also passed 32 multiplex, nine control-frame and 13
bootstrap groups, then 12 Kotlin/Swift process interop cases with explicit v1/v2
selection. These use substituted physical I/O and do not exercise the encrypted
original-file service. Android passed 247 focused tests, built its signed debug
APK and had zero Core lint issues; its full App lint retains 45 unchanged prior
issues. No unrelated dependency upgrade or check suppression was used.

## Cross-language original-file service qualification, 2026-10-24

The opt-in Kotlin/Swift process fixture now connects the actual Android
`MacLanFileTransferClient` and `UsbClassicFileTransferRoute` to the actual Mac
`FileTransferManager` dedicated receiver and `AudioPlaybackReceiveSession`.
Both native-byte/multiplex owners select epoch-v2. A loopback socket substitutes
physical USB I/O; fixed test keys, identities and approved MAIN/account grants
substitute the authentication ceremony; a collecting output substitutes the
physical audio device. This does not qualify account authentication, driver
coexistence, installed startup or acoustic/bit-perfect hardware playback.

The source file travels through normal metadata authentication, receiver
approval, encrypted chunks, private durable commit, verified-file delivery,
receipt authentication and both FIN directions. Success requires full source
SHA-256, decoded PCM equality, 44.1 kHz / 24-bit / stereo format, sender completion,
zero active file I/O, private-file cleanup and both native cleanup receipts.
An independent control stream must still exchange a frame after each file case.

| Case | Required observation |
| --- | --- |
| WAVE, 600,068 bytes / 100,000 frames | Full file and PCM match; one output preparation |
| FLAC, 651 bytes / 96 frames | Full file and PCM match; one output preparation |
| Approved offer has a different digest | Mac records `metadataMismatch`; sender fails; no output preparation |
| Receiver receipt authentication tag is corrupted | Sender records authentication failure; neither side reports completion; no output preparation |

The receipt fault is injected only in the test byte-channel wrapper. The offer
case changes only the fixture's approved digest. Assertions verify those exact
causes instead of accepting an arbitrary disconnection as sufficient evidence.
Fresh peer processes and cleanup receipts are required; this opt-in Gradle entry
does not reuse a cached test outcome. Regular Android tests do not load host
interop sources, and the Swift peer entry is compiled only with
`SKYBRIDGE_USB_FILE_INTEROP`.

The shared `USBLoopbackSocketFixture` is extracted from the existing standalone
native peer and used by both peer entry points. Its canonical native checks and
the older Kotlin/Swift transport cases must remain green after that extraction.
No production transport, account policy or output requirement changes in this
qualification step.

Build the Mac fixture with the explicit compile flag and a regular receiver
selection (one build/test job at a time):

```sh
xcrun swift test --jobs 1 --disable-automatic-resolution \
  -Xswiftc -DSKYBRIDGE_USB_FILE_INTEROP -Xswiftc -warnings-as-errors \
  -Xcc -Werror -Xlinker -fatal_warnings --filter AudioCaptureReceiveSessionTests
```

Then, from Android, set `APPLE_ROOT` to the Apple checkout and create a fresh
`RESULTS_DIR`. Point the opt-in runner at that built bundle and its checked-in
FLAC fixture; it launches only the explicit Swift peer test:

```sh
./gradlew --no-daemon --no-configuration-cache --max-workers=1 \
  -I scripts/audio_usb_probe/stream_reference/interop.gradle \
  "-PusbOriginalFileSwiftBundle=$APPLE_ROOT/.build/out/Products/Debug/SkyBridgeCoreTests.xctest" \
  "-PusbOriginalFileFixtures=$APPLE_ROOT/Tests/SkyBridgeCoreTests/Fixtures/AudioStreaming/flac-decoder-v1" \
  "-PusbOriginalFileResults=$RESULTS_DIR" \
  :core:testDebugUnitTest --tests com.skybridge.compass.core.p2p.UsbOriginalFileAppleInteropTest
```

Evidence is retained in the Android checkout under
`artifacts/android-usb-original-file-interop-20261024/` and
`artifacts/apple-usb-original-file-interop-20261024/`: commands, source/binary
hashes, per-case sender/receiver facts, raw logs and task-relative Apple patches.
The original-file quartet passed before and after adding exact rejection-cause
assertions. The Apple strict selection passed 194 tests; the subsequent receiver
selection reran 60 of those tests after the peer-only assertion change. These
counts overlap and are not additive. No installed package or device permission
was changed for this software qualification. The Apple integration remains in
the existing worktree; the separate component branch still lacks preceding audio
dependencies, so no clean-branch or release qualification is claimed.

The final combined run passed all 16 cases (four file-service cases and 12 prior
transport cases), with zero failures/errors/skips and zero Core lint issues.
The rebuilt native checker passed 32 multiplex, nine control-frame and 13
bootstrap groups. `checks-03` preserves a real test-tool regression: after the
socket driver was extracted, all 12 older process cases verified data/FIN but
failed on exit because the peer still matched its former private EOF enum.
The peer now matches the shared driver's exact EOF type; other errors remain
failures. `checks-04` is the passing rerun, not a relabeling of the failed record.
The wider App lint's 45 previously recorded issues are outside this test-only
change and were not rerun or suppressed here.

## Product reconnection candidate, 2026-10-26

The product Mac entry previously rejected every device already enumerated in
AOA mode, even though its native carrier already selected epoch v2. It now
allows an explicit connection attempt for the exact selected registry
generation and physical port, after rereading the current inventory. Missing,
replaced or ambiguous attachments still fail. A fresh route nonce and a new
epoch-v2 synchronization precede the normal signed MAIN handshake; neither the
USB name/serial nor the route nonce grants identity or account authority.

Android recognizes only the typed epoch `PEER_RESTARTED` termination for this
automatic recovery. The old native owner and all adopted sessions must actually
finish cleanup before a new owner can borrow the still-valid connected-device
foreground-service binding. Permission, current attachment and lease validity
are checked again. The automatic budget is two replacements per explicit
start/retry or new attachment. Explicit stop, permission loss, generic I/O/EOF,
legacy framing and uncertain cleanup cannot trigger this recovery. A failed
replacement remains a failure; it does not retain file or audio authorization.

The physical synchronization budget is 15 seconds on both ends to include the
retired owner's bounded cleanup. Pairing review, MAIN/frame deadlines and audio
authorization are separate. A sole verified peer record can be preselected in
the Mac picker; it does not automatically connect or grant trust.

The old controller failed the new replacement test with one runtime instead of
two. The old Mac coordinator failed the explicit existing-accessory case with
`unownedAccessory`. After the changes, 71 Android ownership/MAIN/multiplex tests
and 65 Mac coordinator/inventory/messages/epoch tests passed, with no skipped
tests. These use controlled native acquisition and are not device acceptance.
Commands, input hashes and both failing and passing results are retained under
`artifacts/usb-product-reconnect-20261026/` in each platform workspace. Installed
reconnection, slow trust review and background recovery still require the
separate physical-device receipts.

Physical follow-up on the signed Mac build `20261026072829` and Samsung
SM-S948U1 completed an unchanged-attachment reconnect and a 52.069-second
Android trust review. Both products then exposed the secure USB connection.
After 90 seconds on the Android home screen, the same service remained alive.
A Mac disconnect/reconnect while Android stayed in the background admitted a
new physical/session owner; the new temporary trust request still required
approval on the phone. Mac's authenticated-channel status alone is not evidence
of that remote feature approval.

The recovered channel subsequently delivered the known 111,868-byte ALAC file
through the ordinary picker and authenticated receive path. The receiver reached
48 kHz / two channels / 24-bit integer output preparation, then refused the
incompatible internal-speaker format. Android received the failure while USB
remained connected. No physical playback or real-session PCM digest was measured.

Explicit Android stop released its foreground service at the 0/5/20-second
observations. A new Mac attempt did not override that stop and timed out. An
explicit retry on both products restored the connection without replugging.
The peer stop currently surfaces as a timeout on Mac, not a verified graceful
stop reason. These bounded device receipts are retained in the Android
workspace's same-named artifact directory, including the negative attempt and
the final reconnect. They do not qualify arbitrary I/O recovery, endurance,
lock-screen music playback or strict physical output.
