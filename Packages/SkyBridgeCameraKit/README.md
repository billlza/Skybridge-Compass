# SkyBridgeCameraKit

`SkyBridgeCameraKit` is the first-party protocol boundary for read-only local camera video.
It is intentionally independent of the macOS and iOS UI/runtime layers.

## Supported release contract

- An exact `rtsp://` or `rtsps://` URL supplied by the user.
- RFC1918 IPv4 or IPv6 ULA literals only; host names and public/link-local addresses are rejected.
- RTSP 1.0 over TCP with interleaved RTP/RTCP channels.
- H.264 single NAL, STAP-A, and FU-A packetization.
- Digest MD5/SHA-256 with `qop=auth`; Basic authentication only over RTSPS.
- System TLS trust and host verification for RTSPS.
- One frame consumer, bounded GOP-aware buffering, fixed request/media deadlines, keepalive, cancellation, and explicit teardown.

The package does **not** implement ONVIF discovery, path guessing, H.265, RTP/UDP,
audio, PTZ, vendor cloud access, certificate bypass, or an RTSP-to-WebRTC compatibility layer.

## H.264 parameter-set transitions

The depacketizer keeps one active, complete SPS/PPS pair and stages changed parameter sets
separately. A new generation is committed only after both sides are received. While a changed
generation is incomplete, VCL access units are not published; after a complete generation is
committed, predictive frames remain suppressed until an IDR is received. Parameter-set-only
access units update this state but never enter the display-frame queue or refresh media activity.

For a one-sided parameter change, a later access unit that only repeats the active counterpart is
treated as ambiguous and does not complete the pending generation. Cameras using that pattern must
send the complete SPS/PPS pair in one access unit. RTP discontinuity, SSRC change, or malformed
input discards every incomplete pending generation so parameter sets are never paired across loss.

## Ownership

Create the frame stream before calling `connectAndPlay()`. The owning app session must consume
that stream and call `stop()` during every terminal path. `stop()` is idempotent so frame-consumer
cancellation and owner shutdown can safely converge on the same teardown operation.

A logical receive timeout preserves the connection generation's one underlying receive for the
next waiter; the client never concurrently re-arms it or discards bytes delivered by its late callback.

Credentials must be passed through `RTSPCredentials`, never embedded in a URL. Public error and
description values are redacted and must not be augmented with the endpoint, headers, session ID,
nonce, or credentials by callers.
