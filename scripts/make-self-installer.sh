#!/usr/bin/env bash
#
# make-self-installer.sh -- build a single self-contained, relocatable
# dosemu2 installer from an existing dosemu2 installation.
#
# The output is one executable shell file with a compressed tarball of the
# dosemu2 runtime (emulator, fdpp DOS kernel, comcom COMMAND.COM, all plugins
# and data) appended to it.  Running it with --install-dir DIR unpacks a fully
# relocatable tree: the launcher rediscovers every data path from its own
# location, so DIR may be moved or copied to another same-arch machine.
#
# Usage:
#   scripts/make-self-installer.sh [--prefix DIR] [--output FILE] [options]
#
# Options:
#   --prefix DIR       dosemu2 install prefix to package        [default: auto]
#   --output FILE      installer file to write       [default: ./dosemu2-<ver>-installer.sh]
#   --version VER      version string baked into the installer  [default: git describe]
#   --comcom-dir DIR   comcom32/comcom64 directory              [default: auto-detect]
#   --launcher FILE    dosemu launcher to relocate              [default: <prefix>/bin/dosemu]
#   --keep-tmp         keep the staging/build tmp dir (debugging)
#   -h, --help         this help
#
# Typical use in CI: build + `make install` dosemu2 (+fdpp), apt-install a
# comcom provider, then run this against the install prefix.
#
set -euo pipefail

SELF="$(readlink -f "$0")"
REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"

PREFIX=""
OUTPUT=""
VERSION=""
COMCOM_DIR=""
LAUNCHER=""
KEEP_TMP=0

die() { echo "make-self-installer: $*" >&2; exit 1; }
log() { echo ">> $*"; }

usage() { sed -n '3,33p' "$SELF" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="${2:?}"; shift 2;;
    --prefix=*) PREFIX="${1#*=}"; shift;;
    --output) OUTPUT="${2:?}"; shift 2;;
    --output=*) OUTPUT="${1#*=}"; shift;;
    --version) VERSION="${2:?}"; shift 2;;
    --version=*) VERSION="${1#*=}"; shift;;
    --comcom-dir) COMCOM_DIR="${2:?}"; shift 2;;
    --comcom-dir=*) COMCOM_DIR="${1#*=}"; shift;;
    --launcher) LAUNCHER="${2:?}"; shift 2;;
    --launcher=*) LAUNCHER="${1#*=}"; shift;;
    --keep-tmp) KEEP_TMP=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown argument: $1 (try --help)";;
  esac
done

# --- tools -----------------------------------------------------------------
for t in tar xz awk sed find sha256sum readlink; do
  command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found"
done

# find_in <relpath> <search-prefixes...> -> echoes first existing <p>/<relpath>
find_in() {
  local rel="$1"; shift
  local p
  for p in "$@"; do
    [ -e "$p/$rel" ] && { echo "$p/$rel"; return 0; }
  done
  return 1
}

# --- locate the dosemu2 prefix by finding the emulator itself --------------
# Don't trust a single hardcoded prefix: the install may live under /usr or
# /usr/local, so search and derive the prefix from where dosemu2.bin actually
# is.  An explicit --prefix is just tried first.
CAND_PREFIXES=()
[ -n "$PREFIX" ] && CAND_PREFIXES+=("$PREFIX")
if command -v dosemu >/dev/null 2>&1; then
  CAND_PREFIXES+=("$(cd "$(dirname "$(readlink -f "$(command -v dosemu)")")/.." && pwd)")
fi
CAND_PREFIXES+=(/usr/local /usr)

PREFIX=""
for p in "${CAND_PREFIXES[@]}"; do
  if [ -f "$p/libexec/dosemu2/dosemu2.bin" ]; then PREFIX="$p"; break; fi
done
[ -n "$PREFIX" ] \
  || die "dosemu2 emulator (libexec/dosemu2/dosemu2.bin) not found in: ${CAND_PREFIXES[*]}"
log "Using dosemu2 prefix: $PREFIX"

