#!/bin/sh
#
# sddm-setup.sh - set up SDDM (pkgsrc) to start LXQt on NetBSD.
#
# Installs the pkgsrc example files (rc.d, pam.d, D-Bus policy) and a
# minimal sddm.conf. Never overwrites an existing file: if a destination
# exists it is left alone and reported. Does not edit /etc/rc.conf.
# At the end it prints the settings that matter so you can check them.
#
# Usage (as root): sh sddm-setup.sh

PREFIX=/usr/pkg
EX=$PREFIX/share/examples
SDDM_CONF=$PREFIX/etc/sddm.conf
DBUS_DIR=$PREFIX/etc/dbus-1/system.d
XSESS=$PREFIX/share/xsessions

ERRORS=0
WARNINGS=0
DBUS_POLICY_NEW=no

ok()   { echo "  OK    $*"; }
info() { echo "  --    $*"; }
warn() { echo "  WARN  $*"; WARNINGS=$((WARNINGS + 1)); }
err()  { echo "  ERROR $*"; ERRORS=$((ERRORS + 1)); }

# install_file SRC DST MODE
# Copy SRC to DST only if DST does not exist yet.
install_file() {
	src=$1 dst=$2 mode=$3
	if [ ! -f "$src" ]; then
		err "missing source $src"
		return 1
	fi
	if [ -e "$dst" ]; then
		if cmp -s "$src" "$dst"; then
			ok "$dst exists (same as example)"
		else
			warn "$dst exists and differs from $src, not touched"
		fi
		return 1
	fi
	mkdir -p "$(dirname "$dst")" &&
	cp "$src" "$dst" &&
	chmod "$mode" "$dst" &&
	ok "installed $dst" && return 0
	err "could not install $dst"
	return 1
}

# ini_get FILE SECTION KEY - print value of KEY in [SECTION], last one wins
ini_get() {
	awk -v sec="[$2]" -v key="$3" '
		/^[[:space:]]*\[/ { cur = $0; gsub(/[[:space:]]/, "", cur); next }
		cur == sec && index($0, key "=") == 1 {
			val = substr($0, length(key) + 2)
		}
		END { print val }
	' "$1"
}

# rc_get VAR - print value of VAR from /etc/rc.conf, last one wins
rc_get() {
	sed -n "s/^[[:space:]]*$1=//p" /etc/rc.conf | tail -n 1 | tr -d "\"'"
}

if [ "$(id -u)" -ne 0 ]; then
	echo "Run this as root." >&2
	exit 1
fi

echo "== Prerequisites"
if pkg_info -e sddm >/dev/null 2>&1; then
	ok "sddm package installed"
else
	err "sddm package not installed (pkgin install sddm)"
fi
if [ -x $PREFIX/sbin/daemonize ]; then
	ok "daemonize present"
else
	err "$PREFIX/sbin/daemonize missing (pkgin install daemonize)"
fi
if [ -x /usr/X11R7/bin/X ]; then
	ok "X server /usr/X11R7/bin/X (default ServerPath)"
elif [ -x $PREFIX/bin/X ]; then
	warn "only $PREFIX/bin/X found: set ServerPath=$PREFIX/bin/X in [X11]"
else
	err "no X server found"
fi
if grep -q '^sddm:' /etc/passwd; then
	ok "user sddm exists, home $(grep '^sddm:' /etc/passwd | cut -d: -f6)"
else
	err "user sddm missing (useradd -d /var/lib/sddm -s /sbin/nologin sddm)"
fi
if [ -f $XSESS/lxqt.desktop ]; then
	ok "$XSESS/lxqt.desktop present"
else
	err "$XSESS/lxqt.desktop missing (pkgin install lxqt)"
fi

if [ $ERRORS -ne 0 ]; then
	echo
	echo "Fix the errors above and run again. Nothing was changed."
	exit 1
fi

echo
echo "== Installing files"
install_file $EX/rc.d/sddm           /etc/rc.d/sddm           555
install_file $EX/pam.d/sddm          /etc/pam.d/sddm          644
install_file $EX/pam.d/sddm-autologin /etc/pam.d/sddm-autologin 644
install_file $EX/pam.d/sddm-greeter  /etc/pam.d/sddm-greeter  644
if install_file $EX/sddm/org.freedesktop.DisplayManager.conf \
    $DBUS_DIR/org.freedesktop.DisplayManager.conf 644; then
	DBUS_POLICY_NEW=yes
fi

if [ -d /var/lib/sddm ]; then
	ok "/var/lib/sddm exists"
else
	mkdir -p /var/lib/sddm && chmod 755 /var/lib/sddm &&
	chown sddm:sddm /var/lib/sddm && ok "created /var/lib/sddm"
fi

if [ -e $SDDM_CONF ]; then
	info "$SDDM_CONF exists, not touched (see checks below)"
else
	cat > $SDDM_CONF <<'CONF'
# Minimal SDDM config for LXQt on NetBSD.
# Everything not set here uses the built-in defaults
# (see: sddm --example-config).

[Autologin]
# Leave both empty for a normal login screen.
# For autologin: User=<your user> and Session=lxqt.desktop
User=
Session=

[General]
DisplayServer=x11
InputMethod=

[Users]
# pkgsrc system users have uid >= 1000; hide them by shell.
HideShells=/sbin/nologin,/usr/sbin/nologin
CONF
	chmod 644 $SDDM_CONF
	ok "created $SDDM_CONF"
fi

if [ $DBUS_POLICY_NEW = yes ]; then
	if /etc/rc.d/dbus status >/dev/null 2>&1; then
		/etc/rc.d/dbus restart && ok "restarted dbus to load new policy"
	else
		info "dbus not running, policy will load when it starts"
	fi
fi

echo
echo "== Checks: /etc/rc.conf"
v=$(rc_get dbus)
case $v in
	[Yy][Ee][Ss]) ok "dbus=$v" ;;
	*) warn "dbus=${v:-<unset>}, should be YES" ;;
