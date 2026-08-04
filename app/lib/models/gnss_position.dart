/// Jakość fixa zgłoszona w polu #6 zdania `$--GGA`.
///
/// Mapowanie wartości liczbowych jest zgodne ze specyfikacją NMEA 0183
/// (nie z kolejnością nazw — `rtkFixed` to wartość 4, `rtkFloat` to 5,
/// mimo że w mowie potocznej "float" zwykle wymienia się przed "fixed"):
/// ```
/// 0 = brak fixa           (noFix)
/// 1 = autonomiczny GPS     (gps)
/// 2 = DGPS                 (dgps)
/// 3 = PPS                  → traktowany jak noFix (nieużywany przez ZED-F9P)
/// 4 = RTK Fixed             (rtkFixed)  — dokładność rzędu 1-3 cm
/// 5 = RTK Float             (rtkFloat)  — dokładność rzędu dm, poprawki niepełne
/// 6 = estimated / dead-reckoning → traktowany jak noFix
/// ```
enum GnssFixQuality {
  noFix,
  gps,
  dgps,
  rtkFloat,
  rtkFixed;

  /// Konwersja z surowej wartości pola GGA #6.
  static GnssFixQuality fromGgaValue(int value) {
    switch (value) {
      case 1:
        return GnssFixQuality.gps;
      case 2:
        return GnssFixQuality.dgps;
      case 4:
        return GnssFixQuality.rtkFixed;
      case 5:
        return GnssFixQuality.rtkFloat;
      default:
        // 0 (invalid), 3 (PPS), 6 (estimated) i wszystko nierozpoznane.
        return GnssFixQuality.noFix;
    }
  }
}

/// Pozycja i jakość fixa z zewnętrznego odbiornika GNSS (parsowana z NMEA).
///
/// Składana z dwóch zdań NMEA nadawanych w tej samej "epoce" pomiaru:
/// `$--GGA` daje pozycję/wysokość/jakość fixa/liczbę satelitów/HDOP,
/// `$--RMC` daje prędkość i kurs. [BluetoothGnssService] łączy najnowsze
/// dane z obu w jeden obiekt przy każdym nowym GGA.
class GnssPosition {
  const GnssPosition({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.fixQuality,
    required this.satellitesCount,
    required this.hdop,
    required this.timestamp,
    this.heading = -1.0,
    this.speed = -1.0,
  });

  final double latitude;
  final double longitude;
  final double altitude; // [m] n.p.m.
  final GnssFixQuality fixQuality;
  final int satellitesCount;
  final double hdop;

  /// [°] od północy, −1 gdy brak aktualnych danych RMC.
  final double heading;

  /// [m/s], −1 gdy brak aktualnych danych RMC.
  final double speed;

  /// Moment odebrania (parsowania) tej pozycji — używany do wykrywania
  /// nieaktualnych danych RMC przy składaniu z GGA.
  final DateTime timestamp;

  @override
  String toString() =>
      'GnssPosition(lat=$latitude, lon=$longitude, alt=$altitude, '
      'fix=$fixQuality, sats=$satellitesCount, hdop=$hdop, '
      'hdg=$heading, spd=$speed)';
}

/// Chwilowy status odbiornika — jakość fixa + liczba satelitów + HDOP,
/// aktualizowany z KAŻDEGO poprawnego strukturalnie zdania GGA, również gdy
/// nie ma jeszcze samego fixu ([GnssPosition] wtedy nie istnieje, bo nie ma
/// współrzędnych).
///
/// Głównie do diagnostyki: liczba satelitów > 0 przy braku fixa oznacza, że
/// dane NMEA faktycznie docierają i antena coś widzi — po prostu odbiornik
/// (lub poprawki RTK) jeszcze się nie zbiegły. Brak jakichkolwiek zdarzeń na
/// tym strumieniu (mimo widocznego połączenia Bluetooth) oznacza, że dane
/// NMEA w ogóle nie docierają albo się nie parsują — inny rodzaj problemu.
class GnssStatus {
  const GnssStatus({
    required this.fixQuality,
    required this.satellitesCount,
    required this.hdop,
  });

