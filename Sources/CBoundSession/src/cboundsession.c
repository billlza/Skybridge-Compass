#include "CBoundSession.h"
#include <stddef.h>

_Static_assert(BS_FFI_ABI_VERSION_V1 == 1, "unexpected BoundSession ABI version");
_Static_assert(BS_FFI_ABI_VERSION_V2 == 2, "unexpected BoundSession ABI-v2 version");
_Static_assert(BS_FFI_CAPABILITIES_V2 == 0x0f,
               "unexpected BoundSession ABI-v2 capability set");
_Static_assert(BS_FFI_HANDLE_BYTES_V1 == 24, "unexpected BoundSession handle size");
_Static_assert(sizeof(BsFfiServiceHandleV1) == BS_FFI_HANDLE_BYTES_V1,
               "service handle layout drift");
_Static_assert(sizeof(BsFfiOwnerHandleV1) == BS_FFI_HANDLE_BYTES_V1,
               "owner handle layout drift");
_Static_assert(sizeof(BsFfiSessionHandleV1) == BS_FFI_HANDLE_BYTES_V1,
               "session handle layout drift");
_Static_assert(sizeof(BsFfiGrantHandleV1) == BS_FFI_HANDLE_BYTES_V1,
               "grant handle layout drift");
_Static_assert(sizeof(BsFfiOperationHandleV1) == BS_FFI_HANDLE_BYTES_V1,
               "operation handle layout drift");
_Static_assert(sizeof(BsFfiCommitPermitHandleV1) == BS_FFI_HANDLE_BYTES_V1,
               "permit handle layout drift");
_Static_assert(sizeof(BsFfiFinalizationRetryHandleV1) == BS_FFI_HANDLE_BYTES_V1,
               "retry handle layout drift");

#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(BsFfiDerivedFileGrantAuthorizationV2) == 104,
               "derived authorization layout drift");
_Static_assert(_Alignof(BsFfiDerivedFileGrantAuthorizationV2) == 8,
               "derived authorization alignment drift");
_Static_assert(offsetof(BsFfiDerivedFileGrantAuthorizationV2,
                        authorization_lifetime_ticks) == 16,
               "derived authorization lifetime offset drift");
_Static_assert(sizeof(BsFfiFileGrantInstallResultV2) == 72,
               "grant install result v2 layout drift");
_Static_assert(_Alignof(BsFfiFileGrantInstallResultV2) == 4,
               "grant install result v2 alignment drift");
_Static_assert(sizeof(BsFfiFileGrantEvidenceV2) == 824,
               "grant evidence v2 layout drift");
_Static_assert(_Alignof(BsFfiFileGrantEvidenceV2) == 8,
               "grant evidence v2 alignment drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2, peer_session_id) == 88,
               "grant evidence peer-session offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2,
                        durable_file_committer_identity_digest) == 792,
               "grant evidence tail offset drift");
_Static_assert(sizeof(BsFfiGrantOutboundMetadataV2) == 160,
               "grant metadata v2 layout drift");
_Static_assert(_Alignof(BsFfiGrantOutboundMetadataV2) == 8,
               "grant metadata v2 alignment drift");
_Static_assert(offsetof(BsFfiGrantOutboundMetadataV2, record_id) == 32,
               "grant metadata record-id offset drift");
_Static_assert(sizeof(BsFfiTrustedDeliveryConfirmationInputV2) == 88,
               "delivery confirmation input v2 layout drift");
_Static_assert(_Alignof(BsFfiTrustedDeliveryConfirmationInputV2) == 4,
               "delivery confirmation input v2 alignment drift");
_Static_assert(sizeof(BsFfiTrustedDeliveryConfirmationResultV2) == 16,
               "delivery confirmation result v2 layout drift");
_Static_assert(_Alignof(BsFfiTrustedDeliveryConfirmationResultV2) == 4,
               "delivery confirmation result v2 alignment drift");
#endif
