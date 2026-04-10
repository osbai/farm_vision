#!/usr/bin/env python3
"""Detect vine poles and analyze grid structure in satellite imagery of a Moroccan vineyard.

Strategy: Use polygon side directions to define row and column axes of the vine grid.
Compute autocorrelation-derived spacing, then place a UNIFORM (equally-spaced) grid
from edge to edge with phase alignment that maximises vegetation signal.
Detect vines at grid intersections.
"""

import math
import os

import cv2
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from refine_boundary import detect_vineyard_boundary, order_quad_points
from scipy.ndimage import gaussian_filter1d
from scipy.signal import correlate

# ---- Configuration (same as fetch_satellite_images.py) ----
COORDS = [
    (-6.252879593919126, 33.947025365498384),
    (-6.252215120432003, 33.94730656161278),  # FIXED NE corner
    (-6.251805489765568, 33.94672277598407),
    (-6.252774693086623, 33.9463611776939),
    (-6.252879593919126, 33.947025365498384),  # close ring
]

# Named corners (lon, lat)
NW_LONLAT = (-6.252879593919126, 33.947025365498384)
NE_LONLAT = (-6.252215120432003, 33.94730656161278)
SE_LONLAT = (-6.251805489765568, 33.94672277598407)
SW_LONLAT = (-6.252774693086623, 33.9463611776939)

TILE_SIZE = 256
ZOOM = 18
BUFFER_METERS = 150
METERS_PER_PIXEL = 0.597  # at zoom 18, latitude ~34°

INPUT_PATH = "/Users/sbaio/farm_vision/output/satellite_close_up_z18_raw.png"
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


def compute_polygon_pixels():
    """Replicate the fetch script's coordinate mapping to get polygon pixels in the cropped image."""
    from shapely.geometry import Polygon as ShapelyPolygon

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

    poly_pixels = []
    for lon, lat in COORDS:
        abs_px, abs_py = lat_lon_to_pixel(lat, lon, ZOOM)
        rel_px = abs_px - origin_x - cl
        rel_py = abs_py - origin_y - ct
        poly_pixels.append((rel_px, rel_py))

    return poly_pixels


def compute_corner_pixels():
    """Compute pixel coordinates for named polygon corners (NW, NE, SE, SW)."""
    from shapely.geometry import Polygon as ShapelyPolygon

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

    corners = {}
    for name, (lon, lat) in [
        ("NW", NW_LONLAT),
        ("NE", NE_LONLAT),
        ("SE", SE_LONLAT),
        ("SW", SW_LONLAT),
    ]:
        abs_px, abs_py = lat_lon_to_pixel(lat, lon, ZOOM)
        corners[name] = np.array([abs_px - origin_x - cl, abs_py - origin_y - ct])

    return corners


def create_polygon_mask(img_shape, poly_pixels):
    """Create a binary mask for the polygon interior."""
    pts = np.array(poly_pixels, dtype=np.int32).reshape((-1, 1, 2))
    mask = np.zeros(img_shape[:2], dtype=np.uint8)
    cv2.fillPoly(mask, [pts], 255)
    return mask


def compute_refined_polygon(img, original_poly_pixels):
    """Compute the refined vineyard boundary using vegetation analysis."""
    refined_quad = detect_vineyard_boundary(img, original_poly_pixels)
    refined_quad = order_quad_points(refined_quad)
    return refined_quad


# ---------------------------------------------------------------------------
# Signal-processing grid detection pipeline
# ---------------------------------------------------------------------------


def compute_exg(img, polygon_mask):
    """Compute Excess Green Index (2G - R - B) within the polygon mask."""
    img_float = img.astype(float)
    exg = 2 * img_float[:, :, 1] - img_float[:, :, 0] - img_float[:, :, 2]
    exg_smooth = cv2.GaussianBlur(exg, (3, 3), 0.8)
    exg_masked = exg_smooth * (polygon_mask / 255.0)
    return exg_smooth, exg_masked


