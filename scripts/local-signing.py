#!/usr/bin/env python3
"""Persistent, local-only release signing. Never reads the app's runtime secrets.

setup is explicit and one-time; ordinary builds never replace a missing identity.
The certificate is not globally trusted and the build keychain is not left in the
user's search list. This is local code identity, not Developer ID/notarization.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import stat
import subprocess
import sys
import tempfile

STATE = Path.home() / "Library/Application Support/moe.tachyon.sotto.build-signing"
APP_ID = "moe.tachyon.sotto"
CERT_NAME = "Sotto Local Release Signing"
KEYCHAIN_FILE = "signing.keychain-db"

# The create/inspect helper requests no interaction and sets the complete ACL
# before importing a new key. It never updates an existing key's ACL: macOS can
# prompt for that operation despite the no-interaction request. codesign itself
# has no public no-UI switch, so first verify the dedicated key's access policy.
HELPER_SOURCE = r'''
#import <Foundation/Foundation.h>
#import <Security/Security.h>

static void check(OSStatus status, const char *operation) {
    if (status != errSecSuccess) {
        fprintf(stderr, "%s failed (OSStatus %d)\n", operation, (int)status);
        exit(1);
    }
}
static NSData *readFile(NSString *directory, NSString *name) {
    NSData *data = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name]];
    if (!data) { fprintf(stderr, "required signing file unavailable\n"); exit(1); }
    return data;
}
static BOOL partitionAllowsApple(SecAccessRef access) {
    CFArrayRef list = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationPartitionID);
    BOOL allowed = NO;
    for (id object in (__bridge NSArray *)list) {
        CFArrayRef apps = NULL; CFStringRef text = NULL; SecKeychainPromptSelector selector;
        if (SecACLCopyContents((__bridge SecACLRef)object, &apps, &text, &selector) == errSecSuccess) {
            // Apple's security tool stores the partition plist as hex text.
            // Read-only validation; the complete policy is set before import.
            NSString *hex = (__bridge NSString *)text;
            NSMutableData *bytes = [NSMutableData data]; BOOL valid = hex && hex.length % 2 == 0;
            for (NSUInteger i = 0; valid && i < hex.length; i += 2) {
                unsigned value; NSScanner *scanner = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
                valid = [scanner scanHexInt:&value] && scanner.isAtEnd;
                if (valid) { unsigned char byte = (unsigned char)value; [bytes appendBytes:&byte length:1]; }
            }
            id plist = valid ? [NSPropertyListSerialization propertyListWithData:bytes options:0 format:NULL error:NULL] : nil;
            if ([plist isKindOfClass:NSDictionary.class] && [plist[@"Partitions"] isKindOfClass:NSArray.class])
                allowed |= [plist[@"Partitions"] containsObject:@"apple:"];
        }
        if (apps) CFRelease(apps); if (text) CFRelease(text);
    }
    if (list) CFRelease(list);
    return allowed;
}
static BOOL codesignIsOnlySigningApp(SecAccessRef access) {
    SecTrustedApplicationRef expected = NULL; CFDataRef expectedData = NULL;
    check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &expected), "codesign ACL reference");
    check(SecTrustedApplicationCopyData(expected, &expectedData), "codesign ACL data");
    CFArrayRef list = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationSign);
    BOOL found = NO, restricted = YES;
    for (id object in (__bridge NSArray *)list) {
        CFArrayRef apps = NULL; CFStringRef text = NULL; SecKeychainPromptSelector selector;
        check(SecACLCopyContents((__bridge SecACLRef)object, &apps, &text, &selector), "signing ACL");
        if (!apps || CFArrayGetCount(apps) != 1) restricted = NO;
        for (id app in (__bridge NSArray *)apps) {
            CFDataRef data = NULL;
            check(SecTrustedApplicationCopyData((__bridge SecTrustedApplicationRef)app, &data), "trusted application data");
            BOOL matches = CFEqual(data, expectedData); found |= matches; restricted &= matches;
            CFRelease(data);
        }
        if (apps) CFRelease(apps); if (text) CFRelease(text);
    }
    if (list) CFRelease(list); CFRelease(expectedData); CFRelease(expected);
    return found && restricted;
}
static void addApplePartition(SecAccessRef access) {
    // Same plist representation used by Apple's security tool; these are
    // public legacy ACL APIs. The separate signing ACL remains codesign-only.
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:@{@"Partitions":@[@"apple:"]}
        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (!xml) { fprintf(stderr, "partition serialization failed\n"); exit(1); }
    NSMutableString *hex = [NSMutableString string];
    const unsigned char *bytes = xml.bytes;
    for (NSUInteger i = 0; i < xml.length; i++) [hex appendFormat:@"%02x", bytes[i]];
    SecACLRef partition = NULL;
    check(SecACLCreateWithSimpleContents(access, NULL, (__bridge CFStringRef)hex, 0, &partition), "create Apple partition ACL");
    check(SecACLUpdateAuthorizations(partition, (__bridge CFArrayRef)@[(__bridge id)kSecACLAuthorizationPartitionID]), "set partition authorization");
    CFRelease(partition);
}
int main(int argc, const char *argv[]) { @autoreleasepool {
    if (argc != 3 || (strcmp(argv[1], "create") && strcmp(argv[1], "inspect"))) return 2;
    check(SecKeychainSetUserInteractionAllowed(false), "disable interaction");
    NSString *directory = [NSString stringWithUTF8String:argv[2]];
    NSData *passwordData = readFile(directory, @"password");
    NSString *password = [[NSString alloc] initWithData:passwordData encoding:NSUTF8StringEncoding];
    if (!password || password.length != 64) return 2;
    const char *keychainPath = [[directory stringByAppendingPathComponent:@"signing.keychain-db"] fileSystemRepresentation];
    SecKeychainRef keychain = NULL;
    if (!strcmp(argv[1], "create")) {
        CFArrayRef original = NULL;
        check(SecKeychainCopySearchList(&original), "snapshot search list");
        OSStatus created = SecKeychainCreate(keychainPath, (UInt32)passwordData.length, passwordData.bytes, false, NULL, &keychain);
        // SecKeychainCreate may add the new keychain; immediately restore even
        // after a failed create. Never set the default or any trust settings.
        OSStatus restored = SecKeychainSetSearchList(original);
        CFArrayRef after = NULL; OSStatus copied = SecKeychainCopySearchList(&after);
        BOOL same = copied == errSecSuccess && CFEqual(original, after);
        if (after) CFRelease(after); CFRelease(original);
        check(restored, "restore search list");
        if (!same) { fprintf(stderr, "search list restore verification failed\n"); return 1; }
        check(created, "create dedicated keychain");
        SecTrustedApplicationRef app = NULL; SecAccessRef access = NULL;
        check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &app), "codesign ACL");
        NSArray *apps = @[(__bridge id)app];
        check(SecAccessCreate(CFSTR("Sotto local build signing"), (__bridge CFArrayRef)apps, &access), "restricted access");
        // Construct the complete initial policy before import. Never change
        // an existing key's ACL: that operation can trigger SecurityAgent UI.
        addApplePartition(access);
        SecItemImportExportKeyParameters params = {0};
        params.version = SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION;
        params.passphrase = (__bridge CFStringRef)password;
        params.accessRef = access;
        params.keyUsage = (__bridge CFArrayRef)@[(__bridge id)kSecAttrCanSign];
        params.keyAttributes = (__bridge CFArrayRef)@[(__bridge id)kSecAttrIsPermanent, (__bridge id)kSecAttrIsSensitive];
        SecExternalFormat format = kSecFormatPKCS12; SecExternalItemType type = kSecItemTypeAggregate;
        NSData *p12 = readFile(directory, @"identity.p12");
        check(SecItemImport((__bridge CFDataRef)p12, NULL, &format, &type, 0, &params, keychain, NULL), "import dedicated identity");
        CFRelease(access); CFRelease(app);
    } else {
        check(SecKeychainOpen(keychainPath, &keychain), "open dedicated keychain");
    }
    check(SecKeychainUnlock(keychain, (UInt32)passwordData.length, passwordData.bytes, true), "unlock dedicated keychain");
    NSDictionary *query = @{(__bridge id)kSecClass:(__bridge id)kSecClassKey,
        (__bridge id)kSecAttrKeyClass:(__bridge id)kSecAttrKeyClassPrivate,
        (__bridge id)kSecMatchSearchList:@[(__bridge id)keychain],
        (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnRef:@YES};
    CFTypeRef result = NULL; check(SecItemCopyMatching((__bridge CFDictionaryRef)query, &result), "dedicated signing key");
    NSArray *keys = (__bridge NSArray *)result;
    if (keys.count != 1) { fprintf(stderr, "expected exactly one dedicated signing key\n"); return 1; }
    SecAccessRef access = NULL;
    check(SecKeychainItemCopyAccess((__bridge SecKeychainItemRef)keys[0], &access), "read signing access policy");
    BOOL restricted = codesignIsOnlySigningApp(access), partition = partitionAllowsApple(access);
    printf("{\"restrictedCodesignACL\":%s,\"applePartition\":%s}\n", restricted ? "true":"false", partition ? "true":"false");
    CFRelease(access); CFRelease(result); CFRelease(keychain);
    return 0;
}}
'''


class SigningError(Exception):
    pass


def run(arguments, *, input=None, allowed_failure=False):
    result = subprocess.run([str(x) for x in arguments], input=input, capture_output=True, timeout=120)
    if result.returncode and not allowed_failure:
        # Never include commands, captured output, or supplied stdin in errors.
        raise SigningError(f"{Path(arguments[0]).name} failed (exit {result.returncode})")
    return result


def protected(path, directory=False):
    try:
        info = path.lstat()
    except FileNotFoundError:
        raise SigningError(f"Signing material missing: {path.name}; run setup explicitly. No identity was generated.")
    required = 0o700 if directory else 0o600
    if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != required or (directory and not stat.S_ISDIR(info.st_mode)) or (not directory and not stat.S_ISREG(info.st_mode)):
        raise SigningError(f"Unsafe signing material ownership/type/mode: {path.name}")


def write_private(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(data)


def helper(action):
    # Compile only our own small helper; no injected code or private APIs.
    with tempfile.TemporaryDirectory(prefix="sotto-signing-helper-") as temporary:
        directory = Path(temporary)
        source, binary = directory / "helper.m", directory / "helper"
        source.write_text(HELPER_SOURCE)
        run(["/usr/bin/clang", "-Wno-deprecated-declarations", "-framework", "Foundation", "-framework", "Security", source, "-o", binary])
        result = run([binary, action, STATE])
        return json.loads(result.stdout)


def metadata():
    protected(STATE, directory=True)
    for name in ("password", "certificate.der", "identity.json", KEYCHAIN_FILE):
        protected(STATE / name)
    value = json.loads((STATE / "identity.json").read_text())
    fingerprint = hashlib.sha1((STATE / "certificate.der").read_bytes()).hexdigest().upper()
    if value.get("certificateSHA1") != fingerprint or value.get("bundleIdentifier") != APP_ID:
        raise SigningError("Pinned signing identity metadata does not match the certificate.")
    run(["/usr/bin/openssl", "x509", "-inform", "DER", "-in", STATE / "certificate.der", "-checkend", "0", "-noout"])
    return value


def ready():
    value = metadata()
    policy = helper("inspect")
    if not policy["restrictedCodesignACL"]:
        raise SigningError("Signing key ACL is not restricted to /usr/bin/codesign; refusing signing.")
    if not policy["applePartition"]:
        raise SigningError("Initial signing policy lacks the Apple partition; refusing signing. Existing key ACL updates are disabled.")
    return value


def export_identity():
    # When passin and passout name the same file, LibreSSL/OpenSSL consume
    # consecutive lines from that source. Give export its own private file
    # containing the same password; never put either password in argv.
    with tempfile.NamedTemporaryFile(mode="wb", dir=STATE, prefix=".p12-password-") as output_password:
        output_password.write((STATE / "password").read_bytes())
        output_password.flush()
        run(["/usr/bin/openssl", "pkcs12", "-export", "-inkey", STATE / "private-key.pem", "-in", STATE / "certificate.pem", "-name", CERT_NAME, "-out", STATE / "identity.p12", "-passin", f"file:{STATE / 'password'}", "-passout", f"file:{output_password.name}", "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"])


def setup():
    if STATE.exists() or STATE.is_symlink():
        raise SigningError("Signing directory already exists; refusing to overwrite or regenerate identity.")
    STATE.mkdir(mode=0o700, parents=True)
    write_private(STATE / "password", secrets.token_hex(32).encode())
    config = """[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=Sotto Local Release Signing
[extensions]
basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage=critical,codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
"""
    write_private(STATE / "certificate.cnf", config.encode())
    password_file = f"file:{STATE / 'password'}"
    run(["/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:3072", "-sha256", "-days", "7300", "-config", STATE / "certificate.cnf", "-keyout", STATE / "private-key.pem", "-out", STATE / "certificate.pem", "-passout", password_file])
    run(["/usr/bin/openssl", "x509", "-in", STATE / "certificate.pem", "-outform", "DER", "-out", STATE / "certificate.der"])
    export_identity()
    # Files are generated under umask 077. The encrypted PEM and PKCS12 are
    # backups of this same identity, never a source for automatic regeneration.
    policy = helper("create")
    for item in STATE.iterdir():
        if item.is_file() and not item.is_symlink():
            item.chmod(0o600)
    value = {"version": 1, "bundleIdentifier": APP_ID, "certificateSHA1": hashlib.sha1((STATE / "certificate.der").read_bytes()).hexdigest().upper()}
    write_private(STATE / "identity.json", (json.dumps(value, indent=2) + "\n").encode())
    print(json.dumps({"created": True, "signingPolicy": policy, "next": "check" if all(policy.values()) else "stop"}))


def signature(path, identifier, value):
    run(["/usr/bin/codesign", "--force", "--sign", value["certificateSHA1"], "--keychain", STATE / KEYCHAIN_FILE, "--timestamp=none", "--identifier", identifier, path])
    requirement = f'identifier "{identifier}" and certificate leaf = H"{value["certificateSHA1"]}"'
    run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, path])
    result = run(["/usr/bin/codesign", "--display", "-r-", path])
    text = (result.stdout + result.stderr).decode()
    match = re.search(r"^designated => (.+)$", text, re.MULTILINE)
    if not match or "cdhash" in match[1] or value["certificateSHA1"].lower() not in match[1].lower() or identifier not in match[1]:
        raise SigningError("Signature has no expected stable certificate-bound designated requirement.")
    return match[1]


def sign_app(path):
    value = ready()
    path = path.resolve(strict=True)
    if STATE == path or STATE.is_relative_to(path):
        raise SigningError("Signing state must never be inside an application bundle.")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != APP_ID:
        raise SigningError("Unexpected release bundle identifier.")
    for library in sorted((path / "Contents/Resources/Frameworks").glob("*.dylib")):
        signature(library, APP_ID + ".library." + library.stem, value)
    requirement = signature(path, APP_ID, value)
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", path])
    print(json.dumps({"signed": True, "certificateSHA1": value["certificateSHA1"], "designatedRequirement": requirement}))


def check_synthetic():
    value = ready()
    with tempfile.TemporaryDirectory(prefix="sotto-signing-check-") as temporary:
        directory = Path(temporary)
        binaries, requirements, hashes = [], [], []
        for version in (1, 2):
            source, binary = directory / f"v{version}.c", directory / f"v{version}"
            source.write_text(f"int main(void) {{ return {version}; }}\n")
            run(["/usr/bin/clang", source, "-o", binary])
            requirements.append(signature(binary, APP_ID + ".SigningCheck", value))
            details = run(["/usr/bin/codesign", "--display", "--verbose=4", binary])
            match = re.search(rb"^CDHash=([0-9a-f]+)$", details.stdout + details.stderr, re.MULTILINE)
            if not match:
                raise SigningError("Synthetic binary has no code directory hash.")
            hashes.append(match[1].decode())
            binaries.append(binary)
        different = binaries[0].read_bytes() != binaries[1].read_bytes()
        for binary, requirement in zip(binaries, reversed(requirements)):
            run(["/usr/bin/codesign", "--verify", "--strict", "-R", "=" + requirement, binary])
        negative = run(["/usr/bin/codesign", "--verify", "--strict", "-R", '=identifier "moe.tachyon.sotto.WrongIdentity"', binaries[0]], allowed_failure=True)
        if not different or hashes[0] == hashes[1] or requirements[0] != requirements[1] or negative.returncode == 0:
            raise SigningError("Synthetic identity continuity checks failed.")
        print(json.dumps({"differentBinaries": True, "differentCDHashes": True, "sameDesignatedRequirement": True, "crossVerification": True, "wrongIdentifierRejected": True, "certificateSHA1": value["certificateSHA1"], "designatedRequirement": requirements[0], "tccContinuityTested": False}, indent=2))


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("setup", "preflight", "sign-app", "check"))
    parser.add_argument("app", nargs="?", type=Path)
    args = parser.parse_args()
    if args.command == "setup": setup()
    elif args.command == "preflight":
        value = ready()
        print(json.dumps({"ready": True, "certificateSHA1": value["certificateSHA1"]}))
    elif args.command == "check": check_synthetic()
    elif args.app is None: parser.error("sign-app requires an application path")
    else: sign_app(args.app)


if __name__ == "__main__":
    try:
        main()
    except (SigningError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"Local signing stopped: {error}", file=sys.stderr)
        sys.exit(1)
