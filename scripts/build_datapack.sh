#!/usr/bin/env bash
#
# Build the datapack geopackage from input files.
#
# Inputs (in data/ directory):
#   - catchments.gpkg  : Geopackage with catchment geometries
#   - current.csv      : Current scenario attribute data
#   - reference.csv    : Reference scenario attribute data
#   - medata.csv       : Column metadata
#
# Output:
#   - data/datapack.gpkg : Combined geopackage with all data
#

set -e

DATA_DIR="${1:-./data}"
OUTPUT="$DATA_DIR/datapack.gpkg"

echo "Building datapack from $DATA_DIR..."

# Check inputs exist
for f in catchments.gpkg current.csv reference.csv; do
    if [ ! -f "$DATA_DIR/$f" ]; then
        echo "Error: Missing $DATA_DIR/$f"
        exit 1
    fi
done

# Remove existing output
rm -f "$OUTPUT"

# Copy the catchments geopackage as the base
echo "Copying catchments.gpkg as base..."
cp "$DATA_DIR/catchments.gpkg" "$OUTPUT"

# Import CSV files as tables using ogr2ogr
echo "Importing current.csv..."
ogr2ogr -f GPKG -update "$OUTPUT" \
    -nln "scenario_current" \
    "$DATA_DIR/current.csv"

echo "Importing reference.csv..."
ogr2ogr -f GPKG -update "$OUTPUT" \
    -nln "scenario_reference" \
    "$DATA_DIR/reference.csv"

# Import metadata if it exists
if [ -f "$DATA_DIR/medata.csv" ]; then
    echo "Importing medata.csv..."
    ogr2ogr -f GPKG -update "$OUTPUT" \
        -nln "metadata" \
        "$DATA_DIR/medata.csv"
elif [ -f "$DATA_DIR/metadata.csv" ]; then
    echo "Importing metadata.csv..."
    ogr2ogr -f GPKG -update "$OUTPUT" \
        -nln "metadata" \
        "$DATA_DIR/metadata.csv"
fi

# Normalize column names to ensure both tables have identical structure
# The input CSVs may have different naming conventions (dots vs dashes/spaces)
# We normalize to dots (.) as the separator character
echo "Normalizing column names..."
python3 - "$OUTPUT" <<'NORMPY'
import sqlite3
import sys
import re

gpkg_path = sys.argv[1]
conn = sqlite3.connect(gpkg_path)
cur = conn.cursor()

def normalize_column_name(name):
    """Normalize column name: replace dashes, spaces, apostrophes, etc. with dots."""
    # Rename the main catchID column to 'catchment_id'
    if name == 'catchID':
        return 'catchment_id'
    # Drop duplicate sp_current.catchID and sp_reference$catchID columns (they have same data as catchID)
    if name in ('sp_current.catchID', 'sp_reference$catchID', 'sp_reference.catchID'):
        return None  # Signal to drop this column

    # Replace ' - ' with '.'
    # Replace '-' with '.'
    # Replace ' ' with '.'
    result = name.replace(' - ', '.')
    result = result.replace('-', '.')
    result = result.replace(' ', '.')
    # Also replace '$' with '.' for the sp_reference$catchID column
    result = result.replace('$', '.')
    # Handle apostrophe differences: 's vs .s (e.g., "Salt's" vs "Salt.s")
    # Normalize ' to . and also handle unicode apostrophes
    result = result.replace("'s", '.s')
    result = result.replace("'", '.')
    # Handle forward slashes
    result = result.replace('/', '.')
    # Handle + at end (Suids+)
    result = result.replace('+', '.')
    # Normalize multiple dots to a single dot (current.csv uses ... vs reference.csv uses .)
    # This handles cases like "browser.frugivores...closed" vs "browser.frugivores.closed"
    import re
    result = re.sub(r'\.{2,}', '.', result)
    return result

def rename_columns(table_name):
    """Rename columns in a table to use normalized names. Drops columns where normalize returns None."""
    cur.execute(f"PRAGMA table_info({table_name})")
    columns = [(row[1], row[2]) for row in cur.fetchall()]  # (name, type)

    renames = []
    drops = []
    for col_name, col_type in columns:
        new_name = normalize_column_name(col_name)
        if new_name is None:
            drops.append(col_name)
        elif new_name != col_name:
            renames.append((col_name, new_name))

    if not renames and not drops:
        print(f"  {table_name}: No columns need changes")
        return

    # SQLite doesn't support ALTER TABLE RENAME COLUMN in older versions
    # We need to recreate the table with new column names
    print(f"  {table_name}: Renaming {len(renames)} columns, dropping {len(drops)} columns...")

    # Build column mapping (excluding dropped columns)
    col_map = {old: new for old, new in renames}
    new_columns = []
    select_parts = []
    for col_name, col_type in columns:
        if col_name in drops:
            continue  # Skip dropped columns
        new_name = col_map.get(col_name, col_name)
        new_columns.append(f'"{new_name}" {col_type}')
        select_parts.append(f'"{col_name}" as "{new_name}"')

    # Create new table, copy data, drop old, rename new
    cur.execute(f"CREATE TABLE {table_name}_new ({', '.join(new_columns)})")
    cur.execute(f"INSERT INTO {table_name}_new SELECT {', '.join(select_parts)} FROM {table_name}")
    cur.execute(f"DROP TABLE {table_name}")
    cur.execute(f"ALTER TABLE {table_name}_new RENAME TO {table_name}")
    conn.commit()

    for old, new in renames[:5]:  # Show first 5
        print(f"    {old} -> {new}")
    if len(renames) > 5:
        print(f"    ... and {len(renames) - 5} more")

