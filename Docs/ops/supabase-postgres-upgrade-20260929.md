# PostgreSQL upgrade and Supabase hardening

Project: `hloqytmhjludmuhwyyzb`, SkyBridge Compass Pro. The user authorized the upgrade, remaining repairs and push, and explicitly selected **keep the Free plan**.

## Deployed result

- Installed Homebrew PostgreSQL **18.6**, the current stable upstream release. The new default cluster uses peer authentication for local sockets and SCRAM for localhost TCP; no persistent background service was enabled. Tests use a separate private Unix-socket cluster.
- Upgraded Supabase from **17.6.1.031 to 17.6.1.171**, the newest GA version offered by the project's eligibility API. The platform completed its post-upgrade physical backup and returned `ACTIVE_HEALTHY`. `SELECT version()` still identifies the hosted engine as **PostgreSQL 17.6**; the platform does not offer PostgreSQL 18 for this project. Do not report the hosted engine as 18.6 or 17.11.
- Before upgrade, took a full custom-format logical backup over `sslmode=verify-full` with the official Supabase CA. The archive is 1,024,015 bytes, contains 1,262 TOC entries and passed full decoding with `pg_restore`. It is private, ignored operational evidence, not a repository artifact. Archive SHA-256: `1b986626bdd34485001365b877f7bf003da3f76fbd404b5b7719f79b76077852`.
- The upgrade also installed `pg_net 0.20.4` and `pg_graphql 1.6.1`. A guarded migration re-created pg_net with registration in `extensions`, preserving response rows and request sequence state. It refuses a nonempty request queue and never uses `CASCADE` or direct catalog updates.
- Restored login guard/audit behavior to the existing source contract, with one-use audit tickets and separate login attempt accounting. Real PostgreSQL tests found an ambiguous `attempt_type` column/parameter reference in the old source; the new migration qualifies the table columns explicitly.
- Added a unique `(user_id, setting_key)` constraint after verifying that the hosted settings table contained no duplicates. Settings updates now use one atomic upsert.
- Deployed `settings-management` version **16** and `scheduled-maintenance` version **12**. Settings verifies the user with Supabase Auth and retains the caller token for all database operations. It has no service-role client or caller-supplied identity fallback. Maintenance requires an independent random credential stored in Vault and Edge secrets. Its existing daily pg_cron call supplies that credential.

The SQL migrations introduced by this pass are `20260929173918_harden_legacy_auth_and_settings.sql` and `20260929173954_relocate_pg_net_and_authenticate_maintenance.sql`. Existing historical files were retained; the already-deployed v7/v8/v9 files are included as dependencies of the reproducible baseline.

## Evidence

- PostgreSQL 18.6 with the real pg_net 0.20.4 extension: the old schema fails the CLI-session security gate; all pending migrations, both acceptance scripts, ownership/permission tests, audit ticket replay tests and extension preservation checks pass. A queued HTTP request blocks the relocation transaction, and a stored response plus the monotonically increasing request ID survive relocation.
- Ten Deno security/error tests and strict type checking pass. They cover forged legacy identities, authorization outages, owner-scoped atomic updates, invalid stored data, oversized bodies, missing/incorrect maintenance credentials, read-only maintenance probing and explicit backend failures.
- Eleven CLI release workflow contract tests and twenty iOS transaction tests pass; actionlint and shellcheck pass for the affected workflows/helper.
- Hosted login guard probe, inside a transaction that was rolled back: `allowed=true`, `audit_ticket_issued=true`.
- Actual HTTP probes: maintenance without credentials **401**; a forged `nebula_` settings identity **401**; authenticated maintenance dry-run **200**, checking all six database operations without mutations.
- A request submitted through the real pg_net worker used the Vault credential to reach the maintenance endpoint: request **379**, response **200**, `timed_out=false`, `dry_run=true`, six checks completed.
- A Data API probe with `Accept-Profile: net` returned **406 / PGRST106**. The configured exposed schemas are `public,graphql_public`.
- The final live gate has passing OTP, migration history, database invariant and private-net-schema checks. Routine fingerprints also bind the expected live definitions, so an out-of-band function rewrite cannot hide behind an unchanged migration version.

Operational receipts are retained in the original workspace at `Docs/ops/.state/supabase-advisor-followup-20260929/`. This includes the backup, upgrade status, source/deployment receipts and full Advisor output. Do not publish the private backup or credential recovery files.

## Hosted extension privileges

Supabase owns the `net` objects as `supabase_admin`. The first relocation attempt emitted PostgreSQL warnings because the project's `postgres` role cannot revoke those owner grants. Catalog inspection confirmed the grants had **not** changed. These warnings were not treated as a successful privilege change.

The published migration applies object ACLs only when the executing role owns them. For hosted ownership it requires NOLOGIN client roles; the live gate additionally verifies that `net` is absent from the Data API configuration and no client-executable public RPC forwards to it. The external 406 probe verifies that boundary. This follows Supabase's documented permission model, rather than editing managed ownership or suppressing diagnostics. The original deployed SQL and log are retained separately; the corrected source removes the unsupported no-op operations for future deployments.

