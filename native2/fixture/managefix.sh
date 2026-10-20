#!/bin/sh
# Builds the management fixture into two app bundles under $1 (default /tmp/dt2-manage): ManageFix.app, the one
# parity steps act on, and ManageQuit.app, which steps launch, open items in and quit.
set -e
out=${1:-/tmp/dt2-manage}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
swiftc -O "$here/managefix.swift" -o "$out/managefix"
for name in ManageFix ManageQuit; do
	app="$out/$name.app"
	rm -rf "$app"
	mkdir -p "$app/Contents/MacOS"
	cp "$out/managefix" "$app/Contents/MacOS/$name"
	cat >"$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>com.example.dt2.$(echo $name | tr A-Z a-z)</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSItemContentTypes</key><array><string>public.item</string></array></dict></array>
</dict></plist>
EOF
done
