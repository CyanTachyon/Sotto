#!/bin/bash
# Rebuild the pinned arm64 libraries from upstream sources for macOS 26.0.
set -Eeuo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
export MACOSX_DEPLOYMENT_TARGET=26.0
export CC="$(xcrun -f clang)"
export CPPFLAGS= CXXFLAGS=
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH
unset DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH CONFIG_SITE
unset AR AS RANLIB NM
ROOT="$(python3 -I -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${SOTTO_DEPENDENCY_ROOT:-$SOURCE_ROOT/.build/macos26-dependencies}")"
case "$ROOT" in /|"$SOURCE_ROOT") echo 'Unsafe dependency output directory' >&2; exit 1;; esac
case "$ROOT$SDKROOT" in *[[:space:]]*) echo 'Dependency output directory and SDKROOT must not contain whitespace' >&2; exit 1;; esac
# Only an empty directory or a cache created by this builder may be replaced.
python3 -I - "$ROOT" <<'PYGUARD'
import json,pathlib,sys
root=pathlib.Path(sys.argv[1])
try:
 if root.is_symlink(): raise ValueError('output directory must not be a symlink')
 if root.exists():
  if not root.is_dir(): raise ValueError('output path must be a directory')
  if any(root.iterdir()):
   try: info=json.loads((root/'build-info.json').read_text())
   except (OSError,ValueError): raise ValueError('nonempty output directory has no valid dependency build-info.json')
   if info.get('builder')!='sotto-build-dependencies-v1': raise ValueError('nonempty output directory is not a dependency cache from this script')
except ValueError as e:
 print(str(e),file=sys.stderr); sys.exit(1)
PYGUARD
JOBS="${SOTTO_BUILD_JOBS:-$(sysctl -n hw.ncpu)}"
case "$JOBS" in ''|*[!0-9]*) echo 'SOTTO_BUILD_JOBS must be a positive integer' >&2; exit 1;; esac
if [ "$JOBS" -lt 1 ]; then echo 'SOTTO_BUILD_JOBS must be positive' >&2; exit 1; fi
if [ "$JOBS" -gt 8 ]; then JOBS=8; fi
SDK_VERSION="$(xcrun --sdk "$SDKROOT" --show-sdk-version)"
SCRIPT_SHA="$(shasum -a 256 "$0" | awk '{print $1}')"
SDK_SHA="$(shasum -a 256 "$SDKROOT/SDKSettings.json" | awk '{print $1}')"
COMPILER_VERSION="$($CC --version)"
export ROOT SDK_VERSION SCRIPT_SHA SDK_SHA COMPILER_VERSION

# A fingerprint uses pinned source digests, this script, SDK settings, compiler,
# architecture and deployment target. No caller-specific flags are inherited.
FINGERPRINT="$(python3 -I - <<'PY'
import hashlib,json,os
x={k:os.environ[k] for k in ('SCRIPT_SHA','SDK_SHA','COMPILER_VERSION')}
x.update(prefix_sha256=hashlib.sha256(os.environ['ROOT'].encode()).hexdigest(),target='26.0',arch='arm64',sources={
 'openssl-4.0.2':'736b467530f916737b7031310ccb21d8218c6229e61e8e160cd1d3458cd543a8',
 'sqlcipher-4.19.0':'7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0',
 'zstd-1.5.7':'37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3'})
print(hashlib.sha256(json.dumps(x,sort_keys=True).encode()).hexdigest())
PY
)"
export FINGERPRINT

verify_archive() {
  local actual
  actual="$(shasum -a 256 "$1" | awk '{print $1}')"
  if [ "$actual" != "$2" ]; then echo "Source checksum mismatch: $(basename "$1")" >&2; exit 1; fi
}
if [ -n "${SOTTO_DEPENDENCY_SOURCES:-}" ]; then
  verify_archive "$SOTTO_DEPENDENCY_SOURCES/openssl-4.0.2.tar.gz" 736b467530f916737b7031310ccb21d8218c6229e61e8e160cd1d3458cd543a8
  verify_archive "$SOTTO_DEPENDENCY_SOURCES/sqlcipher-4.19.0.tar.gz" 7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0
  verify_archive "$SOTTO_DEPENDENCY_SOURCES/zstd-1.5.7.tar.gz" 37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3
