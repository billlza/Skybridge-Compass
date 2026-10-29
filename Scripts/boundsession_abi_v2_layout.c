#include <stddef.h>
#include <stdint.h>

#include "bound_session_ffi.h"

#if UINTPTR_MAX != UINT64_MAX
#error "BoundSession Apple ABI-v2 requires a 64-bit target"
#endif

_Static_assert(sizeof(BsFfiPurposeInputV3) == 112, "v3 purpose size drift");
_Static_assert(_Alignof(BsFfiPurposeInputV3) == 8, "v3 purpose alignment drift");
_Static_assert(offsetof(BsFfiPurposeInputV3, purpose_kind) == 8, "v3 purpose tag offset drift");
_Static_assert(offsetof(BsFfiPurposeInputV3, mode_or_direction) == 12, "v3 purpose mode offset drift");
_Static_assert(offsetof(BsFfiPurposeInputV3, capability_bitmap) == 16, "v3 capabilities offset drift");
_Static_assert(offsetof(BsFfiPurposeInputV3, declared_bytes) == 24, "v3 byte count offset drift");
_Static_assert(offsetof(BsFfiPurposeInputV3, transfer_id) == 32, "v3 transfer id offset drift");
_Static_assert(offsetof(BsFfiPurposeInputV3, content_sha256) == 64, "v3 content digest offset drift");
_Static_assert(offsetof(BsFfiPurposeInputV3, reserved) == 96, "v3 reserved offset drift");

_Static_assert(BS_FFI_ABI_VERSION_V2 == 2, "ABI-v2 version drift");
_Static_assert(BS_FFI_CAPABILITIES_V2 == 0x3f, "ABI-v2 capability drift");

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