SEARCH_PREFIXES=("$PREFIX" /usr/local /usr)
# library dirs vary: lib, lib64, or multiarch (lib/<triplet>)
LIBDIRS=("$PREFIX/lib" "$PREFIX/lib64" "$PREFIX"/lib/*-linux-gnu)

# --- required dosemu2 components -------------------------------------------
DOSEMU_BIN="$PREFIX/libexec/dosemu2/dosemu2.bin"
[ -d "$PREFIX/share/dosemu" ] || die "data dir not found: $PREFIX/share/dosemu"

PLUGINDIR=""
for d in "${LIBDIRS[@]}"; do [ -d "$d/dosemu" ] && { PLUGINDIR="$d/dosemu"; break; }; done
[ -n "$PLUGINDIR" ] \
  || die "plugin dir (lib/dosemu) not found under $PREFIX (looked in: ${LIBDIRS[*]})"

LIBDOSEMU=""
for d in "${LIBDIRS[@]}"; do
  f="$(find "$d" -maxdepth 1 -name 'libdosemu2.so.*' -type f 2>/dev/null | head -n1)"
  [ -n "$f" ] && { LIBDOSEMU="$f"; break; }
done
[ -n "$LIBDOSEMU" ] \
  || die "libdosemu2 not found under $PREFIX (looked in: ${LIBDIRS[*]})"

[ -n "$LAUNCHER" ] || LAUNCHER="$PREFIX/bin/dosemu"
[ -f "$LAUNCHER" ] || die "launcher not found: $LAUNCHER (pass --launcher)"

# --- fdpp (DOS kernel) ------------------------------------------------------
FDPP_LIB_DIR="$(find_in lib/fdpp "${SEARCH_PREFIXES[@]}")" \
  || die "fdpp libraries (lib/fdpp) not found in: ${SEARCH_PREFIXES[*]}"
FDPP_SHARE_DIR="$(find_in share/fdpp "${SEARCH_PREFIXES[@]}")" \
  || die "fdpp kernel (share/fdpp) not found in: ${SEARCH_PREFIXES[*]}"

# --- comcom (COMMAND.COM provider) -----------------------------------------
# Prefer comcom32: self-contained (no dj64/djdev64), boots under cpuemu on any
# machine.  comcom64 is used only as a fallback if comcom32 is not present.
if [ -z "$COMCOM_DIR" ]; then
  for sub in share/comcom32 share/comcom64; do
    if d="$(find_in "$sub" "${SEARCH_PREFIXES[@]}" /opt 2>/dev/null)"; then
      COMCOM_DIR="$d"; break
    fi
  done
fi
[ -n "$COMCOM_DIR" ] && [ -e "$COMCOM_DIR/command.com" ] \
  || die "no comcom (command.com) found; pass --comcom-dir DIR"

# --- version ----------------------------------------------------------------
if [ -z "$VERSION" ]; then
  if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    VERSION="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2>/dev/null || true)"
  fi
  [ -n "$VERSION" ] || { [ -f "$REPO_ROOT/VERSION" ] && VERSION="$(cat "$REPO_ROOT/VERSION")"; }
  [ -n "$VERSION" ] || VERSION="unknown"
fi
[ -n "$OUTPUT" ] || OUTPUT="$PWD/dosemu2-${VERSION}-installer.sh"

log "Version:   $VERSION"
log "emulator:  $DOSEMU_BIN"
log "plugins:   $PLUGINDIR"
log "libdosemu: $LIBDOSEMU"
log "fdpp:      $FDPP_LIB_DIR + $FDPP_SHARE_DIR"
log "comcom:    $COMCOM_DIR"
log "launcher:  $LAUNCHER"
log "output:    $OUTPUT"

# --- staging ----------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dosemu2-mkinst.XXXXXX")"
cleanup() { [ "$KEEP_TMP" -eq 1 ] || rm -rf "$TMP"; }
trap cleanup EXIT
STAGE="$TMP/stage"
# Keep the comcom dir's original basename: dosemu2 identifies the variant by
# whether the directory name contains "32" (comcom_hook in config.c), so it
# must stay comcom32/comcom64 -- not a generic name.
CC_NAME="$(basename "$COMCOM_DIR")"
mkdir -p "$STAGE/bin" "$STAGE/lib/dosemu" "$STAGE/libexec" \
         "$STAGE/share/dosemu" "$STAGE/share/fdpp" "$STAGE/share/$CC_NAME"

log "Staging runtime files"
cp -a "$PREFIX/libexec/dosemu2"        "$STAGE/libexec/"
cp -a "$PLUGINDIR/."                   "$STAGE/lib/dosemu/"
cp -a "$LIBDOSEMU"                     "$STAGE/lib/"
# recreate the unversioned libdosemu2.so symlink (relative)
( cd "$STAGE/lib" && ln -sf "$(basename "$LIBDOSEMU")" libdosemu2.so )
cp -a "$FDPP_LIB_DIR"                  "$STAGE/lib/"          # -> lib/fdpp
cp -a "$FDPP_SHARE_DIR/."              "$STAGE/share/fdpp/"
cp -a "$PREFIX/share/dosemu/."         "$STAGE/share/dosemu/"
cp -a "$COMCOM_DIR/."                  "$STAGE/share/$CC_NAME/"
[ -e "$PREFIX/bin/mkfatimage16" ] && cp -a "$PREFIX/bin/mkfatimage16" "$STAGE/bin/" || true

# --- capture non-system ecosystem libs (e.g. dj64/djdev64 for comcom64) -----
log "Capturing ecosystem libraries"
if command -v ldd >/dev/null 2>&1; then
  find "$STAGE/libexec" "$STAGE/lib/dosemu" -type f \
       \( -name '*.so' -o -name '*.so.*' -o -name 'dosemu2.bin' \) -print0 |
  while IFS= read -r -d '' f; do
    ldd "$f" 2>/dev/null | awk '/=>/ && $3 ~ /^\// {print $1" "$3}'
  done | sort -u | while read -r soname real; do
    case "$soname" in
      libdj64*|libdjdev64*)
        if [ ! -e "$STAGE/lib/$soname" ]; then
          cp -aL "$real" "$STAGE/lib/$soname"
          log "  + $soname"
        fi
        ;;
    esac
  done
fi

# --- generate the relocatable launcher --------------------------------------
log "Generating relocatable launcher"
cat > "$TMP/head.txt" <<'HEAD_EOF'
# --- relocatable install: discover prefix from this script's location ---
__self="$(readlink -f "$0")"
prefix="$(cd "$(dirname "$__self")/.." && pwd)"
libexecdir="$prefix/libexec"
# build-tree autodetection is irrelevant for a relocated install:
LOCAL_BUILD_PATH="$prefix"
LOCAL_BIN_DIR="__none__"
HEAD_EOF

cat > "$TMP/getbin.txt" <<'GETBIN_EOF'
get_binary() {
  BINARY="$libexecdir/dosemu2/dosemu2.bin"
  if [ ! -f "$BINARY" ]; then
    echo "$BINARY does not exist"
    exit 1
  fi
  # Shared libs: libdosemu2 in lib/, libfdpp/libfdldr in lib/fdpp/, plus any
  # captured dj64/djdev64 in lib/.
  for __d in "$prefix/lib" "$prefix/lib/fdpp"; do
    if [ -z "${LD_LIBRARY_PATH:-}" ]; then
      export LD_LIBRARY_PATH="$__d"
    else
      export LD_LIBRARY_PATH="$__d:$LD_LIBRARY_PATH"
    fi
  done
  # Data files: fdpp DOS kernel + comcom COMMAND.COM.
  export FDPP_KERNEL_DIR="$prefix/share/fdpp"
  # comcom: prefer comcom32 (self-contained); keep the real dir name so dosemu2
  # detects the variant correctly.  A user-set DOSEMU2_COMCOM_DIR wins.
  if [ -z "${DOSEMU2_COMCOM_DIR:-}" ]; then
    for __cc in "$prefix"/share/comcom32 "$prefix"/share/comcom64; do
      [ -d "$__cc" ] && { export DOSEMU2_COMCOM_DIR="$__cc"; break; }
    done
  fi
  [ -d "$prefix/share/dosemu2-extras" ] && \
    export DOSEMU2_EXTRAS_DIR="$prefix/share/dosemu2-extras"
  # Plugins, DOS commands, keymaps/cpi/fonts.
  OPTS="$OPTS --Fplugindir $prefix/lib/dosemu"
  OPTS="$OPTS --Fcmddir $prefix/share/dosemu/commands"
  OPTS="$OPTS --Flibdir $prefix/share/dosemu"
  # TTF/PCF fonts for graphical (SDL/X) modes.
  if [ ! -e "$HOME/.fonts/dosemu2" ] && [ -d "$prefix/share/dosemu/Xfonts" ]; then
    mkdir -p "$HOME/.fonts" 2>/dev/null && \
      ln -sf "$prefix/share/dosemu/Xfonts" "$HOME/.fonts/dosemu2" 2>/dev/null || :
  fi
}
GETBIN_EOF

# Replace the hardcoded prefix header block and get_binary() with relocatable
# versions, preserving all other launcher logic verbatim.
awk -v headf="$TMP/head.txt" -v gbf="$TMP/getbin.txt" '
  function emit(f,   l){ while ((getline l < f) > 0) print l; close(f) }
  /^LOCAL_BUILD_PATH=/ && !dh { emit(headf); dh=1; sh=1; next }
  sh { if ($0 ~ /^fi$/) sh=0; next }
  /^get_binary\(\) \{/ && !dg { emit(gbf); dg=1; sg=1; next }
  sg { if ($0 ~ /^}$/) sg=0; next }
  { print }
  END {
    if (!dh) { print "ERR: header block not found" > "/dev/stderr"; exit 3 }
    if (!dg) { print "ERR: get_binary() not found" > "/dev/stderr"; exit 4 }
  }
' "$LAUNCHER" > "$STAGE/bin/dosemu"
chmod 0755 "$STAGE/bin/dosemu"

# sanity: the source prefix must not leak into the relocatable launcher
if grep -Eq "(^|[^A-Za-z0-9_])$PREFIX(/|\"|$)" "$STAGE/bin/dosemu"; then
  echo "ERROR: relocatable launcher still references $PREFIX:" >&2
  grep -n "$PREFIX" "$STAGE/bin/dosemu" >&2 || true
  exit 1
fi

# --- pack the payload -------------------------------------------------------
log "Packing payload (tar.xz)"
( cd "$STAGE" && tar --owner=0 --group=0 --numeric-owner --sort=name -cf - . ) \
  | xz -9e -T0 > "$TMP/payload.tar.xz"
PSHA="$(sha256sum "$TMP/payload.tar.xz" | awk '{print $1}')"
log "Payload sha256: $PSHA"
log "Payload size:   $(du -h "$TMP/payload.tar.xz" | awk '{print $1}')"

# --- assemble the installer (stub + payload) --------------------------------
log "Assembling installer"
cat > "$TMP/stub.sh" <<'STUB_EOF'
#!/usr/bin/env bash
#
# dosemu2 self-contained installer (generated by scripts/make-self-installer.sh)
#
# A single file holding a complete, relocatable dosemu2 runtime plus this
# installer.  The installed tree is relocatable: move/copy it anywhere on a
# same-arch Linux and the launcher rediscovers its data from its own location.
#
# Needs system SDL2/ALSA/libslirp only for graphical/sound/network; headless
# terminal mode ("-td") has no extra runtime dependencies.
#
set -euo pipefail

PAYLOAD_MARKER="__DOSEMU2_PAYLOAD_BELOW__"
DOSEMU2_VERSION="@VERSION@"
PAYLOAD_SHA256="@SHA256@"
MANIFEST=".dosemu2-manifest"

prog="$(basename "$0")"

usage() {
  cat <<EOF
dosemu2 ${DOSEMU2_VERSION} installer

Usage:
  ${prog} --install-dir DIR [--link-bin DIR] [--force]
  ${prog} --uninstall --install-dir DIR
  ${prog} --check

Options:
  --install-dir DIR    Where to install (created if missing).         [required]
  --link-bin DIR       Also symlink the 'dosemu' launcher into DIR.
  --force              Overwrite a non-empty install directory.
  --uninstall          Remove a previous install at --install-dir.
  --check              Verify the embedded payload checksum and exit.
  -h, --help           Show this help.

Examples:
  ${prog} --install-dir ~/dosemu2 --link-bin ~/.local/bin
  ~/dosemu2/bin/dosemu -td -E "dir"
  ${prog} --uninstall --install-dir ~/dosemu2
EOF
}

MODE=install
INSTALL_DIR=""
LINK_BIN=""
FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --install-dir) INSTALL_DIR="${2:?--install-dir needs an argument}"; shift 2;;
    --install-dir=*) INSTALL_DIR="${1#*=}"; shift;;
    --link-bin) LINK_BIN="${2:?--link-bin needs an argument}"; shift 2;;
    --link-bin=*) LINK_BIN="${1#*=}"; shift;;
    --force) FORCE=1; shift;;
    --uninstall) MODE=uninstall; shift;;
    --check) MODE=check; shift;;
    -h|--help) usage; exit 0;;
    *) echo "${prog}: unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done

SELF="$(readlink -f "$0")"
PAYLOAD_LINE="$(awk -v m="$PAYLOAD_MARKER" '$0==m{print NR+1; exit}' "$SELF")"
[ -n "${PAYLOAD_LINE:-}" ] || { echo "${prog}: corrupt installer (no payload marker)" >&2; exit 1; }
extract_payload() { tail -n +"$PAYLOAD_LINE" "$SELF"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "${prog}: required tool '$1' not found" >&2; exit 1; }; }

verify_checksum() {
  # a real sha256 is 64 hex chars; an unsubstituted placeholder still has '@'
  case "$PAYLOAD_SHA256" in *@*) return 0;; esac
  command -v sha256sum >/dev/null 2>&1 || return 0
  local got
  got="$(extract_payload | sha256sum | awk '{print $1}')"
  if [ "$got" != "$PAYLOAD_SHA256" ]; then
    echo "${prog}: payload checksum mismatch (expected $PAYLOAD_SHA256, got $got)" >&2
    exit 1
  fi
}

remove_fonts_link() {
  local fl="$HOME/.fonts/dosemu2" tgt
  if [ -L "$fl" ]; then
    tgt="$(readlink -f "$fl" 2>/dev/null || true)"
    case "$tgt" in "$1"/*) rm -f "$fl"; echo ">> Removed font link $fl";; esac
  fi
}

do_uninstall() {
  [ -n "$INSTALL_DIR" ] || { echo "${prog}: --uninstall needs --install-dir" >&2; exit 2; }
  [ -d "$INSTALL_DIR" ] || { echo "${prog}: not a directory: $INSTALL_DIR" >&2; exit 1; }
  INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
  local man="$INSTALL_DIR/$MANIFEST"
  echo ">> Uninstalling dosemu2 from ${INSTALL_DIR}"
  if [ -f "$man" ]; then
    local line rel
    # remove recorded symlinks (e.g. --link-bin) and files first
    while IFS= read -r line; do
      case "$line" in
        '#'*) ;;
        '@LINK '*) rel="${line#@LINK }"; [ -L "$rel" ] && rm -f "$rel";;
        */) ;;                                   # directory, handled below
        ?*) rel="${line#./}"; rm -f "$INSTALL_DIR/$rel";;
      esac
    done < "$man"
    remove_fonts_link "$INSTALL_DIR"
    # remove directories deepest-first (only if they end up empty)
    { grep '/$' "$man" 2>/dev/null || true; } | sed 's#^\./##' | awk '{print length, $0}' \
      | sort -rn | cut -d' ' -f2- | while read -r rel; do
        rmdir "$INSTALL_DIR/$rel" 2>/dev/null || true
      done
    rm -f "$man"
  else
    echo ">> No manifest; removing known dosemu2 components only"
    remove_fonts_link "$INSTALL_DIR"
    local p
    for p in bin/dosemu bin/mkfatimage16 lib/dosemu lib/fdpp \
             lib/libdosemu2.so lib/libdosemu2.so.* libexec/dosemu2 \
             share/dosemu share/fdpp share/comcom share/comcom32 share/comcom64; do
      rm -rf "$INSTALL_DIR"/$p
    done
  fi
  rmdir "$INSTALL_DIR" 2>/dev/null || true
  echo ">> Uninstalled."
}

