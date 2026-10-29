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
  '20260905130000_lock_down_tenant_policy_and_enrollment_invites_v8.sql'
);
const operationalMirrorPath = path.join(__dirname, '..', 'sql', 'security_v8.sql');
const canonicalMigrationBytes = fs.readFileSync(canonicalMigrationPath);
const operationalMirrorBytes = fs.readFileSync(operationalMirrorPath);
const migration = canonicalMigrationBytes.toString('utf8');

const LOCKED_TABLES = ['tenant_security_policy', 'device_enrollment_invites'];

test('security v8 operational SQL mirror is byte-identical to the canonical Supabase migration', () => {
  assert.deepEqual(
    operationalMirrorBytes,
    canonicalMigrationBytes,
    'Update the canonical Supabase migration and its operational mirror together.'
  );
});

test('security v8 migration is single-transaction, time-bounded and privilege-only', () => {
  assert.match(migration, /^--[\s\S]*\nbegin;\n/);
  assert.match(migration, /set local lock_timeout = '5s';/);
  assert.match(migration, /set local statement_timeout = '60s';/);
  assert.match(migration, /commit;\s*$/);
  for (const forbidden of [/\bdrop\b/i, /\btruncate\b/i, /\bdelete from\b/i, /\bupdate public\./i, /\binsert into\b/i, /\balter column\b/i]) {
    assert.doesNotMatch(migration, forbidden, `v8 must not modify data or schema shape (${forbidden})`);
  }
  assert.doesNotMatch(migration, /create policy/i, 'no client-role policy may be introduced');
});

test('security v8 closes the client-role exposure of both v5 tables', () => {
  for (const table of LOCKED_TABLES) {
    assert.match(migration, new RegExp(`alter table public\\.${table} enable row level security;`));
    assert.match(migration, new RegExp(`revoke all privileges on table public\\.${table}\\s+from public, anon, authenticated;`));
    assert.match(migration, new RegExp(`grant select, insert, update, delete\\s+on table public\\.${table}\\s+to service_role;`));
    assert.match(migration, new RegExp(`security_v8_${table}_rls_disabled`));
    assert.match(migration, new RegExp(`security_v8_${table}_exposed_to_client_roles`));
    assert.match(migration, new RegExp(`security_v8_${table}_missing_service_role_grant`));
    for (const role of ['anon', 'authenticated']) {
      for (const privilege of ['SELECT', 'INSERT', 'UPDATE']) {
        assert.match(
          migration,
          new RegExp(`has_table_privilege\\('${role}', 'public\\.${table}', '${privilege}'\\)`),
          `${table}: the self check must cover ${role} ${privilege}`
        );
      }
    }
  }
  assert.match(migration, /grant usage, select on sequence public\.device_enrollment_invites_id_seq to service_role;/);
  assert.doesNotMatch(migration, /tenant_security_policy_id_seq/, 'tenant_security_policy has a uuid primary key and no sequence');
});
