#!/bin/sh
#
# prepare-wip-build.sh
#
# Universal setup script for pkgsrc + pkgsrc-wip source builds on
# NetBSD 10.x or 11.x. Auto-detects the running OS release and CPU
# architecture from the live filesystem (uname), so the same script
# runs unmodified on either version.
#
# What it does:
#   - Confirms root's login shell is safe (/bin/sh, not pkgsrc-managed)
#   - Bootstraps pkgsrc if not already bootstrapped
#   - Writes a minimal, binary-first /etc/mk.conf (DEPENDS_TARGET=
#     bin-install, UPDATE_TARGET=bin-install, BINPKG_SITES pointed at
#     the correct release-specific CDN path -- same approach used for
#     the Plasma6 build)
#   - Sets PKG_DBDIR consistently in every place pkg tools read it
#   - Installs pkgin and points it at the matching binary repo
#   - Installs core build tools and everyday utilities (git, vim,
#     gmake, autoconf/automake, pkgconf, tmux, etc.)
#   - Creates a bare `python3` symlink if only a versioned python3.NN
#     is installed (many WIP builds expect this)
#   - Clones pkgsrc-wip if missing, or updates it if already present
#   - Adds a UTF-8 locale export to root's profile (session-only; does
#     NOT force it into the build environment, since pkgsrc overrides
#     LANG/LC_ALL to C for every build regardless)
#   - Prints a reminder about stack/file-descriptor limits, since
#     several real WIP builds (Perl, Qt/CMake) need headroom beyond
#     NetBSD's conservative defaults
#
# Safe to re-run: existing /etc/mk.conf is backed up (not clobbered
# blindly), pkgsrc-wip is git-pulled rather than re-cloned if present,
# and package installs are idempotent.
#
# Usage:
#   ./prepare-wip-build.sh                  # auto-detect everything
#   ./prepare-wip-build.sh 10.1              # override release
#   ./prepare-wip-build.sh 10.1 amd64        # override release + arch
#
# Must be run as root.

set -e

# ---- 0. Must run as root ----
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root." >&2
    exit 1
fi

# ---- 1. Detect NetBSD version and architecture (or take overrides) ----
OS_REL="${1:-$(uname -r)}"
ARCH="${2:-$(uname -m)}"

echo "=========================================================="
echo " Target: NetBSD ${OS_REL} (${ARCH})"
echo "=========================================================="

BINPKG_URL="https://cdn.NetBSD.org/pub/pkgsrc/packages/NetBSD/${ARCH}/${OS_REL}"

echo "Checking binary package repo reachability at: ${BINPKG_URL}/All/"
if ftp -o /dev/null "${BINPKG_URL}/All/" 2>/dev/null; then
    echo "  OK: repo appears reachable."
else
    echo "  WARNING: could not verify ${BINPKG_URL}/All/ is reachable."
    echo "  This may be a transient network issue, or this release may"
    echo "  not have a binary package set under this exact path."
    echo "  Continuing anyway -- check BINPKG_SITES manually if builds"
    echo "  fail to fetch binary dependencies."
fi

