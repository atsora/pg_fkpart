#!/usr/bin/env bash
#
# Build the Debian packages postgresql-<N>-pg-fkpart of the pg_fkpart extension,
# one package per PostgreSQL major version.
#
# See packaging/README.md for the details.

set -euo pipefail

# dpkg-deb requires the package directories to be between 0755 and 0775
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
CHANGELOG="$SOURCE_DIR/debian/changelog"

OUTPUT_DIR="$SOURCE_DIR/build"
PG_VERSIONS=""
NEW_VERSION=""
MESSAGE=""
INSTALL_DEPS=0
LINTIAN=1

usage () {
  cat <<EOF
Usage: $(basename "$0") [options]

Build the Debian packages postgresql-<N>-pg-fkpart from the current source tree.

Options:
  -p, --pg-versions "V1 V2..."  PostgreSQL major versions to build the packages for,
                                for example "12 17 18".
                                Default: all the versions with an installed pg_config
                                (/usr/lib/postgresql/<N>/bin/pg_config)
  -n, --new-version VERSION     Add a new entry to debian/changelog before building,
                                for example 1.8.0-1 (requires --message)
  -m, --message TEXT            Description of the new changelog entry
  -o, --output DIR              Build directory (default: $SOURCE_DIR/build)
  -d, --install-deps            Install the required Debian packages with apt (uses sudo)
  -L, --no-lintian              Do not run lintian after the build
  -h, --help                    Show this help

Examples:
  $(basename "$0") --install-deps --pg-versions "12 17 18"
  $(basename "$0") -p "17 18" -n 1.7.1-1 -m "Fix something"
EOF
}

log () {
  echo "==> $*"
}

die () {
  echo "ERROR: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--pg-versions) PG_VERSIONS="${2:?missing value for $1}"; shift 2 ;;
    -n|--new-version) NEW_VERSION="${2:?missing value for $1}"; shift 2 ;;
    -m|--message) MESSAGE="${2:?missing value for $1}"; shift 2 ;;
    -o|--output) OUTPUT_DIR="${2:?missing value for $1}"; shift 2 ;;
    -d|--install-deps) INSTALL_DEPS=1; shift ;;
    -L|--no-lintian) LINTIAN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option $1" ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  echo "WARNING: running as root is not necessary, sudo is only used to install the dependencies" >&2
fi

# 1. Dependencies
if [ "$INSTALL_DEPS" -eq 1 ]; then
  packages="devscripts build-essential postgresql-common postgresql-server-dev-all"
  for v in $PG_VERSIONS; do
    packages="$packages postgresql-server-dev-$v"
  done
  log "Install the dependencies: $packages"
  sudo apt-get update
  # shellcheck disable=SC2086
  sudo apt-get install -y $packages
fi

for cmd in dpkg-parsechangelog debuild dch pg_buildext; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "$cmd is missing, install the dependencies first (option --install-deps)"
done

# 2. PostgreSQL versions
if [ -z "$PG_VERSIONS" ]; then
  for pg_config in /usr/lib/postgresql/*/bin/pg_config; do
    [ -x "$pg_config" ] || continue
    v=$(basename "$(dirname "$(dirname "$pg_config")")")
    PG_VERSIONS="$PG_VERSIONS $v"
  done
  PG_VERSIONS=$(echo "$PG_VERSIONS" | tr ' ' '\n' | sed '/^$/d' | sort -V | tr '\n' ' ')
  PG_VERSIONS="${PG_VERSIONS% }"
  [ -n "$PG_VERSIONS" ] \
    || die "no PostgreSQL server development package found, install postgresql-server-dev-<N> or use --install-deps with --pg-versions"
fi
for v in $PG_VERSIONS; do
  [ -x "/usr/lib/postgresql/$v/bin/pg_config" ] \
    || die "/usr/lib/postgresql/$v/bin/pg_config not found, install postgresql-server-dev-$v"
done
log "PostgreSQL versions: $PG_VERSIONS"

# pg_buildext only considers the versions listed by
# /usr/share/postgresql-common/supported-versions, which honors this variable.
# This avoids editing /usr/share/postgresql-common/supported-versions when the
# distribution default version is not the one we target.
export PG_SUPPORTED_VERSIONS="$PG_VERSIONS"

# 3. Changelog
if [ -n "$NEW_VERSION" ]; then
  [ -n "$MESSAGE" ] || die "--new-version requires --message"
  export DEBFULLNAME="${DEBFULLNAME:-$(git -C "$SOURCE_DIR" config user.name || true)}"
  export DEBEMAIL="${DEBEMAIL:-$(git -C "$SOURCE_DIR" config user.email || true)}"
  [ -n "$DEBFULLNAME" ] && [ -n "$DEBEMAIL" ] \
    || die "set DEBFULLNAME and DEBEMAIL (or git user.name and user.email) for the changelog entry"
  log "Add the version $NEW_VERSION to debian/changelog"
  dch --changelog "$CHANGELOG" --newversion "$NEW_VERSION" \
    --distribution unstable --urgency low "$MESSAGE"
fi

PACKAGE=$(dpkg-parsechangelog -l "$CHANGELOG" -S Source)
FULL_VERSION=$(dpkg-parsechangelog -l "$CHANGELOG" -S Version)
UPSTREAM_VERSION="${FULL_VERSION%-*}"
log "Package $PACKAGE version $FULL_VERSION"

# Check the extension version matches the package version (1.7 <-> 1.7.0)
default_version=$(sed -n "s/^default_version *= *'\(.*\)'.*/\1/p" "$SOURCE_DIR/pg_fkpart.control")
case "$UPSTREAM_VERSION" in
  "$default_version"|"$default_version".*) ;;
  *) echo "WARNING: default_version $default_version in pg_fkpart.control does not match the package version $UPSTREAM_VERSION" >&2 ;;
