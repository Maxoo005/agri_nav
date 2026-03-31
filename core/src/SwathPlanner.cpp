#include "SwathPlanner.h"
#include "clipper2/clipper.h"
#include <algorithm>
#include <cmath>
#include <limits>

using namespace Clipper2Lib;

#ifndef M_PI
static constexpr double M_PI = 3.14159265358979323846;
#endif

namespace agrinav {

// ─── ENU helpers ──────────────────────────────────────────────────────────────

static constexpr double kMPerDegLat = 111320.0;

struct Vec2 { double e, n; };

static Vec2 toENU(double oLat, double oLon, double lat, double lon) {
    const double cosLat = std::cos(oLat * (M_PI / 180.0));
    return { (lon - oLon) * kMPerDegLat * cosLat,
             (lat - oLat) * kMPerDegLat };
}

static LatLon fromENU(double oLat, double oLon, const Vec2& v) {
    const double cosLat = std::cos(oLat * (M_PI / 180.0));
    return { oLat + v.n / kMPerDegLat,
             oLon + v.e / (kMPerDegLat * cosLat) };
}

static double dot(const Vec2& a, const Vec2& b)     { return a.e * b.e + a.n * b.n; }
static double cross2d(const Vec2& a, const Vec2& b) { return a.e * b.n - a.n * b.e; }
static double normVec(const Vec2& v)                 { return std::sqrt(v.e * v.e + v.n * v.n); }

static Vec2 normalize(const Vec2& v) {
    const double l = normVec(v);
    return l < 1e-12 ? Vec2{0.0, 0.0} : Vec2{v.e / l, v.n / l};
}

// ─── Polygon utilities ────────────────────────────────────────────────────────

/// Shoelace signed area. Positive → CCW in standard (ENU) coordinate frame.
static double signedArea(const std::vector<Vec2>& p) {
    double a = 0.0;
    const int n = static_cast<int>(p.size());
    for (int i = 0; i < n; ++i)
        a += cross2d(p[i], p[(i + 1) % n]);
    return a * 0.5;
}

/// Reverse polygon in-place when winding is clockwise (signed area < 0).
static void ensureCCW(std::vector<Vec2>& p) {
    if (signedArea(p) < 0.0)
        std::reverse(p.begin(), p.end());
}

/// Inward polygon offset by `offset` metres using Clipper2 InflatePaths.
///
/// JoinType::Round eliminates the spikes that the previous miter/bevel
/// vertex-walk produced at sharp field corners.  arc_tolerance = 0.25 m
/// keeps the vertex count low for typical field polygons.
///
/// Contract: input must be CCW (enforced by ensureCCW before every call).
/// Returns an empty vector when the polygon fully collapses (area ≤ 0 after
/// shrinking — field is too narrow for this offset value).
static std::vector<Vec2> offsetPolygon(const std::vector<Vec2>& poly,
                                       double                    offset) {
    if (static_cast<int>(poly.size()) < 3 || offset <= 0.0) return {};

    // Build a Clipper2 PathD from ENU metres (x = east, y = north).
    PathD path;
    path.reserve(poly.size());
    for (const auto& v : poly)
        path.emplace_back(v.e, v.n);

    // Negative delta shrinks a CCW polygon inward.
    // miter_limit=2, precision=2 (1 cm), arc_tolerance=0.25 m.
    const PathsD result = InflatePaths(
        PathsD{path},
        -offset,
        JoinType::Round,
        EndType::Polygon,
        /*miter_limit=*/2.0,
        /*precision=*/2,
        /*arc_tolerance=*/0.25
    );

    if (result.empty()) return {};

    // Use the largest output ring (InflatePaths may return multiple rings for
    // self-intersecting inputs; we want the outermost valid contraction).
    const PathD* best = &result[0];
    double bestArea = 0.0;
    for (const auto& r : result) {
        double area = 0.0;
        const int n  = static_cast<int>(r.size());
        for (int i = 0; i < n; ++i) {
            const auto& a = r[static_cast<size_t>(i)];
            const auto& b = r[static_cast<size_t>((i + 1) % n)];
            area += a.x * b.y - b.x * a.y;
        }
        area = std::abs(area) * 0.5;
        if (area > bestArea) { bestArea = area; best = &r; }
    }
    if (bestArea < 1e-4) return {};    // polygon collapsed

    std::vector<Vec2> out;
    out.reserve(best->size());
    for (const auto& pt : *best)
        out.push_back({pt.x, pt.y});

    // Ensure the ring is still CCW after the offset (Clipper2 preserves winding
    // but we guard defensively).
    if (signedArea(out) < 0.0) std::reverse(out.begin(), out.end());

    return out;
}

// ─── Scanline / polygon intersection ─────────────────────────────────────────

/// Collect sorted intersection parameters along the d-axis where the scan line
/// { dot(P, p) = tK } crosses the polygon edges.
/// Half-open edge parameter u ∈ [0,1) avoids double-counting shared vertices.
/// Enforces even count (Jordan curve theorem; pops last entry if odd).
static std::vector<double> clipScanLine(const std::vector<Vec2>& poly,
                                        const Vec2&               d,
                                        const Vec2&               p,
                                        double                    tK) {
    std::vector<double> sVals;
    sVals.reserve(8);

    const int sz = static_cast<int>(poly.size());
    for (int i = 0; i < sz; ++i) {
        const Vec2& v0 = poly[i];
        const Vec2& v1 = poly[(i + 1) % sz];

        const double d0 = dot(v0, p) - tK;
        const double d1 = dot(v1, p) - tK;
        const double dd = d1 - d0;

        if (std::abs(dd) < 1e-10) continue;

        const double u = d0 / (d0 - d1);
        if (u < 0.0 || u >= 1.0) continue;

        const Vec2 pt = {v0.e + u * (v1.e - v0.e),
                         v0.n + u * (v1.n - v0.n)};
        sVals.push_back(dot(pt, d));
    }

    std::sort(sVals.begin(), sVals.end());
    if (!sVals.empty() && sVals.size() % 2 != 0) sVals.pop_back();
    return sVals;
}

// ─── Main entry point ─────────────────────────────────────────────────────────

SwathPlan SwathPlanner::plan(
    const std::vector<LatLon>& polygon,
    LatLon                     a,
    LatLon                     b,
    double                     workingWidthM,
    double                     overlapM,
    int                        headlandLaps
) {
    SwathPlan result;
    if (polygon.size() < 3 || workingWidthM <= 0.0) return result;

    const double oLat = a.lat;
    const double oLon = a.lon;

    // 1. AB direction vectors ──────────────────────────────────────────────────
    const Vec2 bEnu = toENU(oLat, oLon, b.lat, b.lon);
    if (normVec(bEnu) < 0.01) return result;  // A == B

    const Vec2 d = normalize(bEnu);   // unit vector along AB
    const Vec2 p = {-d.n, d.e};       // unit perpendicular (90° CCW = "left")

    // 2. Convert boundary to ENU; normalise winding to CCW ─────────────────────
    const int sz = static_cast<int>(polygon.size());
    std::vector<Vec2> outerPoly(static_cast<size_t>(sz));
    for (int i = 0; i < sz; ++i)
        outerPoly[static_cast<size_t>(i)] =
            toENU(oLat, oLon, polygon[static_cast<size_t>(i)].lat,
                               polygon[static_cast<size_t>(i)].lon);
    ensureCCW(outerPoly);

    // 3. Effective strip pitch = workingWidth − overlap (clamped) ──────────────
    const double effectiveWidth =
        std::max(workingWidthM - std::max(overlapM, 0.0), 0.1);

    // 4. Headland rings ────────────────────────────────────────────────────────
    //
    // The antenna (machine centre) of pass k must sit at the offset that makes
    // the machine's outer edge touch the previous boundary:
    //
    //   pass 1 : offset = W/2          (outer edge = field boundary)
    //   pass 2 : offset = W/2 + W
    //   pass k : offset = W/2 + (k-1)×W  =  (k - 0.5) × effectiveWidth
    //
    // Each ring is computed independently from outerPoly to prevent
    // compounding numerical error across laps.
    //
    // The inner clipping boundary for swath planning is the full-width
    // offset (headlandLaps × effectiveWidth), i.e. just inside the inner
    // edge of the last headland pass — NOT the antenna path of that pass.

    std::vector<Vec2> innerPoly;  // swath-clipping boundary, set after the loop

    for (int k = 1; k <= headlandLaps; ++k) {
        // Antenna-path offset: outer machine edge aligns with previous boundary
        const double antennaOffset =
            (static_cast<double>(k) - 0.5) * effectiveWidth;
        const std::vector<Vec2> ring = offsetPolygon(outerPoly, antennaOffset);
        if (ring.empty()) break;  // field too narrow — stop generating more laps

        // Store ring as LatLon for rendering / guidance.
        std::vector<LatLon> ringLL;
        ringLL.reserve(ring.size());
        for (const auto& v : ring)
            ringLL.push_back(fromENU(oLat, oLon, v));
        result.headlandRings.push_back(std::move(ringLL));
    }

    // Inner clipping boundary = full-width inset after all headland laps.
    // Swaths must not cross this line (they would overlap the headland area).
    if (headlandLaps > 0) {
        const double clipOffset =
            static_cast<double>(headlandLaps) * effectiveWidth;
        innerPoly = offsetPolygon(outerPoly, clipOffset);
    }
    // Fallback: no headland or field too narrow to clip — use outer boundary.
    if (innerPoly.empty()) innerPoly = outerPoly;

    // 5. Parallel swaths inside innerPoly ─────────────────────────────────────
    if (innerPoly.size() < 3) return result;

    double tMin =  std::numeric_limits<double>::max();
    double tMax = -std::numeric_limits<double>::max();
    for (const auto& v : innerPoly) {
        const double t = dot(v, p);
        if (t < tMin) tMin = t;
        if (t > tMax) tMax = t;
    }

    const int nLines = 1 + static_cast<int>(
        std::floor((tMax - tMin) / effectiveWidth));

    for (int k = 0; k <= nLines; ++k) {
        const double tK = tMin + static_cast<double>(k) * effectiveWidth;
        if (tK > tMax + 1e-9) break;

        const std::vector<double> sVals = clipScanLine(innerPoly, d, p, tK);

        for (size_t i = 0; i + 1 < sVals.size(); i += 2) {
            const double sS = sVals[i];
            const double sE = sVals[i + 1];
            if (sE - sS < 0.01) continue;  // discard numerical artefacts

            result.swaths.push_back({
                fromENU(oLat, oLon, {tK * p.e + sS * d.e,
                                     tK * p.n + sS * d.n}),
                fromENU(oLat, oLon, {tK * p.e + sE * d.e,
                                     tK * p.n + sE * d.n})
            });
        }
    }

    return result;
}

} // namespace agrinav