esac
v=$(rc_get wscons)
case $v in
	[Yy][Ee][Ss]) ok "wscons=$v" ;;
	*) warn "wscons=${v:-<unset>}, should be YES" ;;
esac
v=$(rc_get sddm)
case $v in
	[Yy][Ee][Ss]) ok "sddm=$v (starts at boot)" ;;
	*) info "sddm=${v:-<unset>}: test with /etc/rc.d/sddm onestart, then set sddm=YES" ;;
esac

echo
echo "== Checks: $SDDM_CONF"
v=$(ini_get $SDDM_CONF General DisplayServer)
case ${v:-x11} in
	x11) ok "DisplayServer=${v:-<default x11>}" ;;
	*) warn "DisplayServer=$v, expected x11" ;;
esac
v=$(ini_get $SDDM_CONF General InputMethod)
if [ -z "$v" ]; then
	ok "InputMethod empty"
else
	warn "InputMethod=$v, should be empty"
fi
au=$(ini_get $SDDM_CONF Autologin User)
as=$(ini_get $SDDM_CONF Autologin Session)
if [ -n "$as" ] && [ ! -f "$XSESS/$as" ] && [ ! -f "$XSESS/$as.desktop" ]; then
	warn "Autologin Session=$as has no file in $XSESS (use lxqt.desktop)"
elif [ -n "$au" ]; then
	ok "autologin user=$au session=${as:-<last used>}"
else
	ok "autologin off"
fi
v=$(ini_get $SDDM_CONF Users HideShells)
case $v in
	*nologin*) ok "HideShells=$v" ;;
	*) warn "HideShells=${v:-<empty>}: system users will be listed" ;;
esac
v=$(ini_get $SDDM_CONF X11 ServerPath)
p=${v:-/usr/X11R7/bin/X}
if [ -x "$p" ]; then
	ok "ServerPath=$p"
else
	warn "ServerPath=$p is not executable"
fi

echo
echo "== Checks: sessions in $XSESS"
for f in $XSESS/*.desktop; do
	n=$(sed -n 's/^Name=//p' "$f" | head -n 1)
	info "$(basename "$f"): $n"
done

echo
echo "Done: $ERRORS error(s), $WARNINGS warning(s)."
echo "Test:  /etc/rc.d/sddm onestart   (stop: /etc/rc.d/sddm onestop)"
echo "Boot:  set sddm=YES in /etc/rc.conf"