def compute_grid_directions(corners):
    """Compute the two grid axis directions from the polygon sides.

    Direction 1 (col_dir): along right side NE -> SE  -> gives column lines
    Direction 2 (row_dir): along bottom side SE -> SW  -> gives row lines

    Returns:
        col_dir: unit vector along columns (NE->SE direction)
        row_dir: unit vector along rows (SE->SW direction)
        col_angle: angle of column direction in degrees
        row_angle: angle of row direction in degrees
    """
    ne = corners["NE"]
    se = corners["SE"]
    sw = corners["SW"]

    dir1 = se - ne
    col_angle = np.degrees(np.arctan2(dir1[1], dir1[0]))
    col_dir = dir1 / np.linalg.norm(dir1)

    dir2 = sw - se
    row_angle = np.degrees(np.arctan2(dir2[1], dir2[0]))
    row_dir = dir2 / np.linalg.norm(dir2)

    return col_dir, row_dir, col_angle, row_angle


def compute_cross_axis_profile(exg_masked, polygon_mask, axis_dir):
    """Project vegetation signal perpendicular to the given axis direction.

    For a given axis direction, the cross-axis (perpendicular) direction is used
    to bin pixels. This gives a 1-D profile whose peaks correspond to line positions.

    Args:
        exg_masked: ExG image masked to polygon
        polygon_mask: binary mask
        axis_dir: unit vector along the axis (lines run parallel to this)

    Returns:
        profile_norm: average ExG at each perpendicular distance
        profile_count: pixel count per bin
        perp_min: minimum perpendicular coordinate
        perp_dir: perpendicular direction unit vector
    """
    perp_dir = np.array([-axis_dir[1], axis_dir[0]])

    ys, xs = np.where(polygon_mask > 0)
    exg_values = exg_masked[ys, xs]
    perp_coords = xs.astype(float) * perp_dir[0] + ys.astype(float) * perp_dir[1]

    perp_min = float(perp_coords.min())
    perp_max = float(perp_coords.max())
    n_bins = int(np.ceil(perp_max - perp_min)) + 1

    profile_sum = np.zeros(n_bins)
    profile_count = np.zeros(n_bins)

    bin_idx = (perp_coords - perp_min).astype(int)
    bin_idx = np.clip(bin_idx, 0, n_bins - 1)

    np.add.at(profile_sum, bin_idx, exg_values)
    np.add.at(profile_count, bin_idx, 1)

    profile_norm = np.zeros(n_bins)
    np.divide(profile_sum, profile_count, out=profile_norm, where=profile_count > 0)
    return profile_norm, profile_count, perp_min, perp_dir


