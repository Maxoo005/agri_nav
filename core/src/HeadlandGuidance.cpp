#include "HeadlandGuidance.h"

#include <algorithm>
#include <cmath>
#include <limits>

#ifndef M_PI
static constexpr double M_PI = 3.14159265358979323846;
#endif

namespace agrinav {

static constexpr double kMPerDegLatHL    = 111320.0;
static constexpr double kSearchRadiusHL  = 50.0;   // spatial pre-filter [m]

static inline double degToRadHL(double d) { return d * (M_PI / 180.0); }

// ── setRings ─────────────────────────────────────────────────────────────────

void HeadlandGuidance::setRings(
    const std::vector<std::vector<LatLon>>& rings,
    LatLon origin
) {
    std::unique_lock<std::shared_mutex> lk(_mtx);

    _origin = origin;
    _cosLat = std::cos(degToRadHL(origin.lat));
    const double mPerDegLon = kMPerDegLatHL * _cosLat;

    _cache.clear();

    for (int32_t ri = 0; ri < static_cast<int32_t>(rings.size()); ++ri) {
        const auto& ring = rings[static_cast<size_t>(ri)];
        const int32_t n = static_cast<int32_t>(ring.size());
        if (n < 2) continue;

        // Include the closing edge (last → first vertex).
        for (int32_t si = 0; si < n; ++si) {
            const LatLon& a = ring[static_cast<size_t>(si)];
            const LatLon& b = ring[static_cast<size_t>((si + 1) % n)];

            EchoSeg seg;
            seg.sE = (a.lon - origin.lon) * mPerDegLon;
            seg.sN = (a.lat - origin.lat) * kMPerDegLatHL;
            seg.eE = (b.lon - origin.lon) * mPerDegLon;
            seg.eN = (b.lat - origin.lat) * kMPerDegLatHL;

            const double dx = seg.eE - seg.sE;
            const double dy = seg.eN - seg.sN;
            seg.len = std::sqrt(dx * dx + dy * dy);

            if (seg.len < 0.01) { seg.dE = 1.0; seg.dN = 0.0; }
            else                 { seg.dE = dx / seg.len; seg.dN = dy / seg.len; }

            seg.ringIndex = ri;
            seg.segIndex  = si;
            _cache.push_back(seg);
        }
    }
}

// ── hasRings ─────────────────────────────────────────────────────────────────

bool HeadlandGuidance::hasRings() const {
    std::shared_lock<std::shared_mutex> lk(_mtx);
    return !_cache.empty();
}

// ── query ────────────────────────────────────────────────────────────────────

HeadlandSnapResult HeadlandGuidance::query(
    double lat, double lon, double headingDeg
) const {
    std::shared_lock<std::shared_mutex> lk(_mtx);

    if (_cache.empty()) return {0.f, 0.f, -1, -1};

    const double mPerDegLon = kMPerDegLatHL * _cosLat;
    const double qE = (lon - _origin.lon) * mPerDegLon;
    const double qN = (lat - _origin.lat) * kMPerDegLatHL;

    // Machine heading as ENU unit vector (0° = North = +N, 90° = East = +E).
    const double hRad = degToRadHL(headingDeg);
    const double hE   = std::sin(hRad);
    const double hN   = std::cos(hRad);

    double bestScore    = std::numeric_limits<double>::max();
    double bestSigned   = 0.0;
    double bestHeadErr  = 0.0;
    int    bestCacheIdx = -1;

    for (int i = 0; i < static_cast<int>(_cache.size()); ++i) {
        const EchoSeg& seg = _cache[static_cast<size_t>(i)];

        // ── Spatial pre-filter (50 m bounding cylinder) ───────────────────
        const double rxS = qE - seg.sE;
        const double ryS = qN - seg.sN;

        const double tProj = rxS * seg.dE + ryS * seg.dN;
        if (tProj < -kSearchRadiusHL || tProj > seg.len + kSearchRadiusHL) continue;

        const double latDist = std::abs(rxS * seg.dN - ryS * seg.dE);
        if (latDist > kSearchRadiusHL) continue;

        // ── Exact signed point-to-segment distance ────────────────────────
        // Cross product of seg direction with (query − seg_start):
        //   positive → query is to the RIGHT of the direction of travel.
        double signedDist;
        double dist;

        if (tProj <= 0.0) {
            const double dx = qE - seg.sE;
            const double dy = qN - seg.sN;
            dist       = std::sqrt(dx * dx + dy * dy);
            signedDist = dx * seg.dN - dy * seg.dE;
        } else if (tProj >= seg.len) {
            const double dx = qE - seg.eE;
            const double dy = qN - seg.eN;
            dist       = std::sqrt(dx * dx + dy * dy);
            signedDist = dx * seg.dN - dy * seg.dE;
        } else {
            signedDist = rxS * seg.dN - ryS * seg.dE;
            dist       = std::abs(signedDist);
        }

        // ── Heading alignment penalty (same as SwathGuidance) ────────────
        const double dotFwd  =  hE * seg.dE + hN * seg.dN;
        const double dotBwd  = -(hE * seg.dE + hN * seg.dN);
        const double bestDot = std::max(dotFwd, dotBwd);
        const double alignDeg = std::acos(std::min(std::abs(bestDot), 1.0))
                                 * (180.0 / M_PI);
        const double score = dist + std::max(0.0, alignDeg - 45.0) * 0.15;

        if (score < bestScore) {
            bestScore    = score;
            bestSigned   = signedDist;
            bestCacheIdx = i;

            if (dotFwd >= dotBwd) {
                bestHeadErr = std::atan2(
                    hE * seg.dN - hN * seg.dE,
                    dotFwd
                ) * (180.0 / M_PI);
            } else {
                bestHeadErr = std::atan2(
                    hE * (-seg.dN) - hN * (-seg.dE),
                    dotBwd
                ) * (180.0 / M_PI);
            }
        }
    }

    if (bestCacheIdx < 0) return {0.f, 0.f, -1, -1};

    const EchoSeg& best = _cache[static_cast<size_t>(bestCacheIdx)];
    return {
        static_cast<float>(bestSigned),           // signed: + = right of travel
        static_cast<float>(bestHeadErr),
        best.ringIndex,
        best.segIndex
    };
}

} // namespace agrinav
