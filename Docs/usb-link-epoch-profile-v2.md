# USB link epoch profile v2

Status: Kotlin and shared Swift state implementations exist; native activation is
still closed. This is the exchange above [v2 records](usb-link-record-profile-v2.md),
below the existing Yamux/MAIN bytes. Its nonces provide transport generation
correlation. They are not credentials, proof of device/account ownership, a
replacement for Finished, or authorization to play audio.

## Fresh exchange

Client means the USB host (Mac); server means the accessory (Android). These roles
are independent of the audio direction. Each newly created native owner must
generate a new, unpredictable 32-byte nonzero nonce using its platform RNG. Never
reuse a physical attachment ID, stored pairing key or previous epoch nonce.

1. Client sends OFFER(C, zero). Until established it retries at a bounded interval.
2. Server records candidate C and sends SELECT(S, C).
3. Client selects S and sends ACCEPT(C, S).
4. Server selects C only after its SELECT write succeeds and the matching ACCEPT
   arrives. It then sends READY(S, C).
5. Client becomes ready only after its ACCEPT write succeeds and matching READY
   arrives. Server becomes ready only after its READY write succeeds.

Receiving a reply while a write is outstanding is legal: the peer can receive
bytes before the local API completes its callback. This records provisional
confirmation, never premature local success. Replies before the required request
was dispatched are protocol failures. A client may supersede an unconfirmed SELECT
with a newly observed server nonce; a known retired candidate cannot return as
the current candidate. Once READY was received, replacement requires retirement
of this owner, even if its write callback has not completed yet.

DATA is admitted only for the selected sender/recipient pair. During the narrow
confirmation race the server may buffer DATA while its READY is in flight, and
the client may buffer DATA after receiving READY while ACCEPT completion is
pending. Neither can deliver it before readiness. Failure drops provisional
bytes. Early buffer overflow fails the epoch; it cannot wait on a consumer that
is forbidden to read until ready.

## Old records and live replacement

Complete records for a different recipient, and DATA from known retired
candidates, are explicitly quarantined under a finite lifetime budget. They
never reach the inner parser. After readiness, DATA addressed to the current
local nonce from an unknown sender fails with `wrongEpoch`. A matching CLOSE is
carrier loss, not authenticated file completion or successful audio drain.

A delayed OFFER/SELECT alone must not terminate an active stream. A ready server
answers a newly observed OFFER(C2) with SELECT(S, C2) while retaining C1. Only a
matching ACCEPT, after the challenge write completes, proves a live replacement
and fails the old owner with `peerRestarted`. Symmetrically, a ready client
answers newly observed SELECT(S2, C) with ACCEPT(C, S2); matching READY after that
write completes retires the old owner. Candidates first observed during startup
cannot be reclassified as new replacement probes. Candidate entries are not
evicted and rediscovered as new during one owner lifetime.

This challenge is a transport liveness check, not authentication. It neither
publishes the replacement nor copies old stream/account authority. Native
retirement must invalidate old stream owners and per-session grants, wait for
actual reader/writer/native cleanup, and then create a new epoch and new MAIN
handshake. A phone-only restart may not be discovered until the host's existing
carrier/mux liveness deadline expires: this layer does not send periodic OFFER
after readiness or promise immediate restart discovery. Automatic reopening,
retry limits and convergence are responsibilities still requiring native tests.

## Timing, bounds and I/O ownership

The default bounds for one owner are:

| Resource | Bound |
| --- | ---: |
| Whole startup elapsed time | 10 seconds |
| Client OFFER interval during startup | 500 milliseconds |
| Raw startup bytes, including flags/fragments | 1 MiB |
| Startup decoded/rejected records | 128 |
| Recoverable startup decoder rejections | 8 |
| Nonce candidates for the owner lifetime | 4 |
| Transmitted control records for the owner lifetime | 64 |
| Received controls after readiness | 128 |
| Quarantined records for the owner lifetime | 128 |
| Buffered incoming payload | 32 KiB |
| Pending DATA write | One, at most 16 KiB |
| Outstanding native dispatch | One |

Tests can inject smaller valid limits and a clock. The production clock is
monotonic elapsed time since owner construction; incoming traffic and retries do
not renew the deadline. Sampling happens inside the same state lock as updates,
so two caller threads cannot reorder clock samples. Only that owned nonblocking
clock executes under the lock, never native I/O or external effect callbacks.
A clock failure or backward observation is terminal. After ready, native/mux
read and heartbeat deadlines own established-connection liveness.

The native owner must:

- Count every raw read byte before decoding, including empty flags and prefix
  fragments; call `tick` independently of potentially blocked native I/O.
- Keep exactly one reader and one writer, preserving unread native packet tails.
  Split encoded records at the native transfer limit (at most 16 KiB per write).
- Keep its STARTUP decoder reader-owned. After the epoch becomes ready, seal it
  at the next complete record boundary, never concurrently from the writer.
  The epoch rejects any recovery/discard event after readiness even if the
  writer changed state before the reader could seal. Decoder errors retire the
  carrier; there is no scanning past corrupt active payload.
- Call `authorizeOutbound` immediately before each native fragment. Polling a
  dispatch is not continuing authorization after cancellation/retirement.
- Report the actual native callback exactly once. `reportWritten` accounts for
  that callback before rethrowing a prior terminal error or a replacement detected
  by that completion. Do not then call `reportWriteFailure` for the same dispatch.
  A failed epoch retains in-flight ownership until the actual callback; failure
  flags alone never establish physical cleanup.
- Hold a backpressured DATA record and retry that exact object after consumption;
  do not decode/deliver a later record first. Kotlin records carry reference
  identity; Swift wraps a decoded value once in `Inbound`. The state engine
  rejects an overtaking object. A nil read means ready and temporarily empty,
  never EOF or failed transport.

Successful write tickets prove the exact local dispatch completed, not receiver
delivery or application success. Failure preserves the first cause and cannot
be reversed by a late callback. A dispatch from another owner cannot account
for the current owner's flight.

## Native acceptance gates remain open

State tests and Kotlin/Swift process exchange are separate from device behavior.
Both native owners and the AOA application profile marker must move to v2
together; vendor request 51's AOA protocol version remains independent. Do not
interpret raw v1 Yamux as v2 records or silently fall back to Wi-Fi/IP. The current
Mac guard against reusing an already-active AOA attachment stays until physical
same-attachment recovery is demonstrated, including partial queued data,
one-sided restart, cancellation, bounded retry and confirmed cleanup.

Signed identity bindings, Finished, expected peer identity, offline lease expiry
and strict original-format audio output retain their existing contracts. USB
audio capability stays closed until native transport, authentication and actual
playback qualification all pass.
