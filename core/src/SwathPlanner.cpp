#include "SwathPlanner.h"
#include <algorithm>
#include <cmath>
#include <limits>

#ifndef M_PI
static constexpr double M_PI = 3.14159265358979323846;
#endif

namespace agrinav {

// ── Lokalna geometria ENU ─────────────────────────────────────────────────────

static constexpr double kMPerDegLat = 111320.0;

/// 2D wektor w układzie ENU (east [m], north [m]).
struct Vec2 { double e, n; };

/// Konwertuje WGS-84 → ENU względem punktu (originLat, originLon).
static Vec2 toENU(double oLat, double oLon, double lat, double lon) {
    const double cosLat = std::cos(oLat * M_PI / 180.0);
    return {
        (lon - oLon) * kMPerDegLat * cosLat,
        (lat - oLat) * kMPerDegLat
    };
}

/// Konwertuje ENU → WGS-84 względem punktu (originLat, originLon).
static LatLon fromENU(double oLat, double oLon, Vec2 v) {
    const double cosLat = std::cos(oLat * M_PI / 180.0);
    return {
        oLat + v.n / kMPerDegLat,
        oLon + v.e / (kMPerDegLat * cosLat)
    };
}

static double dot(Vec2 a, Vec2 b)  { return a.e * b.e + a.n * b.n; }
static double norm(Vec2 v)         { return std::sqrt(v.e * v.e + v.n * v.n); }
static Vec2   normalize(Vec2 v)    { const double l = norm(v); return {v.e / l, v.n / l}; }

// ── Algorytm ─────────────────────────────────────────────────────────────────

SwathPlan SwathPlanner::plan(
    const std::vector<LatLon>& polygon,
    LatLon                     a,
    LatLon                     b,
    double                     workingWidthM
) {
    SwathPlan result;

    // Walidacja wejścia
    if (polygon.size() < 3 || workingWidthM <= 0.0) return result;

    const double oLat = a.lat;
    const double oLon = a.lon;

    // ── 1. Układ kierunkowy AB ────────────────────────────────────────────────

    const Vec2 bEnu = toENU(oLat, oLon, b.lat, b.lon);
    if (norm(bEnu) < 0.01) return result;  // A == B

    const Vec2 d = normalize(bEnu);        // jednostkowy wektor wzdłuż AB
    const Vec2 p = { -d.n, d.e };          // jednostkowy wektor prostopadły (90° CCW)

    // ── 2. Wielokąt w ENU ────────────────────────────────────────────────────

    const int sz = static_cast<int>(polygon.size());
    std::vector<Vec2> poly(sz);
    for (int i = 0; i < sz; ++i)
        poly[i] = toENU(oLat, oLon, polygon[i].lat, polygon[i].lon);

    // ── 3. Zakres rzutowania na oś p ─────────────────────────────────────────

    double tMin =  std::numeric_limits<double>::max();
    double tMax = -std::numeric_limits<double>::max();
    for (const auto& v : poly) {
        const double t = dot(v, p);
        if (t < tMin) tMin = t;
        if (t > tMax) tMax = t;
    }

    // ── 4. Generowanie linii i przycinanie do wielokąta ───────────────────────

    // Liczba linii; pierwsza i ostatnia mogą leżeć na granicy pola
    const int nLines = 1 + static_cast<int>(std::floor((tMax - tMin) / workingWidthM));

    for (int k = 0; k <= nLines; ++k) {
        const double tK = tMin + static_cast<double>(k) * workingWidthM;
        if (tK > tMax + 1e-9) break;

        // Znajdź wszystkie parametry s wzdłuż d w punktach przecięcia
        // linii { dot(P, p) = tK } z krawędziami wielokąta.
        std::vector<double> sVals;
        sVals.reserve(4);

        for (int i = 0; i < sz; ++i) {
            const Vec2& v0 = poly[i];
            const Vec2& v1 = poly[(i + 1) % sz];

            // Signed distance od linii
            const double d0 = dot(v0, p) - tK;
            const double d1 = dot(v1, p) - tK;

            // Wyklucz krawędzie równoległe do linii
            const double dd = d1 - d0;
            if (std::abs(dd) < 1e-10) continue;

            // Parametr wzdłuż krawędzi wielokąta — musi być w [0, 1)
            // Używamy przedziału half-open żeby uniknąć podwójnego liczenia
            // wierzchołków (dwa sąsiednie krawędzie dzielą ten sam wierzchołek).
            const double u = d0 / (d0 - d1);
            if (u < 0.0 || u >= 1.0) continue;

            // Punkt przecięcia w ENU
            const Vec2 pt = {
                v0.e + u * (v1.e - v0.e),
                v0.n + u * (v1.n - v0.n)
            };
            sVals.push_back(dot(pt, d));  // parametr wzdłuż kierunku AB
        }

        if (sVals.size() < 2) continue;

        // Sortuj — parzyste indeksy = wejście w wielokąt, nieparzyste = wyjście
        std::sort(sVals.begin(), sVals.end());

        // Upewnij się, że mamy parzystą liczbę przecięć (teoria Jordan)
        if (sVals.size() % 2 != 0) sVals.pop_back();

        for (size_t i = 0; i + 1 < sVals.size(); i += 2) {
            const double sStart = sVals[i];
            const double sEnd   = sVals[i + 1];

            // Odcinek zbyt krótki (artefakt numeryczny) — pomiń
            if (sEnd - sStart < 0.01) continue;

            result.swaths.push_back({
                fromENU(oLat, oLon, { tK * p.e + sStart * d.e,
                                      tK * p.n + sStart * d.n }),
                fromENU(oLat, oLon, { tK * p.e + sEnd   * d.e,
                                      tK * p.n + sEnd   * d.n })
            });
        }
    }

    return result;
}

} // namespace agrinav
