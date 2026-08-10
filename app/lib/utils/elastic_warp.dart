import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo_utils.dart';

/// Elastyczna transformacja "gumowa" (rubber-sheeting) metodą Inverse
/// Distance Weighting (IDW, interpolacja Sheparda) — w przeciwieństwie do
/// [GeoUtils.fitSimilarity2D] (sztywny obrót+skala+przesunięcie całego
/// kształtu), przechodzi DOKŁADNIE przez każdą wskazaną parę punktów, a
/// między nimi odkształca kształt gładko i lokalnie.
///
/// ## Jak to działa (intuicja)
///
/// Każda para punktów kontrolnych (źródło↔cel) daje wektor przesunięcia —
/// o ile i w którą stronę trzeba przesunąć ten konkretny punkt, żeby trafić
/// w cel. Dla DOWOLNEGO innego punktu granicy liczona jest ważona średnia
/// WSZYSTKICH wektorów przesunięcia, gdzie waga maleje z kwadratem
/// odległości do danego punktu kontrolnego — jak magnesy: bliższe punkty
/// kontrolne "ciągną" mocniej niż dalekie. Dokładnie w punkcie kontrolnym
/// jego własna waga rośnie do nieskończoności (odległość → 0), więc
/// przesunięcie jest dokładnie takie, jak wskazano — to nadal interpolacja,
/// nie przybliżenie, tak samo jak przy klasycznym Thin Plate Spline (TPS).
///
///   przesunięcie(p) = Σᵢ wᵢ(p)·dᵢ / Σᵢ wᵢ(p),  wᵢ(p) = 1 / |p − źródło_i|²
///   f(p) = p + przesunięcie(p)
///
/// **Różnica względem TPS**: TPS rozwiązuje układ równań liniowych (część
/// afiniczna + promieniowa), co wymaga co najmniej 3 punktów źródłowych
/// NIEleżących na jednej prostej — inaczej układ jest matematycznie
/// nierozwiązywalny. IDW nie rozwiązuje żadnego układu równań (to zwykła
/// ważona średnia), więc działa dla DOWOLNEGO ułożenia punktów, także
/// całkowicie współliniowych (np. wszystkie wzdłuż jednej, długiej krawędzi
/// wąskiego pola — najbardziej naturalny scenariusz korekty w tej
/// aplikacji). Kompromis: IDW nie jest matematycznie "najgładszą możliwą"
/// powierzchnią (jak TPS, minimalizujący energię zginania) — w praktyce,
/// przy typowej gęstości punktów kontrolnych i skali pola, różnica jest
/// wizualnie nieistotna.
///
/// Osobna funkcja tego kształtu jest liczona dla współrzędnej E i osobna
/// dla N (te same wagi, dwa różne wektory przesunięcia).
class ElasticWarp {
  ElasticWarp._(this._srcPts, this._displacements);

  final List<Enu> _srcPts;
  final List<Enu> _displacements; // target_i − source_i, per punkt kontrolny

  /// Minimalna liczba par wymagana przez UI (patrz `ControlPointsPanel`) —
  /// próg spójności/UX ("od 4. pary"), NIE wymóg matematyczny: IDW poniżej
  /// tego progu też dałoby sensowny wynik, po prostu aplikacja poniżej 4 par
  /// używa [GeoUtils.fitSimilarity2D] (sztywnej transformacji).
  static const int minControlPoints = 4;

  /// Dopasowuje IDW do [src]/[tgt] (ten sam indeks = ta sama para), w
  /// lokalnym układzie ENU (metry) — patrz [GeoUtils.toEnu].
  ///
  /// Wymaga `src.length == tgt.length >= [minControlPoints]`. To jedynie
  /// dokumentacja przez `assert` (znika w trybie release) — wywołujący MUSI
  /// sam sprawdzić długość listy przed wywołaniem, dokładnie jak przy
  /// [GeoUtils.fitSimilarity2D].
  factory ElasticWarp.fit(List<Enu> src, List<Enu> tgt) {
    assert(src.length == tgt.length && src.length >= minControlPoints,
        'ElasticWarp.fit wymaga co najmniej $minControlPoints par punktów');
    final displacements = List.generate(
      src.length,
      (i) => (e: tgt[i].e - src[i].e, n: tgt[i].n - src[i].n),
    );
    return ElasticWarp._(List.of(src), displacements);
  }