need tar; need xz; need tail; need awk

case "$MODE" in
  check)
    verify_checksum
    echo "Payload OK (sha256 ${PAYLOAD_SHA256})"
    exit 0;;
  uninstall)
    do_uninstall
    exit 0;;
esac

# --- install ----------------------------------------------------------------
[ -n "$INSTALL_DIR" ] || { echo "${prog}: --install-dir is required" >&2; usage >&2; exit 2; }
if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR" ]; then
  echo "${prog}: $INSTALL_DIR exists and is not a directory" >&2; exit 1
fi
if [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ] && [ "$FORCE" -ne 1 ]; then
  echo "${prog}: $INSTALL_DIR is not empty (use --force)" >&2; exit 1
fi
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"

verify_checksum
echo ">> Installing dosemu2 ${DOSEMU2_VERSION} into ${INSTALL_DIR}"
extract_payload | tar -xJf - -C "$INSTALL_DIR"

LAUNCHER="$INSTALL_DIR/bin/dosemu"
[ -x "$LAUNCHER" ] || { echo "${prog}: extraction failed (no $LAUNCHER)" >&2; exit 1; }

# write uninstall manifest (table of contents + any link we create)
{
  echo "# dosemu2 installer manifest v1"
  echo "# version: ${DOSEMU2_VERSION}"
  extract_payload | tar -tJf -
  [ -n "$LINK_BIN" ] && echo "@LINK $(cd "$LINK_BIN" 2>/dev/null && pwd || echo "$LINK_BIN")/dosemu"
} > "$INSTALL_DIR/$MANIFEST"

