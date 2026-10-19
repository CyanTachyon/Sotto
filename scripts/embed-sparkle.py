#!/usr/bin/env python3
"""Embed the pinned SPM framework, preserving links/modes and thinning every Mach-O."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

MAGICS = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
          b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def embed(artifact_root, app):
    candidates = sorted(artifact_root.glob('**/Sparkle.xcframework'))
    if len(candidates) != 1:
        raise ValueError('Expected exactly one resolved Sparkle.xcframework artifact')
    xcframework = candidates[0]
    metadata = plistlib.loads((xcframework / 'Info.plist').read_bytes())
    libraries = [item for item in metadata['AvailableLibraries']
                 if item['SupportedPlatform'] == 'macos' and 'arm64' in item['SupportedArchitectures']]
    if len(libraries) != 1:
        raise ValueError('Expected one macOS arm64 Sparkle framework slice')
    entry = libraries[0]
    source = xcframework / entry['LibraryIdentifier'] / entry['LibraryPath']
    info = plistlib.loads((source / 'Resources/Info.plist').read_bytes())
    if info.get('CFBundleShortVersionString') != '2.10.0':
        raise ValueError('Sparkle framework version must be exactly 2.10.0')
    target = app / 'Contents/Frameworks/Sparkle.framework'
    if target.exists() or target.is_symlink():
        raise ValueError('Refusing to overwrite an existing embedded Sparkle framework')
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target, symlinks=True, copy_function=shutil.copy2)
    binaries = []
    for path in sorted(target.rglob('*')):
        resolved = path.resolve(strict=True)
        if not resolved.is_relative_to(target.resolve()):
            raise ValueError('Sparkle framework contains a link outside its bundle')
        if path.is_symlink() or not path.is_file():
            continue
        with path.open('rb') as stream:
            if stream.read(4) not in MAGICS:
                continue
        architectures = subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()
        if 'arm64' not in architectures:
            raise ValueError('Embedded Sparkle Mach-O is missing arm64')
        if architectures != ['arm64']:
            with tempfile.TemporaryDirectory(dir=path.parent, prefix='.thin-') as temporary:
                output = Path(temporary) / path.name
                subprocess.run(['lipo', str(path), '-thin', 'arm64', '-output', str(output)], check=True)
                shutil.copystat(path, output)
                output.replace(path)
        binaries.append(path.relative_to(app).as_posix())
    if not binaries:
        raise ValueError('No Sparkle Mach-O binaries were embedded')
    license_path = xcframework.parent / 'LICENSE'
    if not license_path.is_file():
        raise ValueError('Pinned Sparkle artifact is missing its license')
    licenses = app / 'Contents/Resources/ThirdParty'
    licenses.mkdir(parents=True, exist_ok=True)
    shutil.copy2(license_path, licenses / 'Sparkle-LICENSE.txt')
    print('Embedded Sparkle 2.10.0 (arm64): ' + ', '.join(binaries))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact_root', type=Path)
    parser.add_argument('app', type=Path)
    arguments = parser.parse_args()
    embed(arguments.artifact_root, arguments.app)
