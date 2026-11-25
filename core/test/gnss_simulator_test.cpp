#include "GnssSimulator.h"
#include "test_support.h"

using namespace agrinav;
using namespace testutil;

// Wątek symulatora używa zegara systemowego, więc testujemy tylko część
// deterministyczną (parsowanie, stan); start() celowo nie jest wołany.

TEST(GnssSimulator, StartsAtGivenPositionWithRtk) {
    GnssSimulator s(51.5, 17.5, 120);
    const auto p = s.currentPosition();
    EXPECT_NEAR(p.latitude, 51.5, 1e-12);
    EXPECT_NEAR(p.longitude, 17.5, 1e-12);
    EXPECT_NEAR(p.altitude, 120, 1e-12);
    EXPECT_TRUE(s.hasFixRTK());
    EXPECT_FALSE(s.isRunning());
    EXPECT_TRUE(s.lastNmea().empty());
}

TEST(GnssSimulator, ParsesGgaAllHemispheres) {
    GnssSimulator s;
    s.processNmea("$GPGGA,123519,4807.038,N,01131.000,E,4,08,0.9,545.4,M,46.9,M,,*42");
    EXPECT_NEAR(s.currentPosition().latitude, 48.1173, 1e-6);
    EXPECT_NEAR(s.currentPosition().longitude, 11.0 + 31.0 / 60.0, 1e-9);
    s.processNmea("$GPGGA,123519,4807.038,S,01131.000,W,4,08,0.9,545.4,M,46.9,M,,*4D");
    EXPECT_NEAR(s.currentPosition().latitude, -48.1173, 1e-6);
    EXPECT_NEAR(s.currentPosition().longitude, -(11.0 + 31.0 / 60.0), 1e-9);
}

TEST(GnssSimulator, IgnoresOtherSentencesAndNull) {
    GnssSimulator s(50, 20, 0);
    s.processNmea(nullptr);
    s.processNmea("");
    s.processNmea("$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A");
    EXPECT_NEAR(s.currentPosition().latitude, 50.0, 1e-12);
}

TEST(GnssSimulator, TruncatesOverlongSentenceSafely) {
    GnssSimulator s;
    const std::string big = "$GPGGA,123519,4807.038,N,01131.000,E," + std::string(500, '9');
    s.processNmea(big.c_str());
    EXPECT_NEAR(s.currentPosition().latitude, 48.1173, 1e-6);
}

TEST(GnssSimulator, StopWithoutStartIsSafe) {
    GnssSimulator s;
    s.stop();
    EXPECT_FALSE(s.isRunning());
}

TEST(GnssSimulator, XfailNoFixSentenceOverwritesPosition) {
    GnssSimulator s(50, 20, 0);
    // Puste pola: strtok skleja przecinki → kolumny się przesuwają.
    s.processNmea("$GPGGA,123519,,,,,0,00,99.9,,M,,M,,*48");
    const double lat = s.currentPosition().latitude;
    AGRINAV_XFAIL("zdanie bez fixa nadpisuje pozycję śmieciami", EXPECT_NEAR(lat, 50.0, 1e-9));
}

TEST(GnssSimulator, XfailBadChecksumAccepted) {
    GnssSimulator s(50, 20, 0);
    s.processNmea("$GPGGA,123519,4807.038,N,01131.000,E,4,08,0.9,545.4,M,46.9,M,,*00");
    const double lat = s.currentPosition().latitude;
    AGRINAV_XFAIL("symulator nie sprawdza sumy kontrolnej", EXPECT_NEAR(lat, 50.0, 1e-9));
}
