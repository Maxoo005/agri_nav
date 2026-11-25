#include "agri_nav_ffi.h"
#include "test_support.h"

using namespace testutil;

namespace {

std::vector<double> flat(const Ring& r) {
    std::vector<double> v;
    for (const auto& p : r) {
        v.push_back(p.lat);
        v.push_back(p.lon);
    }
    return v;
}

struct FfiTest : ::testing::Test {
    Frame f;
};

TEST_F(FfiTest, VersionIsStable) { EXPECT_EQ(agrinav_version(), 1); }

TEST_F(FfiTest, StructLayoutMatchesDartMirrors) {
    EXPECT_EQ(sizeof(FfiPosition), 32u);
    EXPECT_EQ(sizeof(FfiGuidance), 12u);
    EXPECT_EQ(sizeof(FfiSnapResult), 16u);
    EXPECT_EQ(sizeof(FfiHeadlandResult), 16u);
    EXPECT_EQ(sizeof(FfiLpisOptions), 24u);
}

TEST_F(FfiTest, NavRoundTrip) {
    NavHandle h = agrinav_create();
    const auto a = f.at(0, 0), b = f.at(0, 100), p = f.at(1.25, 10);
    agrinav_set_ab_line(h, a.lat, a.lon, b.lat, b.lon);
    const auto g = agrinav_update(h, {p.lat, p.lon, 99.0, 0.02f});
    EXPECT_EQ(g.isValid, 1);
    EXPECT_NEAR(g.crossTrackError, 1.25, 1e-3);
    const auto back = agrinav_get_position(h);
    EXPECT_NEAR(back.latitude, p.lat, 1e-12);
    EXPECT_NEAR(back.altitude, 99.0, 1e-12);
    agrinav_reset_ab_line(h);
    EXPECT_EQ(agrinav_update(h, {p.lat, p.lon, 0, 0.02f}).isValid, 0);
    agrinav_destroy(h);
}

TEST_F(FfiTest, PlanFullAndFree) {
    const auto poly = flat(f.rect(200, 100));
    const auto a = f.at(0, 0), b = f.at(100, 0);
    auto* r = agrinav_plan_full(poly.data(), 4, a.lat, a.lon, b.lat, b.lon, 10, 0, 1);
    ASSERT_NE(r, nullptr);
    EXPECT_EQ(r->swathCount, 8);
    EXPECT_EQ(r->ringCount, 1);
    EXPECT_GE(r->ringPointCounts[0], 4);
    EXPECT_NEAR(f.en({r->swathData[0], r->swathData[1]}).second, 15.0, 0.02);
    agrinav_free_plan(r);
}

TEST_F(FfiTest, EmptyPlanHasNullBuffers) {
    auto* r = agrinav_plan_full(nullptr, 0, 52, 17, 52.001, 17, 10, 0, 1);
    ASSERT_NE(r, nullptr);
    EXPECT_EQ(r->swathCount, 0);
    EXPECT_EQ(r->ringCount, 0);
    EXPECT_EQ(r->swathData, nullptr);
    agrinav_free_plan(r);
    agrinav_free_plan(nullptr);
}

TEST_F(FfiTest, OptimizeAngle) {
    const auto poly = flat(f.rect(200, 100));
    auto* r = agrinav_optimize_angle(poly.data(), 4, 10, 0, 1, 3.0, 10.0);
    ASSERT_NE(r, nullptr);
    EXPECT_NEAR(r->bestAngleDeg, 90.0, 0.5);
    EXPECT_GT(r->totalLengthM, 0);
    EXPECT_EQ(r->ringCount, 1);
    agrinav_free_optimize_result(r);
    r = agrinav_optimize_angle(nullptr, 0, 10, 0, 0, 3.0, 10.0);
    EXPECT_EQ(r->swathCount, 0);
    agrinav_free_optimize_result(r);
    agrinav_free_optimize_result(nullptr);
}

TEST_F(FfiTest, GuidanceRoundTripAndNullHandle) {
    EXPECT_EQ(agrinav_guidance_query(nullptr, 52, 17, 0).swathIndex, -1);
    GuidanceHandle h = agrinav_guidance_create();
    EXPECT_EQ(agrinav_guidance_query(h, 52, 17, 0).swathIndex, -1);
    const auto a = f.at(0, 0), b = f.at(0, 100), p = f.at(2, 50);
    const double s[] = {a.lat, a.lon, b.lat, b.lon};
    agrinav_guidance_set_swaths(h, s, 1, a.lat, a.lon);
    const auto r = agrinav_guidance_query(h, p.lat, p.lon, 3.f);
    EXPECT_EQ(r.swathIndex, 0);
    EXPECT_EQ(r.side, 1);
    EXPECT_NEAR(r.distanceM, 2.0, 1e-3);
    EXPECT_NEAR(r.headingErrorDeg, 3.0, 1e-3);
    agrinav_guidance_destroy(h);
}

TEST_F(FfiTest, XfailEmptySwathListDoesNotClearGuidance) {
    GuidanceHandle h = agrinav_guidance_create();
    const auto a = f.at(0, 0), b = f.at(0, 100);
    const double s[] = {a.lat, a.lon, b.lat, b.lon};
    agrinav_guidance_set_swaths(h, s, 1, a.lat, a.lon);
    agrinav_guidance_set_swaths(h, s, 0, a.lat, a.lon);
    const int idx = agrinav_guidance_query(h, a.lat, a.lon, 0).swathIndex;
    agrinav_guidance_destroy(h);
    AGRINAV_XFAIL("pusta lista ścieżek zostawia prowadzenie po starym polu", EXPECT_EQ(idx, -1));
}

TEST_F(FfiTest, HeadlandRoundTripAndNullHandle) {
    EXPECT_EQ(agrinav_headland_query(nullptr, 52, 17, 0).ringIndex, -1);
    HeadlandHandle h = agrinav_headland_create();
    const auto pts = flat(f.rect(100, 100));
    const int32_t n = 4;
    const auto a = f.at(0, 0), p = f.at(50, 1);
    agrinav_headland_set_rings(h, pts.data(), &n, 1, a.lat, a.lon);
    const auto r = agrinav_headland_query(h, p.lat, p.lon, 90.f);
    EXPECT_EQ(r.ringIndex, 0);
    EXPECT_NEAR(r.crossTrackM, -1.0, 1e-3);
    agrinav_headland_destroy(h);
}

TEST_F(FfiTest, SectionRoundTripAndNullHandle) {
    EXPECT_FLOAT_EQ(agrinav_section_add_strip(nullptr, 52, 17, 0, 3), 0.f);
    EXPECT_FLOAT_EQ(agrinav_section_check_overlap(nullptr, 52, 17, 0, 3), 0.f);
    EXPECT_NEAR(agrinav_section_covered_ha(nullptr), 0, 1e-12);
    EXPECT_NEAR(agrinav_section_new_area_ha(nullptr), 0, 1e-12);
    agrinav_section_set_origin(nullptr, 0, 0);
    agrinav_section_clear(nullptr);
    SectionHandle h = agrinav_section_create(1.0);
    agrinav_section_set_origin(h, 52, 17);
    EXPECT_FLOAT_EQ(agrinav_section_add_strip(h, 52, 17, 0, 10), 0.f);
    EXPECT_FLOAT_EQ(agrinav_section_check_overlap(h, 52, 17, 0, 10), 1.f);
    EXPECT_NEAR(agrinav_section_covered_ha(h), agrinav_section_new_area_ha(h), 1e-12);
    agrinav_section_clear(h);
    EXPECT_NEAR(agrinav_section_covered_ha(h), 0, 1e-12);
    agrinav_section_destroy(h);
}

TEST_F(FfiTest, MergeAndLpis) {
    auto data = flat(f.rect(100, 100));
    const auto second = flat(f.rect(100, 100, 100, 0));
    data.insert(data.end(), second.begin(), second.end());
    const int32_t counts[] = {4, 4};
    auto* m = agrinav_merge_parcels(data.data(), counts, 2, 0.05);
    ASSERT_NE(m, nullptr);
    EXPECT_EQ(m->ring_count, 1);
    EXPECT_EQ(m->is_multipart, 0);
    EXPECT_EQ(m->ring_types[0], 0);
    agrinav_free_merge_result(m);

    FfiLpisOptions opt{};
    opt.buffer_m = 0.02;
    opt.simplify_epsilon_m = 0.3;
    opt.min_ring_vertices = 0;  // → domyślne 3
    m = agrinav_process_lpis(data.data(), counts, 2, opt);
    ASSERT_NE(m, nullptr);
    EXPECT_EQ(m->ring_count, 1);
    agrinav_free_merge_result(m);

    m = agrinav_merge_parcels(nullptr, nullptr, 0, 0.05);
    EXPECT_EQ(m->ring_count, 0);
    agrinav_free_merge_result(m);
    m = agrinav_process_lpis(nullptr, nullptr, 0, opt);
    EXPECT_EQ(m->ring_count, 0);
    agrinav_free_merge_result(m);
    agrinav_free_merge_result(nullptr);
}

}  // namespace
