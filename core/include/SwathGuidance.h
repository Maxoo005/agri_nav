#pragma once
#include "SwathPlanner.h"
#include <mutex>
#include <vector>

namespace agrinav {

/// Result of a snap-to-nearest-swath query.
struct SnapResult {
    double distanceM;       ///< unsigned perpendicular distance to nearest swath [m]
    int    swathIndex;      ///< index into current swath list; -1 when no swaths loaded
    int    side;            ///< +1 = right of swath direction, -1 = left, 0 = on-line
    double headingErrorDeg; ///< signed heading error [deg]: machine heading − swath dir,
                            ///< range (−180, 180], positive = veering right
};

/// Thread-safe snap-to-nearest-swath guidance engine.
///
/// Usage:
///   1. After SwathPlanner::plan(), call setSwaths() to precompute ENU geometry.
///   2. Each GPS tick, call query() to obtain the nearest swath + lateral offset.
///
/// Performance:
///   All swath endpoints are converted to ENU once at setSwaths() time.
///   query() applies a 50 m bounding-cylinder spatial pre-filter before
///   computing exact point-to-segment distances, keeping the per-tick cost
///   negligible even for 500+ swaths.
///   Both setSwaths() and query() are fully thread-safe (std::mutex).
class SwathGuidance {
public:
    SwathGuidance() = default;

    /// Precompute ENU geometry from a SwathPlan result.
    ///
    /// @param swaths  Inner-field swaths (SwathPlan::swaths).
    /// @param origin  WGS-84 ENU origin — use point A of the AB line so that
    ///                coordinates are consistent with SwathPlanner.
    void setSwaths(const std::vector<Swath>& swaths, LatLon origin);

    /// Query nearest swath.  Thread-safe (read lock).
    ///
    /// @param lat        Current position latitude  [deg WGS-84].
    /// @param lon        Current position longitude [deg WGS-84].
    /// @param headingDeg Machine heading, degrees from North, clock-wise.
    /// @return           SnapResult; swathIndex == -1 when no swaths loaded.
    SnapResult query(double lat, double lon, double headingDeg) const;

    /// Returns true when at least one swath has been loaded.
    bool hasSwaths() const;

private:
    /// Pre-computed per-swath ENU data for fast look-up.
    struct EchoSwath {
        double sE, sN;   ///< start point [m ENU]
        double eE, eN;   ///< end point   [m ENU]
        double dE, dN;   ///< unit direction vector (start → end)
        double len;      ///< segment length [m]
    };

    mutable std::mutex     _mtx;
    std::vector<EchoSwath> _cache;
    LatLon                 _origin{};
    double                 _cosLat{1.0}; ///< cached cos(origin.lat) for ENU conversion
};

} // namespace agrinav
