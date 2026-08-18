#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$HOME/.local/share/aipulse"
SCRIPTS_DIR="$REPO_DIR/scripts"
APPS_DIR="/Applications"
APP_NAME="AIPulse"
BUNDLE_ID="cz.chuchy.aipulse"
LAUNCHD_LABEL="cz.chuchy.aipulse-collect"

echo "=== AIPulse Install ==="
echo ""

# 1. Create data directory
echo "1. Creating $DATA_DIR..."
mkdir -p "$DATA_DIR"

# 2. Copy scripts
echo "2. Installing scripts to $DATA_DIR..."
for script in collect.sh login.py set-interval.sh refresh-limits.sh apply-limits.py fetch-usage.py; do
    # A missing script leaves a half-working install behind, so stop instead of warning.
    if [[ ! -f "$SCRIPTS_DIR/$script" ]]; then
        echo "ERROR: $SCRIPTS_DIR/$script not found"
        exit 1
    fi
    cp "$SCRIPTS_DIR/$script" "$DATA_DIR/$script"
    chmod +x "$DATA_DIR/$script"
    echo "   - $script installed"
done

# 3. Migrate user data if it exists
if [[ -d "$HOME/.local/share/usagebar" ]]; then
    echo "3. Migrating data from old location..."
    if [[ -f "$HOME/.local/share/usagebar/config.json" ]] && [[ ! -f "$DATA_DIR/config.json" ]]; then
        cp "$HOME/.local/share/usagebar/config.json" "$DATA_DIR/config.json"
        echo "   - config.json migrated"
    fi
    if [[ -f "$HOME/.local/share/usagebar/data.json" ]] && [[ ! -f "$DATA_DIR/data.json" ]]; then
        cp "$HOME/.local/share/usagebar/data.json" "$DATA_DIR/data.json"
        echo "   - data.json migrated"
    fi
    echo "   - Old folder kept at ~/.local/share/usagebar (not deleted)"
else
    echo "3. No existing data to migrate"
fi

# 4. Build the app
echo "4. Building AIPulse (this may take a moment)..."
cd "$REPO_DIR"
swift build -c release 2>&1 | grep -v "warning:" | tail -20 || true

BUILD_OUTPUT=$(swift build -c release 2>&1)
if echo "$BUILD_OUTPUT" | grep -q "error:"; then
    echo "ERROR: Build failed"
    echo "$BUILD_OUTPUT"
    exit 1
fi

BUILD_PRODUCT="$REPO_DIR/.build/release/$APP_NAME"
if [[ ! -f "$BUILD_PRODUCT" ]]; then
    echo "ERROR: Build product not found at $BUILD_PRODUCT"
    exit 1
fi

echo "   - Build successful"

# 5. Stop old app if running
echo "5. Stopping old application if running..."
if pgrep -x "UsageBar" > /dev/null 2>&1; then
    killall UsageBar 2>/dev/null || true
    sleep 1
fi
if pgrep -x "AIPulse" > /dev/null 2>&1; then
    killall AIPulse 2>/dev/null || true
    sleep 1
fi

# 6. Remove old app
echo "6. Removing old application..."
if [[ -d "/Applications/UsageBar.app" ]]; then
    rm -rf "/Applications/UsageBar.app"
    echo "   - Removed /Applications/UsageBar.app"
fi

# 7. Create app bundle
echo "7. Creating app bundle..."
APP_BUNDLE="$APPS_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_PRODUCT" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AIPulse</string>
    <key>CFBundleIdentifier</key>
    <string>cz.chuchy.aipulse</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AIPulse</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2025. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "   - Bundle created at $APP_BUNDLE"

# 8. Sign the app
echo "8. Code-signing application..."
# App icon
if [ -f "$REPO_DIR/Resources/AIPulse.icns" ]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources"
  cp "$REPO_DIR/Resources/AIPulse.icns" "$APP_BUNDLE/Contents/Resources/AIPulse.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AIPulse" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AIPulse" "$APP_BUNDLE/Contents/Info.plist"
  echo "  Icon installed"
fi

codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 | grep -v "replacing existing" || true
echo "   - Signed"

# 9. Unload old launchd job if exists
echo "9. Cleaning up old launchd job..."
OLD_LABEL="com.chuchy.usagebar-collect"
launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true

# 10. Create new launchd plist
echo "10. Installing launchd job..."
PLIST_PATH="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
mkdir -p "$(dirname "$PLIST_PATH")"

cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>KeepAlive</key>
	<false/>
	<key>Label</key>
	<string>$LAUNCHD_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$DATA_DIR/collect.sh</string>
	</array>
	<key>StandardErrorPath</key>
	<string>$DATA_DIR/stderr.log</string>
	<key>StandardOutPath</key>
	<string>$DATA_DIR/stdout.log</string>
	<key>StartInterval</key>
	<integer>300</integer>
</dict>
</plist>
PLIST

chmod 600 "$PLIST_PATH"
launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1 || true
if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/tmp/aipulse-bootstrap.err; then
  echo "  Launchd job loaded"
else
  echo "  Launchd job could not be loaded:"
  sed 's/^/    /' /tmp/aipulse-bootstrap.err
fi
rm -f /tmp/aipulse-bootstrap.err
echo "   - Launchd job installed (runs every 5 minutes)"

# 11. Launch the app
echo "11. Launching application..."
open "$APP_BUNDLE"
sleep 2

if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "   - Application is running"
else
    echo "ERROR: Application failed to start"
    exit 1
fi

# 12. Verify config migration
echo "12. Verifying configuration..."
if [[ -f "$DATA_DIR/config.json" ]]; then
    echo "   - Configuration file found"
    if grep -q '"workDays"' "$DATA_DIR/config.json"; then
        WORK_DAYS=$(grep -o '"workDays"[[:space:]]*:[[:space:]]*[0-9]*' "$DATA_DIR/config.json" | grep -o '[0-9]*' | tail -1)
        REFRESH_MINUTES=$(grep -o '"refreshMinutes"[[:space:]]*:[[:space:]]*[0-9]*' "$DATA_DIR/config.json" | grep -o '[0-9]*' | tail -1)
        echo "   - workDays: $WORK_DAYS, refreshMinutes: $REFRESH_MINUTES"
    fi
else
    echo "   - No configuration file (will use defaults)"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Application: $APP_BUNDLE"
echo "Data directory: $DATA_DIR"
echo "Launchd job: $LAUNCHD_LABEL"
echo "Scripts location: $DATA_DIR"
echo ""
echo "Next steps:"
echo "  • AIPulse is now installed and running"
echo "  • It will collect data every 5 minutes via launchd"
echo "  • Configuration at: $DATA_DIR/config.json"
echo "  • To uninstall: see the Uninstalling section of README.md - it removes"
echo "    the launchd plist too, which a plain rm would leave behind"
echo ""
