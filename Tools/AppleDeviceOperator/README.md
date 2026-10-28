# Apple device operator

Development CLI for physical iPhone/iPad operation from macOS. It uses Apple's
versioned `devicectl` JSON and a separately signed XCUIAutomation runner. No
Device Hub, iPhone Mirroring, simulator, reset fixture, or product replacement is
part of the workflow. The UI runner is installed by Xcode; the app being tested
is activated in place, and is not reinstalled or reset.

This is developer tooling, not the product's normal control channel. iOS may
require the device owner to authorize UI Automation with the device passcode.
Two independent sessions on the tested iPhone reused one authorization, but this
does not establish permanent authorization. Ordinary product operations should
use the app's paired, scoped native services without an XCTest runner. This tool
does not bypass system authorization or provide an unrestricted iOS shell.

Run `python3 /absolute/path/to/Tools/AppleDeviceOperator/operate.py --help` from
any working directory. Xcode is required; `build` additionally uses the existing
XcodeGen installation and a valid development signing profile. The selected
project's team is `YKUPL7Z869`; another developer must set their own team.

```sh
python3 Tools/AppleDeviceOperator/operate.py devices
python3 Tools/AppleDeviceOperator/operate.py apps --device DEVICE_ID
python3 Tools/AppleDeviceOperator/operate.py launch --device DEVICE_ID
python3 Tools/AppleDeviceOperator/operate.py screenshot --device DEVICE_ID --out /tmp/phone-new.png
python3 Tools/AppleDeviceOperator/operate.py build --device DEVICE_ID --out /tmp/apple-runner-new
python3 Tools/AppleDeviceOperator/operate.py run --device DEVICE_ID \
  --xctestrun /path/reported/by/build.xctestrun \
  --actions-file Tools/AppleDeviceOperator/examples/snapshot.json --out /tmp/apple-operation-new
```

`run` supports a bounded sequence of `snapshot`, `tap`, `type`, `swipe_up`,
`swipe_down`, `adjust_slider`, and `assert_exists`. Select exactly one accessibility `identifier`
or explicit `label`; ambiguous or non-hittable targets fail. Snapshot first to
obtain identifiers from the actual installed app. A tap proves input injection;
follow it with an appropriate state assertion. File delivery requires the
product's transfer receipt, not the presence of a file-screen element.

If a snapshot contains a button and its text with the same label, specify
`"element_type": "button"` along with the label or identifier. Supported types
are `button`, `static_text`, `text_field`, `secure_text_field`, `search_field`, `text_view`,
`scroll_view`, `switch`, `slider`, and `other`. This narrows the query; multiple matches within that
type still fail. A type alone is never a selector. Rebuild the runner after
changing its supported request schema, and retain the original failure evidence.
For a switch exposed as a labeled container, the operator taps its sole direct
switch child; multiple child controls still fail. Always read back its value,
because an injected tap alone does not prove a setting changed.

`adjust_slider` requires `element_type: "slider"` and a finite `normalized_position`
from 0 to 1. Apple's adjustment is best effort; verify the resulting state.
An `elements` snapshot includes `normalized_slider_position` for sliders, so the
original position can be recorded before a reversible settings test and restored.
The system text-size slider has no identifier or label. For this observed case,
an explicit empty `label` is accepted only by `adjust_slider` with type `slider`;
the runtime still requires exactly one matching slider, and fails on ambiguity.

Use `within_identifier` to restrict a selector to descendants of exactly one
identified container, such as the system file picker's navigation bar. Use
`child_identifier` to require an identified direct child, such as a nested
tab-button wrapper observed in the hierarchy. The child constraint examines at
most 64 matching roots and refuses a broader query. Both constraints are
explicit and optional; the final target must still be unique.
They do not pick an arbitrary match or replace the target's identifier/label.
The earlier experimental `containing_identifier` field is rejected: XCTest's
containing query did not distinguish the nested wrapper in the retained iPad
failure. Rebuild the runner to use the corrected direct-child contract.

For large screens, include `{"action": "snapshot_tree"}` to return XCTest's
hierarchy text in `tree`, with `snapshot_format: "tree"`, instead of querying
each property of up to 512 individual elements. The text keeps at most the first
1 MiB of UTF-8 bytes; `tree_truncated` reports any truncation. Do not infer state
outside the captured tree. The default `elements` format is unchanged. A capture
deadline remains a failed operation, even when a preceding tap visibly occurred;
inspect the state before starting another write, and never replay automatically.

The operation writes a new xctestrun while retaining the original signed runner
and all existing environment entries. It never overwrites an evidence directory.
Success requires both successful Xcode execution and a matching structured test
attachment. Logs and `.xcresult` remain available on failure. A process deadline
terminates the owned host process group, but does not claim a remote operation
was rolled back. Do not automatically replay a write after an unknown outcome.

USB and network are distinct validation surfaces. Device discovery and process
launch are not proof that the XCTest control channel or UI automation mode is
available. Keep the physical device unlocked during UI testing and retain
bootstrap/automation-mode failures independently from functional test failures.

Run helper contract tests with:
`python3 -m unittest discover -s Tools/AppleDeviceOperator -p 'test_*.py'`.
These tests do not establish physical-device acceptance.

## Native application methods through Xcode LLDB

The Sept 26 physical probe invoked the existing public iPhone suite preference
service without XCTest. Use `xcrun lldb --no-lldbinit` with the exact CoreDevice
ID and a freshly resolved app PID. The selected device/process must match the
installed bundle, and the remote Mach-O UUID must match the signed local candidate
before evaluating any app method. Configure `target.swift-module-search-paths`
with that candidate's matching `Release-iphoneos` module directory; import
`SkyBridgeCompass_iOS`. A verified main-actor getter and the normal asynchronous
`PQCCryptoManager.instance.applyProviderPreference` method worked on build 14.
The async request was only reported complete after independently reading its
operation-bound result from the app container. Each probe detached and resumed
the process before proceeding.

The retained probe scripts and results live under
`Artifacts/cli-040-usb-recovery-20260926/`, notably
`lldb-apply-qperiapt-r1.swift`, `lldb-apply-qperiapt-r1-dispatch.json` and
`iphone-qperiapt-apply-r1-result.json`. They are isolated diagnostic recipes, not
a new generic execution command. Never replay a mutation script with an old PID
or reuse its operation/result filename. Device-selection commands invoked inside
the embedded Python command interpreter failed before attachment; the tested path
used the regular interactive LLDB command loop for selection and attachment.

This requires a development-signed, debuggable app and matching compiler modules.
Release optimization removed an internal approval singleton's addressor, so this
does not demonstrate arbitrary UI/button or internal-service control. The product
USB/PQC and file protocol itself does not depend on LLDB. See the official
[LLDB Python API](https://lldb.llvm.org/python_api.html) for debugger operations;
the repository's current evidence, not API availability, determines tested scope.
