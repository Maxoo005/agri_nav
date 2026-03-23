#include "GnssSimulator.h"

#include <chrono>
#include <cmath>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <sstream>

namespace agrinav {

// ── Stałe symulacji ──────────────────────────────────────────────────────────

static constexpr int    SIM_INTERVAL_MS  = 100;       // okres generowania [ms]
static constexpr double ORBIT_RADIUS_M   = 50.0;      // promień ruchu kołowego [m]
static constexpr double ORBIT_PERIOD_S   = 60.0;      // czas jednego okrążenia [s]
static constexpr double DEG_PER_M_LAT    = 1.0 / 111320.0;
static constexpr double SIM_ACCURACY_M   = 0.02;      // RTK fix (< 0.05 m)

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
    // Ruch kołowy o promieniu ORBIT_RADIUS_M wokół punktu startowego
    double stepsPerOrbit = (ORBIT_PERIOD_S * 1000.0) / SIM_INTERVAL_MS;
    double angle = (2.0 * M_PI * _step) / stepsPerOrbit;

    double cosLat           = std::cos(_startLat * M_PI / 180.0);
    double degPerMLon       = (cosLat > 1e-6) ? DEG_PER_M_LAT / cosLat : DEG_PER_M_LAT;

    GnssPosition pos{};
    pos.latitude   = _startLat + ORBIT_RADIUS_M * std::sin(angle) * DEG_PER_M_LAT;
    pos.longitude  = _startLon + ORBIT_RADIUS_M * std::cos(angle) * degPerMLon;
    pos.altitude   = _startAlt + 0.1 * std::sin(angle * 3.0); // lekki szum wys.
    pos.accuracy   = static_cast<float>(SIM_ACCURACY_M);

    // Znacznik czasu UNIX
    pos.timestamp = std::chrono::duration<double>(
        std::chrono::system_clock::now().time_since_epoch()).count();

    std::string nmea = buildGpgga(pos);

    {
        std::unique_lock<std::mutex> lock(_mutex);
        _current  = pos;
        _lastNmea = nmea;
    }

    ++_step;
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