rename_columns("scenario_current")
rename_columns("scenario_reference")

# Verify both tables now have matching column names
cur.execute("PRAGMA table_info(scenario_current)")
current_cols = sorted([row[1] for row in cur.fetchall()])

cur.execute("PRAGMA table_info(scenario_reference)")
reference_cols = sorted([row[1] for row in cur.fetchall()])

# Check for mismatches
if current_cols == reference_cols:
    print(f"  Verified: Both tables have {len(current_cols)} matching columns")
else:
    current_set = set(current_cols)
    reference_set = set(reference_cols)
    only_current = current_set - reference_set
    only_reference = reference_set - current_set
    if only_current:
        print(f"  WARNING: Columns only in scenario_current: {list(only_current)[:5]}")
    if only_reference:
        print(f"  WARNING: Columns only in scenario_reference: {list(only_reference)[:5]}")

conn.close()
print("  Done normalizing column names")
NORMPY

# Create index on catchID columns for fast joins
# First, convert catchID to integer for proper indexing
echo "Creating indexes..."

# Drop SpatiaLite triggers that use functions we don't have
sqlite3 "$OUTPUT" <<EOF
DROP TRIGGER IF EXISTS rtree_catchments_lev12_geom_insert;
DROP TRIGGER IF EXISTS rtree_catchments_lev12_geom_update1;
DROP TRIGGER IF EXISTS rtree_catchments_lev12_geom_update2;
DROP TRIGGER IF EXISTS rtree_catchments_lev12_geom_update3;
DROP TRIGGER IF EXISTS rtree_catchments_lev12_geom_update4;
DROP TRIGGER IF EXISTS rtree_catchments_lev12_geom_delete;
DROP TRIGGER IF EXISTS trigger_insert_feature_count_catchments_lev12;
DROP TRIGGER IF EXISTS trigger_delete_feature_count_catchments_lev12;
EOF

sqlite3 "$OUTPUT" <<EOF
-- Add an integer catchment_id column for proper indexing
ALTER TABLE scenario_current ADD COLUMN catchment_id_int INTEGER;
UPDATE scenario_current SET catchment_id_int = CAST(catchment_id AS INTEGER);
CREATE INDEX IF NOT EXISTS idx_current_catchment_id_int ON scenario_current(catchment_id_int);

ALTER TABLE scenario_reference ADD COLUMN catchment_id_int INTEGER;
UPDATE scenario_reference SET catchment_id_int = CAST(catchment_id AS INTEGER);
CREATE INDEX IF NOT EXISTS idx_reference_catchment_id_int ON scenario_reference(catchment_id_int);

-- Also create an integer index on HYBAS_ID in catchments_lev12
ALTER TABLE catchments_lev12 ADD COLUMN HYBAS_ID_int INTEGER;
UPDATE catchments_lev12 SET HYBAS_ID_int = CAST(HYBAS_ID AS INTEGER);
CREATE INDEX IF NOT EXISTS idx_catchments_hybas_int ON catchments_lev12(HYBAS_ID_int);
EOF

# Add pre-computed GeoJSON column for fast serving
# This avoids expensive WKB-to-GeoJSON conversion at runtime
echo "Computing GeoJSON geometries..."
python3 - "$OUTPUT" <<'PYEOF'
import sqlite3
import sys
import json

gpkg_path = sys.argv[1]
conn = sqlite3.connect(gpkg_path)
cur = conn.cursor()

# Add geojson column if it doesn't exist
try:
    cur.execute("ALTER TABLE catchments_lev12 ADD COLUMN geojson TEXT")
except sqlite3.OperationalError:
    pass  # Column already exists

# Get all catchments with geometry
cur.execute("SELECT fid, geom FROM catchments_lev12 WHERE geom IS NOT NULL")
rows = cur.fetchall()

print(f"Converting {len(rows)} geometries to GeoJSON...")

