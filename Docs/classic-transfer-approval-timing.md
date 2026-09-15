# Classic transfer receiver approval timing

A new classic transfer authenticates metadata and asks the receiver for consent
before reading file payloads. Both Apple applications allow 60 seconds for that
decision. A sender previously gave every socket write only 30 seconds. With
backpressure, accepting a valid prompt after 42 seconds could therefore fail
because the sender had already cancelled its connection. This was observed on a
1,048,593-byte iPad-to-Mac transfer from candidate `2a135c27`.

`ClassicTransferReceiverDecisionWindow` now starts once after a new transfer's
metadata write. Its monotonic deadline covers the existing initial header read
(5 seconds), metadata payload read (10 seconds), and receiver decision (60
seconds). Each payload write adds only the unspent part of that 75-second window
to its ordinary 30-second timeout. Consecutive frames and rate-limited slices
share the same deadline; they cannot restart the allowance. After it expires,
ordinary 30-second frame timeouts apply.

Small and empty files can fit in socket buffers before approval. Their receipt
header wait adds the same remaining allowance to the ordinary 60-second receipt
timeout. Receiving an actual header ends that phase; the receipt payload retains
its original 60-second timeout. Neither a buffered write nor a consent action
marks a transfer successful: the authenticated receipt, file size, file hash and
existing commit checks still decide completion.

Metadata writes and receiver response writes retain their ordinary deadlines.
Resume uses the existing authenticated resume ACK before payload transmission,
so its 15-second ACK waits and subsequent normal I/O timeouts do not receive a
new-file decision allowance. Cancellation, rejection, connection cleanup,
security version 2 and wire transcripts are unchanged.

Regression coverage exercises delayed approval, a non-renewing allowance across
frames and slices, buffered-file receipt waits, expiry and independent attempts.
The release's physical acceptance must additionally demonstrate a delayed
approval beyond the old 30-second timeout, an actual newly saved file with the
expected digest, and its successful authenticated completion receipt.
