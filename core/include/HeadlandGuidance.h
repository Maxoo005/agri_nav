#pragma once
#include "SwathPlanner.h"
#include <mutex>
#include <shared_mutex>
#include <vector>

namespace agrinav {

/// Signed snap-to-nearest-headland-ring result.
struct HeadlandSnapResult {
    float   crossTrackM;       ///< signed cross-track [m]: +right / −left of ring travel direction
    float   headingErrorDeg;   ///< signed heading error [deg]: machine heading − local ring tangent
    int32_t ringIndex;         ///< index into the ring list; −1 when no rings loaded
    int32_t segmentIndex;      ///< index of the nearest segment within the ring
};

/// Thread-safe snap-to-nearest-headland-ring guidance engine.
///
/// Usage mirrors SwathGuidance:
///   1. After SwathPlanner::plan(), call setRings() to precompute ENU geometry.
///   2. Each GPS tick, call query() to obtain the nearest ring segment + signed
///      lateral offset.  The result feeds the Lightbar in headland mode.
///
/// Sign convention for crossTrackM:
///   The ring is traversed in the winding order stored by SwathPlanner
///   (CCW for rings generated via inward polygon offset).  Positive cross-track
///   means the machine is to the RIGHT of the local ring tangent direction.
///
/// Performance: identical to SwathGuidance — all ring segments are converted
/// to ENU once at setRings() time; query() applies a 50 m bounding-cylinder
/// spatial pre-filter before exact segment distance computation.
class HeadlandGuidance {
public:
    HeadlandGuidance() = default;

    /// Precompute ENU geometry from a list of headland rings.
    ///
    /// @param rings   Headland rings as closed polygons (SwathPlan::headlandRings).
    ///                Each ring is a sequence of WGS-84 points; the closing edge
    ///                (last→first) is added automatically.
    /// @param origin  WGS-84 ENU origin — use point A of the AB line so that
    ///                coordinates are consistent with SwathPlanner.
    void setRings(const std::vector<std::vector<LatLon>>& rings, LatLon origin);

    /// Query nearest headland ring segment.  Thread-safe (mutex read-lock).
    ///
    /// @param lat        Current position latitude  [deg WGS-84].
    /// @param lon        Current position longitude [deg WGS-84].
    /// @param headingDeg Machine heading, degrees from North, clockwise.
    /// @return           HeadlandSnapResult; ringIndex == −1 when no rings loaded.
    HeadlandSnapResult query(double lat, double lon, double headingDeg) const;

    /// Returns true when at least one ring has been loaded.
    bool hasRings() const;

private:
    /// Pre-computed per-segment ENU data for fast look-up.
    struct EchoSeg {
        double  sE, sN;    ///< segment start [m ENU]
        double  eE, eN;    ///< segment end   [m ENU]
        double  dE, dN;    ///< unit direction vector (start → end)
        double  len;       ///< segment length [m]
        int32_t ringIndex; ///< which ring this segment belongs to
        int32_t segIndex;  ///< segment index within the ring
    };

    mutable std::shared_mutex _mtx;
    std::vector<EchoSeg> _cache;
    LatLon               _origin{};
    double               _cosLat{1.0};
};

} // namespace agrinav
