-- Legacy v5 registrations can contain a fingerprint without the public key.
-- Retain those identities as revoked without inventing missing key material.
-- Active and grace identities still require a valid, complete public key.
-- No grants, policies, existing records, or admission rules are changed.

begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

alter table public.device_identity_history
    alter column protocol_public_key_base64 drop not null;

do $$
begin
    if not exists (
        select 1 from pg_constraint
         where conrelid = 'public.device_identity_history'::regclass
           and conname = 'device_identity_history_key_material_v9'
    ) then
        alter table public.device_identity_history
            add constraint device_identity_history_key_material_v9 check (
                (state = 'revoked' and protocol_public_key_base64 is null)
                or (
                    protocol_public_key_base64 is not null
                    and public.is_valid_protocol_identity_key_v6(
                        protocol_signing_algorithm,
                        protocol_public_key_base64
                    )
                )
            );
    end if;
end;
$$;

commit;
