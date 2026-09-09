#include <stddef.h>
#include <stdint.h>

#include "bound_session_ffi.h"

#if UINTPTR_MAX != UINT64_MAX
#error "BoundSession Apple ABI-v2 requires a 64-bit target"
#endif

_Static_assert(BS_FFI_ABI_VERSION_V2 == 2, "ABI-v2 version drift");
_Static_assert(BS_FFI_CAPABILITIES_V2 == 0x0f, "ABI-v2 capability drift");

_Static_assert(sizeof(BsFfiDerivedFileGrantAuthorizationV2) == 104,
               "derived authorization size drift");
_Static_assert(_Alignof(BsFfiDerivedFileGrantAuthorizationV2) == 8,
               "derived authorization alignment drift");
_Static_assert(offsetof(BsFfiDerivedFileGrantAuthorizationV2,
                        receiver_target_scope_presence) == 8,
               "derived authorization presence offset drift");
_Static_assert(offsetof(BsFfiDerivedFileGrantAuthorizationV2,
                        authorization_lifetime_ticks) == 16,
               "derived authorization lifetime offset drift");
_Static_assert(offsetof(BsFfiDerivedFileGrantAuthorizationV2,
                        platform_authorization_evidence_digest) == 24,
               "derived authorization evidence offset drift");
_Static_assert(offsetof(BsFfiDerivedFileGrantAuthorizationV2,
                        receiver_target_scope_digest) == 56,
               "derived authorization target offset drift");
_Static_assert(offsetof(BsFfiDerivedFileGrantAuthorizationV2, reserved) == 88,
               "derived authorization reserved offset drift");

_Static_assert(sizeof(BsFfiFileGrantInstallResultV2) == 72,
               "install result size drift");
_Static_assert(_Alignof(BsFfiFileGrantInstallResultV2) == 4,
               "install result alignment drift");
_Static_assert(offsetof(BsFfiFileGrantInstallResultV2, grant) == 8,
               "install result grant offset drift");
_Static_assert(offsetof(BsFfiFileGrantInstallResultV2, peer_session_id) == 32,
               "install result session offset drift");
_Static_assert(offsetof(BsFfiFileGrantInstallResultV2, local_role) == 64,
               "install result role offset drift");

_Static_assert(sizeof(BsFfiFileGrantEvidenceV2) == 824,
               "evidence size drift");
_Static_assert(_Alignof(BsFfiFileGrantEvidenceV2) == 8,
               "evidence alignment drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2, connection_generation) == 32,
               "evidence generation offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2,
                        authorization_expires_at_tick) == 48,
               "evidence expiry offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2, peer_session_id) == 88,
               "evidence session offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2,
                        authorization_transaction_id_digest) == 632,
               "evidence transaction offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2,
                        platform_authorization_evidence_digest) == 664,
               "evidence platform offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2,
                        authorization_record_digest) == 696,
               "evidence record offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2, owner_binding_digest) == 728,
               "evidence owner offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2,
                        service_incarnation_digest) == 760,
               "evidence service offset drift");
_Static_assert(offsetof(BsFfiFileGrantEvidenceV2,
                        durable_file_committer_identity_digest) == 792,
               "evidence committer offset drift");

_Static_assert(sizeof(BsFfiGrantOutboundMetadataV2) == 160,
               "outbound metadata size drift");
_Static_assert(_Alignof(BsFfiGrantOutboundMetadataV2) == 8,
               "outbound metadata alignment drift");
_Static_assert(offsetof(BsFfiGrantOutboundMetadataV2, record_length) == 16,
               "outbound metadata length offset drift");
_Static_assert(offsetof(BsFfiGrantOutboundMetadataV2, record_id) == 32,
               "outbound metadata record offset drift");
_Static_assert(offsetof(BsFfiGrantOutboundMetadataV2, shared_grant_id) == 128,
               "outbound metadata grant offset drift");

_Static_assert(sizeof(BsFfiTrustedDeliveryConfirmationInputV2) == 88,
               "confirmation input size drift");
_Static_assert(_Alignof(BsFfiTrustedDeliveryConfirmationInputV2) == 4,
               "confirmation input alignment drift");
_Static_assert(offsetof(BsFfiTrustedDeliveryConfirmationInputV2, record_id) == 8,
               "confirmation input record offset drift");
_Static_assert(offsetof(BsFfiTrustedDeliveryConfirmationInputV2, reserved) == 72,
               "confirmation input reserved offset drift");

_Static_assert(sizeof(BsFfiTrustedDeliveryConfirmationResultV2) == 16,
               "confirmation result size drift");
_Static_assert(_Alignof(BsFfiTrustedDeliveryConfirmationResultV2) == 4,
               "confirmation result alignment drift");
_Static_assert(offsetof(BsFfiTrustedDeliveryConfirmationResultV2, outcome) == 8,
               "confirmation result outcome offset drift");

static void typecheck_v2_exports(void) {
    uint64_t (*capabilities)(void) = bs_ffi_capabilities_v2;
    int32_t (*install)(BsFfiServiceHandleV1,
                       BsFfiOwnerHandleV1,
                       BsFfiSessionHandleV1,
                       const BsFfiDerivedFileGrantAuthorizationV2 *,
                       BsFfiFileGrantInstallResultV2 *) =
        bs_ffi_session_install_file_grant_v2;
    int32_t (*project)(BsFfiServiceHandleV1,
                       BsFfiOwnerHandleV1,
                       BsFfiGrantHandleV1,
                       BsFfiFileGrantEvidenceV2 *) =
        bs_ffi_grant_evidence_projection_v2;
    int32_t (*peek)(BsFfiServiceHandleV1,
                    BsFfiOwnerHandleV1,
                    BsFfiGrantHandleV1,
                    uint8_t *,
                    uintptr_t,
                    BsFfiGrantOutboundMetadataV2 *) =
        bs_ffi_grant_outbound_peek_v2;
    int32_t (*confirm)(BsFfiServiceHandleV1,
                       BsFfiOwnerHandleV1,
                       BsFfiGrantHandleV1,
                       const BsFfiTrustedDeliveryConfirmationInputV2 *,
                       BsFfiTrustedDeliveryConfirmationResultV2 *) =
        bs_ffi_grant_confirm_outbound_delivery_v2;
    (void)capabilities;
    (void)install;
    (void)project;
    (void)peek;
    (void)confirm;
}

int main(void) {
    typecheck_v2_exports();
    return 0;
}