_Static_assert(BS_FFI_ABI_VERSION_V4 == 4, "v4 version drift");
_Static_assert(BS_FFI_CAPABILITY_DURABLE_FILE_RUNTIME_V4 == 1, "v4 capability drift");
_Static_assert(BS_FFI_RECORD_CERTIFIED_RECEIPT_V4 == 11, "v4 carrier kind drift");
_Static_assert(BS_FFI_CERTIFIED_RECEIPT_BYTES_V4 == 3921, "v4 certified extent drift");
_Static_assert(sizeof(BsFfiDurableServiceConfigV4) == 432, "v4 config size drift");
_Static_assert(offsetof(BsFfiDurableServiceConfigV4, authority_database) == 256, "v4 original resource offset drift");
_Static_assert(sizeof(BsFfiAuthorityFenceV4) == 104, "v4 fence size drift");
_Static_assert(sizeof(BsFfiFileEffectBindingV4) == 248, "v4 binding size drift");
_Static_assert(sizeof(BsFfiFileEffectObservationV4) == 48, "v4 observation size drift");
_Static_assert(sizeof(BsFfiOriginalOperationKeyV4) == 96, "v4 operation size drift");
_Static_assert(sizeof(BsFfiReleaseHandleV4) == 24, "v4 release handle size drift");
_Static_assert(sizeof(BsFfiReleaseSignRequestV4) == 328, "v4 signing request size drift");
_Static_assert(offsetof(BsFfiReleaseSignRequestV4, context_length) == 308, "v4 signing context offset drift");
_Static_assert(sizeof(BsFfiCertifiedReceiptMetadataV4) == 240, "v4 metadata size drift");
_Static_assert(offsetof(BsFfiCertifiedReceiptMetadataV4, frame_sha256) == 200, "v4 full digest offset drift");
static void typecheck_v4_exports(void) {
    uint64_t (*caps4)(void) = bs_ffi_capabilities_v4;
    int32_t (*max4)(uint32_t, uintptr_t *) = bs_ffi_wire_max_length_v4;
    int32_t (*ready4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiGrantHandleV1, const uint8_t *, uintptr_t) = bs_ffi_grant_accept_peer_ready_v4;
    int32_t (*enable4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiGrantHandleV1, BsFfiGrantEnableResultV1 *) = bs_ffi_grant_enable_v4;
    (void)max4; (void)ready4; (void)enable4;
    int32_t (*open4)(const BsFfiDurableServiceConfigV4 *, BsFfiServiceCreateResultV1 *) = bs_ffi_service_open_durable_v4;
    int32_t (*advance4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, uint64_t, BsFfiAuthorityFenceV4 *) = bs_ffi_service_advance_owner_v4;
    int32_t (*head4)(BsFfiServiceHandleV1, BsFfiAuthorityFenceV4 *, uint32_t *) = bs_ffi_service_original_head_v4;
    int32_t (*effect4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiGrantHandleV1, BsFfiOperationHandleV1, BsFfiFileEffectCallbackV4, void *) = bs_ffi_grant_execute_file_effect_v4;
    int32_t (*operation4[])(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiGrantHandleV1, BsFfiOperationHandleV1) = {
        bs_ffi_grant_admit_file_operation_v4, bs_ffi_grant_commit_file_result_v4, bs_ffi_grant_abandon_file_operation_v4 };
    int32_t (*cancel4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiGrantHandleV1) = bs_ffi_grant_cancel_v4;
    int32_t (*key4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiGrantHandleV1, BsFfiOperationHandleV1, BsFfiOriginalOperationKeyV4 *) = bs_ffi_grant_operation_key_v4;
    int32_t (*recovery4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiOriginalOperationKeyV4 *, uintptr_t, uintptr_t *) = bs_ffi_service_recovery_keys_v4;
    int32_t (*recover4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiOriginalOperationKeyV4) = bs_ffi_service_recover_operation_v4;
    int32_t (*prepare4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiOriginalOperationKeyV4, BsFfiReleaseSignRequestV4 *) = bs_ffi_service_prepare_receipt_signature_v4;
    int32_t (*complete4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiReleaseHandleV4, BsFfiBytesV1, uint8_t *, uintptr_t, BsFfiCertifiedReceiptMetadataV4 *) = bs_ffi_service_complete_receipt_signature_v4;
    int32_t (*peek4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiReleaseHandleV4, uint8_t *, uintptr_t, BsFfiCertifiedReceiptMetadataV4 *) = bs_ffi_service_receipt_frame_peek_v4;
    int32_t (*confirm4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiReleaseHandleV4, BsFfiBytesV1) = bs_ffi_service_confirm_receipt_delivery_v4;
    int32_t (*accept4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiBytesV1, uint32_t *) = bs_ffi_service_accept_certified_receipt_v4;
    int32_t (*withdraw4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1, BsFfiBytesV1) = bs_ffi_service_withdraw_receipt_v4;
    int32_t (*retire4)(BsFfiServiceHandleV1, BsFfiOwnerHandleV1) = bs_ffi_service_retire_superseded_v4;
    int32_t (*service4[])(BsFfiServiceHandleV1) = { bs_ffi_service_reopen_authority_v4, bs_ffi_service_close_receiver_owner_v4, bs_ffi_service_abandon_head_update_v4 };
    (void)caps4; (void)open4; (void)advance4; (void)head4; (void)effect4; (void)operation4; (void)cancel4;
    (void)key4; (void)recovery4; (void)recover4; (void)prepare4; (void)complete4; (void)peek4; (void)confirm4;
    (void)accept4; (void)withdraw4; (void)retire4; (void)service4;

}

