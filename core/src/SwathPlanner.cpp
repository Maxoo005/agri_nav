#include "SwathPlanner.h"
#include "clipper2/clipper.h"
#include <algorithm>
#include <array>
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

// ─── Field geometry: angle-independent, expensive (Clipper2) part ────────────

/// Everything about a field that does NOT depend on swath bearing: the CCW
/// outer boundary, the headland rings, the swath-clipping inner boundary and
/// the effective strip pitch. Shared by [SwathPlanner::plan] and
/// [SwathPlanner::optimizeAngle] so the Clipper2 offset work only ever runs
/// once per call.
struct FieldGeometry {
    std::vector<Vec2> outerPoly;                        // ENU, CCW
    std::vector<Vec2> innerPoly;                         // ENU, CCW — swath clip boundary
    std::vector<std::vector<Vec2>> headlandRingsEnu;     // ENU, lap 1..k order
    double effectiveWidth = 0.1;
    bool   valid = false;
};

static FieldGeometry buildFieldGeometry(
    const std::vector<LatLon>& polygon,
    double oLat, double oLon,
    double workingWidthM, double overlapM, int headlandLaps
) {
    FieldGeometry geo;
    if (polygon.size() < 3 || workingWidthM <= 0.0) return geo;

    const int sz = static_cast<int>(polygon.size());
    geo.outerPoly.resize(static_cast<size_t>(sz));
    for (int i = 0; i < sz; ++i)
        geo.outerPoly[static_cast<size_t>(i)] =
            toENU(oLat, oLon, polygon[static_cast<size_t>(i)].lat,
                               polygon[static_cast<size_t>(i)].lon);
    ensureCCW(geo.outerPoly);

    // Effective strip pitch = workingWidth − overlap (clamped) ────────────────
    geo.effectiveWidth = std::max(workingWidthM - std::max(overlapM, 0.0), 0.1);

    // Headland rings ────────────────────────────────────────────────────────
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
    for (int k = 1; k <= headlandLaps; ++k) {
        const double antennaOffset =
            (static_cast<double>(k) - 0.5) * geo.effectiveWidth;
        std::vector<Vec2> ring = offsetPolygon(geo.outerPoly, antennaOffset);
        if (ring.empty()) break;  // field too narrow — stop generating more laps
        geo.headlandRingsEnu.push_back(std::move(ring));
    }

    // Inner clipping boundary = full-width inset after all headland laps.
    // Swaths must not cross this line (they would overlap the headland area).
    if (headlandLaps > 0) {
        const double clipOffset =
            static_cast<double>(headlandLaps) * geo.effectiveWidth;
        geo.innerPoly = offsetPolygon(geo.outerPoly, clipOffset);
    }
    // Fallback: no headland or field too narrow to clip — use outer boundary.
    if (geo.innerPoly.empty()) geo.innerPoly = geo.outerPoly;

    geo.valid = geo.innerPoly.size() >= 3;
    return geo;
}

static std::vector<std::vector<LatLon>> ringsToLatLon(
    const std::vector<std::vector<Vec2>>& ringsEnu, double oLat, double oLon
) {
    std::vector<std::vector<LatLon>> out;
    out.reserve(ringsEnu.size());
    for (const auto& ring : ringsEnu) {
        std::vector<LatLon> ringLL;
        ringLL.reserve(ring.size());
        for (const auto& v : ring)
            ringLL.push_back(fromENU(oLat, oLon, v));
        out.push_back(std::move(ringLL));
    }
    return out;
}

// ─── Swath sweep: angle-dependent, cheap (no Clipper2) part ──────────────────

/// Result of sweeping parallel scanlines across [innerPoly] along direction
/// [d] (perpendicular axis [p]) — kept in ENU (no WGS-84 round-trip) until
/// the final [materializeSwaths] conversion back to WGS-84.
struct EnuSweepResult {
    std::vector<std::array<double, 3>> segments;  // {tK, sS, sE} per swath
    double totalLengthM = 0.0;
    int    swathCount   = 0;
};

