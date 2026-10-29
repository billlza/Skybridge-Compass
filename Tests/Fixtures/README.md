# Loopback benchmark identity

`loopback_test_server_certificate.der` and
`loopback_test_server_private_key.x963` form a test-only identity for local
Network.framework TLS, QUIC, and DTLS benchmarks. They are not production
credentials and must never be used outside loopback tests.

The certificate is a self-signed P-256 server leaf with these constraints:

- `basicConstraints = critical, CA:FALSE`
- `keyUsage = critical, digitalSignature`
- `extendedKeyUsage = serverAuth`
- `subjectAltName = DNS:localhost, IP:127.0.0.1`

The private key uses the 97-byte ANSI X9.63 external representation accepted by
`SecKeyCreateWithData`. The benchmark constructs the `SecIdentity` entirely in
memory and never imports test material into the user's Keychain.
