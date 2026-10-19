# Third-party components

These notices describe the components included in the Sotto 0.0.4 release.
Their original notices and licenses remain in effect for the respective code.
Sotto's project license does not replace these notices.

## SQLCipher 4.19.0 and SQLite 3.53.4

The packaged `libsqlcipher.dylib` is SQLCipher 4.19.0, based on SQLite 3.53.4.
SQLCipher's additions are copyright (c) 2025 ZETETIC LLC, under BSD-3-Clause;
the complete notice is in [SQLCipher-LICENSE.txt](SQLCipher-LICENSE.txt).
The underlying SQLite deliverable code and documentation are dedicated to
the public domain; see [SQLite-LICENSE.txt](SQLite-LICENSE.txt) and the
[official SQLite statement](https://www.sqlite.org/copyright.html).

- Project: <https://www.zetetic.net/sqlcipher/>
- Exact source: <https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v4.19.0.tar.gz>
- Source SHA-256: `7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0`

## Zstandard 1.5.7

The packaged `libzstd.dylib` includes Zstandard 1.5.7. For Zstandard code
offered under BSD-3-Clause or GPL-2.0, this distribution uses the BSD-3-Clause
option. The Meta Platforms, Inc. and affiliates notice is retained in
[Zstandard-LICENSE.txt](Zstandard-LICENSE.txt).

The library also contains the dictionary builder's `divsufsort` implementation,
copyright (c) 2003–2008 Yuta Mori, under the MIT license. Its complete notice
is retained in [Zstandard-divsufsort-MIT.txt](Zstandard-divsufsort-MIT.txt).
This subcomponent's notice is separate from Zstandard's BSD notice.

- Exact source: <https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz>
- Source SHA-256: `37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3`
- Subcomponent source: <https://github.com/facebook/zstd/blob/v1.5.7/lib/dictBuilder/divsufsort.c>

## OpenSSL 4.0.2

The packaged `libcrypto.4.dylib` is from OpenSSL 4.0.2, under Apache-2.0.
The complete license is retained in [OpenSSL-LICENSE.txt](OpenSSL-LICENSE.txt).
The upstream README retains these copyright notices:

- Copyright (c) 1998–2026 The OpenSSL Project Authors
- Copyright (c) 1995–1998 Eric A. Young, Tim J. Hudson

All rights reserved.

- Project: <https://openssl-library.org/>
- Exact source: <https://github.com/openssl/openssl/releases/download/openssl-4.0.2/openssl-4.0.2.tar.gz>
- Source SHA-256: `736b467530f916737b7031310ccb21d8218c6229e61e8e160cd1d3458cd543a8`
- Upstream README: <https://github.com/openssl/openssl/blob/openssl-4.0.2/README.md>

## macOS WeChat local toolkit adaptations

`Backend/bootstrap.py`, `Backend/capture_keys.py` and
`Backend/sqlcipher_probe.py` adapt parts of acmerfight's macOS WeChat local
toolkit. The upstream MIT notice, copyright (c) 2026 Contributors, is retained
unchanged in [wechat-local-MIT.txt](wechat-local-MIT.txt).

- Source: <https://gist.github.com/acmerfight/0a01249ef72970d07a2603dbb629e80f>
- License reference checked at revision `c98dbb10cf23c30e83d5d744905101b0880887a0`:
  <https://gist.github.com/acmerfight/0a01249ef72970d07a2603dbb629e80f/c98dbb10cf23c30e83d5d744905101b0880887a0#file-license>

The reference identifies the checked license; Sotto's adapted scripts have
their own changes and are not an unmodified copy of the whole toolkit.

## Binary provenance and build materials

The release's three third-party libraries are rebuilt from the exact upstream
source archives above, with arm64 / macOS 26.0 as the deployment target.
The release uses the macOS 26.5 SDK. The build enables
`-Werror=unguarded-availability-new` and checks each Mach-O minimum version;
these checks do not substitute for running on a macOS 26 machine.

[`scripts/build-dependencies.sh`](../scripts/build-dependencies.sh) records the
configuration and validates the source SHA-256 values. It builds OpenSSL first,
SQLCipher against that OpenSSL, and Zstandard with legacy/dictionary support.
No Homebrew bottle is copied into the release. The upstream library sources
are not patched. Sotto's app build rewrites Mach-O install names and the
SQLCipher/OpenSSL dependency to `@loader_path`, then signs the copied libraries.

Release source materials accompany the binaries with the complete upstream
source archives, the dependency build script and a sanitized build manifest.
A rebuild uses the builder's own signing identity, not the original publisher's
private signing material. These inputs support reconstructing the program;
they do not promise byte-for-byte reproduction of signed binaries.

## Sparkle 2.10.0

Sparkle provides the in-app update framework, installer helpers and signature validation. The complete upstream copyright and dependency notices are retained in [Sparkle-LICENSE.txt](Sparkle-LICENSE.txt). It uses the MIT license, with the additional upstream component notices in that file.

- Project and exact source: <https://github.com/sparkle-project/Sparkle/tree/2.10.0>
- SwiftPM binary input: <https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip>
- SwiftPM SHA-256: `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`
- Official release tools: <https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz>
- Release tools SHA-256: `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`

The package is pinned to 2.10.0 in Package.swift and Package.resolved. Packaging preserves symlinks and modes, strips unused architectures to arm64, then signs the framework and nested helpers with Sotto's release identity; it does not alter Sparkle source. The dependency-input archive includes the exact official SwiftPM ZIP and tool distribution in addition to the three source-built libraries above.
