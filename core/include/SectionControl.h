#pragma once
#include <cstdint>
#include <unordered_set>
#include <utility>
#include <vector>

namespace agrinav {

/// Grid-based Section-Control and coverage-area engine.
///
/// Divides the local ENU plane into square cells of [cellSizeM] × [cellSizeM].
/// For every vehicle tick, the tool footprint (width across the heading
/// perpendicular) is decomposed into cells.  The engine supports:
///
///   checkOverlap()  — fraction [0, 1] of the tool footprint already covered
///                     (read-only, does NOT change coverage state)
///   addStrip()      — mark footprint covered; returns overlap fraction
///                     calculated BEFORE the new cells are inserted
///   coveredAreaHa() — total unique covered area [ha]
///   clear()         — reset all cells (keeps origin + cell size)
///
/// Cell size: 1 m (default) → 1 ha = 10 000 cells.
/// Origin offset ±600 000 cells → supports 600 km fields at 1 m resolution.
class SectionControl {
public:
    explicit SectionControl(double cellSizeM = 1.0);

    /// Set the WGS-84 ENU origin.  Must be called before first use.
    void setOrigin(double lat, double lon);

    /// Returns fraction [0, 1] of the tool footprint at (lat, lon) already
    /// covered.  Read-only — does not update coverage state.
    float checkOverlap(double lat, double lon,
                       double headingDeg, double toolWidthM) const;

    /// Mark the tool footprint as covered; returns the overlap fraction
    /// that existed BEFORE this strip was added.
    float addStrip(double lat, double lon,
                   double headingDeg, double toolWidthM);

    /// Total covered area [ha] = unique cells × cellArea.
    double coveredAreaHa() const;

    /// Erase all coverage (retains origin + cell size).
    void clear();

    bool hasOrigin() const { return _hasOrigin; }

private:
    double _cellSizeM;
    double _originLat{0}, _originLon{0}, _cosLat{1};
    bool   _hasOrigin{false};

    std::unordered_set<int64_t> _cells;

    // Convert WGS-84 → local ENU [m] relative to origin.
    std::pair<double, double> _toEnu(double lat, double lon) const;

    // Enumerate all grid-cell keys that the tool rectangle overlaps.
    // The rectangle is centred at (eE, eN), spans toolWidthM perpendicular
    // to headingDeg.  No length sampling – one strip per GPS tick.
    std::vector<int64_t> _footprintKeys(double eE, double eN,
                                        double headingDeg,
                                        double toolWidthM) const;

    // Encode (row, col) to int64 with ±600 000 cell range.
    static int64_t _key(int64_t row, int64_t col);
};

} // namespace agrinav
