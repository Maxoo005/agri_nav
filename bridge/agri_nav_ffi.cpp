#include "agri_nav_ffi.h"
#include "GeometryProcessor.h"
#include "GnssSimulator.h"
#include "NavEngine.h"
#include "ParcelMerger.h"
#include "SectionControl.h"
#include "SwathGuidance.h"
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
        // overlapM = 0.0, headlandLaps = 0 (legacy call — no headland)
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

// ── Full planning (swaths + headland rings) ───────────────────────────────────

FfiPlanResult* agrinav_plan_full(
    const double* polygon,
    int32_t       vertexCount,
    double        ax, double ay,
    double        bx, double by,
    double        workingWidth,
    double        overlapM,
    int32_t       headlandLaps
) {
    // Decode flat polygon buffer [lat₀,lon₀, lat₁,lon₁, ...]
    std::vector<agrinav::LatLon> pts;
    pts.reserve(static_cast<size_t>(vertexCount));
    for (int32_t i = 0; i < vertexCount; ++i)
        pts.push_back({ polygon[i * 2], polygon[i * 2 + 1] });

    const auto plan = agrinav::SwathPlanner::plan(
        pts,
        { ax, ay },
        { bx, by },
        workingWidth,
        overlapM,
        static_cast<int>(headlandLaps)
    );

    auto* r = static_cast<FfiPlanResult*>(std::malloc(sizeof(FfiPlanResult)));

    // ── Swaths ────────────────────────────────────────────────────────────────
    r->swathCount = static_cast<int32_t>(plan.swaths.size());
    if (r->swathCount > 0) {
        r->swathData = static_cast<double*>(
            std::malloc(sizeof(double) * 4 * static_cast<size_t>(r->swathCount)));
        for (int32_t i = 0; i < r->swathCount; ++i) {
            const auto& s = plan.swaths[static_cast<size_t>(i)];
            r->swathData[i * 4 + 0] = s.start.lat;
            r->swathData[i * 4 + 1] = s.start.lon;
            r->swathData[i * 4 + 2] = s.end.lat;
            r->swathData[i * 4 + 3] = s.end.lon;
        }
    } else {
        r->swathData = nullptr;
    }

    // ── Headland rings ────────────────────────────────────────────────────────
    r->ringCount = static_cast<int32_t>(plan.headlandRings.size());
    if (r->ringCount > 0) {
        r->ringPointCounts = static_cast<int32_t*>(
            std::malloc(sizeof(int32_t) * static_cast<size_t>(r->ringCount)));

        size_t totalPts = 0;
        for (int32_t k = 0; k < r->ringCount; ++k) {
            const auto cnt =
                static_cast<int32_t>(plan.headlandRings[static_cast<size_t>(k)].size());
            r->ringPointCounts[k] = cnt;
            totalPts += static_cast<size_t>(cnt);
        }

        r->ringPointData = static_cast<double*>(
            std::malloc(sizeof(double) * 2 * totalPts));

        size_t offset = 0;
        for (int32_t k = 0; k < r->ringCount; ++k) {
            for (const auto& ll : plan.headlandRings[static_cast<size_t>(k)]) {
                r->ringPointData[offset * 2 + 0] = ll.lat;
                r->ringPointData[offset * 2 + 1] = ll.lon;
                ++offset;
            }
        }
    } else {
        r->ringPointData   = nullptr;
        r->ringPointCounts = nullptr;
    }

    return r;
}

void agrinav_free_plan(FfiPlanResult* r) {
    if (!r) return;
    std::free(r->swathData);
    std::free(r->ringPointData);
    std::free(r->ringPointCounts);
    std::free(r);
}

// ── Snap-to-nearest-swath guidance ───────────────────────────────────────────

GuidanceHandle agrinav_guidance_create() {
    return new agrinav::SwathGuidance();
}

void agrinav_guidance_destroy(GuidanceHandle h) {
    delete static_cast<agrinav::SwathGuidance*>(h);
}

