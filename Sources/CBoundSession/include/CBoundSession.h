// C module boundary for the frozen BoundSession FFI v1 contract and additive
// ABI-v2 product surface.
//
// The implementation is linked from the BoundSessionFFI binary target. This
// umbrella target owns SwiftPM's module map so the XCFramework does not create
// a second shared include/module.modulemap beside liboqs and Q-Periapt.
#pragma once

#include "bound_session_ffi.h"
