#include "ParcelMerger.h"
#include "clipper2/clipper.h"

#include <cmath>
#include <algorithm>
#include <numeric>

namespace agrinav {

// ── Lokalna konwersja WGS-84 ↔ ENU ──────────────────────────────────────────

static constexpr double kMPerDegLat = 111320.0;

struct RefFrame {
    double centerLat;
    double centerLon;
    double mPerDegLon;   // varies with latitude

    static RefFrame from(const std::vector<std::vector<LatLon>>& parcels) {
        double sumLat = 0.0, sumLon = 0.0;
        size_t n = 0;
        for (const auto& poly : parcels)
            for (const auto& pt : poly) {
                sumLat += pt.lat;
                sumLon += pt.lon;
                ++n;
            }
        double cLat = n > 0 ? sumLat / n : 0.0;
        double cLon = n > 0 ? sumLon / n : 0.0;
        return {cLat, cLon,
                kMPerDegLat * std::cos(cLat * M_PI / 180.0)};
    }

    Clipper2Lib::PointD toLocal(const LatLon& p) const {
        return {
            (p.lon - centerLon) * mPerDegLon,
            (p.lat - centerLat) * kMPerDegLat
        };
    }

    LatLon fromLocal(const Clipper2Lib::PointD& p) const {
        double lat = centerLat + p.y / kMPerDegLat;
        double lon = mPerDegLon > 1e-10
            ? centerLon + p.x / mPerDegLon
            : centerLon;
        return {lat, lon};
    }
};

// ── Orientacja (signed area) ─────────────────────────────────────────────────

/// Zwraca wartość dodatnią gdy pierścień jest CCW (outer), ujemną gdy CW (hole).
static double signedArea(const Clipper2Lib::PathD& path) {
    double area = 0.0;
    const size_t n = path.size();
    for (size_t i = 0; i < n; ++i) {
        const auto& a = path[i];
        const auto& b = path[(i + 1) % n];
        area += (a.x * b.y) - (b.x * a.y);
    }
    return area * 0.5;
}

// ── ParcelMerger::merge ──────────────────────────────────────────────────────

MergeResult ParcelMerger::merge(
    const std::vector<std::vector<LatLon>>& parcels,
    double bufferM)
{
    if (parcels.empty()) return {};

    const RefFrame ref = RefFrame::from(parcels);

    // 1. Konwersja WGS-84 → ENU
    Clipper2Lib::PathsD localPaths;
    localPaths.reserve(parcels.size());
    for (const auto& poly : parcels) {
        if (poly.size() < 3) continue;
        Clipper2Lib::PathD path;
        path.reserve(poly.size());
        for (const auto& pt : poly)
            path.push_back(ref.toLocal(pt));
        localPaths.push_back(std::move(path));
    }

    if (localPaths.empty()) return {};

    // 2. Outward buffer (+bufferM) → eliminacja mikroszczelin
    const Clipper2Lib::PathsD inflated = Clipper2Lib::InflatePaths(
        localPaths, bufferM,
        Clipper2Lib::JoinType::Round,
        Clipper2Lib::EndType::Polygon);

    // 3. Union Boolean
    const Clipper2Lib::PathsD unioned = Clipper2Lib::Union(
        inflated, Clipper2Lib::FillRule::NonZero);

    if (unioned.empty()) return {};

    // 4. Klasyfikacja pierścieni i konwersja ENU → WGS-84
    // Liczymy zewnętrzne obrys (CCW, area > 0)
    std::vector<std::pair<size_t, double>> outerIndices;  // (idx, area)
    for (size_t i = 0; i < unioned.size(); ++i) {
        double a = signedArea(unioned[i]);
        if (a > 0.0) outerIndices.push_back({i, a});
    }

    // Sortuj zewnętrzne malejąco po polu — największy jest główny
    std::sort(outerIndices.begin(), outerIndices.end(),
              [](const auto& x, const auto& y){ return x.second > y.second; });

    MergeResult result;
    result.isMultipart = (outerIndices.size() > 1);

    // Buduj ring dla każdego pierścienia
    size_t outerCount = 0;
    for (size_t i = 0; i < unioned.size(); ++i) {
        const auto& rawPath = unioned[i];
        const double area = signedArea(rawPath);
        const bool isOuter = (area > 0.0);

        // Ustal numer "grupy" (do jakiej zewnętrznej należy otwór)
        size_t groupIdx = 0;
        if (!isOuter) {
            // Otwór należy do najbliższej outer (heurystyka: po indeksie)
            for (size_t k = 0; k < outerIndices.size(); ++k) {
                if (outerIndices[k].first < i) groupIdx = k;
            }
        } else {
            // Znajdź pozycję tego outer w posortowanej liście
            for (size_t k = 0; k < outerIndices.size(); ++k) {
                if (outerIndices[k].first == i) { groupIdx = k; break; }
            }
        }

        RingType rtype;
        if (isOuter) {
            rtype = (groupIdx == 0)
                ? RingType::OuterPrimary
                : RingType::OuterSecondary;
        } else {
            rtype = (groupIdx == 0)
                ? RingType::HolePrimary
                : RingType::HoleSecondary;
        }

        MergeRing ring;
        ring.type = rtype;
        ring.points.reserve(rawPath.size());
        for (const auto& pt : rawPath)
            ring.points.push_back(ref.fromLocal(pt));
        result.rings.push_back(std::move(ring));
    }

    return result;
}

} // namespace agrinav
