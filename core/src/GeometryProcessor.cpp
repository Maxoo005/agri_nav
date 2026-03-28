#include "GeometryProcessor.h"
#include "clipper2/clipper.h"

#include <cmath>
#include <algorithm>

namespace agrinav {

// ── Lokalna ramka ENU (identyczna z ParcelMerger — kompilator i tak inline'uje) ─

static constexpr double kGPMPerDegLat = 111320.0;

struct GpRefFrame {
    double centerLat;
    double centerLon;
    double mPerDegLon;

    static GpRefFrame from(const std::vector<std::vector<LatLon>>& polys) {
        double sumLat = 0.0, sumLon = 0.0;
        size_t n = 0;
        for (const auto& poly : polys)
            for (const auto& pt : poly) {
                sumLat += pt.lat; sumLon += pt.lon; ++n;
            }
        const double cLat = n > 0 ? sumLat / n : 0.0;
        const double cLon = n > 0 ? sumLon / n : 0.0;
        return { cLat, cLon, kGPMPerDegLat * std::cos(cLat * M_PI / 180.0) };
    }

    Clipper2Lib::PointD toLocal(const LatLon& p) const {
        return { (p.lon - centerLon) * mPerDegLon,
                 (p.lat - centerLat) * kGPMPerDegLat };
    }

    LatLon fromLocal(const Clipper2Lib::PointD& p) const {
        double lat = centerLat + p.y / kGPMPerDegLat;
        double lon = (mPerDegLon > 1e-10)
                     ? centerLon + p.x / mPerDegLon
                     : centerLon;
        return { lat, lon };
    }
};

// ── Signed area (CCW > 0 = outer ring) ───────────────────────────────────────

static double gpSignedArea(const Clipper2Lib::PathD& path) {
    double area = 0.0;
    const size_t n = path.size();
    for (size_t i = 0; i < n; ++i) {
        const auto& a = path[i];
        const auto& b = path[(i + 1) % n];
        area += (a.x * b.y) - (b.x * a.y);
    }
    return area * 0.5;
}

// ── GeometryProcessor::processLpis ──────────────────────────────────────────

MergeResult GeometryProcessor::processLpis(
    const std::vector<std::vector<LatLon>>& parcels,
    const LpisProcessOptions& opts)
{
    if (parcels.empty()) return {};

    const GpRefFrame ref = GpRefFrame::from(parcels);

    // 1. WGS-84 → ENU [m]
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

    // 2. Outward buffer (elimina mikroszczelin)
    Clipper2Lib::PathsD working;
    if (opts.bufferM > 1e-6) {
        working = Clipper2Lib::InflatePaths(
            localPaths, opts.bufferM,
            Clipper2Lib::JoinType::Round,
            Clipper2Lib::EndType::Polygon);
    } else {
        working = localPaths;
    }

    // 3. Union Boolean
    Clipper2Lib::PathsD unioned = Clipper2Lib::Union(
        working, Clipper2Lib::FillRule::NonZero);
    if (unioned.empty()) return {};

    // 4. Simplify (Ramer–Douglas–Peucker przez Clipper2)
    if (opts.simplifyEpsilonM > 1e-6) {
        unioned = Clipper2Lib::SimplifyPaths(
            unioned,
            opts.simplifyEpsilonM,
            /*isOpen=*/false);
    }

    // 5. Klasyfikacja pierścieni
    std::vector<std::pair<size_t, double>> outerIndices;
    for (size_t i = 0; i < unioned.size(); ++i) {
        const double a = gpSignedArea(unioned[i]);
        if (a > 0.0) outerIndices.push_back({ i, a });
    }
    std::sort(outerIndices.begin(), outerIndices.end(),
              [](const auto& x, const auto& y){ return x.second > y.second; });

    MergeResult result;
    result.isMultipart = (outerIndices.size() > 1);

    for (size_t i = 0; i < unioned.size(); ++i) {
        const auto& rawPath = unioned[i];
        if (static_cast<int32_t>(rawPath.size()) < opts.minRingVertices)
            continue;

        const double area  = gpSignedArea(rawPath);
        const bool isOuter = (area > 0.0);

        size_t groupIdx = 0;
        if (!isOuter) {
            for (size_t k = 0; k < outerIndices.size(); ++k)
                if (outerIndices[k].first < i) groupIdx = k;
        } else {
            for (size_t k = 0; k < outerIndices.size(); ++k)
                if (outerIndices[k].first == i) { groupIdx = k; break; }
        }

        RingType rtype;
        if (isOuter)
            rtype = (groupIdx == 0) ? RingType::OuterPrimary : RingType::OuterSecondary;
        else
            rtype = (groupIdx == 0) ? RingType::HolePrimary  : RingType::HoleSecondary;

        // 6. ENU → WGS-84
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
