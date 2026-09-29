# Supabase support request — submitted

Submitted through the signed-in Supabase support form on 2026-09-29 after explicit user authorization. The dashboard confirmed **Support request sent** and stated that the ticket had been logged for SkyBridge Compass Pro. No ticket number was displayed. Category: Other; affected service: Database; severity: Low. The project-access switch was **off**, no attachments were included, and the Free plan was retained.

Subject: PostgreSQL 17.11 GA upgrade unavailable for an existing project

Hello Supabase Support,

Please investigate the PostgreSQL upgrade eligibility for our existing Free-plan project:

- Project: SkyBridge Compass Pro
- Project reference: `hloqytmhjludmuhwyyzb`
- Region: `ap-northeast-1`
- Project health: `ACTIVE_HEALTHY`
- Current Supabase database build: `supabase-postgres-17.6.1.171` (GA)
- Actual SQL `server_version`: `17.6`

Your September 25 announcement states that the PostgreSQL 17.11 update became available to existing projects on September 28:
https://supabase.com/changelog/postgres-15-19-17-11-breaking-changes

On September 29, both the signed-in dashboard and Management API still report the older build as the latest available for this project:

- Settings → General → Service versions displays Postgres `17.6.1.171` with the `LATEST` badge and no upgrade action.
- `GET /v1/projects/hloqytmhjludmuhwyyzb/upgrade/eligibility` returns:

```json
{
  "eligible": false,
  "current_app_version": "supabase-postgres-17.6.1.171",
  "current_app_version_release_channel": "ga",
  "latest_app_version": "supabase-postgres-17.6.1.171",
  "target_upgrade_versions": [],
  "validation_errors": [],
  "warnings": []
}
```

The documented compatibility checks found no affected ltree indexes, GiST float indexes, or custom operator estimators. Our database migration and authorization regression suite passes on PostgreSQL 17.11 and 18.6. All eight enabled extensions match the highest versions provided by the current platform image.

Could you identify the rollout or eligibility restriction and provide or enable the supported upgrade path to PostgreSQL 17.11 or a newer stable hosted version? Please also clarify whether the current 17.6.1.171 build includes any security fixes from the announced 17.11 update; we do not want to infer that from the platform build suffix.

We want to remain on the Free plan. Please do not change the subscription or provision paid resources.

Thank you.

---

The submitted body matched the approved draft exactly. It contains project identifiers and version/eligibility metadata only; no database contents, backups, passwords, API tokens, or secret values were submitted. The local receipt and confirmation screenshot are retained under `Docs/ops/.state/supabase-latest-review-20260929/`. Submission does not mean that the requested PostgreSQL upgrade has been enabled or completed.
