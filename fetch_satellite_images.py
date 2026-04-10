#!/usr/bin/env python3
"""Fetch high-resolution satellite imagery using Esri World Imagery tiles."""

import math
import os
from io import BytesIO

import numpy as np
import requests
from PIL import Image, ImageDraw
from shapely.geometry import Polygon

# ---- Configuration ----
COORDS = [
    (-6.252879593919126, 33.947025365498384),
    (-6.252215120432003, 33.94730656161278),  # FIXED NE corner
    (-6.251805489765568, 33.94672277598407),
    (-6.252774693086623, 33.9463611776939),
    (-6.252879593919126, 33.947025365498384),  # close ring
]

TILE_URL = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
TILE_SIZE = 256
OUTPUT_DIR = "/Users/sbaio/farm_vision/output"


def lat_lon_to_pixel(lat, lon, zoom):
    """Convert lat/lon to absolute pixel coordinates at given zoom level."""
    n = 2**zoom
    pixel_x = ((lon + 180.0) / 360.0) * n * TILE_SIZE
    sin_lat = math.sin(math.radians(lat))
    pixel_y = (
        (0.5 - math.log((1 + sin_lat) / (1 - sin_lat)) / (4 * math.pi)) * n * TILE_SIZE
    )
    return pixel_x, pixel_y


def lat_lon_to_tile(lat, lon, zoom):
    """Convert lat/lon to tile x, y."""
    n = 2**zoom
    tx = int((lon + 180.0) / 360.0 * n)
    ty = int(
        (
            1.0
            - math.log(math.tan(math.radians(lat)) + 1.0 / math.cos(math.radians(lat)))
            / math.pi
        )
        / 2.0
        * n
    )
    return tx, ty


def is_placeholder_tile(tile):
    """Detect blank/placeholder tiles by checking pixel value uniformity."""
    arr = np.array(tile.convert("RGB"))
    return float(np.std(arr)) < 10


def fetch_and_stitch(zoom, buffer_meters):
    """Fetch tiles covering the polygon + buffer, stitch, crop, and overlay polygon."""
    polygon = Polygon(COORDS)
    centroid = polygon.centroid

    # Buffer in degrees (approx at this latitude)
    buf_lat = buffer_meters / 111000.0
    buf_lon = buffer_meters / (111000.0 * math.cos(math.radians(centroid.y)))

    minlon, minlat, maxlon, maxlat = polygon.bounds
    minlon -= buf_lon
    minlat -= buf_lat
    maxlon += buf_lon
    maxlat += buf_lat

    # Tile range (note: higher lat = lower tile y)
    tx_min, ty_min = lat_lon_to_tile(maxlat, minlon, zoom)
    tx_max, ty_max = lat_lon_to_tile(minlat, maxlon, zoom)

    nx = tx_max - tx_min + 1
    ny = ty_max - ty_min + 1
    total_tiles = nx * ny
    print(f"  Tiles: {nx}x{ny} = {total_tiles} tiles")

    # Download and stitch
    stitched = Image.new("RGB", (nx * TILE_SIZE, ny * TILE_SIZE))
    session = requests.Session()
    session.headers.update({"User-Agent": "FarmVision/1.0"})

    count = 0
    placeholder_count = 0
    for ty in range(ty_min, ty_max + 1):
        for tx in range(tx_min, tx_max + 1):
            url = TILE_URL.format(z=zoom, y=ty, x=tx)
            resp = session.get(url, timeout=30)
            resp.raise_for_status()
            tile = Image.open(BytesIO(resp.content))
            if is_placeholder_tile(tile):
                placeholder_count += 1
            px = (tx - tx_min) * TILE_SIZE
            py = (ty - ty_min) * TILE_SIZE
            stitched.paste(tile, (px, py))
            count += 1
            print(f"  Downloaded {count}/{total_tiles}", end="\r")
    print()

    if placeholder_count > total_tiles / 2:
        print(
            f"  WARNING: {placeholder_count}/{total_tiles} tiles are placeholders. Skipping zoom {zoom}."
        )
        return None

    # Compute pixel coords for crop region
    crop_left, crop_top = lat_lon_to_pixel(maxlat, minlon, zoom)
    crop_right, crop_bottom = lat_lon_to_pixel(minlat, maxlon, zoom)

    # Origin of stitched image in absolute pixel coords
    origin_x = tx_min * TILE_SIZE
    origin_y = ty_min * TILE_SIZE

    # Relative crop coords
    cl = crop_left - origin_x
    ct = crop_top - origin_y
    cr = crop_right - origin_x
    cb = crop_bottom - origin_y

    cropped = stitched.crop((int(cl), int(ct), int(cr), int(cb)))

    # Save a raw copy before drawing the polygon overlay
    raw_img = cropped.copy()

    # Draw polygon boundary on cropped image
    poly_pixels = []
    for lon, lat in COORDS:
        abs_px, abs_py = lat_lon_to_pixel(lat, lon, zoom)
        rel_px = abs_px - origin_x - cl
        rel_py = abs_py - origin_y - ct
        poly_pixels.append((rel_px, rel_py))

    draw = ImageDraw.Draw(cropped)
    for i in range(len(poly_pixels) - 1):
        draw.line([poly_pixels[i], poly_pixels[i + 1]], fill="red", width=3)

    return cropped, raw_img


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    configs = [
        (18, 150, "close_up"),
        (17, 400, "context"),
    ]

    for zoom, buffer_m, label in configs:
        print(f"\nFetching Esri World Imagery (zoom={zoom}, buffer={buffer_m}m)...")
        try:
            result = fetch_and_stitch(zoom, buffer_m)
        except requests.exceptions.HTTPError as e:
            print(
                f"  WARNING: Tiles not available at zoom {zoom} for this location (HTTP {e.response.status_code}). Skipping."
            )
            continue
        except requests.exceptions.RequestException as e:
            print(f"  WARNING: Failed to fetch tiles at zoom {zoom}: {e}. Skipping.")
            continue
        if result is None:
            continue
        img, raw_img = result
        out_path = os.path.join(OUTPUT_DIR, f"satellite_{label}_z{zoom}.png")
        img.save(out_path, quality=95)
        print(
            f"Saved: {out_path} ({img.size[0]}x{img.size[1]} pixels, {os.path.getsize(out_path) / 1024:.0f} KB)"
        )
        raw_path = os.path.join(OUTPUT_DIR, f"satellite_{label}_z{zoom}_raw.png")
        raw_img.save(raw_path, quality=95)
        print(
            f"Saved: {raw_path} ({raw_img.size[0]}x{raw_img.size[1]} pixels, {os.path.getsize(raw_path) / 1024:.0f} KB)"
        )

    print(f"\nDone! Images saved to {OUTPUT_DIR}/")


if __name__ == "__main__":
    main()