void agrinav_guidance_set_swaths(GuidanceHandle h,
                                  const double*  swathData,
                                  int32_t        swathCount,
                                  double         originLat,
                                  double         originLon) {
    if (!h || !swathData || swathCount <= 0) return;

    // Decode flat buffer: [startLat₀, startLon₀, endLat₀, endLon₀, ...]
    std::vector<agrinav::Swath> swaths;
    swaths.reserve(static_cast<size_t>(swathCount));
    for (int32_t i = 0; i < swathCount; ++i) {
        agrinav::Swath s;
        s.start.lat = swathData[i * 4 + 0];
        s.start.lon = swathData[i * 4 + 1];
        s.end.lat   = swathData[i * 4 + 2];
        s.end.lon   = swathData[i * 4 + 3];
        swaths.push_back(s);
    }

    static_cast<agrinav::SwathGuidance*>(h)->setSwaths(
        swaths, { originLat, originLon });
}

FfiSnapResult agrinav_guidance_query(GuidanceHandle h,
                                      double         lat,
                                      double         lon,
                                      float          headingDeg) {
    if (!h) return {0.f, -1, 0, 0.f};
    const auto r = static_cast<agrinav::SwathGuidance*>(h)
                       ->query(lat, lon, static_cast<double>(headingDeg));
    return {
        static_cast<float>(r.distanceM),
        static_cast<int32_t>(r.swathIndex),
        static_cast<int32_t>(r.side),
        static_cast<float>(r.headingErrorDeg)
    };
}

} // extern "C"

// ── Section Control + Coverage Area ─────────────────────────────────────────────

