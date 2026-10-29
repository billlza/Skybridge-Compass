#ifndef CB_RDP_SYSTEM_TRUST_H
#define CB_RDP_SYSTEM_TRUST_H

#import <Foundation/Foundation.h>

#include <stddef.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Evaluates a complete PEM certificate chain using macOS system trust and exact SSL hostname
/// binding. Returns 2 for session-only acceptance and 0 for every rejection or internal failure.
int CBRDPVerifySystemCertificateChain(
    const uint8_t * _Nullable data,
    size_t length,
    const char * _Nullable hostname,
    uint32_t verificationFlags
);

NS_ASSUME_NONNULL_END

#endif
