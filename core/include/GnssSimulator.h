#pragma once
#include "GnssProcessor.h"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>

namespace agrinav {

// Callback wywoływany z wątku symulatora co ~100 ms.
// Parametry: pozycja WGS-84 + ostatnie zdanie NMEA ($GPGGA).
using SimCallback = std::function<void(const GnssPosition&, const std::string& nmea)>;

// Symulator GPS: generuje dane w formacie NMEA i udostępnia je co 100 ms
// w osobnym wątku std::thread. Implementuje GnssProcessor, więc może
// zastąpić prawdziwy odbiornik w NavEngine podczas testów.
class GnssSimulator : public GnssProcessor {
public:
    // startLat / startLon – punkt startowy (WGS-84 stopnie dziesiętne)
    // startAlt             – wysokość [m], domyślnie 100 m n.p.m.
    explicit GnssSimulator(double startLat  = 52.2297,   // Warszawa
                            double startLon  = 21.0122,
                            double startAlt  = 100.0);
    ~GnssSimulator() override;

    // ── GnssProcessor ────────────────────────────────────────────────────────
    void         processNmea(const char* sentence) override;   // aktualizuje stan z zewnątrz
    GnssPosition currentPosition() const override;
    bool         hasFixRTK()       const override;

    // ── Sterowanie wątkiem ───────────────────────────────────────────────────
    // Uruchamia wątek; callback wywoływany co 100 ms.
    void start(SimCallback callback);
    // Zatrzymuje wątek (blokuje do zakończenia).
    void stop();
    bool isRunning() const { return _running.load(); }

    // ── Ostatnie zdanie NMEA ─────────────────────────────────────────────────
    std::string lastNmea() const;

private:
    void        threadLoop();

    // Generuje zdanie $GPGGA i aktualizuje _current.
    std::string tick();

    static std::string buildGpgga(const GnssPosition& pos);
    static uint8_t     nmeaChecksum(const std::string& body); // body BEZ '$' i '*xx'

    double _startLat, _startLon, _startAlt;
    uint32_t _step{0};

    mutable std::mutex _mutex;
    GnssPosition       _current{};
    std::string        _lastNmea;

    std::thread      _thread;
    std::atomic_bool _running{false};
    SimCallback      _callback;
};

} // namespace agrinav
