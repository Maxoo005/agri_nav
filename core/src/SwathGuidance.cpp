#include "SwathGuidance.h"

#include <algorithm>
#include <cmath>
#include <limits>

#ifndef M_PI
static constexpr double M_PI = 3.14159265358979323846;
#endif

namespace agrinav {

static constexpr double kMPerDegLat    = 111320.0;
static constexpr double kSearchRadiusM = 50.0;   // spatial pre-filter radius [m]

static inline double degToRad(double d) { return d * (M_PI / 180.0); }

// ── setSwaths ────────────────────────────────────────────────────────────────

void SwathGuidance::setSwaths(const std::vector<Swath>& swaths, LatLon origin) {
    std::unique_lock<std::mutex> lk(_mtx);

    _origin = origin;
    _cosLat = std::cos(degToRad(origin.lat));
    const double mPerDegLon = kMPerDegLat * _cosLat;

    _cache.clear();
    _cache.reserve(swaths.size());

    for (const auto& s : swaths) {
        EchoSwath es;
        es.sE = (s.start.lon - origin.lon) * mPerDegLon;
        es.sN = (s.start.lat - origin.lat) * kMPerDegLat;
        es.eE = (s.end.lon   - origin.lon) * mPerDegLon;
        es.eN = (s.end.lat   - origin.lat) * kMPerDegLat;

        const double dx = es.eE - es.sE;
        const double dy = es.eN - es.sN;
        es.len = std::sqrt(dx * dx + dy * dy);

        if (es.len < 0.01) { es.dE = 1.0; es.dN = 0.0; }
        else               { es.dE = dx / es.len; es.dN = dy / es.len; }

        _cache.push_back(es);
    }
}

// ── hasSwaths ────────────────────────────────────────────────────────────────

bool SwathGuidance::hasSwaths() const {
    std::unique_lock<std::mutex> lk(_mtx);
    return !_cache.empty();
}

// ── query ────────────────────────────────────────────────────────────────────

SnapResult SwathGuidance::query(double lat, double lon, double headingDeg) const {
    std::unique_lock<std::mutex> lk(_mtx);

    if (_cache.empty()) return {0.0, -1, 0, 0.0};

    const double mPerDegLon = kMPerDegLat * _cosLat;
    const double qE = (lon - _origin.lon) * mPerDegLon;
    const double qN = (lat - _origin.lat) * kMPerDegLat;

    // Machine heading as ENU unit vector (0° = North = +N, 90° = East = +E)
    const double hRad = degToRad(headingDeg);
    const double hE   = std::sin(hRad);
    const double hN   = std::cos(hRad);

    double bestScore  = std::numeric_limits<double>::max();
    double bestSigned = 0.0;
    double bestHeadErr = 0.0;
    int    bestIdx    = -1;

    for (int i = 0; i < static_cast<int>(_cache.size()); ++i) {
        const EchoSwath& es = _cache[static_cast<size_t>(i)];

        // ── Spatial pre-filter ────────────────────────────────────────────
        // Vector from swath start to query point
        const double rxS = qE - es.sE;
        const double ryS = qN - es.sN;

        // Longitudinal projection along swath direction
        const double tProj = rxS * es.dE + ryS * es.dN;
        if (tProj < -kSearchRadiusM || tProj > es.len + kSearchRadiusM) continue;

        // Lateral (perpendicular) distance — quick reject
        const double latDist = std::abs(rxS * es.dN - ryS * es.dE);
        if (latDist > kSearchRadiusM) continue;

        // ── Exact point-to-segment signed distance ────────────────────────
        // Cross-product with swath direction: positive = right of the swath.
        double signedDist;
        double dist;

        if (tProj <= 0.0) {
            // Nearest point = segment start
            const double dx = qE - es.sE;
            const double dy = qN - es.sN;
            dist       = std::sqrt(dx * dx + dy * dy);
            signedDist = dx * es.dN - dy * es.dE;
        } else if (tProj >= es.len) {
            // Nearest point = segment end
            const double dx = qE - es.eE;
            const double dy = qN - es.eN;
            dist       = std::sqrt(dx * dx + dy * dy);
            signedDist = dx * es.dN - dy * es.dE;
        } else {
            // Nearest point is on the segment
            signedDist = rxS * es.dN - ryS * es.dE;
            dist       = std::abs(signedDist);
        }

        // ── Heading alignment penalty ─────────────────────────────────────
        // Consider both swath directions (machine may travel either way).
        const double dotFwd = hE * es.dE + hN * es.dN;   // cos of fwd angle
        const double dotBwd = -(hE * es.dE + hN * es.dN); // cos of bkwd angle
        const double bestDot = std::max(dotFwd, dotBwd);

        // Alignment angle in [0°, 90°] — 0° = perfectly aligned
        const double alignDeg = std::acos(std::min(std::abs(bestDot), 1.0))
                                 * (180.0 / M_PI);

        // Penalty: 0 when aligned within ±45°; 0.15 m per degree beyond that.
        // Very close swaths (< 1 m) are always preferred regardless of heading.
        const double score = dist + std::max(0.0, alignDeg - 45.0) * 0.15;

        if (score < bestScore) {
            bestScore  = score;
            bestSigned = signedDist;
            bestIdx    = i;

            // Signed heading error against the swath direction that gives
            // the smaller absolute heading difference.
            if (dotFwd >= dotBwd) {
                bestHeadErr = std::atan2(
                    hE * es.dN - hN * es.dE,  // cross product (sin of angle)
                    dotFwd                      // dot product  (cos of angle)
                ) * (180.0 / M_PI);
            } else {
                bestHeadErr = std::atan2(
                    hE * (-es.dN) - hN * (-es.dE),
                    dotBwd
                ) * (180.0 / M_PI);
            }
        }
    }

    if (bestIdx < 0) return {0.0, -1, 0, 0.0};

    const int side = (bestSigned >  0.01) ?  1 :
                     (bestSigned < -0.01) ? -1 : 0;
    return { std::abs(bestSigned), bestIdx, side, bestHeadErr };
}

} // namespace agrinav
