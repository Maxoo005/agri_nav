#include "GnssSimulator.h"

#include <chrono>
#include <cmath>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <sstream>

namespace agrinav {

// ── Stałe symulacji ──────────────────────────────────────────────────────────

static constexpr int    SIM_INTERVAL_MS = 100;      // tick period [ms]
static constexpr double SIM_SPEED_MS    = 3.0;      // travel speed [m/s] ≈ 10.8 km/h
static constexpr double PASS_SHIFT_M    = 5.0;      // lateral shift per pass [m]
static constexpr double SIM_ACCURACY_M  = 0.02;     // RTK-level accuracy [m]
static constexpr double DEG_PER_M_LAT   = 1.0 / 111320.0;

// Fixed lawnmower field endpoints (WGS-84)
static constexpr double SIM_A_LAT = 51.930428;
static constexpr double SIM_A_LON = 17.726242;
static constexpr double SIM_B_LAT = 51.933609;
static constexpr double SIM_B_LON = 17.721690;

#ifndef M_PI
static constexpr double M_PI = 3.14159265358979323846;
#endif

// ── Konstruktor / destruktor ─────────────────────────────────────────────────

GnssSimulator::GnssSimulator(double startLat, double startLon, double startAlt)
    : _startLat(startLat), _startLon(startLon), _startAlt(startAlt)
{
    _current.latitude  = startLat;
    _current.longitude = startLon;
    _current.altitude  = startAlt;
    _current.accuracy  = static_cast<float>(SIM_ACCURACY_M);
}

GnssSimulator::~GnssSimulator() {
    stop();
}

// ── GnssProcessor ────────────────────────────────────────────────────────────

void GnssSimulator::processNmea(const char* sentence) {
    // Symulator akceptuje zewnętrzne zdania NMEA; parsujemy $GPGGA uproszczenie
    if (!sentence || std::strncmp(sentence, "$GPGGA", 6) != 0) return;

    // Minimalne parsowanie: pola oddzielone przecinkami
    // $GPGGA,hhmmss,lat,N/S,lon,E/W,quality,...
    char buf[128];
    std::strncpy(buf, sentence, 127);
    buf[127] = '\0';

    int   field = 0;
    double lat = 0, lon = 0;
    char   nsDir = 'N', ewDir = 'E';

    char* tok = std::strtok(buf, ",");
    while (tok) {
        switch (field) {
            case 2: lat   = std::atof(tok); break;
            case 3: nsDir = tok[0];          break;
            case 4: lon   = std::atof(tok); break;
            case 5: ewDir = tok[0];          break;
        }
        ++field;
        tok = std::strtok(nullptr, ",");
    }

    // NMEA ddmm.mmmm → stopnie dziesiętne
    auto nmea2deg = [](double v) {
        int    deg = static_cast<int>(v / 100);
        double min = v - deg * 100.0;
        return deg + min / 60.0;
    };

    std::unique_lock<std::mutex> lock(_mutex);
    _current.latitude  = nsDir == 'S' ? -nmea2deg(lat) : nmea2deg(lat);
    _current.longitude = ewDir == 'W' ? -nmea2deg(lon) : nmea2deg(lon);
}

GnssPosition GnssSimulator::currentPosition() const {
    std::unique_lock<std::mutex> lock(_mutex);
    return _current;
}

bool GnssSimulator::hasFixRTK() const {
    std::unique_lock<std::mutex> lock(_mutex);
    return _current.accuracy < 0.05f;
}

std::string GnssSimulator::lastNmea() const {
    std::unique_lock<std::mutex> lock(_mutex);
    return _lastNmea;
}

// ── Sterowanie wątkiem ───────────────────────────────────────────────────────

void GnssSimulator::start(SimCallback callback) {
    if (_running.load()) return;
    _callback = std::move(callback);
    _running.store(true);
    _thread = std::thread(&GnssSimulator::threadLoop, this);
}

void GnssSimulator::stop() {
    _running.store(false);
    if (_thread.joinable()) _thread.join();
}

void GnssSimulator::threadLoop() {
    using Clock    = std::chrono::steady_clock;
    using Ms       = std::chrono::milliseconds;

    auto next = Clock::now();

    while (_running.load()) {
        // Oblicz nową pozycję i zbuduj zdanie NMEA
        std::string nmea = tick();

        // Wywołaj callback poza lockiem, by nie blokować
        GnssPosition snap;
        {
            std::unique_lock<std::mutex> lock(_mutex);
            snap = _current;
        }

        if (_callback) {
            _callback(snap, nmea);
        }

        // Precyzyjne czekanie (nadrabiamy dryf czasu)
        next += Ms(SIM_INTERVAL_MS);
        std::this_thread::sleep_until(next);
    }
}

// ── Generowanie pozycji i NMEA ───────────────────────────────────────────────

std::string GnssSimulator::tick() {
    // ── ENU basis  (origin = point A) ────────────────────────────────────────
    const double cosLat     = std::cos(SIM_A_LAT * (M_PI / 180.0));
    const double mPerDegLon = 111320.0 * cosLat;   // [m/deg] at this latitude

    // Vector A→B in ENU [m]
    const double abE   = (SIM_B_LON - SIM_A_LON) * mPerDegLon;
    const double abN   = (SIM_B_LAT - SIM_A_LAT) * 111320.0;
    const double abLen = std::sqrt(abE * abE + abN * abN);

    // Unit vectors: d = along A→B,  l = left of A→B (CCW 90°)
    const double dE = abE / abLen;
    const double dN = abN / abLen;
    const double lE = -dN;   // left perpendicular
    const double lN =  dE;

    // ── Advance parametric position ───────────────────────────────────────────
    const double dt = SIM_INTERVAL_MS * 1e-3;       // tick duration [s]
    _passT += (SIM_SPEED_MS * dt) / abLen;          // delta along unit-normalised pass

    if (_passT >= 1.0) {
        _passT  -= 1.0;       // carry fractional overshoot into the new pass
        _forward = !_forward;
        ++_passIndex;
    }

    // ── Compute ENU position ──────────────────────────────────────────────────
    // Forward  (t: A_shifted → B_shifted):  pos = shift + t·AB
    // Backward (t: B_shifted → A_shifted):  pos = shift + (1-t)·AB
    const double curShift = static_cast<double>(_passIndex) * PASS_SHIFT_M;
    const double sE = curShift * lE;
    const double sN = curShift * lN;

    double posE, posN;
    if (_forward) {
        posE = sE + _passT * abE;
        posN = sN + _passT * abN;
    } else {
        posE = sE + abE * (1.0 - _passT);
        posN = sN + abN * (1.0 - _passT);
    }

    // ── ENU → WGS-84 ──────────────────────────────────────────────────────────
    GnssPosition pos{};
    pos.latitude  = SIM_A_LAT + posN / 111320.0;
    pos.longitude = SIM_A_LON + posE / mPerDegLon;
    pos.altitude  = _startAlt;
    pos.accuracy  = static_cast<float>(SIM_ACCURACY_M);
    pos.timestamp = std::chrono::duration<double>(
        std::chrono::system_clock::now().time_since_epoch()).count();

    std::string nmea = buildGpgga(pos);

    {
        std::unique_lock<std::mutex> lock(_mutex);
        _current  = pos;
        _lastNmea = nmea;
    }

    return nmea;
}

// ── Budowanie zdania $GPGGA ───────────────────────────────────────────────────

std::string GnssSimulator::buildGpgga(const GnssPosition& pos) {
    // Konwersja stopni dziesiętnych → NMEA ddmm.mmmmm
    auto toNmea = [](double deg, int intWidth) -> std::string {
        double absDeg = std::fabs(deg);
        int    d      = static_cast<int>(absDeg);
        double m      = (absDeg - d) * 60.0;
        std::ostringstream ss;
        ss << std::setw(intWidth) << std::setfill('0') << d
           << std::fixed << std::setw(8) << std::setprecision(5)
           << std::setfill('0') << m;
        return ss.str();
    };

    // Czas UTC z systemu
    std::time_t t  = static_cast<std::time_t>(pos.timestamp);
    std::tm*    ut = std::gmtime(&t);
    char timeBuf[16];
    std::snprintf(timeBuf, sizeof(timeBuf), "%02d%02d%02d.00",
                  ut->tm_hour, ut->tm_min, ut->tm_sec);

    std::string latNmea = toNmea(pos.latitude,  2);
    std::string lonNmea = toNmea(pos.longitude, 3);
    char nsDir = pos.latitude  >= 0 ? 'N' : 'S';
    char ewDir = pos.longitude >= 0 ? 'E' : 'W';

    std::ostringstream body;
    body << "GPGGA,"
         << timeBuf          << ","
         << latNmea          << "," << nsDir << ","
         << lonNmea          << "," << ewDir << ","
         << "4,"                // quality: 4 = RTK fix
         << "12,"               // liczba satelitów
         << "0.5,"              // HDOP
         << std::fixed << std::setprecision(2) << pos.altitude << ",M,"
         << "0.0,M,"            // geoid separation
         << ",";                // DGPS – brak

    std::string bodyStr = body.str();
    uint8_t     csum    = nmeaChecksum(bodyStr);

    std::ostringstream sentence;
    sentence << "$" << bodyStr << "*"
             << std::uppercase << std::hex
             << std::setw(2) << std::setfill('0')
             << static_cast<int>(csum);
    return sentence.str();
}

uint8_t GnssSimulator::nmeaChecksum(const std::string& body) {
    uint8_t cs = 0;
    for (char c : body) cs ^= static_cast<uint8_t>(c);
    return cs;
}

} // namespace agrinav
