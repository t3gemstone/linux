#!/usr/bin/env bash
# Build an arm64 .deb from an out-of-tree/external module build.
#
# Usage: extmod-deb.sh <MOD dir relative to kernel tree> <KVER> [ARCH] [CROSS_COMPILE] [LOCALVERSION]
#
# The modules are installed under /lib/modules/<KVER>/updates/, which depmod
# prefers over in-tree modules. On install the package backs up any existing
# copy of the same module, then runs depmod.
set -euo pipefail

MOD="${1:?MOD missing}"
KVER="${2:?KVER missing}"
ARCH="${3:-arm64}"
CROSS_COMPILE="${4:-aarch64-linux-gnu-}"
LOCALVERSION="${5:--ti}"

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TOP"

case "$ARCH" in
	arm64) DEB_ARCH=arm64 ;;
	arm)   DEB_ARCH=armhf ;;
	*)     DEB_ARCH="$ARCH" ;;
esac

NAME="$(basename "$MOD" | tr '_[:upper:]' '-[:lower:]')"
PKG="gemstone-extmod-$NAME"
VERSION="${KVER%+}~gem$(date +%Y%m%d%H%M%S)"
OUT="$TOP/dist/deb"
ROOT="$OUT/$PKG"

rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$OUT"

make -j"$(nproc)" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" LOCALVERSION="$LOCALVERSION" -C "$TOP" M="$TOP/$MOD" \
	INSTALL_MOD_PATH="$ROOT" INSTALL_MOD_DIR=updates INSTALL_MOD_STRIP=1 modules_install

MODDIR="$ROOT/lib/modules/$KVER"
[ -d "$MODDIR/updates" ] || { echo "no modules installed for $KVER" >&2; exit 1; }

# depmod metadata belongs to the target, not to the package
rm -f "$MODDIR"/modules.* "$MODDIR/build" "$MODDIR/source"

# manifest of shipped module file names (used by preinst for backups)
MANIFEST_DIR="usr/share/$PKG"
mkdir -p "$ROOT/$MANIFEST_DIR"
(cd "$MODDIR/updates" && find . -type f -name '*.ko*' -printf '%f\n' | sort) > "$ROOT/$MANIFEST_DIR/modules.list"
MANIFEST_LIST="$ROOT/$MANIFEST_DIR/modules.list"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: $(git config user.name 2>/dev/null || echo unknown) <$(git config user.email 2>/dev/null || echo unknown@localhost)>
Depends: kmod
Section: kernel
Priority: optional
Description: $NAME kernel modules for $KVER (Gemstone)
 Out-of-tree rebuild of $MOD for kernel $KVER.
 Installed to /lib/modules/$KVER/updates/ so it overrides the in-tree copy.
 Previous copies are backed up to /var/backups/$PKG/ on install.
EOF

cat > "$ROOT/DEBIAN/preinst" <<EOF
#!/bin/sh
set -e
KVER="$KVER"
PKG="$PKG"
MODULES="$(cat "$MANIFEST_LIST")"
case "\$1" in
install|upgrade)
	if [ "\$(uname -r)" != "\$KVER" ]; then
		echo "WARNING: package built for \$KVER, running kernel is \$(uname -r)" >&2
	fi
	if [ -d "/lib/modules/\$KVER" ]; then
		BK="/var/backups/\$PKG/\$(date +%Y%m%d%H%M%S)"
		while read -r f; do
			[ -n "\$f" ] || continue
			find "/lib/modules/\$KVER" -type f -name "\$f" | while read -r src; do
				dst="\$BK\${src#/lib/modules/\$KVER}"
				mkdir -p "\$(dirname "\$dst")"
				cp -a "\$src" "\$dst"
				echo "backed up \$src -> \$dst"
			done
		done <<LIST
\$MODULES
LIST
	fi
	;;
esac
exit 0
EOF

cat > "$ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
	depmod -a "$KVER"
fi
exit 0
EOF

cat > "$ROOT/DEBIAN/postrm" <<EOF
#!/bin/sh
set -e
case "\$1" in
remove|purge)
	[ -d "/lib/modules/$KVER" ] && depmod -a "$KVER"
	;;
esac
exit 0
EOF

chmod 0755 "$ROOT"/DEBIAN/preinst "$ROOT"/DEBIAN/postinst "$ROOT"/DEBIAN/postrm

DEB="$OUT/${PKG}_${VERSION}_${DEB_ARCH}.deb"
fakeroot dpkg-deb --build -Zxz "$ROOT" "$DEB"
echo
echo "Created: $DEB"
dpkg-deb -c "$DEB" | grep -E '\.ko' || true
