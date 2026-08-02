#import "CBRDPSystemTrust.h"

#import <Security/Security.h>
#import <os/log.h>
#import <string.h>

static const size_t CBRDPMaximumCertificateChainBytes = 1024 * 1024;
static const NSUInteger CBRDPMaximumCertificateChainDepth = 16;

static os_log_t CBRDPSystemTrustLogger(void) {
    static os_log_t logger;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logger = os_log_create("com.skybridge.compass", "RDPSystemTrust");
    });
    return logger;
}

static BOOL CBRDPIsPEMWhitespace(unichar character) {
    switch (character) {
        case ' ':
        case '\t':
        case '\r':
        case '\n':
            return YES;
        default:
            return NO;
    }
}

/// Parses only a complete sequence of PEM CERTIFICATE blocks. Unknown labels, non-base64
/// payload bytes, trailing data and oversized chains are rejected instead of being ignored.
static NSArray * _Nullable CBRDPParsePEMCertificateChain(const uint8_t *data, size_t length) {
    if (!data || length == 0 || length > CBRDPMaximumCertificateChainBytes) {
        return nil;
    }

    NSString *pem = [[NSString alloc] initWithBytes:data
                                             length:length
                                           encoding:NSASCIIStringEncoding];
    if (!pem) {
        return nil;
    }

    static NSString * const beginMarker = @"-----BEGIN CERTIFICATE-----";
    static NSString * const endMarker = @"-----END CERTIFICATE-----";
    static NSCharacterSet *base64Characters;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        base64Characters = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="];
    });

    NSMutableArray *certificates = [NSMutableArray array];
    NSUInteger cursor = 0;
    while (cursor < pem.length) {
        while (cursor < pem.length && CBRDPIsPEMWhitespace([pem characterAtIndex:cursor])) {
            cursor += 1;
        }
        if (cursor == pem.length) {
            break;
        }
        if (certificates.count >= CBRDPMaximumCertificateChainDepth) {
            return nil;
        }

        NSRange remaining = NSMakeRange(cursor, pem.length - cursor);
        NSRange begin = [pem rangeOfString:beginMarker options:0 range:remaining];
        if (begin.location != cursor) {
            return nil;
        }

        NSUInteger payloadStart = NSMaxRange(begin);
        NSRange payloadAndEnd = NSMakeRange(payloadStart, pem.length - payloadStart);
        NSRange end = [pem rangeOfString:endMarker options:0 range:payloadAndEnd];
        if (end.location == NSNotFound) {
            return nil;
        }

        NSString *payload = [pem substringWithRange:NSMakeRange(payloadStart,
                                                                 end.location - payloadStart)];
        NSMutableString *normalizedBase64 = [NSMutableString stringWithCapacity:payload.length];
        for (NSUInteger index = 0; index < payload.length; index++) {
            unichar character = [payload characterAtIndex:index];
            if (CBRDPIsPEMWhitespace(character)) {
                continue;
            }
            if (![base64Characters characterIsMember:character]) {
                return nil;
            }
            [normalizedBase64 appendFormat:@"%C", character];
        }
        if (normalizedBase64.length == 0) {
            return nil;
        }

        NSData *der = [[NSData alloc] initWithBase64EncodedString:normalizedBase64 options:0];
        if (!der) {
            return nil;
        }
        SecCertificateRef certificate = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
        if (!certificate) {
            return nil;
        }
        [certificates addObject:(__bridge id)certificate];
        CFRelease(certificate);
        cursor = NSMaxRange(end);
    }

    return certificates.count > 0 ? [certificates copy] : nil;
}

int CBRDPVerifySystemCertificateChain(
    const uint8_t *data,
    size_t length,
    const char *hostname,
    uint32_t verificationFlags
) {
    if (verificationFlags != 0 || !hostname) {
        os_log_error(CBRDPSystemTrustLogger(),
                     "RDP certificate rejected: unsupported verification context");
        return 0;
    }

    const size_t hostnameLength = strnlen(hostname, 256);
    if (hostnameLength == 0 || hostnameLength >= 256) {
        os_log_error(CBRDPSystemTrustLogger(), "RDP certificate rejected: invalid hostname");
        return 0;
    }
    NSString *serverName = [[NSString alloc] initWithBytes:hostname
                                                    length:hostnameLength
                                                  encoding:NSUTF8StringEncoding];
    if (!serverName ||
        [serverName rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) {
        os_log_error(CBRDPSystemTrustLogger(),
                     "RDP certificate rejected: invalid hostname encoding");
        return 0;
    }

    NSArray *certificates = CBRDPParsePEMCertificateChain(data, length);
    if (!certificates) {
        os_log_error(CBRDPSystemTrustLogger(),
                     "RDP certificate rejected: malformed certificate chain");
        return 0;
    }

    SecPolicyRef policy = SecPolicyCreateSSL(true, (__bridge CFStringRef)serverName);
    if (!policy) {
        os_log_error(CBRDPSystemTrustLogger(),
                     "RDP certificate rejected: trust policy unavailable");
        return 0;
    }

    SecTrustRef trust = NULL;
    OSStatus status = SecTrustCreateWithCertificates((__bridge CFArrayRef)certificates,
                                                     policy,
                                                     &trust);
    CFRelease(policy);
    if (status != errSecSuccess || !trust) {
        if (trust) {
            CFRelease(trust);
        }
        os_log_error(CBRDPSystemTrustLogger(),
                     "RDP certificate rejected: trust object creation failed");
        return 0;
    }

    status = SecTrustSetNetworkFetchAllowed(trust, false);
    CFErrorRef evaluationError = NULL;
    BOOL trusted = status == errSecSuccess && SecTrustEvaluateWithError(trust, &evaluationError);
    if (evaluationError) {
        CFRelease(evaluationError);
    }
    CFRelease(trust);

    if (!trusted) {
        os_log_error(CBRDPSystemTrustLogger(),
                     "RDP certificate rejected by system trust and hostname policy");
        return 0;
    }

    // Session-only acceptance: this component never writes TOFU or fingerprint state.
    return 2;
}
