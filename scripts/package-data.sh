#!/usr/bin/env bash
set -euo pipefail

# Build a data pack zip from local data/ directory.
# Usage: ./scripts/package-data.sh [version]
#
# The data pack bundles:
#   - MBTiles catchment map tiles (from data/mbtiles/)
#   - Tile style JSON
#   - GeoPackage datapack (if present)
#
# The resulting zip can be installed into Decision Theatre via the UI
# or by extracting it and pointing --data-dir at it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${1:-$(cd "$PROJECT_ROOT" && git describe --tags --always --dirty 2>/dev/null || echo "dev")}"
DIST_DIR="$PROJECT_ROOT/dist"
PACK_NAME="decision-theatre-data-v${VERSION}"
WORK_DIR="$(mktemp -d)"

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

echo "Building data pack: $PACK_NAME"
echo ""

# -------------------------------------------------------
# Step 1: Validate required resources
# -------------------------------------------------------
if [ ! -d "$PROJECT_ROOT/data/mbtiles" ]; then
    echo "ERROR: data/mbtiles directory not found" >&2
    exit 1
fi

if [ ! -f "$PROJECT_ROOT/data/mbtiles/africa.mbtiles" ]; then
    echo "ERROR: data/mbtiles/africa.mbtiles not found" >&2
    exit 1
fi

# -------------------------------------------------------
# Step 2: Assemble pack
# -------------------------------------------------------
PACK_DIR="$WORK_DIR/$PACK_NAME"
mkdir -p "$PACK_DIR/data/mbtiles"

# Copy mbtiles and style JSON (exclude build scripts and source gpkg)
echo "==> Bundling MBTiles and styles..."
cp "$PROJECT_ROOT/data/mbtiles/africa.mbtiles" "$PACK_DIR/data/mbtiles/"
echo "    africa.mbtiles ($(du -h "$PACK_DIR/data/mbtiles/africa.mbtiles" | cut -f1))"

if [ -f "$PROJECT_ROOT/data/mbtiles/style.json" ]; then
    cp "$PROJECT_ROOT/data/mbtiles/style.json" "$PACK_DIR/data/mbtiles/"
    echo "    style.json"
fi

if [ -f "$PROJECT_ROOT/data/mbtiles/uow_tiles.json" ]; then
    cp "$PROJECT_ROOT/data/mbtiles/uow_tiles.json" "$PACK_DIR/data/mbtiles/"
    echo "    uow_tiles.json"
fi

# Copy GeoPackage datapack if present
if [ -f "$PROJECT_ROOT/data/datapack.gpkg" ]; then
    echo "==> Bundling GeoPackage datapack..."
    cp "$PROJECT_ROOT/data/datapack.gpkg" "$PACK_DIR/data/"
    echo "    datapack.gpkg ($(du -h "$PACK_DIR/data/datapack.gpkg" | cut -f1))"
fi

# -------------------------------------------------------
# Step 3: Generate manifest
# -------------------------------------------------------
echo "==> Writing manifest..."
MBTILES_LIST=$(cd "$PACK_DIR/data/mbtiles" 2>/dev/null && ls *.mbtiles 2>/dev/null | jq -R -s 'split("\n") | map(select(length > 0))' || echo "[]")
GPKG_EXISTS="false"
if [ -f "$PACK_DIR/data/datapack.gpkg" ]; then
    GPKG_EXISTS="true"
fi
cat > "$PACK_DIR/manifest.json" <<EOF
{
  "format": "decision-theatre-datapack",
  "version": "$VERSION",
  "description": "Decision Theatre Data Pack — catchment scenario data and map tiles",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "contents": {
    "mbtiles": $MBTILES_LIST,
    "geopackage": $GPKG_EXISTS
  }
}
EOF

# -------------------------------------------------------
# Step 4: Create zip and checksum
# -------------------------------------------------------
echo "==> Creating zip archive..."
mkdir -p "$DIST_DIR"
(cd "$WORK_DIR" && zip -r "$DIST_DIR/$PACK_NAME.zip" "$PACK_NAME")

echo "==> Generating checksum..."
(cd "$DIST_DIR" && sha256sum "$PACK_NAME.zip" > "$PACK_NAME.zip.sha256")

echo ""
echo "Data pack created:"
echo "  $DIST_DIR/$PACK_NAME.zip ($(du -h "$DIST_DIR/$PACK_NAME.zip" | cut -f1))"
echo "  $DIST_DIR/$PACK_NAME.zip.sha256"