extern "C" {

SectionHandle agrinav_section_create(double cell_size_m) {
    return new agrinav::SectionControl(cell_size_m);
}

void agrinav_section_destroy(SectionHandle h) {
    delete static_cast<agrinav::SectionControl*>(h);
}

void agrinav_section_set_origin(SectionHandle h, double lat, double lon) {
    if (h) static_cast<agrinav::SectionControl*>(h)->setOrigin(lat, lon);
}

float agrinav_section_check_overlap(SectionHandle h,
                                     double lat, double lon,
                                     float  heading_deg,
                                     double tool_width_m) {
    if (!h) return 0.f;
    return static_cast<agrinav::SectionControl*>(h)
        ->checkOverlap(lat, lon, static_cast<double>(heading_deg), tool_width_m);
}

float agrinav_section_add_strip(SectionHandle h,
                                 double lat, double lon,
                                 float  heading_deg,
                                 double tool_width_m) {
    if (!h) return 0.f;
    return static_cast<agrinav::SectionControl*>(h)
        ->addStrip(lat, lon, static_cast<double>(heading_deg), tool_width_m);
}

double agrinav_section_covered_ha(SectionHandle h) {
    if (!h) return 0.0;
    return static_cast<agrinav::SectionControl*>(h)->coveredAreaHa();
}

void agrinav_section_clear(SectionHandle h) {
    if (h) static_cast<agrinav::SectionControl*>(h)->clear();
}

// ── Scalanie działek katastralnych ──────────────────────────────────────────────────

FfiMergeResult* agrinav_merge_parcels(
    const double*  polygon_data,
    const int32_t* vertex_counts,
    int32_t        polygon_count,
    double         buffer_m)
{
    // Zbuduj wejście
    std::vector<std::vector<agrinav::LatLon>> parcels;
    parcels.reserve(static_cast<size_t>(polygon_count));

    size_t offset = 0;
    for (int32_t p = 0; p < polygon_count; ++p) {
        const int32_t vc = vertex_counts[p];
        std::vector<agrinav::LatLon> poly;
        poly.reserve(static_cast<size_t>(vc));
        for (int32_t i = 0; i < vc; ++i) {
            agrinav::LatLon pt{
                polygon_data[offset + static_cast<size_t>(i) * 2],
                polygon_data[offset + static_cast<size_t>(i) * 2 + 1]
            };
            poly.push_back(pt);
        }
        offset += static_cast<size_t>(vc) * 2;
        if (poly.size() >= 3)
            parcels.push_back(std::move(poly));
    }

    // Wykonaj scalanie
    agrinav::MergeResult mr = agrinav::ParcelMerger::merge(parcels, buffer_m);

    // Przydziel wynik
    auto* out = new FfiMergeResult{};
    const int32_t rc = static_cast<int32_t>(mr.rings.size());
    out->ring_count = rc;
    out->is_multipart = mr.isMultipart ? 1 : 0;

    if (rc == 0) {
        out->ring_data          = nullptr;
        out->ring_vertex_counts = nullptr;
        out->ring_types         = nullptr;
        return out;
    }

    // Policz łączną liczbę wierzchołków
    size_t totalVerts = 0;
    for (const auto& ring : mr.rings) totalVerts += ring.points.size();

    out->ring_data          = new double[totalVerts * 2];
    out->ring_vertex_counts = new int32_t[static_cast<size_t>(rc)];
    out->ring_types         = new int32_t[static_cast<size_t>(rc)];

    size_t dataOff = 0;
    for (int32_t i = 0; i < rc; ++i) {
        const auto& ring = mr.rings[static_cast<size_t>(i)];
        out->ring_vertex_counts[i] = static_cast<int32_t>(ring.points.size());
        out->ring_types[i]         = static_cast<int32_t>(ring.type);
        for (const auto& pt : ring.points) {
            out->ring_data[dataOff++] = pt.lat;
            out->ring_data[dataOff++] = pt.lon;
        }
    }

    return out;
}

void agrinav_free_merge_result(FfiMergeResult* result) {
    if (!result) return;
    delete[] result->ring_data;
    delete[] result->ring_vertex_counts;
    delete[] result->ring_types;
    delete result;
}

// ── Przetwarzanie geometrii LPIS (ARiMR) ─────────────────────────────────────

/// Pomocnicza funkcja do budowania FfiMergeResult z MergeResult.
static FfiMergeResult* buildFfiMergeResult(const agrinav::MergeResult& mr) {
    auto* out = new FfiMergeResult{};
    const int32_t rc = static_cast<int32_t>(mr.rings.size());
    out->ring_count   = rc;
    out->is_multipart = mr.isMultipart ? 1 : 0;

    if (rc == 0) {
        out->ring_data = nullptr; out->ring_vertex_counts = nullptr;
        out->ring_types = nullptr;
        return out;
    }

    size_t totalVerts = 0;
    for (const auto& ring : mr.rings) totalVerts += ring.points.size();

    out->ring_data          = new double[totalVerts * 2];
    out->ring_vertex_counts = new int32_t[static_cast<size_t>(rc)];
    out->ring_types         = new int32_t[static_cast<size_t>(rc)];

    size_t dataOff = 0;
    for (int32_t i = 0; i < rc; ++i) {
        const auto& ring = mr.rings[static_cast<size_t>(i)];
        out->ring_vertex_counts[i] = static_cast<int32_t>(ring.points.size());
        out->ring_types[i]         = static_cast<int32_t>(ring.type);
        for (const auto& pt : ring.points) {
            out->ring_data[dataOff++] = pt.lat;
            out->ring_data[dataOff++] = pt.lon;
        }
    }
    return out;
}

FfiMergeResult* agrinav_process_lpis(
    const double*      polygon_data,
    const int32_t*     vertex_counts,
    int32_t            polygon_count,
    FfiLpisOptions     opts)
{
    std::vector<std::vector<agrinav::LatLon>> parcels;
    parcels.reserve(static_cast<size_t>(polygon_count));

    size_t offset = 0;
    for (int32_t p = 0; p < polygon_count; ++p) {
        const int32_t vc = vertex_counts[p];
        std::vector<agrinav::LatLon> poly;
        poly.reserve(static_cast<size_t>(vc));
        for (int32_t i = 0; i < vc; ++i) {
            poly.push_back({
                polygon_data[offset + static_cast<size_t>(i) * 2],
                polygon_data[offset + static_cast<size_t>(i) * 2 + 1]
            });
        }
        offset += static_cast<size_t>(vc) * 2;
        if (poly.size() >= 3) parcels.push_back(std::move(poly));
    }

    agrinav::LpisProcessOptions lpisOpts;
    lpisOpts.bufferM          = opts.buffer_m;
    lpisOpts.simplifyEpsilonM = opts.simplify_epsilon_m;
    lpisOpts.minRingVertices  = opts.min_ring_vertices > 0 ? opts.min_ring_vertices : 3;

    const agrinav::MergeResult mr =
        agrinav::GeometryProcessor::processLpis(parcels, lpisOpts);
    return buildFfiMergeResult(mr);
}

} // extern "C"
