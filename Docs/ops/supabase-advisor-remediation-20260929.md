# Supabase Advisor remediation — 2026-09-29

This records the first remediation pass. For the completed platform upgrade,
pg_net relocation, Edge authentication repairs and build integration, see
[the follow-up report](supabase-postgres-upgrade-20260929.md).

Project: **SkyBridge Compass Pro**, `hloqytmhjludmuhwyyzb` (Tokyo).

Status: **the three approved migrations are deployed; hosted catalog, migration-history, OTP and REST permission checks passed**. Two platform warnings remain unresolved, so the overall Advisor gate correctly returns failure rather than claiming every warning is fixed.

## Verified hosted result

The user authorized the three migrations and the OTP change in this chat. The CLI applied the exact reviewed file hashes, and independent MCP/Management API reads confirmed all three migration versions in the hosted history. Auth readback at `2026-09-29T17:18:49Z` confirmed `mailer_otp_exp=600`.

| Check | Before | After |
| --- | ---: | ---: |
| RLS disabled in public | 1 ERROR | 0 |
| Mutable function/procedure search path | 34 WARN | 0 |
| Per-row Auth RLS lookup | 26 WARN | 0 |
| Multiple permissive policies | 8 WARN | 0 |
| Unindexed foreign keys | 13 INFO | 0 |
| GraphQL anon/authenticated table exposure | 57 / 57 WARN | 2 / 21 intentional WARN |
| Anon/authenticated SECURITY DEFINER execution | 30 / 33 WARN | 2 / 6 intentional WARN |
| Long email OTP expiry | 1 WARN | 0 |
| Non-relocatable pg_net / unavailable leaked-password feature | 2 WARN | 2 unresolved WARN |

Both hosted SQL acceptance checks passed. The read-only gate's three checks (`email_otp_bounded`, `migration_history_matches`, `database_invariants`) are true; there are no pending, remote-only or mismatched migration names. The gate returns exit 1 solely for the two unresolved warnings. The 31 intentional exposure findings remain visible, alongside 33 default-deny RLS INFO findings and 84 unused-index INFO findings.

Actual REST probes with the existing client's anonymous key and `limit=0` returned `401 / 42501` for both `cli_login_sessions` and `verification_codes`. The intentionally public `constellations` table returned 200. No user rows or credentials were printed.

Receipts and pre/post reports are retained locally under `Docs/ops/.state/supabase-advisor-20260929/` (ignored operational evidence). These files are not part of the Git changes.

The final whitespace check found trailing spaces in the captured binding-status function body. Only those trailing line spaces were normalized in the new local migration after deployment. The exact applied SQL and its original reviewed hash are retained in `*.deployed.sql` and `receipt.json`, alongside the normalized file's hash. No additional hosted SQL or behavior change was made.

## Observed cause

The hosted migration history is missing `20260802000000` and `20260901120000`, although both exist locally. The hosted schema still has client grants inherited from old Supabase defaults. A new table or function can therefore become client-accessible unless its author explicitly revokes the grants. Source files alone did not establish deployment.

The security advisor reported one RLS error, 214 warning findings and 31 informational findings. Performance reported 34 warnings, 13 unindexed foreign keys and 71 unused-index notices. The schema comprises 63 public tables totaling approximately 2.9 MB including indexes. No user rows were exported for this work.

## Reviewed cloud change

Applied these exact files, in order, using `supabase db push --linked --include-all --yes` after reviewing its dry run:

1. `supabase/migrations/20260802000000_harden_auth_privilege_boundaries.sql`
2. `supabase/migrations/20260901120000_harden_cli_sessions_and_pin_search_path.sql`
3. `supabase/migrations/20260929165934_remediate_advisor_privileges_and_rls.sql`

The first two are retained existing work. The third supplements them by:

- Pinning all 52 application functions and the maintenance procedure to trusted schemas, with `pg_catalog` first and `pg_temp` last. The maintenance procedure leaves its transaction commit to pg_cron's top-level `CALL`, because a procedure with a `SET` clause cannot execute `COMMIT`.
- Making new application tables, sequences and functions private by default for client roles. Future migrations must grant the intended access explicitly.
- Revoking client table privileges that are not supported by the access contract, including `TRUNCATE`, which RLS does not protect. Public read access remains for `constellations` and `disposable_email_domains`; authenticated ownership policies remain for the reviewed user tables.
- Restricting privileged helpers to service use, preserving both registration RPCs, authenticated avatar/contact RPCs, and the Auth hook's `supabase_auth_admin` grant.
- Removing unsafe verification-code table access and a user-prefix ownership bypass. Contact audit inserts become server-only. A missing identity can no longer pass the binding-status check through SQL NULL comparison.
- Rewriting per-row `auth.uid()` evaluation as initplans, removing duplicate profile policies, and adding 13 foreign-key indexes without deleting any existing indexes.

