#include "SwathPlanner.h"
#include <algorithm>
#include <cmath>
#include <limits>

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

/// Inward polygon offset by `offset` metres (Minkowski erosion for convex,
/// miter-join for general simple polygons).
///
/// Contract: input must be CCW.
///
/// Per-vertex algorithm:
///   For each vertex the new position is the intersection of the two adjacent
///   inward-offset edge lines (Cramer's rule).  When the miter would exceed
///   kMiterScale × offset (near-reflex or very sharp corners) the vertex is
///   bevelled to the midpoint of the two offset-edge endpoints instead,
///   preventing geometric spikes.
///
/// Returns an empty vector when the polygon fully collapses (area ≤ 0 after
/// shrinking — field is too narrow for this offset value).
static std::vector<Vec2> offsetPolygon(const std::vector<Vec2>& poly,
                                       double                    offset) {
    const int n = static_cast<int>(poly.size());
    if (n < 3 || offset <= 0.0) return {};

    // Maximum miter reach before switching to bevel (dimensionless ratio).
    constexpr double kMiterScale = 5.0;

    std::vector<Vec2> out;
    out.reserve(n);

    for (int i = 0; i < n; ++i) {
        const Vec2& prev = poly[(i - 1 + n) % n];
        const Vec2& curr = poly[i];
        const Vec2& next = poly[(i + 1) % n];

        // Unit vectors along incoming edge (prev→curr) and outgoing (curr→next).
        const Vec2 e1 = normalize({curr.e - prev.e, curr.n - prev.n});
        const Vec2 e2 = normalize({next.e - curr.e, next.n - curr.n});

        // Inward (left-side) normals for a CCW polygon:
        //   rotate edge direction 90° CCW → (-dn, de).
        const Vec2 n1 = {-e1.n,  e1.e};
        const Vec2 n2 = {-e2.n,  e2.e};

        // Reference points on the two inward-offset edge lines at this vertex.
        const Vec2 P1 = {curr.e + offset * n1.e, curr.n + offset * n1.n};
        const Vec2 P2 = {curr.e + offset * n2.e, curr.n + offset * n2.n};

        // Solve  t·e1 − s·e2 = P2 − P1  for t  (Cramer's rule).
        //   det = cross(e1, e2)
        //   t   = cross(rhs, e2) / det
        const Vec2   rhs = {P2.e - P1.e, P2.n - P1.n};
        const double det = cross2d(e1, e2);

        Vec2 vx;
        if (std::abs(det) < 1e-8) {
            // Parallel edges (straight section) — plain translation along n1.
            vx = P1;
        } else {
            const double t = cross2d(rhs, e2) / det;
            if (std::abs(t) > kMiterScale * offset) {
                // Sharp / near-reflex corner: bevel at midpoint of P1 and P2.
                vx = {(P1.e + P2.e) * 0.5, (P1.n + P2.n) * 0.5};
            } else {
                vx = {P1.e + t * e1.e, P1.n + t * e1.n};
            }
        }
        out.push_back(vx);
    }

    // Reject collapsed / inverted result (polygon vanished at this offset).
    if (signedArea(out) < 1e-4) return {};
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
    // Ring k is offset inward by  k × effectiveWidth  from the outer boundary.
    // Each ring is computed independently from outerPoly to avoid compounding error.
    std::vector<Vec2> innerPoly = outerPoly;  // inner field boundary, updated below

    for (int k = 1; k <= headlandLaps; ++k) {
        const double d_offset = static_cast<double>(k) * effectiveWidth;
        const std::vector<Vec2> ring = offsetPolygon(outerPoly, d_offset);
        if (ring.empty()) break;  // field too narrow — stop generating more laps

        // Store ring as LatLon (closed: first point repeated as last is NOT
        // stored; the caller closes if needed for rendering).
        std::vector<LatLon> ringLL;
        ringLL.reserve(ring.size());
        for (const auto& v : ring)
            ringLL.push_back(fromENU(oLat, oLon, v));
        result.headlandRings.push_back(std::move(ringLL));

        innerPoly = ring;  // deepest valid ring becomes the inner field boundary
    }

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