fi
if python3 -I - <<'PY'
import hashlib,json,os,pathlib,sys
root=pathlib.Path(os.environ['ROOT'])
try:
 info=json.loads((root/'build-info.json').read_text())
 assert info['fingerprint']==os.environ['FINGERPRINT']
 expected=('prefix/openssl@4/lib/libcrypto.4.dylib','prefix/sqlcipher/lib/libsqlcipher.dylib','prefix/zstd/lib/libzstd.dylib')
 assert set(info['libraries'])==set(expected)
 for p in expected:
  assert hashlib.sha256((root/p).read_bytes()).hexdigest()==info['libraries'][p]['sha256']
except (OSError,ValueError,KeyError,AssertionError):
 sys.exit(1)
PY
then
  echo "Using verified macOS 26 dependency cache: $ROOT"
  exit 0
fi

mkdir -p "$(dirname "$ROOT")"
TEMP="$(mktemp -d "${ROOT}.tmp.XXXXXX")"
export TEMP
cleanup() { rm -rf "$TEMP"; }
trap cleanup EXIT
mkdir -p "$TEMP/archives" "$TEMP/src" "$TEMP/logs" "$TEMP/install"
fetch() {
  local name="$1" url="$2" sha="$3"
  if [ -n "${SOTTO_DEPENDENCY_SOURCES:-}" ]; then
    cp "$SOTTO_DEPENDENCY_SOURCES/$name.tar.gz" "$TEMP/archives/$name.tar.gz"
  else
    curl --fail --location --proto '=https' --tlsv1.2 --retry 3 "$url" -o "$TEMP/archives/$name.tar.gz"
  fi
  verify_archive "$TEMP/archives/$name.tar.gz" "$sha"
  tar -xzf "$TEMP/archives/$name.tar.gz" -C "$TEMP/src"
}
fetch openssl-4.0.2 https://github.com/openssl/openssl/releases/download/openssl-4.0.2/openssl-4.0.2.tar.gz 736b467530f916737b7031310ccb21d8218c6229e61e8e160cd1d3458cd543a8
fetch sqlcipher-4.19.0 https://github.com/sqlcipher/sqlcipher/archive/refs/tags/v4.19.0.tar.gz 7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0
fetch zstd-1.5.7 https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz 37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3

export CFLAGS="-O2 -isysroot $SDKROOT -arch arm64 -mmacosx-version-min=26.0 -Werror=unguarded-availability-new"
export LDFLAGS="-isysroot $SDKROOT -arch arm64 -mmacosx-version-min=26.0"
# DESTDIR keeps install names at their final location while all writes and
# intermediate build inputs stay in a disposable staging directory.
STAGED_PREFIX="$TEMP/install$ROOT/prefix"
export STAGED_PREFIX
on_failure() {
  local status=$?
  trap - ERR
  local failed="${ROOT}.failed-$(date +%Y%m%d%H%M%S)-$$"
  mkdir -p "$failed"
  cp -R "$TEMP/logs" "$failed/"
  for log in "$TEMP/logs/"*.log; do
    if [ -f "$log" ]; then tail -20 "$log" >&2; fi
  done
  echo "Dependency build failed; logs: $failed/logs" >&2
  exit "$status"
}
trap on_failure ERR
run_logged() {
  local name="$1"
  shift
  "$@" > "$TEMP/logs/$name.log" 2>&1
}

build_openssl() (
  set -ex
  cd "$TEMP/src/openssl-4.0.2"
  perl ./Configure darwin64-arm64-cc shared enable-ec_nistp_64_gcc_128 \
    --prefix="$ROOT/prefix/openssl@4" --openssldir="$ROOT/prefix/openssl@4/etc/openssl" --libdir=lib
  make -j"$JOBS"
  make DESTDIR="$TEMP/install" install_sw install_ssldirs
)
echo 'Building OpenSSL 4.0.2 for arm64 macOS 26.0...'
run_logged openssl build_openssl

