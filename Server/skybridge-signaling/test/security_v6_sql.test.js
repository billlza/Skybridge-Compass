'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const canonicalMigrationPath = path.join(
  __dirname,
  '..',
  '..',
  '..',
  'supabase',
  'migrations',
  '20260722041138_device_identity_rotation_v6.sql'
);
const operationalMirrorPath = path.join(__dirname, '..', 'sql', 'security_v6.sql');
const canonicalMigrationBytes = fs.readFileSync(canonicalMigrationPath);
const operationalMirrorBytes = fs.readFileSync(operationalMirrorPath);
const migration = canonicalMigrationBytes.toString('utf8');

test('security v6 operational SQL mirror is byte-identical to the canonical Supabase migration', () => {
  assert.deepEqual(
    operationalMirrorBytes,
    canonicalMigrationBytes,
    'Update the canonical Supabase migration and its operational mirror together.'
  );
});

test('security v6 migration is single-transaction and installs the rotation authority schema', () => {
  assert.match(migration, /^--[\s\S]*\nbegin;\n/);
  assert.match(migration, /set local lock_timeout = '5s';/);
  assert.match(migration, /set local statement_timeout = '60s';/);
  assert.match(migration, /alter table public\.registered_devices[\s\S]*identity_generation bigint not null default 1/);
  assert.match(migration, /create table if not exists public\.device_identity_rotations/);
  assert.match(migration, /create table if not exists public\.device_identity_history/);
  assert.match(migration, /create table if not exists public\.device_identity_rotation_audit/);
  assert.match(migration, /commit;\s*$/);
});

test('security v6 migration enforces one active identity and collision-safe issued rotations', () => {
  assert.match(
    migration,
    /device_identity_history_one_active_per_device_idx[\s\S]*where state = 'active'/
  );
  assert.match(
    migration,
    /device_identity_rotations_one_issued_per_device_idx[\s\S]*where state = 'issued'/
  );
  assert.match(
    migration,
    /device_identity_rotations_one_issued_per_new_key_idx[\s\S]*where state = 'issued'/
  );
  assert.match(
    migration,
    /device_identity_rotations_request_id_idx[\s\S]*tenant_id, user_id, device_id, request_id/
  );
});

test('security v6 commit RPC is atomic, generation-CASed, and idempotent by transcript hash', () => {
  const commitStart = migration.indexOf('create or replace function public.commit_device_identity_rotation_v6');
  const commitEnd = migration.indexOf('revoke execute on function public.is_valid_protocol_identity_key_v6');
  assert.ok(commitStart >= 0 && commitEnd > commitStart);
  const commitRPC = migration.slice(commitStart, commitEnd);

  assert.match(commitRPC, /for update;/);
  assert.match(commitRPC, /if v_rotation\.transcript_hash <> p_transcript_hash/);
  assert.match(commitRPC, /if v_rotation\.state = 'committed'[\s\S]*return v_rotation\.result;/);
  assert.match(commitRPC, /set state = 'grace'/);
  assert.match(commitRPC, /'active', v_now, p_rotation_id/);
  assert.match(commitRPC, /identity_generation = v_new_generation/);
  assert.match(commitRPC, /and identity_generation = p_old_generation/);
  assert.match(commitRPC, /get diagnostics v_rows = row_count;/);
  assert.match(commitRPC, /if v_rows <> 1 then[\s\S]*identity_generation_conflict/);
});

test('security v6 audit and RPC privileges are fail closed', () => {
  assert.match(migration, /alter table public\.device_identity_rotations enable row level security;/);
  assert.match(migration, /alter table public\.device_identity_history enable row level security;/);
  assert.match(migration, /alter table public\.device_identity_rotation_audit enable row level security;/);
  assert.match(migration, /identity_rotation_audit_is_immutable/);
  assert.match(migration, /before update or delete on public\.device_identity_rotation_audit/);
  assert.match(migration, /assert_service_role_request_v5\('issue_device_identity_rotation_v6'\)/);
  assert.match(migration, /assert_service_role_request_v5\('commit_device_identity_rotation_v6'\)/);
  assert.match(
    migration,
    /revoke execute on function public\.commit_device_identity_rotation_v6\([\s\S]*from public, anon, authenticated;/
  );
  assert.match(
    migration,
    /grant execute on function public\.commit_device_identity_rotation_v6\([\s\S]*to service_role;/
  );
  assert.match(migration, /security_v6_commit_rpc_exposed_to_anon/);
  assert.match(migration, /security_v6_audit_immutability_trigger_missing/);
});

test('security v6 uses a common per-device lock order and bounds persistent growth', () => {
  const deviceLock = /hashtextextended\([\s\S]*?p_tenant_id::text \|\| ':' \|\| p_user_id::text \|\| ':' \|\| p_device_id,[\s\S]*?6001/g;
  assert.equal([...migration.matchAll(deviceLock)].length, 2);
  assert.match(migration, /identity_rotation_device_daily_limited/);
  assert.match(migration, /identity_rotation_user_daily_limited/);
  assert.match(migration, /create or replace function public\.expire_device_identity_grace_v6/);
  assert.match(
    migration,
    /with expired_candidate as \([\s\S]*new_protocol_public_key_fingerprint = p_new_protocol_public_key_fingerprint[\s\S]*state = 'issued'[\s\S]*expires_at <= v_now[\s\S]*candidate_claim_expired/
  );
  assert.match(
    migration,
    /if v_request\.state = 'expired' or v_request\.expires_at <= v_now then[\s\S]*raise exception 'rotation_expired'/
  );
});
