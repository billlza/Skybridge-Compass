#!/usr/bin/env python3
"""Replay pending/future migrations in an EMPTY local PostgreSQL database."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--psql", default="psql")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", default="5432")
    parser.add_argument("--user", default="postgres")
    parser.add_argument("--database", default="supabase_advisor_test")
    args = parser.parse_args()
    if args.host not in ("localhost", "127.0.0.1", "::1") and not Path(args.host).is_absolute():
        parser.error("Only a local host or absolute Unix socket directory is allowed")
    if args.database in ("postgres", "template0", "template1"):
        parser.error("Use a dedicated empty test database")
    command = [args.psql, "-X", "-v", "ON_ERROR_STOP=1", "-h", args.host,
               "-p", args.port, "-U", args.user, "-d", args.database]

    def run(sql=None, path=None, expect_failure=None):
        invocation = command + (["-At", "-c", sql] if sql else ["-f", str(path)])
        result = subprocess.run(invocation, capture_output=True, text=True, timeout=120)
        if expect_failure:
            if result.returncode == 0 or expect_failure not in result.stderr:
                raise RuntimeError("Baseline failed to reproduce the target defect: " + result.stderr)
        elif result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout.strip()

    count = run(sql="SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public'")
    if count != "0":
        raise RuntimeError("Test database is not empty; refusing to overwrite it")
    run(sql="CREATE EXTENSION pg_net WITH SCHEMA public")
    run(sql="INSERT INTO net._http_response(id,status_code,content) VALUES (777,204,'retained fixture'); SELECT setval('net.http_request_queue_id_seq',1000,true)")
    run(path=ROOT / "supabase/tests/fixtures/advisor_schema_before.sql")
    run(path=ROOT / "supabase/verification/advisor_security_acceptance.sql",
        expect_failure="RLS disabled: cli_login_sessions")
    print("PASS: observed baseline fails the security gate for CLI session exposure", flush=True)
    baseline = json.loads((ROOT / "supabase/tests/fixtures/migration_state.json").read_text())
    for name, digest in baseline["captured_local_hashes"].items():
        path = ROOT / "supabase/migrations" / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Historical migration changed: {name}; add a new migration instead")
    paths = sorted((ROOT / "supabase/migrations").glob("*.sql"))
    for path in paths:
        if path.name.split("_", 1)[0] not in baseline["applied_versions"]:
            if path.stem.endswith("relocate_pg_net_and_authenticate_maintenance"):
                run(sql="INSERT INTO net.http_request_queue(method,url,headers,timeout_milliseconds) VALUES ('GET','https://fixture.invalid','{}',1000)")
                run(path=path, expect_failure="pg_net queue must drain")
                run(sql="DELETE FROM net.http_request_queue WHERE url='https://fixture.invalid'")
            run(path=path)
            print("PASS: " + path.name, flush=True)
    if run(sql="SELECT count(*) FROM net._http_response WHERE id=777 AND content='retained fixture'") != "1":
        raise RuntimeError("Extension relocation lost a response")
    if int(run(sql="SELECT last_value FROM net.http_request_queue_id_seq")) < 1000:
        raise RuntimeError("Extension relocation reset request IDs")
    for path in ["supabase/verification/auth_privilege_boundaries_acceptance.sql",
                 "supabase/verification/advisor_security_acceptance.sql",
                 "supabase/tests/advisor_regression.sql"]:
        run(path=ROOT / path)
        print("PASS: " + path, flush=True)


if __name__ == "__main__":
    main()
