#!/usr/bin/env bash
set -euo pipefail

# Build a data pack zip from local data/ and resources/ directories.
# Usage: ./scripts/build-datapack.sh [version]
#
# The resulting zip can be installed into Decision Theatre via the UI
# or by extracting it and pointing --data-dir / --resources-dir at it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-$(cd "$PROJECT_ROOT" && git describe --tags --always --dirty 2>/dev/null || echo "dev")}"
DIST_DIR="$PROJECT_ROOT/dist"
PACK_NAME="decision-theatre-data-v${VERSION}"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "Building data pack: $PACK_NAME"

# Validate required directories
if [ ! -d "$PROJECT_ROOT/resources/mbtiles" ]; then
    echo "ERROR: resources/mbtiles directory not found" >&2
    exit 1
fi

# Create pack structure
PACK_DIR="$WORK_DIR/$PACK_NAME"
mkdir -p "$PACK_DIR/data" "$PACK_DIR/resources"

# Copy resources (mbtiles, styles — exclude build scripts and source gpkg)
cp -r "$PROJECT_ROOT/resources/mbtiles" "$PACK_DIR/resources/"
# Remove build scripts and source files from the pack
rm -f "$PACK_DIR/resources/mbtiles/"*.sh
rm -f "$PACK_DIR/resources/mbtiles/"*.gpkg

# Copy data files if they exist
if [ -d "$PROJECT_ROOT/data" ] && [ "$(ls -A "$PROJECT_ROOT/data" 2>/dev/null)" ]; then
    cp -r "$PROJECT_ROOT/data/"* "$PACK_DIR/data/"
fi

# Generate manifest
cat > "$PACK_DIR/manifest.json" <<EOF
{
  "format": "decision-theatre-datapack",
  "version": "$VERSION",
  "description": "Decision Theatre Data Pack",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

# Create zip
mkdir -p "$DIST_DIR"
(cd "$WORK_DIR" && zip -r "$DIST_DIR/$PACK_NAME.zip" "$PACK_NAME")

# Generate checksum
(cd "$DIST_DIR" && sha256sum "$PACK_NAME.zip" > "$PACK_NAME.zip.sha256")

echo ""
echo "Data pack created:"
echo "  $DIST_DIR/$PACK_NAME.zip"
echo "  $DIST_DIR/$PACK_NAME.zip.sha256"