esac

# 4. Source tree and orig archive
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
WORK_DIR="$OUTPUT_DIR/${PACKAGE}_${UPSTREAM_VERSION}"
SRC_NAME="$PACKAGE-$UPSTREAM_VERSION"
SRC_TREE="$WORK_DIR/$SRC_NAME"

log "Prepare the source tree in $SRC_TREE"
rm -rf "$WORK_DIR"
mkdir -p "$SRC_TREE"

# A file system without Unix permissions (Windows drive /mnt/c in WSL, CIFS share,
# VirtualBox shared folder...) makes dpkg-deb fail with 'bad permissions 777'
permission_test="$WORK_DIR/permission-test"
mkdir "$permission_test"
chmod 0755 "$permission_test"
permissions=$(stat -c %a "$permission_test")
rmdir "$permission_test"
[ "$permissions" = "755" ] \
  || die "the build directory $OUTPUT_DIR does not keep the Unix permissions (got $permissions instead of 755), choose a directory on a Linux file system, for example: --output ~/pg_fkpart-build"
# build is always excluded, it may contain the result of a previous build with
# another --output
excludes=(--exclude-vcs --exclude=./build --exclude=./debian/control --exclude='*.bak' --exclude='*~')
case "$OUTPUT_DIR" in
  "$SOURCE_DIR"/*) excludes+=("--exclude=./${OUTPUT_DIR#"$SOURCE_DIR"/}") ;;
esac
tar -C "$SOURCE_DIR" "${excludes[@]}" -cf - . | tar -C "$SRC_TREE" -xf -

# Normalize the permissions: on a Windows drive (/mnt/c in WSL) all the files
# are seen as executable
find "$SRC_TREE" -type d -exec chmod 0755 {} +
find "$SRC_TREE" -type f -exec chmod 0644 {} +
chmod 0755 "$SRC_TREE/debian/rules"
[ ! -f "$SRC_TREE/debian/tests/installcheck" ] || chmod 0755 "$SRC_TREE/debian/tests/installcheck"

# pg_buildext reads debian/pgversions with 'while read', which skips a last line
# without a final newline: no version would be found
pgversions="$SRC_TREE/debian/pgversions"
if [ -s "$pgversions" ] && [ -n "$(tail -c 1 "$pgversions")" ]; then
  echo >> "$pgversions"
fi

ORIG="$WORK_DIR/${PACKAGE}_${UPSTREAM_VERSION}.orig.tar.gz"
log "Create the archive $(basename "$ORIG")"
tar -C "$WORK_DIR" --anchored --exclude="$SRC_NAME/debian" -czf "$ORIG" "$SRC_NAME"

# 5. debian/control, generated from debian/control.in for each version
log "Generate debian/control"
(cd "$SRC_TREE" && pg_buildext updatecontrol)
for v in $PG_VERSIONS; do
  grep -q "^Package: postgresql-$v-$PACKAGE\$" "$SRC_TREE/debian/control" \
    || die "debian/control has no package for PostgreSQL $v, check debian/pgversions"
done

# 6. Build
log "Build the packages"
debuild_options=(--preserve-envvar=PG_SUPPORTED_VERSIONS)
[ "$LINTIAN" -eq 1 ] || debuild_options+=(--no-lintian)
(cd "$SRC_TREE" && debuild "${debuild_options[@]}" -us -uc)

# 7. Result
shopt -s nullglob
debs=("$WORK_DIR"/*.deb)
[ ${#debs[@]} -gt 0 ] || die "no .deb file was created in $WORK_DIR"
log "Created packages:"
for deb in "${debs[@]}"; do
  echo "  $deb"
done
if [ -n "$NEW_VERSION" ]; then
  log "Do not forget to commit debian/changelog"
fi