  final GnssFixQuality fixQuality;
  final int satellitesCount;
  final double hdop;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Walidacja checksumy NMEA
// ═══════════════════════════════════════════════════════════════════════════════

/// Sprawdza checksumę zdania NMEA (`$....*hh`).
///
/// Checksuma to XOR kodów ASCII wszystkich znaków między `$` a `*`,
/// zapisany jako 2 cyfry heksadecymalne. Odrzuca uszkodzone/przycięte
/// linijki (typowe przy transmisji Bluetooth, gdzie bajty mogą się gubić
/// lub dzielić na przypadkowe fragmenty).
bool isNmeaChecksumValid(String sentence) {
  final s = sentence.trim();
  if (s.length < 4 || !s.startsWith(r'$')) return false;

  final starIndex = s.indexOf('*');
  if (starIndex < 1 || starIndex + 3 > s.length) return false;

  final expectedHex = s.substring(starIndex + 1, starIndex + 3);
  final expected = int.tryParse(expectedHex, radix: 16);
  if (expected == null) return false;

  int checksum = 0;
  for (int i = 1; i < starIndex; i++) {
    checksum ^= s.codeUnitAt(i);
  }

  return checksum == expected;
}

// ═══════════════════════════════════════════════════════════════════════════════
// Parsowanie $--GGA
// ═══════════════════════════════════════════════════════════════════════════════

/// Wynik parsowania zdania `$--GGA` (np. `$GNGGA`, `$GPGGA`).
///
/// [latitude]/[longitude]/[altitude] są `null` gdy [fixQuality] to
/// [GnssFixQuality.noFix] — odbiornik wtedy zwykle zostawia te pola puste
/// w samym zdaniu NMEA (nie ma pozycji do podania).
class GgaData {
  const GgaData({
    required this.latitude,
    required this.longitude,
    required this.altitude,
    required this.fixQuality,
    required this.satellitesCount,
    required this.hdop,
  });

  final double? latitude;
  final double? longitude;
  final double? altitude;
  final GnssFixQuality fixQuality;
  final int satellitesCount;
  final double hdop;
}

/// Parsuje zdanie `$--GGA`. Zwraca `null` tylko gdy checksuma jest zła albo
/// format nie pasuje — CELOWO zwraca dane też przy braku fixa (quality=0),
/// żeby wywołujący mógł zaktualizować status "brak fixa" na żywo, nawet gdy
/// nie ma jeszcze współrzędnych do pokazania na mapie.
///
/// Pola GGA (po przecinkach, indeksy liczone od `$GNGGA`):
/// `0:ID 1:czas 2:lat 3:N/S 4:lon 5:E/W 6:quality 7:numSV 8:HDOP 9:alt 10:M ...`
GgaData? parseGga(String sentence) {
  if (!isNmeaChecksumValid(sentence)) return null;

  final body = sentence.split('*').first;
  final fields = body.split(',');
  // Sam identyfikator + 9 pól pozycyjnych (0..9) musi być obecne.
  if (fields.length < 10) return null;
  if (!fields[0].endsWith('GGA')) return null;

  final qualityRaw = int.tryParse(fields[6]);
  if (qualityRaw == null) return null; // strukturalnie uszkodzone pole

  return GgaData(
    latitude: _parseNmeaLatLon(fields[2], fields[3]),
    longitude: _parseNmeaLatLon(fields[4], fields[5]),
    altitude: double.tryParse(fields[9]),
    fixQuality: GnssFixQuality.fromGgaValue(qualityRaw),
    satellitesCount: int.tryParse(fields[7]) ?? 0,
    hdop: double.tryParse(fields[8]) ?? 99.9,
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Parsowanie $--RMC
// ═══════════════════════════════════════════════════════════════════════════════

/// Wynik parsowania zdania `$--RMC` (np. `$GNRMC`, `$GPRMC`).
class RmcData {
  const RmcData({required this.heading, required this.speed});

  /// [°] kurs nad ziemią (true course).
  final double heading;

  /// [m/s] prędkość nad ziemią.
  final double speed;
}

/// Parsuje zdanie `$--RMC`. Zwraca `null` gdy checksuma jest zła, format
/// nie pasuje, albo odbiornik oznaczył dane jako nieważne (`status != 'A'`).
///
/// Pola RMC: `0:ID 1:czas 2:status(A/V) 3:lat 4:N/S 5:lon 6:E/W
/// 7:prędkość[węzły] 8:kurs[°] 9:data ...`
RmcData? parseRmc(String sentence) {
  if (!isNmeaChecksumValid(sentence)) return null;

  final body = sentence.split('*').first;
  final fields = body.split(',');
  if (fields.length < 9) return null;
  if (!fields[0].endsWith('RMC')) return null;
  if (fields[2] != 'A') return null; // odbiornik zgłasza dane jako nieważne

  final speedKnots = double.tryParse(fields[7]);
  final courseDeg = double.tryParse(fields[8]);
  if (speedKnots == null || courseDeg == null) return null;

  const knotsToMs = 0.514444;
  return RmcData(heading: courseDeg, speed: speedKnots * knotsToMs);
}

// ═══════════════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════════════

/// Konwertuje współrzędną NMEA w formacie `ddmm.mmmm` (lub `dddmm.mmmm` dla
/// długości geograficznej) + literę półkuli na stopnie dziesiętne.
///
/// Przykład: `5213.7247,N` → 52° + 13.7247/60 = 52.229578.
double? _parseNmeaLatLon(String raw, String hemisphere) {
  if (raw.isEmpty || hemisphere.isEmpty) return null;
  final value = double.tryParse(raw);
  if (value == null) return null;

  final degrees = (value / 100).floorToDouble();
  final minutes = value - degrees * 100;
  double decimal = degrees + minutes / 60.0;

  if (hemisphere == 'S' || hemisphere == 'W') decimal = -decimal;
  return decimal;
}