  /// Próg odległości [m], poniżej którego punkt jest traktowany jako
  /// pokrywający się z punktem kontrolnym (unika dzielenia przez ~0 przy
  /// wadze `1/odległość²`).
  static const double _coincidentThresholdM = 1e-3;

  /// Transformuje dowolny punkt [p] (ENU) ze źródła do celu — nie tylko
  /// punkty użyte jako kontrolne, każdy punkt w przestrzeni źródłowej.
  Enu transform(Enu p) {
    var sumW = 0.0, sumWE = 0.0, sumWN = 0.0;
    for (var i = 0; i < _srcPts.length; i++) {
      final dE = p.e - _srcPts[i].e;
      final dN = p.n - _srcPts[i].n;
      final dist2 = dE * dE + dN * dN;
      if (dist2 < _coincidentThresholdM * _coincidentThresholdM) {
        return (e: p.e + _displacements[i].e, n: p.n + _displacements[i].n);
      }
      final w = 1.0 / dist2;
      sumW += w;
      sumWE += w * _displacements[i].e;
      sumWN += w * _displacements[i].n;
    }
    return (e: p.e + sumWE / sumW, n: p.n + sumWN / sumW);
  }

  /// Wygoda odpowiadająca [GeoUtils.applySimilarity2D] — transformuje [point]
  /// (WGS-84) przez [transform], konwertując do/z lokalnego ENU względem
  /// [origin].
  LatLng applyToLatLng(LatLng origin, LatLng point) {
    final p = GeoUtils.toEnu(origin, point);
    final t = transform(p);
    return GeoUtils.fromEnu(origin, t.e, t.n);
  }

  /// Wstawia dodatkowe punkty pośrednie na każdej krawędzi zamkniętego
  /// pierścienia [ring] (ostatni punkt łączy się z pierwszym — jak
  /// `FieldModel.boundary`, bez powielania punktu zamykającego), co ~[stepM]
  /// metrów (maks. [maxPerEdge] na krawędź).
  ///
  /// Potrzebne wyłącznie przy renderowaniu przez tę transformację: mapa
  /// rysuje granicę jako proste odcinki między kolejnymi punktami, więc
  /// krzywizna, którą wprowadza [transform], jest widoczna tylko tam, gdzie
  /// faktycznie ISTNIEJE punkt do przesunięcia. Surowa geometria katastralna
  /// ma wierzchołki tylko w narożnikach — bez zagęszczenia odkształcenie
  /// środka długiego, prostego boku (dokładnie ten przypadek, który ta
  /// transformacja ma naprawiać) w ogóle by się nie pokazało, bo oba jego
  /// końce (narożniki) po prostu przesunęłyby się, a odcinek między nimi
  /// zostałby narysowany jako nowa prosta. Wywołaj PRZED [transform]/
  /// [applyToLatLng] — interpolacja liniowa ma sens na surowej (jeszcze
  /// nieodkształconej) geometrii, gdzie krawędzie naprawdę są proste.
  static List<Enu> densifyRing(
    List<Enu> ring, {
    double stepM = 5.0,
    int maxPerEdge = 40,
  }) {
    if (ring.length < 2) return List.of(ring);
    final out = <Enu>[];
    for (var i = 0; i < ring.length; i++) {
      final a = ring[i];
      final b = ring[(i + 1) % ring.length];
      out.add(a);
      final dE = b.e - a.e;
      final dN = b.n - a.n;
      final lenM = math.sqrt(dE * dE + dN * dN);
      final subdivisions = (lenM / stepM).ceil().clamp(1, maxPerEdge);
      for (var k = 1; k < subdivisions; k++) {
        final t = k / subdivisions;
        out.add((e: a.e + t * dE, n: a.n + t * dN));
      }
    }
    return out;
  }
}
