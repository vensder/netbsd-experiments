#!/bin/sh
# wine32-sandbox.sh
#
# Prepares and enters the wine32 sandbox on NetBSD:
#  - sets the sysctls wine needs
#  - refreshes the X11 auth cookie for the sandbox's wine user
#    (the old cookie goes stale every time your X session restarts)
#  - drops you into the sandbox as root, ready to "su -l wine"
#
# Run this after every reboot before using 32-bit wine apps.

set -e

SANDBOX_NAME=wine
SANDBOX_ROOT=/var/chroot/wine-i386
SANDBOX_USER=wine
SANDBOX_UID=1000
SANDBOX_GID=100

echo "Setting required sysctls..."
sudo sysctl -w vm.user_va0_disable=0 >/dev/null
sudo sysctl -w hw.audio0.multiuser=1 >/dev/null
sudo sysctl -w machdep.user_ldt=1 >/dev/null

echo "Refreshing X11 auth cookie for sandbox..."
XAUTH_TMP=/tmp/wine-sandbox-x0.xauth
/usr/X11R7/bin/xauth -f "$HOME/.Xauthority" extract - :0 > "$XAUTH_TMP"
sudo cp "$XAUTH_TMP" "$SANDBOX_ROOT/home/$SANDBOX_USER/.Xauthority"
sudo chown "$SANDBOX_UID:$SANDBOX_GID" "$SANDBOX_ROOT/home/$SANDBOX_USER/.Xauthority"
sudo chmod 600 "$SANDBOX_ROOT/home/$SANDBOX_USER/.Xauthority"
rm -f "$XAUTH_TMP"

echo "Ready. Entering sandbox as root."
echo "Once inside, run:"
echo "    su -l $SANDBOX_USER"
echo "    wine <program>"
echo ""

sudo sandboxctl -c "$SANDBOX_NAME" shell
