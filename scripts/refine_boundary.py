#!/usr/bin/env python3
"""Refine vineyard plot boundary using satellite image analysis.

The GPS coordinates give ~5,779 m² but the actual plot is 6,600 m².
This script detects the vineyard boundary from the satellite image
using vegetation indices, then refines the polygon to better match
the true extent.
"""

import math
import os

import cv2
import numpy as np
from pyproj import Transformer
from shapely.geometry import Polygon as ShapelyPolygon

# ---- Configuration (same as fetch_satellite_images.py) ----
COORDS = [
    (-6.252879593919126, 33.947025365498384),
    (-6.252215120432003, 33.94730656161278),  # FIXED NE corner
    (-6.251805489765568, 33.94672277598407),
    (-6.252774693086623, 33.9463611776939),
    (-6.252879593919126, 33.947025365498384),  # close ring
]

TILE_SIZE = 256
ZOOM = 18
BUFFER_METERS = 150
TARGET_AREA = 6600  # m²

# Manual vertical offset to align boundary with actual plot (pixels, positive = south/down)
Y_OFFSET_PX = 0  # no offset needed — coordinates are now accurate

INPUT_PATH = "/Users/sbaio/farm_vision/output/satellite_close_up_z18_raw.png"
OUTPUT_DIR = "/Users/sbaio/farm_vision/output"

# Transformers for WGS84 <-> UTM zone 29N
to_utm = Transformer.from_crs("EPSG:4326", "EPSG:32629", always_xy=True)
to_wgs = Transformer.from_crs("EPSG:32629", "EPSG:4326", always_xy=True)


# ---- Tile math (replicated from fetch_satellite_images.py) ----


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


def compute_image_origin():
    """Compute the pixel origin (origin_x, origin_y, cl, ct) for the cropped image."""
    polygon = ShapelyPolygon(COORDS)
    centroid = polygon.centroid

    buf_lat = BUFFER_METERS / 111000.0
    buf_lon = BUFFER_METERS / (111000.0 * math.cos(math.radians(centroid.y)))

    minlon, minlat, maxlon, maxlat = polygon.bounds
    minlon -= buf_lon
    minlat -= buf_lat
    maxlon += buf_lon
    maxlat += buf_lat

    tx_min, ty_min = lat_lon_to_tile(maxlat, minlon, ZOOM)

    origin_x = tx_min * TILE_SIZE
    origin_y = ty_min * TILE_SIZE

    crop_left, crop_top = lat_lon_to_pixel(maxlat, minlon, ZOOM)
    cl = crop_left - origin_x
    ct = crop_top - origin_y

    return origin_x, origin_y, cl, ct


# Global image origin
ORIGIN_X, ORIGIN_Y, CL, CT = compute_image_origin()


def pixel_to_lonlat(px, py):
    """Convert cropped-image pixel coords to (lon, lat)."""
    n = 2**ZOOM
    abs_px = px + ORIGIN_X + CL
    abs_py = py + ORIGIN_Y + CT

    lon = abs_px / (n * TILE_SIZE) * 360.0 - 180.0
    lat_rad = math.atan(math.sinh(math.pi * (1 - 2.0 * abs_py / (n * TILE_SIZE))))
    lat = math.degrees(lat_rad)

    return lon, lat


def lonlat_to_pixel(lon, lat):
    """Convert (lon, lat) to cropped-image pixel coords."""
    abs_px, abs_py = lat_lon_to_pixel(lat, lon, ZOOM)
    rel_px = abs_px - ORIGIN_X - CL
    rel_py = abs_py - ORIGIN_Y - CT
    return rel_px, rel_py


def compute_original_polygon_pixels():
    """Get original polygon vertices in cropped-image pixel coords."""
    poly_pixels = []
    for lon, lat in COORDS:
        px, py = lonlat_to_pixel(lon, lat)
        poly_pixels.append((px, py))
    return poly_pixels


# ---- Boundary detection ----


