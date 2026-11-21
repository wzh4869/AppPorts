#!/bin/bash
set -euo pipefail

# Build the portal's executable from source before Xcode copies resources.
appports_launcher_source="$SRCROOT/Tools/StubLauncher/StubLauncherSource.swift"
appports_launcher_output="$SCRIPT_OUTPUT_FILE_0"
appports_launcher_work="$SCRIPT_OUTPUT_FILE_1"
mkdir -p "$appports_launcher_work"
cp "$appports_launcher_source" "$appports_launcher_work/main.swift"

for appports_launcher_arch in arm64 x86_64; do
  xcrun --sdk macosx swiftc \
    -target "$appports_launcher_arch-apple-macos${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
    -sdk "$SDKROOT" \
    -module-cache-path "$appports_launcher_work/ModuleCache" \
    -O "$appports_launcher_work/main.swift" "$SRCROOT/AppPorts/Utils/ApplicationLaunchGate.swift" \
    "$SRCROOT/AppPorts/Utils/PortalLocalizedStrings.swift" \
    "$SRCROOT/AppPorts/Utils/TauriUpdateSupport.swift" \
    -o "$appports_launcher_work/$appports_launcher_arch"
done

xcrun lipo -create \
  "$appports_launcher_work/arm64" \
  "$appports_launcher_work/x86_64" \
  -output "$appports_launcher_output"
chmod 755 "$appports_launcher_output"
