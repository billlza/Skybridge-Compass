# Vendored FreeRDP / WinPR headers

These are the public and CMake-generated headers built by
`Scripts/build_freerdp_dylibs.sh` from the same pinned FreeRDP source revision as
the runtime closure in `Sources/Vendor/FreeRDPDylibs`.

`Sources/Vendor/FreeRDPRuntime.provenance.json` is the machine-verifiable source
of truth for the exact upstream versions, commits, build inputs, header-tree
digest, binary hashes, architectures, deployment target, install names and
dynamic dependency closure. A release must reject any header/runtime/provenance
version mismatch.

The reviewed source patch in `Scripts/Patches` fixes CMake 4 flag detection,
Apple arm64/NEON portability, disabled-feature stubs, signed-size checks and
strict test return handling. It also removes duplicate link inputs. The recipe
forbids warning suppressions and builds the product's actual surface: the
libfreerdp/WinPR core, software GDI and basic input. Client-common and every
channel plugin are not built or registered; FreeRDP audio, image scaling, USB
redirection and smart-card support are explicitly disabled. The bridge also
forces redirection, RemoteApp and display-control settings off before connect.
The FreeRDP and WinPR deprecated 3.x API surfaces are disabled in both the
runtime and bridge compilation.

The recipe copies the upstream public headers, overlays the generated
configuration headers, and applies a separate header-only Apple compatibility
change in `include/winpr/wtypes.h`: WinPR's `REFIID` typedef is omitted on Apple
platforms because CoreFoundation already exports an incompatible definition.
The RDP core paths consumed by `FreeRDPBridge` do not use that alias.

FreeRDP and WinPR are licensed under Apache-2.0; see the upstream repository.
