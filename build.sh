#!/bin/sh
# Build abstarwars2_nx.nsp in the AArch32 toolchain container: the runtime's
# docker_build.sh. libnx32 is found in libnx32/prefix, ../libnx32/prefix, or DCR_LIBNX32.
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ -d "$HERE/libnx32/prefix" ]; then
  export DCR_LIBNX32="$HERE/libnx32/prefix"
fi
exec "$HERE/runtime/tools/docker_build.sh" "$@"
