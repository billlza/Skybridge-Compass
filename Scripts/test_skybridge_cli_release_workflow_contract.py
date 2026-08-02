#!/usr/bin/env python3

from __future__ import annotations

import pathlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
WORKFLOW = ROOT / ".github/workflows/skybridge-cli-release.yml"
PACKAGING_WORKFLOW = ROOT / ".github/workflows/skybridge-cli-packaging.yml"
GITHUB_PUBLISHER = ROOT / "rust/scripts/publish_cli_github_release.sh"
NPM_PUBLISHER = ROOT / "rust/scripts/publish_cli_npm.py"
HOMEBREW_PUBLISHER = ROOT / "rust/scripts/publish_homebrew_formula.sh"
FINALIZER = ROOT / "rust/scripts/finalize_cli_release_assets.py"
HANDOFF = ROOT / "rust/scripts/cli_release_handoff.py"
CODEOWNERS = ROOT / ".github/CODEOWNERS"
FFI_BUILD_SCRIPT = ROOT / "rust/crates/skybridge-ffi/build.rs"


def job_block(workflow: str, name: str) -> str:
    start_marker = f"  {name}:\n"
    start = workflow.index(start_marker)
    next_job = re.search(r"^  [a-z][a-z0-9-]+:\n", workflow[start + len(start_marker) :], re.MULTILINE)
    if next_job is None:
        return workflow[start:]
    return workflow[start : start + len(start_marker) + next_job.start()]


class SkyBridgeCLIReleaseWorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")
        cls.github_publisher = GITHUB_PUBLISHER.read_text(encoding="utf-8")
        cls.npm_publisher = NPM_PUBLISHER.read_text(encoding="utf-8")
        cls.homebrew_publisher = HOMEBREW_PUBLISHER.read_text(encoding="utf-8")

    def test_actions_are_current_full_sha_pins_and_checkout_never_persists_credentials(self) -> None:
        action_uses = re.findall(r"^\s+(?:- )?uses: ([^@\s]+)@([^\s]+)", self.workflow, re.MULTILINE)
        self.assertGreaterEqual(len(action_uses), 20)
        for action, reference in action_uses:
            with self.subTest(action=action):
                self.assertRegex(reference, r"^[0-9a-f]{40}$")
        expected = {
            ("actions/checkout", "3d3c42e5aac5ba805825da76410c181273ba90b1"),
            ("actions/setup-python", "5fda3b95a4ea91299a34e894583c3862153e4b97"),
            ("actions/setup-node", "820762786026740c76f36085b0efc47a31fe5020"),
            ("actions/upload-artifact", "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"),
            ("actions/download-artifact", "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"),
            ("actions/create-github-app-token", "bcd2ba49218906704ab6c1aa796996da409d3eb1"),
        }
        self.assertTrue(expected.issubset(set(action_uses)))
        self.assertEqual(
            self.workflow.count("uses: actions/checkout@"),
            self.workflow.count("persist-credentials: false"),
        )

    def test_permissions_and_protected_environments_are_separate(self) -> None:
        metadata = job_block(self.workflow, "metadata")
        build = job_block(self.workflow, "build")
        assemble = job_block(self.workflow, "assemble")
        github = job_block(self.workflow, "publish-github")
        npm = job_block(self.workflow, "publish-npm")
        homebrew = job_block(self.workflow, "publish-homebrew")
        self.assertIn("permissions:\n  contents: read", self.workflow)
        self.assertEqual(
            len(re.findall(r"^\s+contents: write$", self.workflow, re.MULTILINE)),
            1,
        )
        self.assertIn("contents: write", github)
        self.assertNotIn("id-token: write", github)
        self.assertNotRegex(
            metadata + build + assemble + npm + homebrew,
            r"(?m)^\s+contents: write$",
        )
        self.assertEqual(self.workflow.count("id-token: write"), 1)
        self.assertIn("id-token: write", npm)
        self.assertIn("name: skybridge-cli-github-release", github)
        self.assertIn("name: skybridge-cli-npm-release", npm)
        self.assertIn("name: skybridge-cli-homebrew-release", homebrew)
        self.assertIn("actions/create-github-app-token@", homebrew)
        self.assertNotIn("HOMEBREW_TAP_GITHUB_TOKEN: ${{ secrets.", homebrew)
        self.assertIn("TAP_BRANCH: ${{ vars.HOMEBREW_TAP_BRANCH }}", homebrew)
        self.assertIn('[[ "${TAP_BRANCH}" == "main" ]]', homebrew)
        self.assertIn('--tap-repo "${TAP_OWNER}/${TAP_REPOSITORY}"', homebrew)
        self.assertIn('--formula-path "${TAP_FORMULA_PATH}"', homebrew)
        self.assertNotIn('--branch "${{ vars.', homebrew)

    def test_source_and_handoff_identity_are_fail_closed(self) -> None:
        for required in (
            "REF_PROTECTED: ${{ github.ref_protected }}",
            '[[ "${REF_PROTECTED}" == "true" ]]',
            "git merge-base --is-ancestor",
            "--expect-tag \"${GITHUB_REF_NAME}\"",
            "artifact-ids: ${{ needs.assemble.outputs.artifact_id }}",
            "digest-mismatch: error",
            "producer_run_id: ${{ steps.producer.outputs.run_id }}",
            "producer_run_attempt: ${{ steps.producer.outputs.run_attempt }}",
            "producer_workflow_ref: ${{ steps.producer.outputs.workflow_ref }}",
            "producer_workflow_sha: ${{ steps.producer.outputs.workflow_sha }}",
            "--workflow-run-id \"${{ needs.assemble.outputs.producer_run_id }}\"",
            "--workflow-run-attempt \"${{ needs.assemble.outputs.producer_run_attempt }}\"",
            "--workflow-ref \"${{ needs.assemble.outputs.producer_workflow_ref }}\"",
            "--workflow-sha \"${{ needs.assemble.outputs.producer_workflow_sha }}\"",
            "--handoff-artifact-id \"${{ needs.assemble.outputs.artifact_id }}\"",
            "--handoff-artifact-digest \"${{ needs.assemble.outputs.artifact_digest }}\"",
        ):
            self.assertIn(required, self.workflow)
        self.assertGreaterEqual(self.workflow.count("digest-mismatch: error"), 7)
        finalizer = FINALIZER.read_text(encoding="utf-8")
        handoff = HANDOFF.read_text(encoding="utf-8")
        self.assertNotIn('"workflow_run_id"', finalizer)
        self.assertNotIn('"workflow_run_attempt"', finalizer)
        self.assertIn('"producer_workflow_run_id"', handoff)
        self.assertIn('"producer_workflow_run_attempt"', handoff)
        self.assertIn('"producer_workflow_ref"', handoff)
        self.assertIn('"producer_workflow_sha"', handoff)

    def test_channel_order_and_recovery_contract_are_explicit(self) -> None:
        github = job_block(self.workflow, "publish-github")
        npm = job_block(self.workflow, "publish-npm")
        homebrew = job_block(self.workflow, "publish-homebrew")
        validate_homebrew = job_block(self.workflow, "validate-homebrew")
        self.assertIn("- publish-github", npm)
        self.assertIn("- publish-npm", validate_homebrew)
        self.assertIn("- validate-homebrew", homebrew)
        self.assertLess(self.workflow.index("  publish-github:"), self.workflow.index("  publish-npm:"))
        self.assertLess(self.workflow.index("  publish-npm:"), self.workflow.index("  validate-homebrew:"))
        self.assertLess(self.workflow.index("  validate-homebrew:"), self.workflow.index("  publish-homebrew:"))
        self.assertLess(self.workflow.index("  publish-npm:"), self.workflow.index("  publish-homebrew:"))
        self.assertNotIn("environment:", validate_homebrew)
        self.assertNotIn("create-github-app-token", validate_homebrew)
        self.assertIn("brew audit --strict --online", validate_homebrew)
        self.assertIn("brew install --formula", validate_homebrew)
        self.assertIn("brew test skybridge", validate_homebrew)
        self.assertIn("--draft", self.github_publisher)
        self.assertIn("--draft=false", self.github_publisher)
        self.assertIn("isImmutable", self.github_publisher)
        self.assertIn("gh release verify-asset", self.github_publisher)
        self.assertNotIn("--clobber", self.github_publisher)
        self.assertIn("already-published-exact", self.npm_publisher)
        self.assertIn("published-concurrently-exact", self.npm_publisher)
        self.assertIn("refusing to downgrade", self.homebrew_publisher)
        self.assertIn("same-version Homebrew formula bytes differ", self.homebrew_publisher)

    def test_publication_is_blocked_until_platform_signatures_are_verified(self) -> None:
        metadata = job_block(self.workflow, "metadata")
        signing_gate = job_block(self.workflow, "public-release-signing-gate")

        self.assertIn("publication_blocked:", metadata)
        self.assertIn("PUBLICATION_BLOCKED=true", metadata)
        self.assertNotIn("PUBLISH_REQUESTED=true", metadata)
        self.assertIn("- assemble", signing_gate)
        self.assertIn("macOS signing/notarization", signing_gate)
        self.assertIn("Windows publisher-signature proofs", signing_gate)
        self.assertIn("exit 1", signing_gate)

    def test_exact_assets_and_lifecycle_boundaries_are_enforced(self) -> None:
        exact_assets = (
            "skybridge-aarch64-apple-darwin.tar.gz",
            "skybridge-aarch64-unknown-linux-gnu.tar.gz",
            "skybridge-x86_64-unknown-linux-gnu.tar.gz",
            "skybridge-x86_64-pc-windows-msvc.zip",
            "skybridge.rb",
            "release-manifest.json",
            "SHA256SUMS.txt",
        )
        for asset in exact_assets:
            self.assertIn(asset, self.github_publisher)
        self.assertIn('"skybridge-cli-${VERSION}.tgz"', self.github_publisher)
        self.assertIn('"--ignore-scripts"', self.npm_publisher)
        self.assertIn('"--provenance"', self.npm_publisher)
        self.assertIn("--ignore-scripts", self.workflow)
        forbidden = (
            "softprops/action-gh-release",
            "dtolnay/rust-toolchain",
            "release-assets/*",
            "merge-multiple: true",
            "NPM_TOKEN is not configured",
            "skipping npm publish",
            "skipping tap publish",
        )
        for value in forbidden:
            self.assertNotIn(value, self.workflow)

    def test_pinned_toolchain_installs_binary_inspection_tools(self) -> None:
        toolchain = (ROOT / "rust-toolchain.toml").read_text(encoding="utf-8")
        packaging_workflow = (ROOT / ".github/workflows/skybridge-cli-packaging.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('components = ["clippy", "llvm-tools-preview", "rustfmt"]', toolchain)
        self.assertIn("--component llvm-tools-preview", packaging_workflow)

    def test_release_and_packaging_verify_the_complete_rust_workspace(self) -> None:
        packaging_workflow = PACKAGING_WORKFLOW.read_text(encoding="utf-8")
        release_verify = job_block(self.workflow, "verify")
        for workflow in (release_verify, packaging_workflow):
            self.assertIn("cargo install cargo-audit --locked --version 0.22.2", workflow)
            self.assertIn("cargo audit --deny warnings --file rust/Cargo.lock", workflow)
            self.assertIn("cargo fmt --manifest-path rust/Cargo.toml --all --check", workflow)
            self.assertIn(
                "cargo test --locked --manifest-path rust/Cargo.toml --workspace --all-targets",
                workflow,
            )
            self.assertIn(
                "cargo clippy --locked --manifest-path rust/Cargo.toml --workspace --all-targets -- -D warnings",
                workflow,
            )
            self.assertIn("--component clippy", workflow)
            self.assertIn(
                "node --test rust/packaging/npm/skybridge-cli/test/install.test.js", workflow
            )
            self.assertIn("rust/scripts/test_verify_cli_release_proof.py", workflow)
            self.assertIn("shellcheck", workflow)
        self.assertIn("workflow_dispatch:", packaging_workflow)
        pull_request_block = packaging_workflow.split("  pull_request:\n", 1)[1].split(
            "  push:\n", 1
        )[0]
        self.assertNotIn("paths:", pull_request_block)
        build = job_block(self.workflow, "build")
        self.assertIn("- verify", build)

    def test_external_cargo_path_dependency_is_pinned_and_prepared_on_every_rust_job(self) -> None:
        packaging_workflow = PACKAGING_WORKFLOW.read_text(encoding="utf-8")
        release_verify = job_block(self.workflow, "verify")
        release_build = job_block(self.workflow, "build")
        required_checkout = (
            "repository: billlza/q-periapt",
            "ref: 5664fd86a617f92b620ea37e7692d3417d0e307d",
            "path: External/pqt_hybrid_suite",
            "crates/q-periapt-backends/Cargo.toml",
        )
        for workflow in (packaging_workflow, release_verify, release_build):
            for value in required_checkout:
                self.assertIn(value, workflow)

        core_manifest = (ROOT / "rust/crates/skybridge-core/Cargo.toml").read_text(
            encoding="utf-8"
        )
        self.assertEqual(core_manifest.count('path = "../../../External/pqt_hybrid_suite/'), 3)
        self.assertNotIn("../../../../pqt_hybrid_suite", core_manifest)
        self.assertIn("name: Test the platform runtime", release_build)
        for package in (
            "-p skybridge-core",
            "-p skybridge-agent",
            "-p skybridge-crossnet-client",
            "-p skybridge-ffi",
            "-p skybridge",
        ):
            self.assertIn(package, release_build)
        self.assertIn('--target "${TARGET}"', release_build)

    def test_ffi_header_generation_is_cross_target_and_fail_closed(self) -> None:
        build_script = FFI_BUILD_SCRIPT.read_text(encoding="utf-8")
        release_build = job_block(self.workflow, "build")

        self.assertIn(".with_src(&c_abi_source)", build_script)
        self.assertNotIn(".with_crate(&crate_dir)", build_script)
        self.assertNotIn("ParseSyntaxError", build_script)
        self.assertIn("-p skybridge-ffi", release_build)

    def test_release_control_surfaces_have_explicit_owners(self) -> None:
        codeowners = CODEOWNERS.read_text(encoding="utf-8")
        for required in (
            "/.github/workflows/ @billlza",
            "/rust-toolchain.toml @billlza",
            "/rust/scripts/ @billlza",
            "/rust/packaging/ @billlza",
            "/Sources/Vendor/ @billlza",
            "/VendorProvenance/ @billlza",
        ):
            self.assertIn(required, codeowners)


if __name__ == "__main__":
    unittest.main()