def find_line_spacing(profile_norm, profile_count, min_count=10):
    """Find line spacing in pixels via autocorrelation of the cross-axis profile."""
    valid_mask = profile_count > min_count
    valid = profile_norm[valid_mask]

    if len(valid) < 10:
        return 4.5

    smoothed = gaussian_filter1d(valid, sigma=1.0)
    centered = smoothed - np.mean(smoothed)
    autocorr = correlate(centered, centered, mode="full")
    autocorr = autocorr[len(autocorr) // 2 :]
    if autocorr[0] > 0:
        autocorr /= autocorr[0]

    max_lag = min(len(autocorr), 30)
    from scipy.signal import find_peaks as _find_peaks

    acorr_peaks, _ = _find_peaks(autocorr[2:max_lag], height=0.02, distance=2)
    if len(acorr_peaks) > 0:
        return float(acorr_peaks[0] + 2)
    return 4.5


def find_uniform_line_positions(
    exg_masked, polygon_mask, axis_dir, spacing_px, corners, n_phase=50
):
    """Place equally-spaced lines from edge to edge, phase-aligned to vegetation.

    1. Project all 4 polygon corners onto the perpendicular axis.
    2. The range of projections = total width to cover.
    3. Number of lines = total_width / spacing.
    4. Try n_phase offsets in [0, spacing) and pick the one that maximises
       total ExG along the candidate lines.

    Returns:
        best_perp_dists: array of perpendicular distances for the best-aligned grid
        perp_dir: perpendicular direction unit vector
    """
    perp_dir = np.array([-axis_dir[1], axis_dir[0]])

    corner_projs = []
    for name in ["NW", "NE", "SE", "SW"]:
        c = corners[name]
        corner_projs.append(c[0] * perp_dir[0] + c[1] * perp_dir[1])
    proj_min = min(corner_projs)
    proj_max = max(corner_projs)
    total_width = proj_max - proj_min

    n_lines = max(1, int(round(total_width / spacing_px)))

    ys, xs = np.where(polygon_mask > 0)
    if len(ys) == 0:
        return np.array([]), perp_dir

    exg_values = exg_masked[ys, xs]
    perp_coords = xs.astype(float) * perp_dir[0] + ys.astype(float) * perp_dir[1]

    best_score = -np.inf
    best_offset = 0.0

    for i in range(n_phase):
        offset = (i / n_phase) * spacing_px
        positions = proj_min + offset + np.arange(n_lines) * spacing_px

        score = 0.0
        half_w = 1.5  # sample within ±1.5 px of line
        for pos in positions:
            near = np.abs(perp_coords - pos) < half_w
            if np.any(near):
                score += np.sum(exg_values[near])

        if score > best_score:
            best_score = score
            best_offset = offset

    best_perp_dists = proj_min + best_offset + np.arange(n_lines) * spacing_px
    return best_perp_dists, perp_dir


def clip_line_to_mask(point_on_line, direction, mask):
    """Clip an infinite line to the region inside a binary mask."""
    h, w = mask.shape
    diag = np.sqrt(h**2 + w**2)
    n_test = int(diag * 3)
    t_vals = np.linspace(-diag, diag, n_test)

    x_vals = point_on_line[0] + t_vals * direction[0]
    y_vals = point_on_line[1] + t_vals * direction[1]

    xi = np.round(x_vals).astype(int)
    yi = np.round(y_vals).astype(int)

    in_bounds = (xi >= 0) & (xi < w) & (yi >= 0) & (yi < h)
    in_mask = np.zeros(n_test, dtype=bool)
    valid = np.where(in_bounds)[0]
    if len(valid) == 0:
        return None, None
    in_mask[valid] = mask[yi[valid], xi[valid]] > 0

    if not np.any(in_mask):
        return None, None

    mask_indices = np.where(in_mask)[0]
    start_pt = np.array([x_vals[mask_indices[0]], y_vals[mask_indices[0]]])
    end_pt = np.array([x_vals[mask_indices[-1]], y_vals[mask_indices[-1]]])
    return start_pt, end_pt


def construct_lines(perp_dists, axis_dir, perp_dir, polygon_mask):
    """Convert perpendicular distances into line segments clipped to mask."""
    lines = []
    for d in perp_dists:
        point_on_line = d * perp_dir
        start, end = clip_line_to_mask(point_on_line, axis_dir, polygon_mask)
        if start is not None:
            lines.append((start, end))
    return lines


def line_intersection(p1, d1, p2, d2):
    """Find intersection of two lines defined by point + direction."""
    det = d1[0] * (-d2[1]) - d1[1] * (-d2[0])
    if abs(det) < 1e-10:
        return None
    dp = p2 - p1
    t = ((-d2[1]) * dp[0] - (-d2[0]) * dp[1]) / det
    return p1 + t * d1


def detect_vines_at_intersections(
    row_lines,
    col_lines,
    row_dir,
    col_dir,
    exg,
    polygon_mask,
    exg_threshold_percentile=40,
):
    """Detect vines at grid intersections.

    At each intersection of a row line and column line, check the ExG value.
    If above threshold -> vine present, else -> missing.
    Points near the polygon border get stricter filtering to reject
    neighboring hedgerows or non-vineyard vegetation.
    """
    h, w = exg.shape
    mask_bool = polygon_mask > 0

    exg_inside = exg[mask_bool]
    threshold = np.percentile(exg_inside, exg_threshold_percentile)
    border_threshold = threshold * 1.5

    check_radius = 2
    border_dist_px = 8  # ~5 m at 0.6 m/px
    variance_window = 2  # 5×5 patch (radius 2)
    hedgerow_var_limit = 10.0

    dist_transform = cv2.distanceTransform(polygon_mask, cv2.DIST_L2, 5)

    vine_results = {}  # (row_idx, col_idx) -> bool
    intersection_positions = {}  # (row_idx, col_idx) -> (x, y)

    for ri, (row_start, row_end) in enumerate(row_lines):
        for ci, (col_start, col_end) in enumerate(col_lines):
            pt = line_intersection(row_start, row_dir, col_start, col_dir)
            if pt is None:
                continue

            ix, iy = int(round(pt[0])), int(round(pt[1]))

            if ix < check_radius or ix >= w - check_radius:
                continue
            if iy < check_radius or iy >= h - check_radius:
                continue

            if not mask_bool[iy, ix]:
                continue

            patch = exg[
                iy - check_radius : iy + check_radius + 1,
                ix - check_radius : ix + check_radius + 1,
            ]
            local_exg = np.mean(patch)

            dist_to_border = dist_transform[iy, ix]

            if dist_to_border < border_dist_px:
                if local_exg <= border_threshold:
                    vine_results[(ri, ci)] = False
                    intersection_positions[(ri, ci)] = (pt[0], pt[1])
                    continue

                var_patch = exg[
                    max(0, iy - variance_window) : min(h, iy + variance_window + 1),
                    max(0, ix - variance_window) : min(w, ix + variance_window + 1),
                ]
                if np.var(var_patch) < hedgerow_var_limit:
                    vine_results[(ri, ci)] = False
                    intersection_positions[(ri, ci)] = (pt[0], pt[1])
                    continue

            is_vine = local_exg > threshold
            vine_results[(ri, ci)] = is_vine
            intersection_positions[(ri, ci)] = (pt[0], pt[1])

    vine_positions = [intersection_positions[k] for k, v in vine_results.items() if v]
    missing_positions = [
        intersection_positions[k] for k, v in vine_results.items() if not v
    ]

    return vine_positions, missing_positions, vine_results, intersection_positions


# ---------------------------------------------------------------------------
# Visualization (matplotlib)
# ---------------------------------------------------------------------------


def save_grid_detection_visualization(
    img,
    vine_positions,
    missing_positions,
    poly_pixels,
    row_lines,
    col_lines,
    n_rows,
    n_cols,
    output_path,
):
    """Save matplotlib figure with grid lines, vine detections, and polygon overlay."""
    img_rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
    h, w = img.shape[:2]

    fig, ax = plt.subplots(1, 1, figsize=(12, 12))
    ax.imshow(img_rgb)

    # Polygon outline with semi-transparent fill
    poly_xy = [(x, y) for x, y in poly_pixels]
    from matplotlib.patches import Polygon as MplPolygon

    poly_patch = MplPolygon(
        poly_xy,
        closed=True,
        facecolor=(1, 0.7, 0, 0.15),
        edgecolor=(1, 0.8, 0, 1.0),
        linewidth=2,
    )
    ax.add_patch(poly_patch)

    # Row lines in cyan
    for start, end in row_lines:
        ax.plot(
            [start[0], end[0]],
            [start[1], end[1]],
            color="cyan",
            linewidth=0.7,
            alpha=0.5,
        )

    # Column lines in magenta
    for start, end in col_lines:
        ax.plot(
            [start[0], end[0]],
            [start[1], end[1]],
            color="magenta",
            linewidth=0.7,
            alpha=0.5,
        )

    # Detected vines as green filled circles
    if vine_positions:
        vx = [p[0] for p in vine_positions]
        vy = [p[1] for p in vine_positions]
        ax.scatter(vx, vy, s=20, c="lime", edgecolors="white", linewidths=0.5, zorder=5)

    # Missing positions as red x
    if missing_positions:
        mx = [p[0] for p in missing_positions]
        my = [p[1] for p in missing_positions]
        ax.scatter(mx, my, s=20, c="red", marker="x", linewidths=0.8, zorder=5)

    total = len(vine_positions) + len(missing_positions)
    ax.set_title(
        f"Uniform Grid: {n_rows} rows × {n_cols} cols  |  "
        f"Vines: {len(vine_positions)}  Missing: {len(missing_positions)}  "
        f"({100 * len(vine_positions) / max(total, 1):.1f}%)",
        fontsize=13,
        fontweight="bold",
    )
    ax.set_xlim(0, w)
    ax.set_ylim(h, 0)
    ax.axis("off")
    fig.tight_layout()
    fig.savefig(output_path, dpi=200, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: {output_path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    img = cv2.imread(INPUT_PATH)
    if img is None:
        raise FileNotFoundError(f"Cannot load image: {INPUT_PATH}")
    print(f"Loaded image: {img.shape[1]}x{img.shape[0]} pixels")

    poly_pixels = compute_polygon_pixels()
    print(f"Polygon vertices (pixels): {[(int(x), int(y)) for x, y in poly_pixels]}")

    corners = compute_corner_pixels()
    print(
        f"Corner pixels: NW={corners['NW'].astype(int)}, NE={corners['NE'].astype(int)}, "
        f"SE={corners['SE'].astype(int)}, SW={corners['SW'].astype(int)}"
    )

    print("\nComputing refined boundary...")
    refined_quad = compute_refined_polygon(img, poly_pixels)
    refined_poly_pixels = [(float(x), float(y)) for x, y in refined_quad]
    print(
        f"Refined polygon vertices: {[(int(x), int(y)) for x, y in refined_poly_pixels]}"
    )

    refined_mask = create_polygon_mask(img.shape, refined_poly_pixels)
    poly_area_px = cv2.countNonZero(refined_mask)
    poly_area_m2 = poly_area_px * METERS_PER_PIXEL**2
    print(f"Refined polygon area: {poly_area_px} px² ({poly_area_m2:.0f} m²)")

    erode_kernel = np.ones((12, 12), np.uint8)
    detection_mask = cv2.erode(refined_mask, erode_kernel, iterations=1)
    det_area_px = cv2.countNonZero(detection_mask)
    print(
        f"Detection mask area (after erosion): {det_area_px} px² "
        f"({det_area_px * METERS_PER_PIXEL**2:.0f} m²)"
    )

    # ---- Step 1: Compute ExG vegetation index ----
    exg, exg_masked = compute_exg(img, detection_mask)
    print("\nComputed Excess Green Index (ExG)")

    # ---- Step 2: Compute grid directions from polygon sides ----
    col_dir, row_dir, col_angle, row_angle = compute_grid_directions(corners)
    print(
        f"Column direction (NE→SE): {col_angle:.1f}°, unit vec = ({col_dir[0]:.3f}, {col_dir[1]:.3f})"
    )
    print(
        f"Row direction (SE→SW): {row_angle:.1f}°, unit vec = ({row_dir[0]:.3f}, {row_dir[1]:.3f})"
    )

    # ---- Step 3: Find ROW spacing via autocorrelation ----
    print("\n--- Detecting ROW lines (parallel to bottom side) ---")
    row_profile, row_count, row_perp_min, _ = compute_cross_axis_profile(
        exg_masked, detection_mask, row_dir
    )
    row_spacing_px = find_line_spacing(row_profile, row_count)
    print(
        f"Row spacing (autocorrelation): {row_spacing_px:.1f} px "
        f"({row_spacing_px * METERS_PER_PIXEL:.1f} m)"
    )

    # Uniform row grid placement with phase alignment
    row_perp_dists, row_perp_dir = find_uniform_line_positions(
        exg_masked, detection_mask, row_dir, row_spacing_px, corners
    )
    n_rows = len(row_perp_dists)
    print(f"Placed {n_rows} equally-spaced row lines")

    row_lines = construct_lines(row_perp_dists, row_dir, row_perp_dir, detection_mask)
    print(f"Constructed {len(row_lines)} row line segments (clipped to polygon)")

    # ---- Step 4: Find COLUMN spacing via autocorrelation ----
    print("\n--- Detecting COLUMN lines (parallel to right side) ---")
    col_profile, col_count, col_perp_min, _ = compute_cross_axis_profile(
        exg_masked, detection_mask, col_dir
    )
    col_spacing_px = find_line_spacing(col_profile, col_count)
    print(
        f"Column spacing (autocorrelation): {col_spacing_px:.1f} px "
        f"({col_spacing_px * METERS_PER_PIXEL:.1f} m)"
    )

    # Uniform column grid placement with phase alignment
    col_perp_dists, col_perp_dir = find_uniform_line_positions(
        exg_masked, detection_mask, col_dir, col_spacing_px, corners
    )
    n_cols = len(col_perp_dists)
    print(f"Placed {n_cols} equally-spaced column lines")

    col_lines = construct_lines(col_perp_dists, col_dir, col_perp_dir, detection_mask)
    print(f"Constructed {len(col_lines)} column line segments (clipped to polygon)")

    if n_rows == 0 or n_cols == 0:
        print(
            "Insufficient rows or columns detected. Check image quality / polygon placement."
        )
        return

    # ---- Step 5: Detect vines at grid intersections ----
    print("\n--- Detecting vines at grid intersections ---")
    vine_positions, missing_positions, vine_results, intersection_positions = (
        detect_vines_at_intersections(
            row_lines, col_lines, row_dir, col_dir, exg, detection_mask
        )
    )
    print(
        f"Detected {len(vine_positions)} vines, {len(missing_positions)} missing positions"
    )

    # ---- Step 5b: Filter grid lines with fewer than MIN_DETECTIONS_PER_LINE ----
    MIN_DETECTIONS_PER_LINE = 3

    row_counts = {}
    for (ri, ci), is_vine in vine_results.items():
        if is_vine:
            row_counts[ri] = row_counts.get(ri, 0) + 1

    col_counts = {}
    for (ri, ci), is_vine in vine_results.items():
        if is_vine:
            col_counts[ci] = col_counts.get(ci, 0) + 1

    valid_rows = {
        ri for ri, cnt in row_counts.items() if cnt >= MIN_DETECTIONS_PER_LINE
    }
    valid_cols = {
        ci for ci, cnt in col_counts.items() if cnt >= MIN_DETECTIONS_PER_LINE
    }

    filtered_results = {
        (ri, ci): v
        for (ri, ci), v in vine_results.items()
        if ri in valid_rows and ci in valid_cols
    }

    vine_positions_filtered = [
        intersection_positions[k] for k in filtered_results if filtered_results[k]
    ]
    missing_positions_filtered = [
        intersection_positions[k] for k in filtered_results if not filtered_results[k]
    ]

    row_lines_filtered = [row_lines[ri] for ri in sorted(valid_rows)]
    col_lines_filtered = [col_lines[ci] for ci in sorted(valid_cols)]
    n_rows_filtered = len(valid_rows)
    n_cols_filtered = len(valid_cols)

    print(f"\n--- Filtering lines (min {MIN_DETECTIONS_PER_LINE} detections) ---")
    print(f"Rows: {n_rows} -> {n_rows_filtered} (removed {n_rows - n_rows_filtered})")
    print(f"Cols: {n_cols} -> {n_cols_filtered} (removed {n_cols - n_cols_filtered})")
    print(
        f"Vines: {len(vine_positions)} -> {len(vine_positions_filtered)}, "
        f"Missing: {len(missing_positions)} -> {len(missing_positions_filtered)}"
    )

    # ---- Step 6: Visualization (filtered) ----
    save_grid_detection_visualization(
        img,
        vine_positions_filtered,
        missing_positions_filtered,
        poly_pixels,
        row_lines_filtered,
        col_lines_filtered,
        n_rows_filtered,
        n_cols_filtered,
        os.path.join(OUTPUT_DIR, "vine_grid_detection.png"),
    )

    # ---- Step 7: Print summary ----
    row_spacing_m = row_spacing_px * METERS_PER_PIXEL
    col_spacing_m = col_spacing_px * METERS_PER_PIXEL
    total_before = len(vine_positions) + len(missing_positions)
    total_after = len(vine_positions_filtered) + len(missing_positions_filtered)
    rate_before = 100.0 * len(vine_positions) / max(total_before, 1)
    rate_after = 100.0 * len(vine_positions_filtered) / max(total_after, 1)

    print()
    print("=" * 55)
    print("=== Uniform Grid Analysis ===")
    print("=" * 55)
    print(f"Row direction: {row_angle:.1f}° (parallel to bottom side)")
    print(f"Column direction: {col_angle:.1f}° (parallel to right side)")
    print(f"Row spacing: {row_spacing_m:.1f} m ({row_spacing_px:.1f} px)")
    print(f"Column spacing: {col_spacing_m:.1f} m ({col_spacing_px:.1f} px)")
    print(f"Rows: {n_rows} -> {n_rows_filtered} (after filter)")
    print(f"Columns: {n_cols} -> {n_cols_filtered} (after filter)")
    print(f"Total grid positions: {total_before} -> {total_after}")
    print(f"Detected vines: {len(vine_positions)} -> {len(vine_positions_filtered)}")
    print(
        f"Missing positions: {len(missing_positions)} -> {len(missing_positions_filtered)}"
    )
    print(f"Detection rate: {rate_before:.1f}% -> {rate_after:.1f}%")
    print("=" * 55)


if __name__ == "__main__":
    main()
