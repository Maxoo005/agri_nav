#pragma once
#include "SwathPlanner.h"

#include <gtest/gtest-spi.h>
#include <gtest/gtest.h>

#include <cmath>
#include <fstream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

/// Ścisłe "oczekiwane niepowodzenie" (odpowiednik pytest xfail(strict=True)):
/// [assertion] opisuje zachowanie POPRAWNE i dziś nie przechodzi. Po naprawie
/// błędu w kodzie produkcyjnym test zacznie się wywalać — wtedy usuń XFAIL.
#define AGRINAV_XFAIL(reason, assertion)                                       \
    do {                                                                       \
        RecordProperty("xfail", reason);                                       \
        EXPECT_NONFATAL_FAILURE(assertion, "");                                \
    } while (0)

namespace testutil {

using agrinav::LatLon;
using Ring = std::vector<LatLon>;

constexpr double kPi   = 3.14159265358979323846;
constexpr double kMDeg = 111320.0;  // ta sama stała, co w kodzie produkcyjnym
constexpr double kNaN  = std::numeric_limits<double>::quiet_NaN();

/// Lokalny układ metryczny: pozwala zapisywać testy w metrach (E, N).
struct Frame {
    double lat0 = 52.0, lon0 = 17.0;
    LatLon at(double e, double n) const {
        return {lat0 + n / kMDeg,
                lon0 + e / (kMDeg * std::cos(lat0 * kPi / 180.0))};
    }
    std::pair<double, double> en(const LatLon& p) const {
        return {(p.lon - lon0) * kMDeg * std::cos(lat0 * kPi / 180.0),
                (p.lat - lat0) * kMDeg};
    }
    Ring ring(const std::vector<std::pair<double, double>>& pts) const {
        Ring r;
        for (const auto& p : pts) r.push_back(at(p.first, p.second));
        return r;
    }
    Ring rect(double w, double h, double e0 = 0, double n0 = 0) const {
        return ring({{e0, n0}, {e0 + w, n0}, {e0 + w, n0 + h}, {e0, n0 + h}});
    }
    /// Pole ze znakiem [m²], CCW > 0.
    double area(const Ring& r) const {
        double a = 0;
        for (size_t i = 0; i < r.size(); ++i) {
            const auto p = en(r[i]);
            const auto q = en(r[(i + 1) % r.size()]);
            a += p.first * q.second - q.first * p.second;
        }
        return a / 2;
    }
    double length(const agrinav::Swath& s) const {
        const auto a = en(s.start), b = en(s.end);
        return std::hypot(b.first - a.first, b.second - a.second);
    }
};

/// Fixture CSV "lat,lon"; linie zaczynające się od '#' są komentarzami.
inline Ring loadRing(const std::string& name) {
    std::ifstream in(std::string(AGRINAV_FIXTURES) + "/" + name);
    if (!in) throw std::runtime_error("brak fixture: " + name);
    Ring out;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        LatLon p{};
        char comma = 0;
        if (ss >> p.lat >> comma >> p.lon) out.push_back(p);
    }
    return out;
}

}  // namespace testutil