build_sqlcipher() (
  set -ex
  export CFLAGS="$CFLAGS -I$STAGED_PREFIX/openssl@4/include -DSQLITE_HAS_CODEC -DSQLITE_ENABLE_JSON1 -DSQLITE_ENABLE_FTS3 -DSQLITE_ENABLE_FTS3_PARENTHESIS -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_EXTRA_INIT=sqlcipher_extra_init -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown"
  export LDFLAGS="$LDFLAGS -L$STAGED_PREFIX/openssl@4/lib -lcrypto"
  export DYLD_LIBRARY_PATH="$STAGED_PREFIX/openssl@4/lib"
  export PKG_CONFIG_PATH="$STAGED_PREFIX/openssl@4/lib/pkgconfig"
  cd "$TEMP/src/sqlcipher-4.19.0"
  ./configure --disable-tcl --dll-basename=libsqlcipher --enable-load-extension \
    --includedir="$ROOT/prefix/sqlcipher/include/sqlcipher" --prefix="$ROOT/prefix/sqlcipher" \
    --with-tempstore=yes "CFLAGS=$CFLAGS" "LDFLAGS=$LDFLAGS"
  make -j"$JOBS"
  make DESTDIR="$TEMP/install" install
  # Match the formula's SQLCipher names, including links already named
  # libsqlcipher.dylib that still target SQLite-named versioned files.
  python3 -I - <<'PY'
import os,pathlib
root=pathlib.Path(os.environ['STAGED_PREFIX'])/'sqlcipher'
for d in ('bin','share/man/man1','lib/pkgconfig','lib'):
 for p in (root/d).glob('*sqlite3*'):
  target=p.with_name(p.name.replace('sqlite3','sqlcipher'))
  if p.is_symlink():
   link=str(p.readlink()).replace('sqlite3','sqlcipher'); p.unlink(); target.symlink_to(link)
  else: p.rename(target)
for p in (root/'lib').iterdir():
 if p.is_symlink() and 'sqlite3' in str(p.readlink()):
  link=str(p.readlink()).replace('sqlite3','sqlcipher'); p.unlink(); p.symlink_to(link)
p=root/'lib/pkgconfig/sqlcipher.pc'
p.write_text(p.read_text().replace('-lsqlite3','-lsqlcipher'))
PY
)
echo 'Building SQLCipher 4.19.0 against the new OpenSSL...'
run_logged sqlcipher build_sqlcipher

build_zstd() (
  set -ex
  cd "$TEMP/src/zstd-1.5.7"
  make -C lib -j"$JOBS" PREFIX="$ROOT/prefix/zstd" ZSTD_LEGACY_SUPPORT=1 lib
  make -C lib PREFIX="$ROOT/prefix/zstd" DESTDIR="$TEMP/install" ZSTD_LEGACY_SUPPORT=1 install
)
echo 'Building Zstandard 1.5.7...'
run_logged zstd build_zstd
mv "$STAGED_PREFIX" "$TEMP/prefix"

python3 -I - <<'PY'
import datetime,hashlib,json,os,pathlib,re,subprocess
root=pathlib.Path(os.environ['TEMP'])
libs={}
for rel in ('prefix/openssl@4/lib/libcrypto.4.dylib','prefix/sqlcipher/lib/libsqlcipher.dylib','prefix/zstd/lib/libzstd.dylib'):
 p=root/rel
 arch=subprocess.check_output(['lipo','-archs',str(p)],text=True).strip()
 assert arch=='arm64', (rel,arch)
 commands=subprocess.check_output(['otool','-l',str(p)],text=True)
 match=re.search(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)\s+minos ([\d.]+)\s+sdk ([\d.]+)',commands)
 assert match and match[1]=='1' and tuple(map(int,match[2].split('.'))) <= (26,0), (rel,match)
 links=subprocess.check_output(['otool','-L',str(p)],text=True)
 deps=[line.strip().split(' (compatibility')[0] for line in links.splitlines()[1:]]
 assert deps[0].startswith(os.environ['ROOT']+'/prefix/'), (rel,deps)
 for dep in deps[1:]:
  assert dep.startswith(('/usr/lib/','/System/Library/')) or dep==os.environ['ROOT']+'/prefix/openssl@4/lib/libcrypto.4.dylib', (rel,dep)
 libs[rel]={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'architecture':arch,'minos':match[2],'sdk':match[3]}
 (root/'logs'/(p.name+'.otool.txt')).write_text(commands+'\n'+links)