static EnuSweepResult sweepSwathsEnu(
    const std::vector<Vec2>& innerPoly, const Vec2& d, const Vec2& p,
    double effectiveWidth, bool flushNearSide
) {
    EnuSweepResult out;
    if (innerPoly.size() < 3) return out;

    double tMin =  std::numeric_limits<double>::max();
    double tMax = -std::numeric_limits<double>::max();
    for (const auto& v : innerPoly) {
        const double t = dot(v, p);
        if (t < tMin) tMin = t;
        if (t > tMax) tMax = t;
    }

    const double span = tMax - tMin;
    int    nLines;
    double c1;

    if (flushNearSide) {
        // headlandLaps > 0: the pass nearest tMin MUST be flush against
        // innerPoly — its outer edge (centreline − W/2) has to land exactly
        // on tMin, zero tolerance (this is what makes the machine's outer
        // edge touch the headland's inner edge with no gap and no overlap).
        // Any leftover slack that doesn't divide evenly into whole passes is
        // pushed entirely onto the far (tMax) side, and only ever as a GAP —
        // nLines is floor()'d, never ceil()'d, so the far-side pass can
        // never cross tMax either (consistent with "swaths must not cross
        // innerPoly" below). Worst case the far side is left with an
        // uncovered strip up to just under one effectiveWidth; that's the
        // accepted trade-off for guaranteeing the near-side flush touch.
        nLines = (span < effectiveWidth)
            ? 1
            : std::max(1, static_cast<int>(std::floor(span / effectiveWidth + 1e-9)));
        c1 = tMin + effectiveWidth * 0.5;
    } else {
        // headlandLaps == 0: no headland ring exists, so there is nothing to
        // flush against — keep the symmetric, span-centred fixed-pitch grid
        // from the previous fix (replaces the old tMin-anchored grid, which
        // either double-covered a half-width strip when the swath direction
        // ran parallel to the nearest edge, or silently dropped a whole pass
        // to a sub-threshold sliver when tMin was realised at a single
        // vertex instead of a whole edge).
        nLines = std::max(
            1, static_cast<int>(std::ceil(span / effectiveWidth - 1e-9)));
        const double center = (tMin + tMax) * 0.5;
        c1 = center - static_cast<double>(nLines - 1) * effectiveWidth * 0.5;
    }

    for (int k = 0; k < nLines; ++k) {
        const double tK = c1 + static_cast<double>(k) * effectiveWidth;

        const std::vector<double> sVals = clipScanLine(innerPoly, d, p, tK);

        for (size_t i = 0; i + 1 < sVals.size(); i += 2) {
            const double sS = sVals[i];
            const double sE = sVals[i + 1];
            if (sE - sS < 0.01) continue;  // discard numerical artefacts

            out.segments.push_back({tK, sS, sE});
            out.totalLengthM += sE - sS;
            ++out.swathCount;
        }
    }

    return out;
}

static std::vector<Swath> materializeSwaths(
    const EnuSweepResult& sweep, const Vec2& d, const Vec2& p,
    double oLat, double oLon
) {
    std::vector<Swath> out;
    out.reserve(sweep.segments.size());
    for (const auto& seg : sweep.segments) {
        const double tK = seg[0], sS = seg[1], sE = seg[2];
        out.push_back({
            fromENU(oLat, oLon, {tK * p.e + sS * d.e, tK * p.n + sS * d.n}),
            fromENU(oLat, oLon, {tK * p.e + sE * d.e, tK * p.n + sE * d.n})
        });
    }
    return out;
}

// ─── Deterministic direction rule: longest boundary edge ─────────────────────

