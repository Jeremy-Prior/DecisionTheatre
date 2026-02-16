#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# GeoPackage → Vector MBTiles conversion pipeline
# ============================================================
#
# USAGE
# -----
# ./gpkg_to_mbtiles.sh input.gpkg [fix_geometry:false]
#
# Examples:
#   ./gpkg_to_mbtiles.sh UoW_layers.gpkg
#   ./gpkg_to_mbtiles.sh UoW_layers.gpkg true
#
# ARGUMENTS
# ---------
# input.gpkg        Required GeoPackage file
# fix_geometry      Optional: true/false (default: false)
#
# OUTPUT
# ------
# Stages output in resources/mbtiles/africa.mbtiles during processing,
# then moves to data/mbtiles/africa.mbtiles on completion.
#
# WHAT THIS SCRIPT DOES
# ---------------------
# 1. Verifies required dependencies (GDAL, tippecanoe, sqlite3)
# 2. Detects all feature layers from gpkg_contents
# 3. Checks for NULL geometries
# 4. Optionally fixes geometries using ogr2ogr -makevalid
# 5. Exports each layer to GeoJSONSeq
# 6. Builds ONE MBTiles PER LAYER (layer-specific zoom levels)
# 7. Merges them using tile-join
#
# ============================================================


# -----------------------------
# LOGGING
# -----------------------------
info()  { echo "ℹ️  $1"; }
warn()  { echo "⚠️  $1"; }
error() { echo "❌ $1" >&2; exit 1; }


# -----------------------------
# DEPENDENCY CHECK (OS-AWARE)
# -----------------------------
install_deps() {
  if command -v apt >/dev/null 2>&1; then
    sudo apt update
    sudo apt install -y gdal-bin sqlite3 tippecanoe
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y gdal sqlite tippecanoe
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm gdal sqlite tippecanoe
  elif command -v nix-env >/dev/null 2>&1; then
    nix-env -iA nixpkgs.gdal nixpkgs.sqlite nixpkgs.tippecanoe
  elif command -v brew >/dev/null 2>&1; then
    brew install gdal sqlite tippecanoe
  else
    warn "Could not detect package manager."
    warn "Please install manually: gdal sqlite tippecanoe"
  fi
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "$1 not found — attempting install"
    install_deps
  }
}

ensure_cmd ogr2ogr
ensure_cmd sqlite3
ensure_cmd tippecanoe
ensure_cmd tile-join

info "GDAL version: $(ogrinfo --version)"


# -----------------------------
# INPUT ARGUMENTS
# -----------------------------
INPUT_GPKG="${1:-}"
FIX_GEOMETRY="${2:-false}"

# Output paths - stage in resources, final destination in data/mbtiles
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STAGING_MBTILES="$SCRIPT_DIR/africa.mbtiles"
FINAL_MBTILES="$PROJECT_ROOT/data/mbtiles/africa.mbtiles"

[[ -z "$INPUT_GPKG" ]] && error "Usage: $0 input.gpkg [fix_geometry]"
[[ ! -f "$INPUT_GPKG" ]] && error "GeoPackage not found: $INPUT_GPKG"


# -----------------------------
# USER CONFIGURATION (ZOOMS)
# -----------------------------
declare -A LAYER_ZOOMS=(
  ["ne_african_countries"]="2 10"
  ["ne_10m_rivers"]="6 15"
  ["ne_10m_lakes"]="6 15"
  ["ecoregions"]="2 8"
  ["catchments_lev12"]="8 15"
  ["ne_10m_populated_places"]="6 15"
  ["WDPA_Feb2026_Public"]="6 15"
  ["Africa_Roads_Primary-Tertiary"]="6 15"
)

DEFAULT_ZOOMS="6 15"


# -----------------------------
# WORKDIR
# -----------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

VALIDATED_GPKG="$WORKDIR/validated.gpkg"
GEOJSON_DIR="$WORKDIR/geojson"
MBTILES_DIR="$WORKDIR/mbtiles"

mkdir -p "$GEOJSON_DIR" "$MBTILES_DIR"


# -----------------------------
# LAYER DISCOVERY
# -----------------------------
info "Detecting layers..."

MAP_LAYERS=$(sqlite3 -batch -noheader "$INPUT_GPKG" \
  "SELECT table_name FROM gpkg_contents WHERE data_type='features';")

