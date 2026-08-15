#pragma once
#include <vector>

namespace agrinav {

/// WGS-84 coordinate pair.
struct LatLon {
    double lat;
    double lon;
};

/// A single parallel pass (straight A→B segment) inside the inner field.
struct Swath {
    LatLon start;
    LatLon end;
};

/// Full planning result: inner-field swaths + concentric headland rings.
struct SwathPlan {
    /// Parallel inner-field fill swaths.
    std::vector<Swath> swaths;

    /// Headland rings as closed polygons (ready to render as polylines).
    /// Index 0 = nearest to field boundary (lap 1),
    /// index n-1 = innermost lap (adjacent to inner field).
    std::vector<std::vector<LatLon>> headlandRings;
};

/// Result of [SwathPlanner::optimizeAngle]: the swath plan at the field's
/// longest-edge bearing, plus the angle and summary stats that produced it.
struct SwathAngleResult {
    /// Full plan (swaths + headland rings) at [bestAngleDeg].
    SwathPlan plan;

    /// Winning swath bearing, degrees from North, folded to [0, 180).
    double bestAngleDeg = 0.0;

    /// Sum of all swath segment lengths [m] at [bestAngleDeg].
    double totalLengthM = 0.0;

    /// Number of swath segments at [bestAngleDeg] (== plan.swaths.size()).
    int swathCount = 0;
};

/// Parallel swath planner with polygon-offset headland support.
///
/// All geographic inputs are WGS-84. Every computation is done in a local
/// ENU frame (point A as origin), limiting projection error to < 1 mm for
/// fields up to ~10 km.
///
/// Algorithm:
///  1. Convert boundary to ENU; normalise to CCW winding.
///  2. Generate headlandLaps concentric rings via inward polygon offsetting
///     (miter join, miter-limited to 5× strip width to guard against spikes
///     at sharp corners; falls back to midpoint bevel automatically).
///  3. Clip parallel scanlines against the inner field polygon (boundary
///     remaining after removing all headland strips).
///  4. Convert all results back to WGS-84.
class SwathPlanner {
public:
    /// @param polygon        Field boundary vertices (WGS-84, CW or CCW).
    ///                       Need not be closed (last ≠ first).
    /// @param a              Point A of the reference line (WGS-84).
    /// @param b              Point B of the reference line (WGS-84).
    /// @param workingWidthM  Machine working width [m].
    /// @param overlapM       Strip overlap [m] subtracted from working width
    ///                       (0 = no overlap).  Clamped to [0, workingWidthM).
    /// @param headlandLaps   Number of concentric headland passes to produce
    ///                       (0 = full-field swaths with no headland).
    /// @return               SwathPlan ready for FFI transfer.
    static SwathPlan plan(
        const std::vector<LatLon>& polygon,
        LatLon                     a,
        LatLon                     b,
        double                     workingWidthM,
        double                     overlapM    = 0.0,
        int                        headlandLaps = 0
    );

    /// Deterministic swath bearing: the bearing of the field boundary's
    /// single longest edge (between adjacent vertices), folded to [0, 180)
    /// with full double precision. No search, no scoring — the same input
    /// polygon always yields the same angle.
    ///
    /// @param polygon           Field boundary vertices (WGS-84).
    /// @param workingWidthM     Machine working width [m].
    /// @param overlapM          Strip overlap [m] (see [plan]).
    /// @param headlandLaps      Headland passes (see [plan]).
    /// @return                  Longest-edge angle + its plan + summary stats.
    ///                          Empty plan / swathCount==0 on invalid input.
    static SwathAngleResult optimizeAngle(
        const std::vector<LatLon>& polygon,
        double                     workingWidthM,
        double                     overlapM     = 0.0,
        int                        headlandLaps = 0
    );
};

} // namespace agrinav