## Future builds

The reusable `supabase-security.yml` workflow runs real PostgreSQL **17.11 and 18.6** migration tests and the Edge Function security tests. It builds pg_net from the pinned upstream commit `698fb055f666366a78c112b0578b0a5652ddbcfa`; no mocks replace extension DDL. macOS readiness, iOS export, CLI packaging and CLI release builds depend on this gate. No cloud credentials are required for those build tests.

Linux extension builds install ICU development headers required by PostgreSQL. Disposable database containers use SCRAM authentication, and health checks select the existing database role explicitly. Server logs retain the two expected negative-test errors (the vulnerable baseline and nonempty queue guard); those are asserted failures, not unexplained production errors.

The optional live check requires `SUPABASE_ACCESS_TOKEN` and compares migration history, actual catalog invariants, routine fingerprints, exposed schemas, Auth expiry and Advisors. Update the routine contract only after a reviewed deployment and regression verification. It is not a blanket permission to accept unexpected drift.

The migration hash ledger freezes all 23 published migration files, including this rollout. The replay baseline still records the 18 versions present before remediation so regression runs continue to apply and exercise all five corrective migrations. Subsequent schema changes must use a new migration rather than rewriting deployed history.

`supabase/config.toml` retains each function's deployed gateway authentication mode. Deploy the two functions individually using `supabase functions deploy <name> --project-ref hloqytmhjludmuhwyyzb --use-api`; the maintenance handler requires `SKYBRIDGE_MAINTENANCE_TOKEN` to match the named Vault secret. Do not deploy with `--prune`, which would remove unrelated hosted functions absent from this source subset. Function configuration follows the [official configuration format](https://supabase.com/docs/guides/functions/function-configuration).

## Remaining findings

### Version recheck after the request to update all database components

The local Supabase CLI was upgraded from **2.67.1 to 2.118.0**, matching the latest stable vendor release. The official Homebrew tap was fast-forwarded before installation and the package checksum was verified by Homebrew. The new CLI successfully read the project and ran `db push --dry-run --include-all --skip-vault`, reporting no pending migrations. Local PostgreSQL and psql remain **18.6**, the latest stable upstream release.

The hosted kernel is still **17.6**. A fresh eligibility response reports `eligible=false`, `latest_app_version=supabase-postgres-17.6.1.171`, and an empty `target_upgrade_versions` array. This is a real outstanding version gap: [Supabase's September 25 announcement](https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes) says 17.11 upgrades became available to existing projects on September 28. The project-specific response does not expose that release. No assertion is made that 17.6.1.171 contains all upstream 17.11 fixes. After the user completed browser login, **Settings → General → Service versions** independently confirmed Postgres **17.6.1.171** marked **LATEST**, with no upgrade action. The same panel reports Auth **2.197.0** and PostgREST **14.18**. A managed kernel cannot be replaced by upgrading local psql or rebuilding the app. A [support request draft](supabase-postgres-upgrade-support-draft-20260929.md) records the discrepancy; it has not been sent.

All eight enabled extensions match the highest versions installed on the hosted platform: `pg_cron 1.6.4`, `pg_graphql 1.6.1`, `pg_net 0.20.4`, `pg_stat_statements 1.11`, `pgcrypto 1.3`, `plpgsql 1.0`, `supabase_vault 0.3.1`, and `uuid-ossp 1.1`. Extension version numbers do not establish that the older server binary has every upstream security fix.

The 17.11 compatibility preflight found no ltree indexes, GiST float indexes, or custom operator estimators covered by the announcement. No PGP legacy-cipher calls were found in public routine definitions or the inspected application/database source. This does not claim a complete audit of every external caller or stored ciphertext.

These database and deployed Edge Function repairs are enforced on the server and take effect for existing clients using the same project. RPC signatures were preserved, and the inspected macOS/iOS source already handles audit tickets. A new App Store package is not required just to activate the server fixes. Installed older binaries have not received a complete physical-device compatibility test in this task.

### Advisor findings

The only unresolved actionable platform warning is **leaked-password protection**, which requires Pro. It remains disabled because the user selected Free. The checker continues to report it and returns nonzero; it does not label the whole hosted audit green.

Thirty-one existing findings describe deliberate public/reference-data or authenticated ownership-protected RPC/table exposure. Thirty-three INFO findings describe default-deny internal tables without client policies, and unused-index INFO counts changed after the platform upgrade. These are retained with their rationale; indexes and needed client permissions were not deleted merely to clear the dashboard.

The maintenance verification was read-only. It did not manually execute the production deletion/expiry job. This report does not claim a full mobile sign-in UI test or complete security proof for every legacy Edge Function.

## Sources

- [PostgreSQL releases](https://www.postgresql.org/docs/release/)
- [Supabase upgrade process and caveats](https://supabase.com/docs/guides/platform/upgrading)
- [pg_net permissions and relocation](https://supabase.com/docs/guides/database/extensions/pg_net)
- [Leaked-password protection availability](https://supabase.com/docs/guides/auth/password-security)