The new migration uses a 3-second lock timeout, 45-second statement timeout, and rejects blocking index creation if a table has grown beyond 64 MiB. Schema transactions roll back on failure. Existing migration files each have their own transaction; a failed later migration must be diagnosed rather than marking the entire rollout complete.

Auth configuration change: set `mailer_otp_exp` from **86400 to 600 seconds**, then independently read it back. SMS OTP is already 300 seconds.

## Verification actually performed

- Supabase MCP: current projects, both Advisors, actual function definitions, table/policy/privilege catalogs, migration history, and relevant deployed Edge Function callers.
- Supabase CLI 2.67.1: `db push --linked --dry-run --include-all` identified exactly the three files above.
- Native PostgreSQL **17.6**, isolated Unix socket and synthetic test users: replayed the captured schema; the old state failed on CLI-session RLS; all three migrations, both read-only acceptance scripts, and behavioral regression tests passed.
- Behavioral tests: anonymous denial, cross-user reads/writes, owner reassignment, direct privileged-helper access, RLS-bypassing `TRUNCATE`, missing-identity rejection, default grants on newly created objects, retained registration/login guard behavior, existing-account avatar projection, and service access.
- Five Python tests passed for malformed/truncated Advisor responses, changed overloads, unexpected errors and unresolved platform limits. `actionlint` and Python compilation passed.
- The read-only hosted gate was exercised before deployment. It correctly failed on missing migrations, the deployed schema and the 24-hour OTP; it did not claim the source changes had fixed the service.

This does not claim a full end-to-end mobile sign-in, new-account avatar provisioning, or execution of the production maintenance HTTP job. The local fixture contains the real public-schema definitions plus minimal managed Auth/Storage dependencies; it does not emulate the hosted gateway or extension worker.

## Prevention and continuing checks

`Scripts/test_supabase_advisor_migrations.py` replays every migration absent from the captured baseline into a dedicated **empty local database**, including future migrations. It also rejects edits to captured historical migration files by SHA-256, requiring a new migration. `.github/workflows/supabase-security.yml` runs it and the parser tests for relevant PRs and main/master pushes.

`Scripts/check_supabase_advisors.py --project-ref hloqytmhjludmuhwyyzb --output <report.json>` checks live Advisors, actual catalog invariants, migration history and Auth expiry. It reads `SUPABASE_ACCESS_TOKEN` or the existing macOS Supabase CLI Keychain credential without printing it. Unknown formats, query/API failures, missing migrations and unresolved warnings fail the gate. A manually dispatched read-only CI job requires the repository's `SUPABASE_ACCESS_TOKEN` secret. This workflow has been authored locally; it is not active on GitHub until the changes are committed and pushed.

`supabase/advisor_contract.json` explicitly records 31 intentional schema/RPC exposure findings by exact metadata. This does **not** suppress them in Supabase. Changes to signatures or new exposed objects fail review. RLS/no-policy and unused-index INFO findings stay visible: internal tables use default-deny RLS, and zero index scans alone do not justify deleting indexes.

After deployment, rerun both acceptance scripts and both Advisors; verify migration history and OTP via an independent read. Keep the report even when unresolved platform findings make the gate return failure.

## Genuine remaining limits and separately observed risks

- **Leaked-password protection:** the organization is on Free; Supabase makes this feature available on Pro and above. No upgrade or purchase is part of this change. The warning remains unresolved.
- **`pg_net` in public:** the extension is non-relocatable (`extrelocatable=false`) and its actual objects live in `net`. `ALTER EXTENSION ... SET SCHEMA` is not a valid fix. Dropping/recreating it may affect the HTTP queue and managed dependencies. Retain the warning for a Supabase-supported maintenance operation; do not edit the system catalog or drop the extension to hide it.
- Source inspection found additional legacy Edge Function issues outside these database Advisor changes: `scheduled-maintenance` has no request authentication and uses its service key for cleanup; `settings-management` accepts a caller-supplied `nebula_` identity before choosing its service client. Tightened table RLS cannot secure code that deliberately uses `service_role`. These paths need a separate reviewed server-authentication repair; the project must not be described as fully security-audited or fully hardened on the basis of this migration.
- The historical live login guard returns without issuing a login audit ticket, while the retained migration file describes a different contract. This rollout preserves observed live behavior; migration-version equality does not prove every historical function body matches source. A separate auth-contract reconciliation is needed before claiming login risk-control parity.

## Primary guidance

- [Explicit exposure and default privileges](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically)
- [Database Advisor checks](https://supabase.com/docs/guides/database/database-linter)
- [RLS performance](https://supabase.com/docs/guides/database/postgres/row-level-security#rls-performance-recommendations)
- [Password protection and plan availability](https://supabase.com/docs/guides/auth/password-security)