# ---- 2. Confirm root's shell is safe (never pkgsrc-managed) ----
ROOT_SHELL=$(awk -F: '$1=="root"{print $NF}' /etc/master.passwd)
case "$ROOT_SHELL" in
    /usr/pkg/*)
        echo ""
        echo "WARNING: root's login shell is ${ROOT_SHELL} (pkgsrc-managed)."
        echo "If /usr/pkg is ever wiped (a bad bulk build, a botched"
        echo "'pkg_delete *', etc.) this locks root out entirely except"
        echo "via single-user boot. Switching root to /bin/sh now."
        usermod -s /bin/sh root
        ;;
    *)
        echo "root shell (${ROOT_SHELL}) already safe."
        ;;
esac

# ---- 3. Bootstrap pkgsrc if not already done ----
if [ ! -x /usr/pkg/bin/bmake ]; then
    echo ""
    echo "pkgsrc not bootstrapped yet -- bootstrapping now..."
    mkdir -p /usr/src
    if [ ! -d /usr/pkgsrc/bootstrap ]; then
        echo "ERROR: /usr/pkgsrc/bootstrap not found." >&2
        echo "Is the pkgsrc tree present at /usr/pkgsrc?" >&2
        exit 1
    fi
    NPROC=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)
    (
        cd /usr/pkgsrc/bootstrap
        ./bootstrap --prefix=/usr/pkg --pkgdbdir=/usr/pkg/pkgdb \
            --make-jobs="${NPROC}"
    )
else
    echo "pkgsrc already bootstrapped, skipping."
fi

PATH="/usr/pkg/bin:/usr/pkg/sbin:${PATH}"
export PATH

# ---- 4. Consistent PKG_DBDIR everywhere pkg tools read it ----
echo "PKG_DBDIR=/usr/pkg/pkgdb" > /etc/pkg_install.conf
mkdir -p /usr/pkg/etc
echo "PKG_DBDIR=/usr/pkg/pkgdb" > /usr/pkg/etc/pkg_install.conf

# ---- 5. Minimal, stable /etc/mk.conf (binary-first, no build-debug cruft) ----
if [ -f /etc/mk.conf ]; then
    BACKUP="/etc/mk.conf.bak.$(date +%Y%m%d%H%M%S)"
    cp /etc/mk.conf "$BACKUP"
    echo "Existing /etc/mk.conf backed up to ${BACKUP}"
fi

NJOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 2)

cat > /etc/mk.conf << EOF
PKG_DBDIR=      /usr/pkg/pkgdb

MAKE_JOBS=      ${NJOBS}

DEPENDS_TARGET= bin-install
UPDATE_TARGET=  bin-install
BINPKG_SITES=   ${BINPKG_URL}
EOF

echo ""
echo "/etc/mk.conf written:"
cat /etc/mk.conf

# ---- 6. Install pkgin (needs PKG_PATH only transiently, for this one
#          bootstrap pkg_add call -- PKG_PATH is NOT exported into the
#          persistent shell environment, since bsd.pkg.mk refuses to
#          run any bmake build while PKG_PATH is set) ----
if ! command -v pkgin >/dev/null 2>&1; then
    echo ""
    echo "Installing pkgin (bootstrap via PKG_PATH, this step only)..."
    PKG_PATH="/usr/pkgsrc/packages/All;${BINPKG_URL}/All" pkg_add pkgin
else
    echo "pkgin already installed, skipping bootstrap."
fi

# ---- 7. Point pkgin at the matching binary repo ----

mkdir -p /usr/pkg/etc/pkgin
cat > /usr/pkg/etc/pkgin/repositories.conf << EOF
${BINPKG_URL}/All
EOF

echo ""
echo "Updating pkgin repo cache..."
pkgin -y update

# ---- 8. Core build tools + everyday utilities ----
PACKAGES="git vim mktools bootstrap-mk-files cwrappers digest gmake \
autoconf automake libtool-base pkgconf python313 tmux less"

echo ""
echo "Installing core packages:"
echo "  ${PACKAGES}"
# shellcheck disable=SC2086
pkgin -y install ${PACKAGES}

# ---- 9. Bare python3 symlink (many WIP builds expect this).
#         Sort by version, not alphabetically -- head -n1 on an
#         unsorted glob can pick python3.11 over a newer python3.13. ----
if [ ! -e /usr/pkg/bin/python3 ]; then
    PY=$(ls /usr/pkg/bin/python3.* 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$PY" ]; then
        ln -s "$PY" /usr/pkg/bin/python3
        echo "Created python3 -> ${PY} symlink."
    fi
fi

# ---- 9b. Bare pyrcc5 / pyuic5 symlinks. Several PyQt5-based WIP
#          builds (e.g. audio/carla) auto-detect PyQt5 support via
#          `which pyrcc5` / `which pyuic5` -- a bare name on PATH,
#          not the versioned binary NetBSD's py-qt5 package actually
#          installs (pyrcc5-3.13, pyuic5-3.13, ...). Without this,
#          such builds silently fall back to a broken/incomplete
#          non-GUI variant instead of erroring clearly. ----
for tool in pyrcc5 pyuic5; do
    if [ ! -e "/usr/pkg/bin/${tool}" ]; then
        REAL=$(ls /usr/pkg/bin/${tool}-3.* 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$REAL" ]; then
            ln -s "$REAL" "/usr/pkg/bin/${tool}"
            echo "Created ${tool} -> ${REAL} symlink."
        fi
    fi
done

# ---- 10. Clone or update pkgsrc-wip ----
echo ""
if [ ! -d /usr/pkgsrc/wip ]; then
    echo "Cloning pkgsrc-wip..."
    (cd /usr/pkgsrc && git clone https://github.com/NetBSD/pkgsrc-wip.git wip)
else
    echo "Updating existing pkgsrc-wip checkout..."
    (cd /usr/pkgsrc/wip && git pull --ff-only) || \
        echo "  (git pull failed -- check for local changes/conflicts manually)"
fi

# ---- 11. UTF-8 locale for interactive session use (not forced into builds) ----
if locale -a 2>/dev/null | grep -qi '^en_US\.UTF-8$'; then
    if ! grep -q 'en_US.UTF-8' /root/.profile 2>/dev/null; then
        {
            echo 'export LANG=en_US.UTF-8'
            echo 'export LC_ALL=en_US.UTF-8'
        } >> /root/.profile
        echo "Added en_US.UTF-8 export to /root/.profile."
    fi
else
    echo "en_US.UTF-8 locale not found on this system -- skipping."
fi

# ---- 12. Reminder about resource limits for heavy builds ----
echo ""
echo "NOTE: some WIP builds (Perl's Unicode table generation, Qt/CMake"
echo "codegen) need more stack and open-file headroom than NetBSD's"
echo "conservative defaults. If a build dies with 'stack overflow"
echo "detected' on the console or file-descriptor errors, raise these"
echo "in /etc/login.conf for the 'default' class, then 'cap_mkdb"
echo "/etc/login.conf' and re-login (login-class limits apply at"
echo "login time, not mid-session):"
echo "    :stacksize-cur=256M:\\"
echo "    :stacksize-max=256M:\\"
echo "    :openfiles-cur=4096:\\"
echo "    :openfiles-max=4096:\\"

echo ""
echo "=========================================================="
echo " Done. NetBSD ${OS_REL} (${ARCH}) is prepared for pkgsrc"
echo " and pkgsrc-wip source builds, binary-first."
echo ""
echo "  PKG_DBDIR:    /usr/pkg/pkgdb"
echo "  BINPKG_SITES: ${BINPKG_URL}"
echo "  pkgsrc-wip:   /usr/pkgsrc/wip"
echo "  mk.conf:      /etc/mk.conf"
echo ""
echo " Note: PKG_PATH is intentionally NOT set persistently (it"
echo " conflicts with bmake builds -- see mk.conf/BINPKG_SITES for"
echo " the binary-first build path instead). For a one-off manual"
echo " 'pkg_add <pkg>' you can prefix it per-command:"
echo "   PKG_PATH=\"/usr/pkgsrc/packages/All;${BINPKG_URL}/All\" pkg_add <pkg>"
echo ""
echo " Re-login (or 'source /root/.profile') to pick up any PATH"
echo " changes in this shell."
echo "=========================================================="
