#!/usr/bin/env python3
"""Exercise the packaging script's real bundle-copy operations with stale Xcode inputs."""

import json
import plistlib
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("package_app.sh").read_text()


def shell_function(name: str) -> str:
    start = SCRIPT.index(f"function {name}() {{")
    return SCRIPT[start:SCRIPT.index("\nfunction ", start + 1)]


class ResourcePrecedenceTests(unittest.TestCase):
    def test_dashboard_catalogs_cover_account_devices_and_system_information(self):
        repository = Path(__file__).resolve().parent.parent
        card = (repository / 'Sources/SkyBridgeCompassApp/Dashboard/Sections/AppleSiliconInfoCardView.swift').read_text()
        keys = set(re.findall(r'localizedString\("([^"\n]+)"\)', card))
        keys.update(('dashboard.accountDevices', 'dashboard.accountDevices.viewAll',
                     'discovery.accountDevices.nebulaId', 'discovery.accountDevices.failure.serverRejected'))
        for locale in ('en', 'zh-Hans', 'ja'):
            path = repository / f'Sources/SkyBridgeCore/Resources/{locale}.lproj/Localizable.strings'
            catalog = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(path)]))
            with self.subTest(locale=locale):
                self.assertEqual(keys - catalog.keys(), set(), 'Dashboard must not display resource identifiers')
                self.assertTrue(all(catalog[key] and catalog[key] != key for key in keys))

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="skybridge-resource-precedence-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.primary = self.root / "current build"
        self.xcode = self.root / "old xcode build"
        self.output = self.root / "app resources"
        for path in (self.primary, self.xcode, self.output):
            path.mkdir()

    def make_bundle(self, parent: Path, current: bool) -> Path:
        bundle = parent / "SkyBridgeCompassApp_SkyBridgeCore.bundle"
        resources = bundle if current else bundle / "Contents/Resources"
        resources.mkdir(parents=True)
        info = bundle / "Info.plist" if current else bundle / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.skybridge.resource-test"}))
        language = resources / "en.lproj"
        language.mkdir()
        (language / "Localizable.strings").write_text(
            '"dashboard.accountDevices" = "Account Devices";\n' if current else '"old.key" = "Old";\n'
        )
        if not current:
            (resources / "Assets.car").write_bytes(b"compiled asset fixture")
        return resources

    def run_shell(self, body: str):
        definitions = "\n".join(shell_function(name) for name in (
            "normalize_resource_bundle_to_macos_layout", "copy_resource_bundle_into_app_resources",
            "copy_compiled_native_app_resource", "graft_xcode_app_compiled_resources_into_module_bundle",
        ))
        subprocess.run(
            ["zsh", "-eu", "-c", definitions + '\nBUILD_DIR="$1"; XCODE_BUILD_DIR="$2"; RES_DIR="$3"; XCODE_APP_BUNDLE="$4"\n' + body,
             "resource-test", str(self.primary), str(self.xcode), str(self.output), str(self.xcode / "App.app")],
            check=True, capture_output=True, text=True,
        )

    def test_current_bundle_owns_localization_and_keeps_compiled_assets(self):
        current = self.make_bundle(self.primary, True)
        stale = self.make_bundle(self.xcode, False)
        expected = (current / "en.lproj/Localizable.strings").read_bytes()
        start = SCRIPT.index('found_bundle=0\nresource_bundle_dirs=')
        end = SCRIPT.index('\nAPP_RESOURCE_BUNDLE=', start)
        self.run_shell(SCRIPT[start:end])
        output = self.output / "SkyBridgeCompassApp_SkyBridgeCore.bundle/Contents/Resources"
        self.assertEqual((output / "en.lproj/Localizable.strings").read_bytes(), expected)
        self.assertEqual((output / "Assets.car").read_bytes(), b"compiled asset fixture")
        self.assertEqual((current / "en.lproj/Localizable.strings").read_bytes(), expected)
        self.assertEqual((stale / "en.lproj/Localizable.strings").read_text(), '"old.key" = "Old";\n')

    def test_compiled_app_assets_do_not_replace_current_translations(self):
        current = self.make_bundle(self.output, True)
        native = self.xcode / "App.app/Contents/Resources"
        (native / "en.lproj").mkdir(parents=True)
        (native / "en.lproj/Localizable.strings").write_text('"old.key" = "Old";\n')
        for name in ("Assets.car", "default.metallib"):
            (native / name).write_bytes(name.encode())
        expected = (current / "en.lproj/Localizable.strings").read_bytes()
        self.run_shell('graft_xcode_app_compiled_resources_into_module_bundle "$RES_DIR/SkyBridgeCompassApp_SkyBridgeCore.bundle"')
        output = current / "Contents/Resources"
        self.assertEqual((output / "en.lproj/Localizable.strings").read_bytes(), expected)
        for name in ("Assets.car", "default.metallib"):
            self.assertEqual((output / name).read_bytes(), name.encode())

    def test_plain_swiftpm_resources_replace_native_bundle_shader_at_its_lookup_path(self):
        name = 'SkyBridgeWeatherRendering_SkyBridgeWeatherRendering.bundle'
        current = self.primary / name / 'Resources'
        current.mkdir(parents=True)
        (current / 'RainVolume.metal').write_text('current rain and foreground entry points')
        native = self.xcode / name / 'Contents/Resources'
        (native / 'Resources').mkdir(parents=True)
        (native.parent / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.skybridge.weather.resources'}))
        (native / 'Resources/RainVolume.metal').write_text('stale rain shader')
        (native / 'default.metallib').write_bytes(b'compiled native assets')
        start = SCRIPT.index('found_bundle=0\nresource_bundle_dirs=')
        end = SCRIPT.index('\nAPP_RESOURCE_BUNDLE=', start)
        self.run_shell(SCRIPT[start:end])
        output = self.output / name
        self.assertEqual((output / 'Contents/Resources/Resources/RainVolume.metal').read_bytes(),
                         (current / 'RainVolume.metal').read_bytes())
        self.assertEqual(len(list(output.rglob('RainVolume.metal'))), 1)
        self.assertEqual((output / 'Contents/Resources/default.metallib').read_bytes(), b'compiled native assets')
        self.assertEqual((native / 'Resources/RainVolume.metal').read_text(), 'stale rain shader')
        self.assertFalse((self.primary / name / 'Info.plist').exists())


if __name__ == "__main__":
    unittest.main()
