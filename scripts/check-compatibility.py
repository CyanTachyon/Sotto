#!/usr/bin/env python3
"""Fail closed on Sotto's macOS 26 / arm64 package compatibility requirements.

Only reads bundle metadata and Mach-O load commands; never launches the app.
All diagnostic paths are relative to the inspected bundle (or self-test folder).
"""
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


TARGET = "26.0"
MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
}
DEPENDENCY_COMMANDS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
    "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB",
}


class CompatibilityError(Exception):
    def __init__(self, code, message, path=None):
        self.detail = {"code": code, "message": message}
        if path is not None:
            self.detail["path"] = path
        super().__init__(message)


def relative(path, root):
    try:
        return path.relative_to(root).as_posix()
    except ValueError:
        return "."


def inside(path, root):
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except (OSError, ValueError, RuntimeError):
        return False


def command(arguments, path=None):
    tool = arguments[0]
    if shutil.which(tool) is None:
        raise CompatibilityError("tool_missing", "Required tool is unavailable: " + tool, path)
    try:
        result = subprocess.run(arguments, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise CompatibilityError("tool_timeout", "Compatibility inspection timed out: " + tool, path)
    except (OSError, UnicodeError):
        raise CompatibilityError("tool_failed", "Could not run compatibility inspection: " + tool, path)
    if result.returncode:
        # Tool stderr can contain private build or temporary paths. Do not emit it.
        raise CompatibilityError("tool_failed", "Compatibility inspection failed: " + tool, path)
    return result.stdout


def version(value, path):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise CompatibilityError("invalid_minos", "Could not parse minimum macOS version.", path)
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def load_commands(output):
    commands = []
    for block in re.split(r"(?m)^Load command \d+\s*$", output)[1:]:
        name = re.search(r"(?m)^\s*cmd\s+(LC_\S+)\s*$", block)
        if name:
            commands.append((name.group(1), block))
    return commands


def minimum_versions(commands, path):
    values = []
    for name, block in commands:
        if name == "LC_BUILD_VERSION":
            platform = re.search(r"(?m)^\s*platform\s+(\S+)\s*$", block)
            minimum = re.search(r"(?m)^\s*minos\s+(\S+)\s*$", block)
            if not platform or platform.group(1).upper() not in {"1", "MACOS"}:
                raise CompatibilityError("wrong_platform", "Mach-O must target macOS.", path)
        elif name == "LC_VERSION_MIN_MACOSX":
            minimum = re.search(r"(?m)^\s*version\s+(\S+)\s*$", block)
        else:
            continue
        if not minimum:
            raise CompatibilityError("minos_missing", "Mach-O minimum macOS version is missing.", path)
        values.append(minimum.group(1))
    if not values:
        raise CompatibilityError("minos_missing", "Mach-O minimum macOS version is missing.", path)
    return values


def is_macho(path):
    with path.open("rb") as source:
        return source.read(4) in MACHO_MAGICS


def verify_binary(path, bundle_root):
    """Inspect one binary without executing it; also used by --self-test."""
    label = relative(path, bundle_root)
    if not inside(path, bundle_root):
        raise CompatibilityError("outside_bundle", "Binary resolves outside the bundle.", label)
    if not path.is_file():
        raise CompatibilityError("file_missing", "Required binary is missing.", label)
    try:
        if not is_macho(path):
            raise CompatibilityError("not_macho", "Required binary is not Mach-O.", label)
    except OSError:
        raise CompatibilityError("file_unreadable", "Could not read required binary.", label)
    architectures = command(["lipo", "-archs", str(path)], label).split()
    if architectures != ["arm64"]:
        raise CompatibilityError("wrong_architecture", "Mach-O must contain only arm64.", label)
    output = command(["otool", "-l", str(path)], label)
    commands = load_commands(output)
    if not commands:
        raise CompatibilityError("load_commands_missing", "Could not parse Mach-O load commands.", label)
    minimums = minimum_versions(commands, label)
    if any(version(value, label) > version(TARGET, label) for value in minimums):
        raise CompatibilityError("minimum_too_new", "Mach-O requires macOS newer than " + TARGET + ".", label)
    packaged_dependencies = []
    system_dependencies = 0
    for name, block in commands:
        # LC_ID_DYLIB describes this library itself; it is not a dependency.
        if name not in DEPENDENCY_COMMANDS:
            continue
        dependency = re.search(r"(?m)^\s*name (.+) \(offset \d+\)\s*$", block)
        if not dependency:
            raise CompatibilityError("dependency_unreadable", "Could not parse a library dependency.", label)
        dependency = dependency.group(1)
        if dependency.startswith(("/usr/lib/", "/System/Library/")):
            # These can live in the dyld shared cache, without individual files.
            if ".." in Path(dependency).parts:
                raise CompatibilityError("external_dependency", "Library dependency escapes its system location.", label)
            system_dependencies += 1
        elif dependency.startswith("@loader_path/"):
            resolved = path.parent / dependency[len("@loader_path/"):]
            if not inside(resolved, bundle_root):
                raise CompatibilityError("outside_bundle", "Library dependency resolves outside the bundle.", label)
            if not resolved.is_file():
                raise CompatibilityError("dependency_missing", "Packaged library dependency is missing.", label)
            try:
                if not is_macho(resolved):
                    raise CompatibilityError("dependency_not_macho", "Packaged library dependency is not Mach-O.", label)
            except OSError:
                raise CompatibilityError("file_unreadable", "Could not read packaged library dependency.", label)
            packaged_dependencies.append(relative(resolved.resolve(), bundle_root))
        else:
            raise CompatibilityError("external_dependency", "Library dependency must use a system location or packaged @loader_path.", label)
    return {"path": label, "architectures": architectures, "minimumMacOS": max(minimums, key=lambda value: version(value, label)),
            "systemDependencyCount": system_dependencies, "packagedDependencies": sorted(set(packaged_dependencies))}


def verify_app(bundle):
    root = bundle.resolve()
    if not root.is_dir():
        raise CompatibilityError("bundle_missing", "App bundle is missing.", ".")
    info_path = root / "Contents/Info.plist"
    if not inside(info_path, root):
        raise CompatibilityError("outside_bundle", "Info.plist resolves outside the bundle.", "Contents/Info.plist")
    try:
        with info_path.open("rb") as source:
            info = plistlib.load(source)
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise CompatibilityError("plist_unreadable", "Info.plist is missing or invalid.", "Contents/Info.plist")
    if not isinstance(info, dict) or info.get("LSMinimumSystemVersion") != TARGET:
        raise CompatibilityError("plist_minimum_mismatch", "LSMinimumSystemVersion must be exactly " + TARGET + ".", "Contents/Info.plist")
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or executable in {".", ".."} or "/" in executable:
        raise CompatibilityError("executable_invalid", "CFBundleExecutable must name a bundle executable.", "Contents/Info.plist")
    binaries = {root / "Contents/MacOS" / executable}
    frameworks = root / "Contents/Resources/Frameworks"
    if not frameworks.is_dir() or not inside(frameworks, root):
        raise CompatibilityError("frameworks_missing", "Packaged Frameworks directory is missing or outside the bundle.", "Contents/Resources/Frameworks")
    binaries.update(frameworks.glob("*.dylib"))
    # Catch additional Mach-O helpers/libraries anywhere in the app as well.
    for path in sorted(root.rglob("*")):
        if not inside(path, root):
            raise CompatibilityError("outside_bundle", "Bundle entry resolves outside the bundle.", relative(path, root))
        if path.is_file():
            try:
                if is_macho(path):
                    binaries.add(path)
            except OSError:
                raise CompatibilityError("file_unreadable", "Could not inspect bundle file.", relative(path, root))
    checks, errors = [], []
    for path in sorted(binaries):
        try:
            checks.append(verify_binary(path, root))
        except CompatibilityError as error:
            errors.append(error.detail)
    return {"ok": not errors, "targetMacOS": TARGET, "requiredArchitecture": "arm64", "binaries": checks, "errors": errors}


def self_test():
    checks = []
    with tempfile.TemporaryDirectory(prefix="sotto-compatibility-") as folder:
        root = Path(folder).resolve()
        source = root / "tiny.c"
        source.write_text("int sotto_compatibility_fixture(void) { return 1; }\n")
        for minimum in ("26.0", "27.0"):
            path = root / ("libminimum" + minimum.split(".")[0] + ".dylib")
            command(["xcrun", "clang", "-target", "arm64-apple-macos" + minimum,
                     "-dynamiclib", str(source), "-Wl,-install_name,@loader_path/" + path.name,
                     "-o", str(path)], path.name)
            try:
                result = verify_binary(path, root)
                observed = "accepted"
                error_code = None
            except CompatibilityError as error:
                observed = "rejected"
                error_code = error.detail["code"]
                result = None
            expected = "accepted" if minimum == TARGET else "rejected"
            passed = observed == expected and (minimum == TARGET or error_code == "minimum_too_new")
            check = {"name": "minimum_macOS_" + minimum, "passed": passed, "expected": expected, "observed": observed}
            if error_code:
                check["errorCode"] = error_code
            if result:
                check["binary"] = result
            checks.append(check)
    return {"ok": all(check["passed"] for check in checks), "targetMacOS": TARGET, "selfTest": checks}


def main():
    try:
        if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
            report = self_test()
        elif len(sys.argv) == 2 and not sys.argv[1].startswith("--"):
            report = verify_app(Path(sys.argv[1]))
        else:
            raise CompatibilityError("usage", "Usage: python3 scripts/check-compatibility.py <Sotto.app> | --self-test")
    except CompatibilityError as error:
        report = {"ok": False, "targetMacOS": TARGET, "errors": [error.detail]}
    except Exception:
        # Malformed plist/parser errors must also stay JSON-only and path-safe.
        report = {"ok": False, "targetMacOS": TARGET, "errors": [{"code": "inspection_failed", "message": "Could not inspect bundle or create synthetic fixtures."}]}
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
