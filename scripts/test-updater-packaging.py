#!/usr/bin/env python3
"""Synthetic packaging checks; never launch Sotto or access signing credentials."""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


def module(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), Path(__file__).with_name(name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


compat = module('check-compatibility')
signing = module('local-signing')
embed = module('embed-sparkle')


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='sotto-packaging-test-')
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / 'Fixture.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/Frameworks').mkdir()
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Fixture'}))
        self.source = self.root / 'fixture.c'
        self.source.write_text('int fixture(void) { return 1; }\n')
        self.library = self.app / 'Contents/Frameworks/libfixture.dylib'
        self.compile_library(self.library)
        main_source = self.root / 'main.c'
        main_source.write_text('extern int fixture(void); int main(void) { return fixture(); }\n')
        self.binary = self.app / 'Contents/MacOS/Fixture'
        subprocess.run(['xcrun', 'clang', '-target', 'arm64-apple-macos26.0', str(main_source), str(self.library),
                        '-Wl,-rpath,@executable_path/../Frameworks', '-o', str(self.binary)], check=True, capture_output=True)

    def tearDown(self):
        self.temporary.cleanup()

    def compile_library(self, path, minimum='26.0', architecture='arm64'):
        subprocess.run(['xcrun', 'clang', '-target', architecture + '-apple-macos' + minimum,
                        '-dynamiclib', str(self.source), '-Wl,-install_name,@rpath/libfixture.dylib',
                        '-o', str(path)], check=True, capture_output=True)

    def change(self, dependency):
        subprocess.run(['install_name_tool', '-change', '@rpath/libfixture.dylib', dependency, str(self.binary)], check=True, capture_output=True)

    def reject(self, code):
        with self.assertRaises(compat.CompatibilityError) as caught:
            compat.verify_binary(self.binary, self.app)
        self.assertEqual(caught.exception.detail['code'], code)

    def test_bundle_rpath(self):
        result = compat.verify_binary(self.binary, self.app)
        self.assertEqual(result['packagedDependencies'], ['Contents/Frameworks/libfixture.dylib'])

    def test_executable_path(self):
        self.change('@executable_path/../Frameworks/libfixture.dylib')
        compat.verify_binary(self.binary, self.app)

    def test_loader_path(self):
        self.change('@loader_path/../Frameworks/libfixture.dylib')
        compat.verify_binary(self.binary, self.app)

    def test_missing_rpath_target(self):
        self.library.unlink()
        self.reject('dependency_missing')

    def test_dependency_escape(self):
        self.change('@executable_path/../../../external.dylib')
        self.reject('outside_bundle')

    def test_symlink_escape(self):
        external = self.root / 'external.dylib'
        self.library.rename(external)
        self.library.symlink_to(external)
        self.reject('outside_bundle')

    def test_external_runpath(self):
        subprocess.run(['install_name_tool', '-add_rpath', '/tmp/unsafe', str(self.binary)], check=True, capture_output=True)
        self.reject('external_dependency')

    def test_minimum_and_architecture(self):
        self.compile_library(self.library, minimum='27.0')
        with self.assertRaises(compat.CompatibilityError) as caught:
            compat.verify_binary(self.library, self.app)
        self.assertEqual(caught.exception.detail['code'], 'minimum_too_new')
        self.compile_library(self.library, architecture='x86_64')
        with self.assertRaises(compat.CompatibilityError) as caught:
            compat.verify_binary(self.library, self.app)
        self.assertEqual(caught.exception.detail['code'], 'wrong_architecture')

    def test_nested_signing_order_and_vendor_ids(self):
        framework = self.app / 'Contents/Frameworks/Sparkle.framework'
        version = framework / 'Versions/B'
        (version / 'Resources').mkdir(parents=True)
        (version / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.sparkle-project.Sparkle', 'CFBundleExecutable': 'Sparkle'}))
        (version / 'Sparkle').write_bytes(b'\xcf\xfa\xed\xfe')
        (framework / 'Resources').symlink_to('Versions/B/Resources')
        (framework / 'Sparkle').symlink_to('Versions/B/Sparkle')
        helper = version / 'Autoupdate'
        helper.write_bytes(b'\xcf\xfa\xed\xfe')
        installer = version / 'Updater.app'
        (installer / 'Contents/MacOS').mkdir(parents=True)
        (installer / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.sparkle-project.Sparkle.Updater', 'CFBundleExecutable': 'Updater'}))
        (installer / 'Contents/MacOS/Updater').write_bytes(b'\xcf\xfa\xed\xfe')
        self.library.unlink()  # Different library location belongs to the fixture, not Sotto's legacy libraries.
        with patch.object(signing, 'run', return_value=subprocess.CompletedProcess([], 0, b'', b'Identifier=org.sparkle-project.Sparkle.Autoupdate\n')):
            targets = signing.signing_targets(self.app)
        paths = [target for target, _ in targets]
        self.assertLess(paths.index(helper), paths.index(framework))
        self.assertLess(paths.index(installer), paths.index(framework))
        self.assertEqual(dict(targets)[helper], 'org.sparkle-project.Sparkle.Autoupdate')
        self.assertEqual(dict(targets)[installer], 'org.sparkle-project.Sparkle.Updater')
        self.assertNotIn(version / 'Sparkle', paths)
        self.assertNotIn(installer / 'Contents/MacOS/Updater', paths)

    def artifact(self, version='2.10.0'):
        artifact = self.root / 'artifacts/Sparkle.xcframework'
        source = artifact / 'macos-arm64_x86_64/Sparkle.framework'
        binary_root = source / 'Versions/B'
        (binary_root / 'Resources').mkdir(parents=True)
        (artifact.parent / 'LICENSE').write_text('Synthetic Sparkle license fixture\n')
        (artifact / 'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': [{
            'SupportedPlatform': 'macos', 'SupportedArchitectures': ['arm64', 'x86_64'],
            'LibraryIdentifier': 'macos-arm64_x86_64', 'LibraryPath': 'Sparkle.framework'}]}))
        (binary_root / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': version}))
        alternate = self.root / 'intel.dylib'
        self.compile_library(alternate, architecture='x86_64')
        subprocess.run(['lipo', '-create', str(self.library), str(alternate), '-output', str(binary_root / 'Sparkle')], check=True, capture_output=True)
        (binary_root / 'Sparkle').chmod(0o755)
        (source / 'Sparkle').symlink_to('Versions/B/Sparkle')
        (source / 'Resources').symlink_to('Versions/B/Resources')
        return artifact, source

    def test_embed_preserves_links_and_permissions_and_thins(self):
        artifact, _ = self.artifact()
        embed.embed(artifact.parent, self.app)
        framework = self.app / 'Contents/Frameworks/Sparkle.framework'
        self.assertTrue((framework / 'Sparkle').is_symlink())
        self.assertEqual((self.app / 'Contents/Resources/ThirdParty/Sparkle-LICENSE.txt').read_text(), 'Synthetic Sparkle license fixture\n')
        self.assertEqual((framework / 'Sparkle').stat().st_mode & 0o777, 0o755)
        architectures = subprocess.check_output(['lipo', '-archs', str(framework / 'Sparkle')], text=True).strip()
        self.assertEqual(architectures, 'arm64')

    def test_embed_rejects_wrong_version(self):
        artifact, _ = self.artifact(version='2.9.0')
        with self.assertRaisesRegex(ValueError, 'exactly 2.10.0'):
            embed.embed(artifact.parent, self.app)

    def test_embed_rejects_symlink_escape(self):
        artifact, framework = self.artifact()
        (framework / 'external').symlink_to(self.source)
        with self.assertRaisesRegex(ValueError, 'outside its bundle'):
            embed.embed(artifact.parent, self.app)


if __name__ == '__main__':
    unittest.main()
