#include "agri_nav_ffi.h"
#include "GnssSimulator.h"
#include "NavEngine.h"
#include "SwathPlanner.h"
#include <cstdint>
#include <cstdlib>
#include <string>

// Prosta implementacja GnssProcessor oparta o dane przekazane z Fluttera
struct FfiGnssAdapter : agrinav::GnssProcessor {
    agrinav::GnssPosition pos{};

    void processNmea(const char*) override {}  // nieużywane przy FFI push
    agrinav::GnssPosition currentPosition() const override { return pos; }
    bool hasFixRTK() const override { return pos.accuracy < 0.05f; }
};

struct NavContext {
    FfiGnssAdapter  gnss;
    agrinav::NavEngine engine{gnss};
};

extern "C" {

int32_t agrinav_version() { return 1; }

NavHandle agrinav_create() { return new NavContext(); }
void      agrinav_destroy(NavHandle h) { delete static_cast<NavContext*>(h); }

void agrinav_set_ab_line(NavHandle h,
                          double ax, double ay,
                          double bx, double by) {
    auto* ctx = static_cast<NavContext*>(h);
    ctx->engine.setAbLine({ax, ay}, {bx, by});
}

void agrinav_reset_ab_line(NavHandle h) {
    static_cast<NavContext*>(h)->engine.resetAbLine();
}

FfiGuidance agrinav_update(NavHandle h, FfiPosition pos) {
    auto* ctx = static_cast<NavContext*>(h);
    ctx->gnss.pos.latitude  = pos.latitude;
    ctx->gnss.pos.longitude = pos.longitude;
    ctx->gnss.pos.altitude  = pos.altitude;
    ctx->gnss.pos.accuracy  = pos.accuracy;

    auto out = ctx->engine.update();
    return FfiGuidance{out.crossTrackError, out.headingError,
                        out.isValid ? 1 : 0};
}

FfiPosition agrinav_get_position(NavHandle h) {
    const auto& p = static_cast<NavContext*>(h)->gnss.pos;
    return FfiPosition{p.latitude, p.longitude, p.altitude, p.accuracy};
}

// ── Symulator GPS ────────────────────────────────────────────────────────────

struct SimContext {
    agrinav::GnssSimulator sim;
    // bufor dla last_nmea – zabezpiecza wskaźnik char* przed danglem
    std::string nmea;

    SimContext(double lat, double lon, double alt)
        : sim(lat, lon, alt) {}
};

SimHandle agrinav_sim_create(double startLat, double startLon, double startAlt) {
    return new SimContext(startLat, startLon, startAlt);
}

void agrinav_sim_start(SimHandle h, SimPositionCallback cb) {
    auto* ctx = static_cast<SimContext*>(h);
    ctx->sim.start([ctx, cb](const agrinav::GnssPosition& pos,
                              const std::string& nmea) {
        // Przechowaj NMEA przed wywołaniem callbacku
        ctx->nmea = nmea;
        if (cb) cb(pos.latitude, pos.longitude, pos.altitude, pos.accuracy);
    });
}

void agrinav_sim_stop(SimHandle h) {
    static_cast<SimContext*>(h)->sim.stop();
}

void agrinav_sim_destroy(SimHandle h) {
    auto* ctx = static_cast<SimContext*>(h);
    ctx->sim.stop();
    delete ctx;
}

int32_t agrinav_sim_is_running(SimHandle h) {
    return static_cast<SimContext*>(h)->sim.isRunning() ? 1 : 0;
}

FfiPosition agrinav_sim_get_position(SimHandle h) {
    const auto p = static_cast<SimContext*>(h)->sim.currentPosition();
    return FfiPosition{p.latitude, p.longitude, p.altitude, p.accuracy};
}

const char* agrinav_sim_last_nmea(SimHandle h) {
    return static_cast<SimContext*>(h)->nmea.c_str();
}

// ── Planowanie ścieżek uprawowych ─────────────────────────────────────────────

FfiSwathList* agrinav_plan_swaths(
    const double* polygon,
    int32_t       vertex_count,
    double        ax, double ay,
    double        bx, double by,
    double        working_width
) {
    // Konwertuj płaski bufor [lat₀,lon₀, lat₁,lon₁, ...] → wektor LatLon
    std::vector<agrinav::LatLon> pts;
    pts.reserve(static_cast<size_t>(vertex_count));
    for (int32_t i = 0; i < vertex_count; ++i)
        pts.push_back({ polygon[i * 2], polygon[i * 2 + 1] });

    const auto plan = agrinav::SwathPlanner::plan(
        pts,
        { ax, ay },
        { bx, by },
        working_width
    );

    // Zaalokuj strukturę wynikową
    auto* result = static_cast<FfiSwathList*>(std::malloc(sizeof(FfiSwathList)));
    result->swath_count = static_cast<int32_t>(plan.swaths.size());

    if (plan.swaths.empty()) {
        result->data = nullptr;
        return result;
    }

    // Każdy swath = 4 double: startLat, startLon, endLat, endLon
    result->data = static_cast<double*>(
        std::malloc(sizeof(double) * 4 * static_cast<size_t>(result->swath_count))
    );

    for (int32_t i = 0; i < result->swath_count; ++i) {
        const auto& s = plan.swaths[static_cast<size_t>(i)];
        result->data[i * 4 + 0] = s.start.lat;
        result->data[i * 4 + 1] = s.start.lon;
        result->data[i * 4 + 2] = s.end.lat;
        result->data[i * 4 + 3] = s.end.lon;
    }

    return result;
}

void agrinav_free_swaths(FfiSwathList* list) {
    if (!list) return;
    std::free(list->data);
    std::free(list);
}

} // extern "C"