/// Bearing of the single longest edge between adjacent vertices of [poly]
/// (CCW ENU), folded to [0, 180) in the same convention as
/// [SwathPlanner::plan]'s AB-derived bearing (d = (sinθ, cosθ) in (E,N)).
/// Full double precision (no rounding) — exact to the input coordinates.
static double longestEdgeBearingDeg(const std::vector<Vec2>& poly) {
    const int n = static_cast<int>(poly.size());
    if (n < 2) return 0.0;

    double bestLenSq    = -1.0;
    double bestAngleDeg =  0.0;
    for (int i = 0; i < n; ++i) {
        const Vec2& a = poly[static_cast<size_t>(i)];
        const Vec2& b = poly[static_cast<size_t>((i + 1) % n)];
        const double de = b.e - a.e;
        const double dn = b.n - a.n;
        const double lenSq = de * de + dn * dn;
        if (lenSq > bestLenSq) {
            bestLenSq = lenSq;
            const double angleDeg = std::atan2(de, dn) * 180.0 / M_PI;
            bestAngleDeg = std::fmod(angleDeg + 360.0, 180.0);
        }
    }
    return bestAngleDeg;
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

    const Vec2 bEnu = toENU(oLat, oLon, b.lat, b.lon);
    if (normVec(bEnu) < 0.01) return result;  // A == B

    const Vec2 d = normalize(bEnu);   // unit vector along AB
    const Vec2 p = {-d.n, d.e};       // unit perpendicular (90° CCW = "left")

    const FieldGeometry geo = buildFieldGeometry(
        polygon, oLat, oLon, workingWidthM, overlapM, headlandLaps);
    if (!geo.valid) return result;

    const EnuSweepResult sweep = sweepSwathsEnu(
        geo.innerPoly, d, p, geo.effectiveWidth, headlandLaps > 0);
    result.swaths = materializeSwaths(sweep, d, p, oLat, oLon);
    result.headlandRings = ringsToLatLon(geo.headlandRingsEnu, oLat, oLon);
    return result;
}

SwathAngleResult SwathPlanner::optimizeAngle(
    const std::vector<LatLon>& polygon,
    double                     workingWidthM,
    double                     overlapM,
    int                        headlandLaps
) {
    SwathAngleResult result;
    if (polygon.size() < 3 || workingWidthM <= 0.0) return result;

    const double oLat = polygon[0].lat;
    const double oLon = polygon[0].lon;

    const FieldGeometry geo = buildFieldGeometry(
        polygon, oLat, oLon, workingWidthM, overlapM, headlandLaps);
    if (!geo.valid) return result;

    // Deterministic rule: swath bearing = bearing of the field boundary's
    // single longest edge, folded to [0, 180). Replaces the old coarse-to-
    // fine blind search (no scoring, no turn-penalty heuristic, no rotating
    // calipers) — see longestEdgeBearingDeg().
    //
    // Edge case: the RTK-walked boundary is RDP-simplified (ε ≈ 0.15 m,
    // see map_view.dart) before it reaches this function, which removes
    // most walking-noise vertices. A long, nominally straight edge with a
    // real deviation greater than that epsilon can still survive as two
    // separate segments, in which case this rule may pick a different edge
    // than the field's true longest physical side.
    const double bestAngle = longestEdgeBearingDeg(geo.outerPoly);

    const double rad = bestAngle * M_PI / 180.0;
    const Vec2 d = { std::sin(rad), std::cos(rad) };
    const Vec2 p = { -d.n, d.e };

    const EnuSweepResult sweep = sweepSwathsEnu(
        geo.innerPoly, d, p, geo.effectiveWidth, headlandLaps > 0);

    result.plan.swaths = materializeSwaths(sweep, d, p, oLat, oLon);
    result.plan.headlandRings = ringsToLatLon(geo.headlandRingsEnu, oLat, oLon);
    result.bestAngleDeg = bestAngle;
    result.totalLengthM = sweep.totalLengthM;
    result.swathCount   = sweep.swathCount;
    return result;
}

} // namespace agrinav