def detect_vineyard_boundary(img, original_poly_pixels):
    """Detect the vineyard boundary from satellite image using vegetation index.

    Uses Excess Green Index (ExG) to separate green vineyard from brown surroundings,
    then morphological operations to create a solid shape, and contour detection
    to extract the boundary.
    """
    img_f = img.astype(np.float32)

    # Excess Green Index: 2G - R - B
    b, g, r = img_f[:, :, 0], img_f[:, :, 1], img_f[:, :, 2]
    exg = 2 * g - r - b

    # Also try HSV-based detection for robustness
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    h, s, v = hsv[:, :, 0], hsv[:, :, 1], hsv[:, :, 2]

    # Combine ExG with saturation for better vegetation mask
    exg_norm = cv2.normalize(exg, None, 0, 255, cv2.NORM_MINMAX).astype(np.uint8)
    s_norm = s  # already 0-255

    # Create a combined vegetation score
    veg_score = cv2.addWeighted(exg_norm, 0.7, s_norm, 0.3, 0)

    # Create a search region around the original polygon (expand modestly)
    orig_pts = np.array(original_poly_pixels[:4], dtype=np.int32).reshape((-1, 1, 2))
    search_mask = np.zeros(img.shape[:2], dtype=np.uint8)
    centroid = np.mean(orig_pts.reshape(-1, 2), axis=0)

    # Expand polygon outward from centroid by 20%
    expanded_pts = []
    for pt in orig_pts.reshape(-1, 2):
        direction = pt - centroid
        expanded_pt = centroid + direction * 1.2
        expanded_pts.append(expanded_pt)
    expanded_pts = np.array(expanded_pts, dtype=np.int32).reshape((-1, 1, 2))
    cv2.fillPoly(search_mask, [expanded_pts], 255)

    # Apply search mask to vegetation score
    veg_masked = cv2.bitwise_and(veg_score, veg_score, mask=search_mask)

    # Use Otsu's method within the search region for adaptive threshold
    veg_vals = veg_masked[search_mask > 0]
    otsu_thresh, _ = cv2.threshold(
        veg_vals.astype(np.uint8), 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU
    )
    # Use a threshold above Otsu to be more selective
    threshold = otsu_thresh * 1.17
    print(f"  Otsu threshold: {otsu_thresh:.0f}, using: {threshold:.0f}")

    veg_mask = (veg_masked > threshold).astype(np.uint8) * 255
    veg_mask[search_mask == 0] = 0

    # Morphological closing to fill gaps between vine rows
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (15, 15))
    closed = cv2.morphologyEx(veg_mask, cv2.MORPH_CLOSE, kernel, iterations=2)

    # Light smoothing
    kernel_smooth = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
    closed = cv2.morphologyEx(closed, cv2.MORPH_OPEN, kernel_smooth, iterations=1)

    # Find contours
    contours, _ = cv2.findContours(closed, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    if not contours:
        print("WARNING: No contours found, returning original polygon")
        return np.array(original_poly_pixels[:4], dtype=np.float32)

    # Find contour that best overlaps with original polygon
    orig_mask = np.zeros(img.shape[:2], dtype=np.uint8)
    orig_pts_fill = np.array(original_poly_pixels[:4], dtype=np.int32).reshape(
        (-1, 1, 2)
    )
    cv2.fillPoly(orig_mask, [orig_pts_fill], 255)

    best_contour = None
    best_score = -1

    for contour in contours:
        area = cv2.contourArea(contour)
        if area < 5000:  # too small
            continue

        contour_mask = np.zeros(img.shape[:2], dtype=np.uint8)
        cv2.fillConvexHull = cv2.drawContours(contour_mask, [contour], -1, 255, -1)

        intersection = cv2.bitwise_and(orig_mask, contour_mask)
        union = cv2.bitwise_or(orig_mask, contour_mask)
        iou = cv2.countNonZero(intersection) / max(cv2.countNonZero(union), 1)

        if iou > best_score:
            best_score = iou
            best_contour = contour

    if best_contour is None:
        # Fall back to largest contour
        best_contour = max(contours, key=cv2.contourArea)

    print(f"  Best contour IoU with original: {best_score:.3f}")
    print(f"  Best contour area: {cv2.contourArea(best_contour):.0f} px²")

    # Approximate to quadrilateral
    quad = approximate_to_quad(best_contour)
    return quad


def approximate_to_quad(contour):
    """Approximate a contour to exactly 4 points (quadrilateral).

    Tries cv2.approxPolyDP with decreasing epsilon until we get 4 points.
    Falls back to minimum area bounding rectangle if needed.
    """
    peri = cv2.arcLength(contour, True)

    # Try decreasing epsilon to get exactly 4 points
    for eps_frac in np.arange(0.08, 0.001, -0.002):
        approx = cv2.approxPolyDP(contour, eps_frac * peri, True)
        if len(approx) == 4:
            print(f"  approxPolyDP gave 4 points at epsilon={eps_frac:.3f}")
            return approx.reshape(-1, 2).astype(np.float32)

    # If we never got exactly 4, try the range where we got closest to 4
    best_approx = None
    best_diff = float("inf")
    for eps_frac in np.arange(0.15, 0.001, -0.001):
        approx = cv2.approxPolyDP(contour, eps_frac * peri, True)
        diff = abs(len(approx) - 4)
        if diff < best_diff:
            best_diff = diff
            best_approx = approx
        if diff == 0:
            break

    if best_approx is not None and len(best_approx) == 4:
        return best_approx.reshape(-1, 2).astype(np.float32)

    # Fall back to minimum area bounding rectangle
    print("  Using minimum area bounding rectangle")
    rect = cv2.minAreaRect(contour)
    box = cv2.boxPoints(rect)
    return box.astype(np.float32)


def order_quad_points(pts):
    """Order quadrilateral points consistently: top-left, top-right, bottom-right, bottom-left."""
    centroid = pts.mean(axis=0)
    angles = np.arctan2(pts[:, 1] - centroid[1], pts[:, 0] - centroid[0])
    # Sort by angle (counter-clockwise from -pi)
    order = np.argsort(angles)
    ordered = pts[order]

    # Reorder so top-left is first (smallest x+y sum ≈ top-left)
    sums = ordered[:, 0] + ordered[:, 1]
    start_idx = np.argmin(sums)
    ordered = np.roll(ordered, -start_idx, axis=0)

    return ordered


# ---- Measurement utilities ----


def compute_utm_measurements(lonlat_coords):
    """Compute area, perimeter, and side lengths in UTM coordinates."""
    utm_coords = []
    for lon, lat in lonlat_coords:
        x, y = to_utm.transform(lon, lat)
        utm_coords.append((x, y))

    # Close the ring for area/perimeter
    polygon = ShapelyPolygon(utm_coords)
    area = polygon.area
    perimeter = polygon.length

    # Side lengths
    sides = []
    for i in range(len(utm_coords)):
        x1, y1 = utm_coords[i]
        x2, y2 = utm_coords[(i + 1) % len(utm_coords)]
        side = math.sqrt((x2 - x1) ** 2 + (y2 - y1) ** 2)
        sides.append(side)

    return area, perimeter, sides


def dd_to_dms(dd, is_lon=False):
    """Convert decimal degrees to degrees, minutes, seconds string."""
    direction = ""
    if is_lon:
        direction = "W" if dd < 0 else "E"
    else:
        direction = "S" if dd < 0 else "N"

    dd = abs(dd)
    d = int(dd)
    m = int((dd - d) * 60)
    s = (dd - d - m / 60) * 3600
    return f"{d}°{m:02d}'{s:05.2f}\"{direction}"


# ---- Visualization ----


def save_visualization(img, original_pixels, refined_pixels, output_path):
    """Save image with original (red) and refined (green) polygons overlaid."""
    vis = img.copy()

    # Draw original polygon in red
    orig_pts = np.array(original_pixels[:4], dtype=np.int32).reshape((-1, 1, 2))
    cv2.polylines(vis, [orig_pts], isClosed=True, color=(0, 0, 255), thickness=2)

    # Draw refined polygon in green
    ref_pts = np.array(refined_pixels, dtype=np.int32).reshape((-1, 1, 2))
    cv2.polylines(vis, [ref_pts], isClosed=True, color=(0, 255, 0), thickness=2)

    # Label corners of original polygon
    for i, (x, y) in enumerate(original_pixels[:4]):
        cx, cy = int(x), int(y)
        cv2.circle(vis, (cx, cy), 5, (0, 0, 255), -1)
        cv2.putText(
            vis,
            f"O{i+1}",
            (cx + 8, cy - 8),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.5,
            (0, 0, 255),
            2,
        )

    # Label corners of refined polygon
    for i, (x, y) in enumerate(refined_pixels):
        cx, cy = int(x), int(y)
        cv2.circle(vis, (cx, cy), 5, (0, 255, 0), -1)
        cv2.putText(
            vis,
            f"R{i+1}",
            (cx + 8, cy + 18),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.5,
            (0, 255, 0),
            2,
        )

    # Legend
    cv2.putText(
        vis, "RED = Original", (10, 25), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 0, 255), 2
    )
    cv2.putText(
        vis, "GREEN = Refined", (10, 50), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 0), 2
    )

    cv2.imwrite(output_path, vis)
    print(f"Saved: {output_path}")