[[ -z "$MAP_LAYERS" ]] && error "No feature layers found"

while read -r L; do echo "  - $L"; done <<< "$MAP_LAYERS"


# -----------------------------
# NULL GEOMETRY CHECK
# -----------------------------
FIX_REQUIRED=false
info "Checking for NULL geometries..."

while read -r LAYER; do
  NULL_COUNT=$(ogrinfo "$INPUT_GPKG" \
    -sql "SELECT COUNT(*) FROM \"$LAYER\" WHERE geometry IS NULL" \
    2>/dev/null | grep -Eo '[0-9]+' | tail -n1 || echo "0")

  if [[ "$NULL_COUNT" -gt 0 ]]; then
    warn "Layer '$LAYER' has $NULL_COUNT NULL geometries"
    FIX_REQUIRED=true
  else
    info "Layer '$LAYER' OK"
  fi
done <<< "$MAP_LAYERS"


# -----------------------------
# GEOMETRY FIX
# -----------------------------
if [[ "$FIX_GEOMETRY" == "true" ]] || [[ "$FIX_REQUIRED" == true ]]; then
  info "Fixing geometries..."
  ogr2ogr -f GPKG "$VALIDATED_GPKG" "$INPUT_GPKG" -makevalid
else
  cp "$INPUT_GPKG" "$VALIDATED_GPKG"
fi


# -----------------------------
# GEOMETRY COLUMN
# -----------------------------
get_geometry_column() {
  sqlite3 -batch -noheader "$1" \
    "SELECT column_name FROM gpkg_geometry_columns WHERE table_name='$2' LIMIT 1;"
}


# -----------------------------
# EXPORT TO GEOJSONSEQ
# -----------------------------
info "Exporting layers to GeoJSONSeq..."

while read -r LAYER; do
  OUT="$GEOJSON_DIR/$LAYER.jsonseq"
  GEOM_COL=$(get_geometry_column "$VALIDATED_GPKG" "$LAYER")

  if [[ -n "$GEOM_COL" ]]; then
    ogr2ogr -f GeoJSONSeq "$OUT" "$VALIDATED_GPKG" "$LAYER" \
      -nlt PROMOTE_TO_MULTI \
      -where "\"$GEOM_COL\" IS NOT NULL" || \
    ogr2ogr -f GeoJSONSeq "$OUT" "$VALIDATED_GPKG" "$LAYER" -nlt PROMOTE_TO_MULTI
  else
    ogr2ogr -f GeoJSONSeq "$OUT" "$VALIDATED_GPKG" "$LAYER" -nlt PROMOTE_TO_MULTI
  fi
done <<< "$MAP_LAYERS"


# -----------------------------
# BUILD PER-LAYER MBTILES
# -----------------------------
info "Building per-layer MBTiles..."

while read -r LAYER; do
  IN="$GEOJSON_DIR/$LAYER.jsonseq"
  OUT="$MBTILES_DIR/$LAYER.mbtiles"

  if [[ -n "${LAYER_ZOOMS[$LAYER]+x}" ]]; then
    read MINZ MAXZ <<< "${LAYER_ZOOMS[$LAYER]}"
  else
    read MINZ MAXZ <<< "$DEFAULT_ZOOMS"
  fi

  info "  → $LAYER (z$MINZ–z$MAXZ)"

  tippecanoe \
    -o "$OUT" \
    --force \
    --read-parallel \
    --layer="$LAYER" \
    --minimum-zoom="$MINZ" \
    --maximum-zoom="$MAXZ" \
    --simplification=10 \
    --simplification-at-maximum-zoom=0.2 \
    --no-tiny-polygon-reduction \
    "$IN"

done <<< "$MAP_LAYERS"


# -----------------------------
# MERGE MBTILES
# -----------------------------
info "Merging layers into final MBTiles..."

tile-join \
  -o "$STAGING_MBTILES" \
  --force \
  "$MBTILES_DIR"/*.mbtiles


# -----------------------------
# MOVE TO FINAL DESTINATION
# -----------------------------
info "Moving to final destination..."
mkdir -p "$(dirname "$FINAL_MBTILES")"
mv "$STAGING_MBTILES" "$FINAL_MBTILES"

info "✅ Done — MBTiles written to: $FINAL_MBTILES"
