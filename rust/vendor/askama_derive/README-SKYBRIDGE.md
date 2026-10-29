# Askama configuration parser maintenance

This is the crates.io `askama_derive 0.16.1` release, archive SHA-256
`071ee5ebf2138e3ad180e0aacf6940c2cab5e6d8333741d9925c7bee2b153f39`,
upstream commit `9ae4d5bdf4352b35e34106e38944c90d7a7ede3e`.
Original licenses and sources are retained. The unused upstream Cargo.lock
is omitted; the application uses rust/Cargo.lock.

`basic-toml` is unmaintained (RUSTSEC-2026-0374), including the version used by
the latest Askama release. The `config` feature is required by UniFFI's Swift
and Kotlin template generator; disabling it would remove binding generation.

The patch changes only the TOML dependency in both manifests and the
`RawConfig::from_toml_str` call, using maintained `toml` with `std`, `parse`,
and `serde` features. Its borrowing deserializer preserves Askama's borrowed
configuration model. Parse errors still become `CompileError`; there is no
fallback to an empty configuration. Regression tests cover malformed/duplicate
configuration input in addition to the upstream configuration tests.

Remove this patch when an upstream release replaces the unmaintained parser,
then rerun the configuration tests and actual Swift/Kotlin UniFFI generation.