# ---- Main ----


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    # Load satellite image
    img = cv2.imread(INPUT_PATH)
    if img is None:
        raise FileNotFoundError(f"Cannot load image: {INPUT_PATH}")
    print(f"Loaded image: {img.shape[1]}x{img.shape[0]} pixels")

    # A. Original polygon in pixel coords
    original_pixels = compute_original_polygon_pixels()
    print(
        f"Original polygon pixels: {[(int(x), int(y)) for x, y in original_pixels[:4]]}"
    )

    # Verify pixel↔geo round-trip
    for i, (lon, lat) in enumerate(COORDS[:4]):
        px, py = lonlat_to_pixel(lon, lat)
        lon2, lat2 = pixel_to_lonlat(px, py)
        assert (
            abs(lon - lon2) < 1e-8 and abs(lat - lat2) < 1e-8
        ), f"Round-trip failed for point {i}: ({lon},{lat}) -> ({lon2},{lat2})"
    print("Pixel↔geo round-trip verified ✓")

    # Original measurements
    orig_lonlat = [(lon, lat) for lon, lat in COORDS[:4]]
    orig_area, orig_peri, orig_sides = compute_utm_measurements(orig_lonlat)
    print(f"Original area: {orig_area:.0f} m²")

    # B. Detect vineyard boundary
    print("\nDetecting vineyard boundary...")
    refined_quad = detect_vineyard_boundary(img, original_pixels)
    refined_quad = order_quad_points(refined_quad)

    # Apply vertical offset to shift boundary down (south)
    refined_quad[:, 1] += Y_OFFSET_PX

    # C. Convert refined pixel corners to lon/lat
    refined_lonlat = []
    for px, py in refined_quad:
        lon, lat = pixel_to_lonlat(float(px), float(py))
        refined_lonlat.append((lon, lat))

    # D. Compute refined measurements
    ref_area, ref_peri, ref_sides = compute_utm_measurements(refined_lonlat)

    # E. Output comparison
    print()
    print("=" * 60)
    print("=== Boundary Refinement ===")
    print("=" * 60)
    print(f"{'':20s} {'Original':>12s} {'Refined':>12s} {'Target':>12s}")
    print(
        f"{'Area:':20s} {orig_area:>10,.0f} m² {ref_area:>10,.0f} m² {TARGET_AREA:>10,d} m²"
    )
    print(f"{'Perimeter:':20s} {orig_peri:>10.1f} m  {ref_peri:>10.1f} m")
    print()
    print("Side lengths:")
    for i in range(4):
        orig_s = orig_sides[i] if i < len(orig_sides) else 0
        ref_s = ref_sides[i] if i < len(ref_sides) else 0
        print(f"  Side {i+1}:           {orig_s:>6.1f} m       {ref_s:>6.1f} m")

    print()
    print("Refined GPS coordinates (DMS):")
    for i, (lon, lat) in enumerate(refined_lonlat):
        lat_dms = dd_to_dms(lat, is_lon=False)
        lon_dms = dd_to_dms(lon, is_lon=True)
        print(f"  Corner {i+1}: {lat_dms}  {lon_dms}")

    print()
    print("Refined GPS coordinates (Decimal):")
    for i, (lon, lat) in enumerate(refined_lonlat):
        print(f"  Corner {i+1}: {lat:.6f}, {lon:.6f}")

    area_diff = ref_area - TARGET_AREA
    area_pct = (ref_area / TARGET_AREA - 1) * 100
    print(f"\nArea difference from target: {area_diff:+.0f} m² ({area_pct:+.1f}%)")
    print("=" * 60)

    # F. Visualization
    viz_path = os.path.join(OUTPUT_DIR, "boundary_refinement.png")
    save_visualization(img, original_pixels, refined_quad, viz_path)

    print("\nDone!")


if __name__ == "__main__":
    main()