_Static_assert(sizeof(BsFfiFirstUseHandleV5) == 24, "v5 owner layout drift");
_Static_assert(sizeof(BsFfiFirstUseAnchorV5) == 88, "v5 anchor layout drift");
_Static_assert(sizeof(BsFfiFirstUseStateV5) == 24, "v5 state layout drift");
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(BsFfiFirstUseConfigV5) == 184, "v5 config layout drift");
_Static_assert(offsetof(BsFfiFirstUseConfigV5, platform_plan_binding) == 136, "v5 plan offset drift");
#endif
static void typecheck_v5_exports(void) {
    uint64_t (*caps5)(void) = bs_ffi_capabilities_v5;
    int32_t (*begin5)(const BsFfiFirstUseConfigV5 *, BsFfiFirstUseHandleV5 *) = bs_ffi_first_use_begin_v5;
    int32_t (*restore5)(const BsFfiFirstUseConfigV5 *, const BsFfiFirstUseAnchorV5 *, BsFfiFirstUseHandleV5 *) = bs_ffi_first_use_restore_v5;
    int32_t (*reserve5)(BsFfiFirstUseHandleV5, BsFfiFirstUseAnchorV5 *) = bs_ffi_first_use_reserve_v5;
    int32_t (*complete5)(BsFfiFirstUseHandleV5, const BsFfiFirstUseAnchorV5 *) = bs_ffi_first_use_complete_v5;
    int32_t (*state5)(BsFfiFirstUseHandleV5, BsFfiFirstUseStateV5 *) = bs_ffi_first_use_state_v5;
    int32_t (*owner5[])(BsFfiFirstUseHandleV5) = { bs_ffi_first_use_close_v5, bs_ffi_first_use_destroy_v5 };
    (void)caps5; (void)begin5; (void)restore5; (void)reserve5; (void)complete5; (void)state5; (void)owner5;
}

_Static_assert(sizeof(BsFfiInitializationHandleV6) == 24, "v6 handle layout drift");
_Static_assert(sizeof(BsFfiInitializationOpenV6) == 96, "v6 open layout drift");
_Static_assert(sizeof(BsFfiInitializationStateV6) == 24, "v6 state layout drift");
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(BsFfiInitializationStoreV6) == 48, "v6 store layout drift");
_Static_assert(sizeof(BsFfiInitializationConfigV6) == 504, "v6 config layout drift");
_Static_assert(offsetof(BsFfiInitializationConfigV6, resources) == 8, "v6 resource offset drift");
_Static_assert(offsetof(BsFfiInitializationConfigV6, trusted_policy_state) == 320, "v6 policy offset drift");
#endif
_Static_assert(sizeof(BsFfiInitializationKeyDigestsV6) == 216, "v6 key digest layout drift");
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(BsFfiInitializationKeyMaterialV6) == 104, "v6 public key material layout drift");
#endif
static void typecheck_v6_exports(void) {
    int32_t (*keys6)(const BsFfiInitializationKeyMaterialV6 *, BsFfiInitializationKeyDigestsV6 *) = bs_ffi_initialization_key_digests_v6;
    (void)keys6;
    uint64_t (*caps6)(void) = bs_ffi_capabilities_v6;
    int32_t (*begin6)(const BsFfiInitializationConfigV6 *, const BsFfiInitializationStoreV6 *, BsFfiInitializationOpenV6 *) = bs_ffi_initialization_begin_v6;
    int32_t (*restore6)(BsFfiBytesV1, const BsFfiInitializationStoreV6 *, BsFfiInitializationOpenV6 *) = bs_ffi_initialization_restore_v6;
    int32_t (*advance6)(BsFfiInitializationHandleV6, const BsFfiInitializationStoreV6 *, BsFfiFirstUseAnchorV5 *) = bs_ffi_initialization_advance_v6;
    int32_t (*plan6)(BsFfiInitializationHandleV6, uint8_t *, uintptr_t, uintptr_t *) = bs_ffi_initialization_plan_v6;
    int32_t (*state6)(BsFfiInitializationHandleV6, BsFfiInitializationStateV6 *) = bs_ffi_initialization_state_v6;
    int32_t (*owner6[])(BsFfiInitializationHandleV6) = {bs_ffi_initialization_close_v6, bs_ffi_initialization_destroy_v6};
    (void)caps6; (void)begin6; (void)restore6; (void)advance6; (void)plan6; (void)state6; (void)owner6;
}

int main(void) {
    typecheck_v6_exports();
    typecheck_v5_exports();
    typecheck_v4_exports();
    typecheck_v2_exports();
    return 0;
}
