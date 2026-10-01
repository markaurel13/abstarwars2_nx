#!/bin/sh
# Build abstarwars2_nx.nro (the launcher) with the runtime's launcher build
# (devkitPro's 64-bit toolchain container).
HERE="$(cd "$(dirname "$0")" && pwd)"
LAUNCHER_DIR="$HERE" PAYLOAD=abstarwars2_nx exec "$HERE/../runtime/launcher/build.sh" "$@"