def gpb_to_geojson(gpb):
    """Convert GeoPackage Binary to GeoJSON dict."""
    if len(gpb) < 8:
        return None
    # Check magic
    if gpb[0:2] != b'GP':
        return None

    # Get envelope type from flags
    flags = gpb[3]
    envelope_type = (flags >> 1) & 0x07

    envelope_sizes = {0: 0, 1: 32, 2: 48, 3: 48, 4: 64}
    envelope_size = envelope_sizes.get(envelope_type, 0)

    wkb_start = 8 + envelope_size
    if wkb_start >= len(gpb):
        return None

    wkb = gpb[wkb_start:]
    return wkb_to_geojson(wkb)

def wkb_to_geojson(wkb):
    """Convert WKB to GeoJSON dict."""
    if len(wkb) < 5:
        return None

    byte_order = wkb[0]
    big_endian = byte_order == 0

    if big_endian:
        geom_type = int.from_bytes(wkb[1:5], 'big')
    else:
        geom_type = int.from_bytes(wkb[1:5], 'little')

    base_type = geom_type & 0xFF

    if base_type == 3:  # Polygon
        return parse_polygon(wkb, big_endian)
    elif base_type == 6:  # MultiPolygon
        return parse_multipolygon(wkb, big_endian)
    return None

def read_float64(data, offset, big_endian):
    import struct
    fmt = '>d' if big_endian else '<d'
    return struct.unpack(fmt, data[offset:offset+8])[0]

def parse_polygon(wkb, big_endian):
    offset = 5
    if big_endian:
        num_rings = int.from_bytes(wkb[offset:offset+4], 'big')
    else:
        num_rings = int.from_bytes(wkb[offset:offset+4], 'little')
    offset += 4

    rings = []
    for _ in range(num_rings):
        if big_endian:
            num_points = int.from_bytes(wkb[offset:offset+4], 'big')
        else:
            num_points = int.from_bytes(wkb[offset:offset+4], 'little')
        offset += 4

        ring = []
        for _ in range(num_points):
            x = read_float64(wkb, offset, big_endian)
            y = read_float64(wkb, offset + 8, big_endian)
            offset += 16
            ring.append([x, y])
        rings.append(ring)

    return {"type": "Polygon", "coordinates": rings}

def parse_multipolygon(wkb, big_endian):
    offset = 5
    if big_endian:
        num_polygons = int.from_bytes(wkb[offset:offset+4], 'big')
    else:
        num_polygons = int.from_bytes(wkb[offset:offset+4], 'little')
    offset += 4

    polygons = []
    for _ in range(num_polygons):
        # Skip byte order and type for inner polygon
        offset += 5

        if big_endian:
            num_rings = int.from_bytes(wkb[offset:offset+4], 'big')
        else:
            num_rings = int.from_bytes(wkb[offset:offset+4], 'little')
        offset += 4

        rings = []
        for _ in range(num_rings):
            if big_endian:
                num_points = int.from_bytes(wkb[offset:offset+4], 'big')
            else:
                num_points = int.from_bytes(wkb[offset:offset+4], 'little')
            offset += 4

            ring = []
            for _ in range(num_points):
                x = read_float64(wkb, offset, big_endian)
                y = read_float64(wkb, offset + 8, big_endian)
                offset += 16
                ring.append([x, y])
            rings.append(ring)
        polygons.append(rings)

    return {"type": "MultiPolygon", "coordinates": polygons}

# Process in batches
batch_size = 1000
updates = []
for i, (fid, geom) in enumerate(rows):
    if geom:
        geojson = gpb_to_geojson(geom)
        if geojson:
            updates.append((json.dumps(geojson, separators=(',', ':')), fid))

    if len(updates) >= batch_size:
        cur.executemany("UPDATE catchments_lev12 SET geojson = ? WHERE fid = ?", updates)
        conn.commit()
        print(f"  Processed {i+1}/{len(rows)}...")
        updates = []

# Final batch
if updates:
    cur.executemany("UPDATE catchments_lev12 SET geojson = ? WHERE fid = ?", updates)
    conn.commit()

print(f"Done converting {len(rows)} geometries.")

# Restore the triggers (commented out - they use SpatiaLite functions we don't have)
# But since we're not modifying geometry, we don't need them for our use case
# for trig_name, trig_sql in saved_triggers.items():
#     if trig_sql:
#         try:
#             cur.execute(trig_sql)
#         except Exception as e:
#             print(f"Warning: could not restore trigger {trig_name}: {e}")
# conn.commit()

conn.close()
PYEOF

# Check the result
echo ""
echo "Created $OUTPUT"
echo "Layers:"
ogrinfo "$OUTPUT" 2>/dev/null | grep -E "^\d+:" || ogrinfo "$OUTPUT"

echo ""
echo "Done!"
