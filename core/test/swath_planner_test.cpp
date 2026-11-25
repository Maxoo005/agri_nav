#include "SwathPlanner.h"
#include "test_support.h"

#include <algorithm>

using namespace agrinav;
using namespace testutil;

namespace {

struct SwathPlannerTest : ::testing::Test {
    Frame f;
    Ring rect = f.rect(200, 100);
    LatLon o = f.at(0, 0), east = f.at(100, 0), north = f.at(0, 100);

    double total(const std::vector<Swath>& s) const {
        double t = 0;
        for (const auto& x : s) t += f.length(x);
        return t;
    }
};

// ── Wejście zdegenerowane ────────────────────────────────────────────────────

TEST_F(SwathPlannerTest, EmptyOrTooSmallPolygon) {
    for (const Ring& r : {Ring{}, Ring{o}, Ring{o, east}}) {
        EXPECT_TRUE(SwathPlanner::plan(r, o, east, 10).swaths.empty());
        EXPECT_EQ(SwathPlanner::optimizeAngle(r, 10).swathCount, 0);
    }
}

TEST_F(SwathPlannerTest, NonPositiveWidthGivesEmptyPlan) {
    for (double w : {0.0, -3.0}) {
        EXPECT_TRUE(SwathPlanner::plan(rect, o, east, w).swaths.empty());
        EXPECT_EQ(SwathPlanner::optimizeAngle(rect, w).swathCount, 0);
    }
}

TEST_F(SwathPlannerTest, CoincidentAbGivesEmptyPlan) {
    EXPECT_TRUE(SwathPlanner::plan(rect, o, o, 10).swaths.empty());
}

TEST_F(SwathPlannerTest, CollinearPolygonHasNoUsableSwaths) {
    const Ring line = f.ring({{0, 0}, {50, 0}, {100, 0}});
    EXPECT_TRUE(SwathPlanner::plan(line, o, north, 10).swaths.empty());
}

TEST_F(SwathPlannerTest, NonFiniteInputGivesEmptyPlan) {
    for (double bad : {kNaN, static_cast<double>(INFINITY)}) {
        for (int i = 0; i < 4; ++i) {
            Ring r = rect;
            r[i].lat = bad;
            EXPECT_TRUE(SwathPlanner::plan(r, o, east, 10, 0, 1).swaths.empty());
            EXPECT_TRUE(SwathPlanner::plan(r, o, east, 10, 0, 1).headlandRings.empty());
            EXPECT_EQ(SwathPlanner::optimizeAngle(r, 10).swathCount, 0);
        }
        EXPECT_TRUE(SwathPlanner::plan(rect, o, east, bad).swaths.empty());
        EXPECT_TRUE(SwathPlanner::plan(rect, o, east, 10, bad).swaths.empty());
        EXPECT_TRUE(SwathPlanner::plan(rect, {bad, 17}, east, 10).swaths.empty());
        EXPECT_TRUE(SwathPlanner::plan(rect, o, {bad, 17}, 10).swaths.empty());
    }
}

// ── Wartości referencyjne ────────────────────────────────────────────────────

TEST_F(SwathPlannerTest, RectangleEastWest) {
    const auto p = SwathPlanner::plan(rect, o, east, 10);
    ASSERT_EQ(p.swaths.size(), 10u);  // 100 m / 10 m
    EXPECT_TRUE(p.headlandRings.empty());
    for (size_t i = 0; i < p.swaths.size(); ++i) {
        EXPECT_NEAR(f.length(p.swaths[i]), 200.0, 1e-3);
        EXPECT_NEAR(f.en(p.swaths[i].start).second, 5.0 + 10.0 * i, 1e-3);
    }
}

TEST_F(SwathPlannerTest, RectangleNorthSouth) {
    const auto p = SwathPlanner::plan(rect, o, north, 10);
    ASSERT_EQ(p.swaths.size(), 20u);
    EXPECT_NEAR(total(p.swaths), 20 * 100.0, 1e-2);
}

TEST_F(SwathPlannerTest, WindingDoesNotMatter) {
    Ring cw(rect.rbegin(), rect.rend());
    EXPECT_EQ(SwathPlanner::plan(cw, o, east, 10).swaths.size(), 10u);
}

TEST_F(SwathPlannerTest, ExplicitlyClosedRingIsAccepted) {
    Ring closed = rect;
    closed.push_back(rect.front());
    EXPECT_EQ(SwathPlanner::plan(closed, o, east, 10).swaths.size(), 10u);
}

TEST_F(SwathPlannerTest, OverlapReducesPitch) {
    const auto p = SwathPlanner::plan(rect, o, east, 10, 2);  // skok 8 m
    ASSERT_EQ(p.swaths.size(), 13u);                          // ceil(100/8)
    EXPECT_NEAR(f.en(p.swaths[1].start).second - f.en(p.swaths[0].start).second, 8.0, 1e-3);
}

TEST_F(SwathPlannerTest, NegativeOverlapIsIgnored) {
    EXPECT_EQ(SwathPlanner::plan(rect, o, east, 10, -5).swaths.size(), 10u);
}

TEST_F(SwathPlannerTest, OverlapLargerThanWidthIsClamped) {
    // Skok spada do minimum 0.1 m — plan skończony, bez dzielenia przez zero.
    // Pole 2 m / 0.1 m = 20 pasów (±1 na zaokrągleniu).
    const auto n = SwathPlanner::plan(f.rect(20, 2), o, east, 3, 5).swaths.size();
    EXPECT_GE(n, 20u);
    EXPECT_LE(n, 21u);
}

TEST_F(SwathPlannerTest, ImplementWiderThanFieldGivesOneCentredPass) {
    const auto p = SwathPlanner::plan(f.rect(100, 6), o, east, 24);
    ASSERT_EQ(p.swaths.size(), 1u);
    EXPECT_NEAR(f.en(p.swaths[0].start).second, 3.0, 1e-3);
}

TEST_F(SwathPlannerTest, DiagonalSwathsStayInsideField) {
    const auto p = SwathPlanner::plan(rect, o, f.at(100, 37), 7);
    ASSERT_FALSE(p.swaths.empty());
    for (const auto& s : p.swaths)
        for (const auto& pt : {s.start, s.end}) {
            const auto en = f.en(pt);
            EXPECT_GE(en.first, -1e-3);
            EXPECT_LE(en.first, 200 + 1e-3);
            EXPECT_GE(en.second, -1e-3);
            EXPECT_LE(en.second, 100 + 1e-3);
        }
}

TEST_F(SwathPlannerTest, ConcaveFieldSplitsPasses) {
    // Litera U: wcięcie 20..80 m od góry do N=20.
    const Ring u = f.ring({{0, 0}, {100, 0}, {100, 100}, {80, 100},
                           {80, 20}, {20, 20}, {20, 100}, {0, 100}});
    const auto p = SwathPlanner::plan(u, o, east, 10);
    EXPECT_EQ(p.swaths.size(), 2u + 8u * 2u);
    EXPECT_NEAR(total(p.swaths) * 10.0, f.area(u), 1.0);
}

// ── Uwrocia ──────────────────────────────────────────────────────────────────

TEST_F(SwathPlannerTest, HeadlandRingsAreInsetByHalfWidth) {
    const auto p = SwathPlanner::plan(rect, o, east, 10, 0, 2);
    ASSERT_EQ(p.headlandRings.size(), 2u);
    EXPECT_NEAR(f.area(p.headlandRings[0]), 190.0 * 90.0, 5.0);  // 5 m
    EXPECT_NEAR(f.area(p.headlandRings[1]), 170.0 * 70.0, 5.0);  // 15 m
}

TEST_F(SwathPlannerTest, SwathsStartFlushWithHeadland) {
    const auto p = SwathPlanner::plan(rect, o, east, 10, 0, 1);
    ASSERT_EQ(p.swaths.size(), 8u);  // wnętrze 180 x 80 m
    EXPECT_NEAR(f.en(p.swaths.front().start).second, 15.0, 0.02);
    EXPECT_NEAR(f.en(p.swaths.back().start).second, 85.0, 0.02);
    EXPECT_NEAR(f.length(p.swaths[0]), 180.0, 0.05);
}

TEST_F(SwathPlannerTest, LeftoverStripGetsExtraPass) {
    // Wnętrze 180 x 75 m, szer. 10 → 8 pasów o skoku (75-10)/7.
    const auto p = SwathPlanner::plan(f.rect(200, 95), o, east, 10, 0, 1);
    ASSERT_EQ(p.swaths.size(), 8u);
    EXPECT_NEAR(f.en(p.swaths.front().start).second, 15.0, 0.02);
    EXPECT_NEAR(f.en(p.swaths.back().start).second, 80.0, 0.02);
}

TEST_F(SwathPlannerTest, NarrowInnerStripStillGetsPass) {
    // Regresja opisana w SwathPlanner.cpp: pole 45 m, maszyna 18 m, 1 uwrocie.
    const auto p = SwathPlanner::plan(f.rect(200, 45), o, east, 18, 0, 1);
    ASSERT_EQ(p.swaths.size(), 1u);
    EXPECT_NEAR(f.en(p.swaths[0].start).second, 22.5, 0.02);
}

TEST_F(SwathPlannerTest, TooManyLapsStopWhenFieldCollapses) {
    const auto p = SwathPlanner::plan(f.rect(60, 60), o, east, 10, 0, 50);
    EXPECT_EQ(p.headlandRings.size(), 3u);  // 5, 15, 25 m; 35 m > 30 m
}

TEST_F(SwathPlannerTest, NegativeLapsBehaveLikeZero) {
    const auto p = SwathPlanner::plan(rect, o, east, 10, 0, -1);
    EXPECT_TRUE(p.headlandRings.empty());
    EXPECT_EQ(p.swaths.size(), 10u);
}

// ── Optymalizacja kąta ───────────────────────────────────────────────────────

TEST_F(SwathPlannerTest, OptimizerPicksLongAxis) {
    const auto r = SwathPlanner::optimizeAngle(rect, 10);
    EXPECT_NEAR(r.bestAngleDeg, 90.0, 0.5);
    EXPECT_EQ(r.swathCount, 10);
    EXPECT_NEAR(r.totalLengthM, 2000.0, 5.0);
    EXPECT_EQ(r.plan.swaths.size(), static_cast<size_t>(r.swathCount));
}

TEST_F(SwathPlannerTest, OptimizerFollowsRotatedField) {
    const double th = 30.0 * kPi / 180.0;  // dłuższa oś na azymucie 30°
    const double dE = std::sin(th), dN = std::cos(th);
    const auto r = SwathPlanner::optimizeAngle(
        f.ring({{0, 0}, {300 * dE, 300 * dN},
                {300 * dE - 80 * dN, 300 * dN + 80 * dE}, {-80 * dN, 80 * dE}}), 10);
    EXPECT_NEAR(r.bestAngleDeg, 30.0, 0.5);
}

TEST_F(SwathPlannerTest, OptimizerIsDeterministicAndInRange) {
    const Ring tri = f.ring({{0, 0}, {150, 20}, {40, 130}});
    const auto a = SwathPlanner::optimizeAngle(tri, 6, 0.3, 1);
    const auto b = SwathPlanner::optimizeAngle(tri, 6, 0.3, 1);
    EXPECT_DOUBLE_EQ(a.bestAngleDeg, b.bestAngleDeg);
    EXPECT_GE(a.bestAngleDeg, 0.0);
    EXPECT_LT(a.bestAngleDeg, 180.0);
    EXPECT_GT(a.swathCount, 0);
    EXPECT_EQ(a.plan.headlandRings.size(), 1u);
}

TEST_F(SwathPlannerTest, WorksAcrossUtmBoundaryAndInSouth) {
    for (const Frame& g : {Frame{52, 18}, Frame{52, 24}, Frame{-33.5, -60.25}}) {
        const auto p = SwathPlanner::plan(g.rect(200, 100, -100, -50), g.at(0, 0),
                                          g.at(100, 0), 10);
        EXPECT_EQ(p.swaths.size(), 10u) << g.lon0;
    }
}

// ── Znane błędy ──────────────────────────────────────────────────────────────

TEST_F(SwathPlannerTest, XfailDatelineField) {
    const Frame g{0.0, 180.0};
    Ring r = g.rect(200, 100, -100, 0);
    for (auto& p : r)
        if (p.lon > 180.0) p.lon -= 360.0;
    const auto p = SwathPlanner::plan(r, g.at(-100, 0), g.at(-50, 0), 10);
    const double len = p.swaths.empty() ? 0.0 : Frame{0, 0}.length(p.swaths[0]);
    AGRINAV_XFAIL("brak zawijania długości geograficznej na 180°",
                  EXPECT_NEAR(len, 200.0, 1.0));
}

TEST_F(SwathPlannerTest, DumbbellFieldKeepsBothParts) {
    // Dwa kwadraty ~100x100 połączone przesmykiem 8 m. Uwrocie 10 m rozcina
    // wnętrze na dwie części — obie muszą dostać ścieżki i uwrocia.
    const Ring db = f.ring({{0, 0}, {100, 0}, {100, 46}, {150, 46}, {150, 0},
                            {251, 0}, {251, 100}, {150, 100}, {150, 54},
                            {100, 54}, {100, 100}, {0, 100}});
    const auto p = SwathPlanner::plan(db, o, north, 10, 0, 1);
    bool west = false, eastSide = false;
    for (const auto& s : p.swaths) {
        if (f.en(s.start).first < 100) west = true;
        if (f.en(s.start).first > 150) eastSide = true;
    }
    EXPECT_TRUE(west && eastSide);
    EXPECT_EQ(p.headlandRings.size(), 2u);
    const auto opt = SwathPlanner::optimizeAngle(db, 10, 0, 1);
    EXPECT_EQ(opt.plan.headlandRings.size(), 2u);
    EXPECT_EQ(opt.plan.swaths.size(), static_cast<size_t>(opt.swathCount));
    // Dwa wnętrza ok. 80x80 m → ok. 2·6400 m² / 10 m.
    EXPECT_NEAR(opt.totalLengthM, 1290.0, 60.0);
}

TEST_F(SwathPlannerTest, XfailScanlineThroughReflexVertex) {
    // Arytmetyka dokładna (równik, U = 111320/2048): pas N=2.5U przechodzi
    // dokładnie przez wierzchołek wcięcia (ostrze od góry) → nieparzysta
    // liczba przecięć i pop_back() odcina prawą połowę pasa.
    const double q = 1.0 / 2048.0, U = kMDeg * q;
    const Ring r = {{0, 0}, {0, 8 * q}, {4 * q, 8 * q}, {4 * q, 6 * q},
                    {2.5 * q, 4 * q}, {4 * q, 2 * q}, {4 * q, 0}};
    const auto p = SwathPlanner::plan(r, {0, 0}, {0, q}, U);
    const Frame g{0, 0};
    double covered = 0;
    for (const auto& s : p.swaths)
        if (std::abs(g.en(s.start).second - 2.5 * U) < 0.01) covered += g.length(s);
    EXPECT_GT(covered, 0.0);
    AGRINAV_XFAIL("wierzchołek wklęsły na linii skanu ucina połowę pasa",
                  EXPECT_NEAR(covered, 8 * U, 1.0));
}

TEST_F(SwathPlannerTest, HeadlandWithOverlapStaysInsideField) {
    // W=10, zakładka 2: zewnętrzna krawędź maszyny ma dotykać granicy, więc
    // antena W/2 = 5 m od niej (nie (W-overlap)/2 = 4 m).
    const auto p = SwathPlanner::plan(rect, o, east, 10, 2, 1);
    ASSERT_EQ(p.headlandRings.size(), 1u);
    double minN = 1e9;
    for (const auto& pt : p.headlandRings[0]) minN = std::min(minN, f.en(pt).second);
    EXPECT_NEAR(minN, 5.0, 0.05);
    // Kolejne tory co skok 8 m, pierwszy pas wnętrza o skok od uwrocia.
    EXPECT_NEAR(f.en(p.swaths.front().start).second, 13.0, 0.05);
    const auto two = SwathPlanner::plan(rect, o, east, 10, 2, 2);
    ASSERT_EQ(two.headlandRings.size(), 2u);
    EXPECT_NEAR(f.area(two.headlandRings[1]), 174.0 * 74.0, 5.0);  // 13 m
}

TEST_F(SwathPlannerTest, XfailPoleIsUnsupported) {
    const Ring r = {{89.999, 0}, {89.999, 90}, {89.999, 180}, {89.999, -90}};
    const auto p = SwathPlanner::plan(r, {90.0, 0}, {89.999, 0}, 10);
    double len = 0;  // pole to kwadrat o przekątnej ~222 m
    for (const auto& s : p.swaths) len += std::abs(s.end.lat - s.start.lat) * kMDeg;
    AGRINAV_XFAIL("ENU (equirectangular) jest zdegenerowane na biegunie",
                  EXPECT_GT(len, 100.0));
}

}  // namespace
