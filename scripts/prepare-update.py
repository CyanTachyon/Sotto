#!/usr/bin/env python3
"""Create and verify a signed GitHub Releases appcast; never publish or install.

The release-only Ed25519 seed stays in the builder's protected local file.
Sparkle's official sign_update signs the feed; no Keychain is consulted.
"""
import argparse
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "https://github.com/CyanTachyon/Sotto"
PRIVATE = Path.home() / "Library/Application Support/moe.tachyon.sotto.update-signing/private-key"
SIGN_UPDATE_SHA256 = "43c249771bafc3aa581228abae00731a012d324691b8292860896635050be76b"


def run(arguments):
    result = subprocess.run([str(x) for x in arguments], capture_output=True, text=True, timeout=120)
    if result.returncode:
        # Upstream malformed-key errors may print their input; never relay it.
        raise ValueError("Update preparation tool failed: " + Path(arguments[0]).name)
    return result.stdout


def build_version(value):
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Build versions must contain one to three numeric components.")
    parts = tuple(int(x) for x in value.split("."))
    return parts + (0,) * (3 - len(parts))


def verify_archive(app, archive):
    """Only the supplied, already signed app may be inside the update ZIP."""
    with zipfile.ZipFile(archive) as zipped:
        files = [i for i in zipped.infolist() if not i.is_dir()]
        names = [i.filename for i in files]
        if len(names) != len(set(names)):
            raise ValueError("Duplicate update ZIP entries.")
        expected = {}
        for path in app.rglob("*"):
            if path.is_symlink():
                expected[app.name + "/" + path.relative_to(app).as_posix()] = path.readlink().as_posix().encode()
            elif path.is_file():
                expected[app.name + "/" + path.relative_to(app).as_posix()] = path.read_bytes()
        if set(names) != set(expected):
            raise ValueError("Update archive must contain only the exact signed application.")
        for info in files:
            if zipped.read(info) != expected[info.filename]:
                raise ValueError("Update archive does not match the signed application.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sparkle-directory", type=Path, required=True)
    parser.add_argument("--previous-build", required=True)
    args = parser.parse_args()
    app, archive = args.app.resolve(strict=True), args.archive.resolve(strict=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or info["CFBundleIdentifier"] != "moe.tachyon.sotto":
        raise ValueError("Unexpected release identity or version.")
    if build_version(build) <= build_version(args.previous_build):
        raise ValueError("Release build must increase.")
    if archive.name != f"Sotto-{version}-macOS-arm64.zip":
        raise ValueError("Unexpected update archive filename.")
    if info.get("SUFeedURL") != REPOSITORY + "/releases/latest/download/appcast.xml":
        raise ValueError("Release does not use the expected GitHub feed.")
    for key in ["SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"]:
        if info.get(key) is not True:
            raise ValueError("Release does not enforce signed feed/archive verification.")
    if info.get("SUAllowsAutomaticUpdates") is not False:
        raise ValueError("Release must require interactive installation.")
    public = ROOT / "Resources/UpdatePublicKey.txt"
    if info.get("SUPublicEDKey") != public.read_text().strip():
        raise ValueError("Embedded update public key does not match this source.")
    run(["swift", ROOT / "scripts/update-signing.swift", "check", public])
    identity = json.loads(run(["python3", ROOT / "scripts/local-signing.py", "preflight"]))
    certificate = identity["certificateSHA1"]
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", certificate):
        raise ValueError("Invalid release certificate identity.")
    requirement = '=identifier "moe.tachyon.sotto" and certificate leaf = H"' + certificate + '"'
    run(["codesign", "--verify", "--deep", "--strict", "-R", requirement, app])
    compatibility = json.loads(run(["python3", ROOT / "scripts/check-compatibility.py", app]))
    if not compatibility["ok"]:
        raise ValueError("Release compatibility gate failed.")
    verify_archive(app, archive)
    tool = args.sparkle_directory.resolve(strict=True) / "bin/sign_update"
    # The framework must be the exact dependency version used for this release.
    spark_info = plistlib.loads((args.sparkle_directory / "Sparkle.framework/Resources/Info.plist").read_bytes())
    if spark_info.get("CFBundleShortVersionString") != "2.10.0":
        raise ValueError("Expected the pinned Sparkle 2.10.0 tools.")
    if hashlib.sha256(tool.read_bytes()).hexdigest() != SIGN_UPDATE_SHA256:
        raise ValueError("Official release signing tool checksum does not match.")
    signature = json.loads(run(["swift", ROOT / "scripts/update-signing.swift", "sign", public, archive]))
    run([tool, "--verify", "--ed-key-file", PRIVATE, archive, signature["edSignature"]])
    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Sotto 更新"
    ET.SubElement(channel, "link").text = REPOSITORY + "/releases"
    ET.SubElement(channel, "language").text = "zh-CN"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Sotto {version}"
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, "link").text = REPOSITORY + "/releases/tag/v" + version
    ET.SubElement(item, "{" + SPARKLE + "}version").text = build
    ET.SubElement(item, "{" + SPARKLE + "}shortVersionString").text = version
    ET.SubElement(item, "{" + SPARKLE + "}minimumSystemVersion").text = "26.0"
    ET.SubElement(item, "description", {"{" + SPARKLE + "}format": "plain-text"}).text = args.notes.read_text()
    ET.SubElement(item, "enclosure", {
        "url": REPOSITORY + f"/releases/download/v{version}/" + archive.name,
        "length": str(signature["length"]), "type": "application/octet-stream",
        "{" + SPARKLE + "}edSignature": signature["edSignature"],
    })
    args.output.mkdir(parents=True, exist_ok=True)
    feed = args.output / "appcast.xml"
    if feed.exists():
        raise ValueError("Refusing to overwrite an existing signed appcast.")
    ET.indent(rss)
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    run([tool, "--ed-key-file", PRIVATE, feed])
    run([tool, "--verify", "--ed-key-file", PRIVATE, feed])
    report = {"version": version, "build": build, "archive": archive.name,
              "archiveSHA256": hashlib.sha256(archive.read_bytes()).hexdigest(),
              "archiveBytes": signature["length"], "archiveSignature": signature["edSignature"],
              "feedSHA256": hashlib.sha256(feed.read_bytes()).hexdigest(),
              "feedSigned": True, "archiveSigned": True, "keychain": False}
    (args.output / "update-verification.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired, zipfile.BadZipFile, plistlib.InvalidFileException):
        print("Update preparation stopped: release inputs, signatures or tool checks failed.", file=sys.stderr)
        raise SystemExit(1)
