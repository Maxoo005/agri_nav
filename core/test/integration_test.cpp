// Przepływ: fixture pola → plan → prowadzenie → pokrycie (bez sprzętu i zegara).
#include "HeadlandGuidance.h"
#include "ParcelMerger.h"
#include "SectionControl.h"
#include "SwathGuidance.h"
#include "SwathPlanner.h"
#include "test_support.h"

using namespace agrinav;
using namespace testutil;

namespace {

/// Przejazd po wszystkich pasach z krokiem 0.25 m i stałym odchyleniem bocznym.
void drive(const Frame& f, const SwathPlan& plan, double width, double lateral,
           SectionControl& sc, const SwathGuidance& g) {
    for (size_t i = 0; i < plan.swaths.size(); ++i) {
        const auto a = f.en(plan.swaths[i].start), b = f.en(plan.swaths[i].end);
        const double len = f.length(plan.swaths[i]);
        const double dE = (b.first - a.first) / len, dN = (b.second - a.second) / len;
        const double hdg = std::atan2(dE, dN) * 180.0 / kPi;
        for (double t = 0.1; t < len; t += 0.25) {
            const auto p = f.at(a.first + t * dE + lateral * dN,
                                a.second + t * dN - lateral * dE);
            const auto s = g.query(p.lat, p.lon, hdg);
            ASSERT_EQ(s.swathIndex, static_cast<int>(i));
            ASSERT_NEAR(s.distanceM, std::abs(lateral), 1e-3);
            ASSERT_EQ(s.side, lateral > 0.01 ? 1 : 0);
            sc.addStrip(p.lat, p.lon, hdg, width);
        }
    }
}

struct Integration : ::testing::Test {
    Frame f;
    SwathGuidance g;
    SectionControl sc{0.5};
};

TEST_F(Integration, RectangleFullCoverage) {
    const Ring field = loadRing("field_rect_200x100.csv");
    ASSERT_EQ(field.size(), 4u);
    EXPECT_NEAR(f.area(field), 20000.0, 0.1);
    const auto plan = SwathPlanner::plan(field, field[0], field[1], 10.0);
    g.setSwaths(plan.swaths, field[0]);
    sc.setOrigin(field[0].lat, field[0].lon);
    drive(f, plan, 10.0, 0.0, sc, g);
    EXPECT_NEAR(sc.coveredAreaHa(), 2.0, 0.04);
}

TEST_F(Integration, OffsetDriveIsMeasured) {
    const Ring field = loadRing("field_rect_200x100.csv");
    const auto plan = SwathPlanner::plan(field, field[0], field[1], 10.0);
    g.setSwaths(plan.swaths, field[0]);
    sc.setOrigin(field[0].lat, field[0].lon);
    drive(f, plan, 10.0, 0.4, sc, g);
}

TEST_F(Integration, LShapeOptimizedWithHeadland) {
    const Ring field = loadRing("field_l_shape.csv");
    EXPECT_NEAR(f.area(field), 15000.0, 0.1);
    const auto opt = SwathPlanner::optimizeAngle(field, 6.0, 0.0, 1);
    ASSERT_GT(opt.swathCount, 0);
    ASSERT_EQ(opt.plan.headlandRings.size(), 1u);
    HeadlandGuidance hg;
    hg.setRings(opt.plan.headlandRings, field[0]);
    // Na wierzchołku uwrocia odchylenie od uwrocia jest zerowe.
    const auto& v = opt.plan.headlandRings[0][0];
    EXPECT_NEAR(hg.query(v.lat, v.lon, 0).crossTrackM, 0.0, 1e-3);
    // Pasy nie wchodzą na uwrocie (6 m od granicy).
    for (const auto& s : opt.plan.swaths)
        for (const auto& p : {s.start, s.end}) {
            EXPECT_GE(f.en(p).first, 6.0 - 0.1);
            EXPECT_LE(f.en(p).first, 194.0 + 0.1);
        }
}

TEST_F(Integration, MergedParcelsCanBePlanned) {
    const auto merged = ParcelMerger::merge({f.rect(100, 100), f.rect(100, 100, 100, 0)});
    ASSERT_EQ(merged.rings.size(), 1u);
    const auto plan = SwathPlanner::plan(merged.rings[0].points, f.at(0, 0), f.at(100, 0), 10);
    EXPECT_EQ(plan.swaths.size(), 11u);  // 100.1 m po buforze 5 cm → 11. pas
}

}  // namespace
