#pragma once
#include <array>

namespace agrinav {

// Pozycja geograficzna w układzie WGS-84
struct GnssPosition {
    double latitude;   // [deg]
    double longitude;  // [deg]
    double altitude;   // [m]
    float  accuracy;   // [m] pozioma dokładność
    double timestamp;  // [s] UNIX epoch
};

// Przetwarza surowe dane NMEA / RTCM i dostarcza bieżącą pozycję
class GnssProcessor {
public:
    virtual ~GnssProcessor() = default;

    virtual void       processNmea(const char* sentence) = 0;
    virtual GnssPosition currentPosition() const         = 0;
    virtual bool         hasFixRTK() const               = 0;
};

} // namespace agrinav
