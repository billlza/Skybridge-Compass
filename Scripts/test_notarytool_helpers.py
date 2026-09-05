"""Exercise the real shell helper with a deterministic, offline notary CLI."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).with_name("notarytool_helpers.sh").resolve()
SUBMISSION_ID = "11111111-2222-4333-8444-555555555555"
OTHER_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
SHELL_DRIVER = r'''
source "$1"
skybridge_notarytool_require_args() {
  SKYBRIDGE_NOTARYTOOL_ARGS=(--keychain-profile fixture-profile)
}
skybridge_notarytool_submit_and_wait "$2" "${@:3}"
'''
FAKE_CLI = r'''
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if args == ["-f", "notarytool"]:
    print(sys.argv[0])
    raise SystemExit(0)
if len(args) < 2 or args[0] != "notarytool":
    raise SystemExit(98)
root = Path(os.environ["NOTARY_FIXTURE_ROOT"])
spec = json.loads((root / "case.json").read_text())
log = root / "calls.jsonl"
previous = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
with log.open("a") as handle:
    handle.write(json.dumps(args) + "\n")
if args[1] == "submit":
    reply = spec["submit"]
elif args[1] == "info":
    ordinal = sum(call[1] == "info" for call in previous)
    if ordinal >= len(spec["info"]):
        print("unexpected extra polling request", file=sys.stderr)
        raise SystemExit(97)
    reply = spec["info"][ordinal]
else:
    raise SystemExit(96)
if "payload" in reply:
    print(json.dumps(reply["payload"]))
else:
    print(reply.get("stdout", ""), end="")
if reply.get("stderr"):
    print(reply["stderr"], file=sys.stderr)
raise SystemExit(reply["exit"])
'''


def response(status="Accepted", *, identity=SUBMISSION_ID, exit_code=0, stderr=""):
    return {
        "exit": exit_code,
        "payload": {"id": identity, "status": status},
        "stderr": stderr,
    }


class NotaryHelperTests(unittest.TestCase):
    def run_case(self, submit, info, expected_exit, *, extra=(), app_directory=False):
        for shell in ("/bin/bash", "/bin/zsh"):
            with self.subTest(shell=shell), tempfile.TemporaryDirectory(
                prefix="skybridge-notary-test-"
            ) as directory:
                root = Path(directory)
                bin_dir = root / "bin"
                bin_dir.mkdir()
                (root / "case.json").write_text(json.dumps({"submit": submit, "info": info}))
                cli = root / "fake_notary_cli.py"
                cli.write_text(FAKE_CLI)
                shim = bin_dir / "xcrun"
                shim.write_text(
                    "#!/bin/sh\nexec " + shlex.quote(sys.executable) + " "
                    + shlex.quote(str(cli)) + ' "$@"\n'
                )
                shim.chmod(0o700)
                artifact = root / ("Candidate App.app" if app_directory else "Candidate Archive.zip")
                if app_directory:
                    artifact.mkdir()
                else:
                    artifact.write_bytes(b"offline fixture")
                environment = dict(os.environ)
                environment.update({
                    "PATH": str(bin_dir) + os.pathsep + environment["PATH"],
                    "NOTARY_FIXTURE_ROOT": str(root),
                    "SKYBRIDGE_NOTARYTOOL_ENV_LOADED": "1",
                    "SKYBRIDGE_NOTARYTOOL_POLL_SECONDS": "0",
                    "SKYBRIDGE_NOTARYTOOL_MAX_POLL_ATTEMPTS": "2",
                })
                result = subprocess.run(
                    [shell, "-euo", "pipefail", "-c", SHELL_DRIVER,
                     "notary-contract", str(HELPER), str(artifact), *extra],
                    env=environment, capture_output=True, text=True, timeout=10,
                    check=False,
                )
                self.assertEqual(
                    result.returncode, expected_exit,
                    msg=f"stdout={result.stdout}\nstderr={result.stderr}",
                )
                log = root / "calls.jsonl"
                calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
                submits = [call for call in calls if call[1] == "submit"]
                infos = [call for call in calls if call[1] == "info"]
                if extra and extra[0] in ("--no-wait", "--output-format", "--progress"):
                    self.assertEqual(calls, [])
                    continue
                self.assertEqual(len(submits), 1, "an outcome must never trigger another upload")
                self.assertEqual(len(infos), len(info))
                self.assertEqual(submits[0][2], str(artifact))
                for call in calls:
                    self.assertIn("--output-format", call)
                    self.assertEqual(call[call.index("--output-format") + 1], "json")
                    self.assertIn("--no-progress", call)
                for call in infos:
                    self.assertEqual(call[2], SUBMISSION_ID)
                self.assertEqual("--no-s3-acceleration" in submits[0], "--no-s3-acceleration" in extra)
                self.assertEqual("--force" in submits[0], app_directory)

    def test_success_requires_matching_accepted_info(self):
        self.run_case(response(), [response()], 0)

    def test_submit_error_with_identity_reconciles_without_reupload(self):
        self.run_case(
            response("In Progress", exit_code=17, stderr="HTTPClientError.deadlineExceeded"),
            [response()], 0,
        )

    def test_transport_error_without_identity_preserves_exit(self):
        self.run_case({"exit": 17, "stderr": "abortedUpload HTTPClientError.connectTimeout"}, [], 17)

    def test_non_transport_failure_without_identity_preserves_exit(self):
        self.run_case({"exit": 65, "stderr": "input rejected"}, [], 65)

    def test_zero_exit_without_identity_is_not_success(self):
        self.run_case({"exit": 0, "payload": {"status": "Accepted"}}, [], 1)

    def test_malformed_identity_is_not_queried(self):
        self.run_case(response(identity="not-a-submission"), [], 1)

    def test_identity_type_is_checked(self):
        self.run_case(response(identity=42), [], 1)

    def test_submit_non_json_success_is_rejected(self):
        self.run_case({"exit": 0, "stdout": "success without a bound identity"}, [], 1)

    def test_uppercase_uuid_is_canonicalized(self):
        uppercase = "ABCDEF12-2222-4333-8444-555555555555"
        # This case checks the parser directly; end-to-end tests use the fixed ID.
        for shell in ("/bin/bash", "/bin/zsh"):
            with self.subTest(shell=shell):
                result = subprocess.run(
                    [shell, "-euo", "pipefail", "-c",
                     'source "$1"; skybridge_notarytool_submission_id_from_output "$2"',
                     "notary-parser", str(HELPER), json.dumps({"id": uppercase})],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), uppercase.lower())

    def test_matching_identity_can_progress_then_finish(self):
        self.run_case(response("In Progress"), [response("In Progress"), response()], 0)

    def test_poll_exhaustion_is_unresolved_without_resubmit(self):
        self.run_case(
            response("In Progress", exit_code=17, stderr="abortedUpload"),
            [response("In Progress"), response("In Progress")], 1,
        )

    def test_terminal_rejection_is_not_reuploaded(self):
        for status in ("Invalid", "Rejected"):
            with self.subTest(status=status):
                self.run_case(response(exit_code=17), [response(status)], 1)

    def test_successful_submit_with_rejected_info_fails(self):
        self.run_case(response(), [response("Invalid")], 1)

    def test_info_transport_failure_preserves_actual_exit(self):
        self.run_case(response(), [{"exit": 23, "stderr": "connection lost"}], 23)

    def test_wrong_submission_info_cannot_establish_acceptance(self):
        self.run_case(response(), [response(identity=OTHER_ID)], 1)

    def test_unknown_missing_or_wrong_type_status_is_rejected(self):
        for payload in (
            {"id": SUBMISSION_ID, "status": "future-status"},
            {"id": SUBMISSION_ID},
            {"id": SUBMISSION_ID, "status": True},
        ):
            with self.subTest(payload=payload):
                self.run_case(response(), [{"exit": 0, "payload": payload}], 1)

    def test_non_json_info_is_rejected(self):
        self.run_case(response(), [{"exit": 0, "stdout": "Accepted"}], 1)

    def test_caller_cannot_bypass_wait_or_output_contract(self):
        for extra in (("--no-wait",), ("--output-format", "normal"), ("--progress",)):
            with self.subTest(extra=extra):
                self.run_case(response(), [], 1, extra=extra)

    def test_explicit_transport_option_is_used_only_once(self):
        self.run_case(response(), [response()], 0, extra=("--no-s3-acceleration",))

    def test_app_directory_retains_force_option(self):
        self.run_case(response(), [response()], 0, app_directory=True)


if __name__ == "__main__":
    unittest.main()