if [ -n "$LINK_BIN" ]; then
  mkdir -p "$LINK_BIN"
  ln -sf "$LAUNCHER" "$LINK_BIN/dosemu"
  echo ">> Linked $LINK_BIN/dosemu -> $LAUNCHER"
fi

cat <<EOF

>> Done. dosemu2 ${DOSEMU2_VERSION} installed at:
       ${INSTALL_DIR}

   Run it:
       ${LAUNCHER} -td -E "dir"     # headless: run one DOS command
       ${LAUNCHER}                   # interactive

   Uninstall:
       $0 --uninstall --install-dir ${INSTALL_DIR}
EOF
if [ -n "$LINK_BIN" ]; then
  case ":$PATH:" in
    *":$LINK_BIN:"*) echo "   ('dosemu' is on your PATH via $LINK_BIN)";;
    *) echo "   Add to PATH:  export PATH=\"$LINK_BIN:\$PATH\"";;
  esac
fi
echo
exit 0
__DOSEMU2_PAYLOAD_BELOW__
STUB_EOF

# substitute version + checksum into the stub, then append the binary payload
sed -e "s#@VERSION@#${VERSION}#g" -e "s#@SHA256@#${PSHA}#g" "$TMP/stub.sh" > "$TMP/installer.sh"
cat "$TMP/installer.sh" "$TMP/payload.tar.xz" > "$OUTPUT"
chmod 0755 "$OUTPUT"

log "Installer ready: $OUTPUT ($(du -h "$OUTPUT" | awk '{print $1}'))"