info={'builder':'sotto-build-dependencies-v1','format_version':1,'fingerprint':os.environ['FINGERPRINT'],'built_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'versions':{'openssl':'4.0.2','sqlcipher':'4.19.0','sqlite':'3.53.4','zstd':'1.5.7'},
 'source_sha256':{'openssl-4.0.2.tar.gz':'736b467530f916737b7031310ccb21d8218c6229e61e8e160cd1d3458cd543a8','sqlcipher-4.19.0.tar.gz':'7075f96cbabe45b4ecfc2e6b1745a625f856f695b0827a5506ce9ed85b906aa0','zstd-1.5.7.tar.gz':'37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3'},
 'sdk':{'version':os.environ['SDK_VERSION'],'settings_sha256':os.environ['SDK_SHA']},'target':'26.0','architecture':'arm64',
 'script_sha256':os.environ['SCRIPT_SHA'],'compiler':os.environ['COMPILER_VERSION'].splitlines()[0],
 'flags':{'CFLAGS':'-O2 -isysroot <SDK> -arch arm64 -mmacosx-version-min=26.0 -Werror=unguarded-availability-new','LDFLAGS':'-isysroot <SDK> -arch arm64 -mmacosx-version-min=26.0','SQLCipher':'-I<new-openssl>/include -L<new-openssl>/lib -lcrypto; SQLITE_HAS_CODEC SQLITE_ENABLE_JSON1 SQLITE_ENABLE_FTS3 SQLITE_ENABLE_FTS3_PARENTHESIS SQLITE_ENABLE_FTS5 SQLITE_ENABLE_COLUMN_METADATA SQLITE_EXTRA_INIT=sqlcipher_extra_init SQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown'},
 'commands':{'openssl':'perl ./Configure darwin64-arm64-cc shared enable-ec_nistp_64_gcc_128 --prefix=<final-prefix> --openssldir=<final-prefix>/etc/openssl --libdir=lib; make; make DESTDIR=<stage> install_sw install_ssldirs','sqlcipher':'./configure --disable-tcl --dll-basename=libsqlcipher --enable-load-extension --with-tempstore=yes --prefix=<final-prefix> --includedir=<final-prefix>/include/sqlcipher; make; make DESTDIR=<stage> install; rename sqlite3 outputs','zstd':'make -C lib PREFIX=<final-prefix> ZSTD_LEGACY_SUPPORT=1 lib; make -C lib PREFIX=<final-prefix> DESTDIR=<stage> ZSTD_LEGACY_SUPPORT=1 install'},
 'libraries':libs}
(root/'build-info.json').write_text(json.dumps(info,indent=2)+'\n')
PY
# Keep only completed outputs and their evidence. A failed build never replaces
# an existing valid prefix; a prior successful tree remains as a backup.
rm -rf "$TEMP/src" "$TEMP/install" "$TEMP/archives"
BACKUP="${ROOT}.previous-$(date +%Y%m%d%H%M%S)-$$"
if [ -e "$ROOT" ]; then mv "$ROOT" "$BACKUP"; fi
if ! mv "$TEMP" "$ROOT"; then
  if [ -e "$BACKUP" ]; then mv "$BACKUP" "$ROOT"; fi
  exit 1
fi
trap - EXIT ERR
echo "Built and verified macOS 26 dependencies: $ROOT"
