#include "SectionControl.h"
#include <algorithm>
#include <cmath>

namespace agrinav {

static constexpr double kPi     = 3.14159265358979323846;
static constexpr double kMetLat = 111320.0; // metres per degree of latitude

SectionControl::SectionControl(double cellSizeM)
    : _cellSizeM(cellSizeM > 0.05 ? cellSizeM : 1.0) {}

void SectionControl::setOrigin(double lat, double lon) {
    _originLat = lat;
    _originLon = lon;
    _cosLat    = std::cos(lat * kPi / 180.0);
    _hasOrigin = true;
}

// ── Internal helpers ──────────────────────────────────────────────────────────

std::pair<double, double> SectionControl::_toEnu(double lat, double lon) const {
    return {
        (lon - _originLon) * kMetLat * _cosLat,   // eE
        (lat - _originLat) * kMetLat               // eN
    };
}

// Encode (row, col) with ±600 000 range → covers 600 km radius at 1 m cells.
int64_t SectionControl::_key(int64_t row, int64_t col) {
    constexpr int64_t kOff   = 600000LL;
    constexpr int64_t kScale = 1200001LL; // 2*kOff + 1
    return (row + kOff) * kScale + (col + kOff);
}

std::vector<int64_t> SectionControl::_footprintKeys(
        double eE, double eN, double headingDeg, double toolWidthM) const
{
    // Perpendicular-to-heading unit vector in (E, N).
    const double rad   = headingDeg * kPi / 180.0;
    const double perpE =  std::cos(rad);   // 90° CCW of (sinθ, cosθ)
    const double perpN = -std::sin(rad);

    const double halfW  = toolWidthM * 0.5;
    // Sample at half-cell resolution so no cell is ever skipped.
    const double step   = _cellSizeM * 0.5;
    const int    nSteps = static_cast<int>(std::ceil(toolWidthM / step)) + 1;

    std::vector<int64_t> keys;
    keys.reserve(static_cast<size_t>(nSteps + 2));

    for (int i = 0; i <= nSteps; ++i) {
        const double t  = -halfW + i * step;
        const double pE = eE + t * perpE;
        const double pN = eN + t * perpN;

        const auto row = static_cast<int64_t>(std::floor(pN / _cellSizeM));
        const auto col = static_cast<int64_t>(std::floor(pE / _cellSizeM));
        keys.push_back(_key(row, col));
    }

    // Remove duplicates (sample list is small; sort+unique is cache-friendly).
    std::sort(keys.begin(), keys.end());
    keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
    return keys;
}

// ── Public API ────────────────────────────────────────────────────────────────

float SectionControl::checkOverlap(double lat, double lon,
                                    double headingDeg, double toolWidthM) const
{
    if (!_hasOrigin) return 0.f;
    const auto [eE, eN] = _toEnu(lat, lon);
    const auto keys     = _footprintKeys(eE, eN, headingDeg, toolWidthM);
    if (keys.empty()) return 0.f;

    int covered = 0;
    for (const auto k : keys)
        if (_cells.count(k)) ++covered;

    return static_cast<float>(covered) / static_cast<float>(keys.size());
}

float SectionControl::addStrip(double lat, double lon,
                                double headingDeg, double toolWidthM)
{
    if (!_hasOrigin) return 0.f;
    const auto [eE, eN] = _toEnu(lat, lon);
    const auto keys     = _footprintKeys(eE, eN, headingDeg, toolWidthM);
    if (keys.empty()) return 0.f;

    // Count overlap BEFORE inserting (caller receives "old" overlap).
    int covered = 0;
    for (const auto k : keys) {
        if (_cells.count(k)) ++covered;
        _cells.insert(k);
    }

    return static_cast<float>(covered) / static_cast<float>(keys.size());
}

double SectionControl::coveredAreaHa() const {
    return static_cast<double>(_cells.size()) * _cellSizeM * _cellSizeM / 10000.0;
}

void SectionControl::clear() {
    _cells.clear();
}

} // namespace agrinav
