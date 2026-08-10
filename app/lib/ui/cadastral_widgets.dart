import 'package:flutter/material.dart';

import '../models/field_model.dart';
import '../services/gps_location_service.dart';
import '../utils/elastic_warp.dart';
import 'widgets/fix_quality_badge.dart';

// ─────────────────────────────────────────────────────────────────────────────
// NudgePanel — panel korekty przesunięcia działki
// ─────────────────────────────────────────────────────────────────────────────

/// Overlay strzałkowy do ręcznego przesuwania granicy działki.
/// Każde kliknięcie przesuwa o [_stepM] metrów.
class NudgePanel extends StatelessWidget {
  const NudgePanel({
    super.key,
    required this.field,
    required this.onNudge,
    required this.onReset,
    required this.onClose,
  });

  final FieldModel field;
  final void Function(double dx, double dy) onNudge;
  final VoidCallback onReset;
  final VoidCallback onClose;

  static const double _stepM = 0.25; // krok 25 cm

  @override
  Widget build(BuildContext context) {
    final offsetCm = (
      lat: (field.offsetLat * 111320.0 * 100).toStringAsFixed(0),
      lon: (field.offsetLon * 111320.0 * 100).toStringAsFixed(0),
    );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Tytuł + zamknij ────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Korekta granicy',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              GestureDetector(
                onTap: onClose,
                child: const Icon(Icons.close, color: Colors.white54, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 4),

          // ── Aktualny offset ────────────────────────────────────────────
          Text(
            'N: ${offsetCm.lat} cm  /  E: ${offsetCm.lon} cm',
            style: const TextStyle(color: Colors.yellowAccent, fontSize: 11),
          ),
          const SizedBox(height: 8),

          // ── Krzyżak strzałkowy ─────────────────────────────────────────
          _NudgeButton(
            icon: Icons.keyboard_arrow_up_rounded,
            onTap: () => onNudge(0, _stepM),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _NudgeButton(
                icon: Icons.keyboard_arrow_left_rounded,
                onTap: () => onNudge(-_stepM, 0),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: onReset,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.center_focus_strong_rounded,
                      color: Colors.white54, size: 18),
                ),
              ),
              const SizedBox(width: 4),
              _NudgeButton(
                icon: Icons.keyboard_arrow_right_rounded,
                onTap: () => onNudge(_stepM, 0),
              ),
            ],
          ),
          _NudgeButton(
            icon: Icons.keyboard_arrow_down_rounded,
            onTap: () => onNudge(0, -_stepM),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ControlPointsPanel — panel korekty granicy punktami kontrolnymi
// ─────────────────────────────────────────────────────────────────────────────

/// Overlay sterujący trybem wskazywania par punktów kontrolnych
/// (wierzchołek granicy katastralnej ↔ jego rzeczywista pozycja na
/// ortofotomapie). Metoda dopasowania jest dobierana automatycznie z liczby
/// wskazanych par — bez osobnego przełącznika: 2-3 pary liczą transformację
/// podobieństwa (obrót+skala+przesunięcie, [FieldCorrectionMode.similarity]),
/// a od [ElasticWarp.minControlPoints] par aplikacja sama przechodzi na
/// elastyczne dopasowanie ([FieldCorrectionMode.elastic]), które dogina
/// kształt lokalnie zamiast tylko globalnie obracać/skalować.
class ControlPointsPanel extends StatelessWidget {
  const ControlPointsPanel({
    super.key,
    required this.pairCount,
    required this.hasPendingSource,
    required this.onUndo,
    required this.onReset,
    required this.onRemovePair,
    required this.onCancel,
    required this.onConfirm,
  });

  final int pairCount;
  final bool hasPendingSource;
  final VoidCallback onUndo;
  final VoidCallback onReset;

  /// Usuwa pojedynczą parę o indeksie [int] — przydatne przy 4+ parach,
  /// gdy trzeba poprawić jedną konkretną bez cofania wszystkich po niej.
  final void Function(int index) onRemovePair;
  final VoidCallback onCancel;

  /// Zawsze klikalny — przy < 2 parach [onConfirm] pokazuje komunikat
  /// zamiast cicho nic nie robić (przycisk `onPressed: null` łatwo
  /// przeoczyć w ciemnym motywie).
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final hint = hasPendingSource
        ? 'Krok 2: stuknij odpowiadający punkt na ortofotomapie'
        : 'Krok 1: stuknij wierzchołek granicy katastralnej';
    final isElastic = pairCount >= ElasticWarp.minControlPoints;

    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Punkty kontrolne',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              GestureDetector(
                onTap: onCancel,
                child: const Icon(Icons.close, color: Colors.white54, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            hint,
            style: const TextStyle(color: Colors.yellowAccent, fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text(
            pairCount >= 2 ? 'Par: $pairCount ✓ gotowe' : 'Par: $pairCount (min. 2)',
            style: TextStyle(
              color: pairCount >= 2 ? Colors.lightGreenAccent : Colors.orangeAccent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (pairCount >= 2) ...[
            const SizedBox(height: 2),
            Text(
              isElastic
                  ? 'Dopasowanie: elastyczne'
                  : 'Dopasowanie: proste (obrót+skala)',
              style: TextStyle(
                color: isElastic ? Colors.cyanAccent : Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (pairCount >= 1) ...[
            const SizedBox(height: 4),
            const Text(
              'Rozłóż punkty wzdłuż całej granicy, nie tylko na końcach — '
              'od 4. pary dopasowanie staje się elastyczne i lokalnie '
              'doginie kształt.',
              style: TextStyle(color: Colors.white54, fontSize: 10),
            ),
          ],
          if (pairCount > 0) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 110),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: pairCount,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Para ${i + 1}',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 11),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => onRemovePair(i),
                        child: const Icon(Icons.close,
                            color: Colors.redAccent, size: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: (pairCount > 0 || hasPendingSource) ? onUndo : null,
                  child: const Text('Cofnij'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: OutlinedButton(
                  onPressed: (pairCount > 0 || hasPendingSource) ? onReset : null,
                  child: const Text('Reset'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onCancel,
                  child: const Text('Anuluj'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FilledButton(
                  onPressed: onConfirm,
                  style: FilledButton.styleFrom(
                    backgroundColor:
                        pairCount >= 2 ? null : Colors.white24,
                  ),
                  child: const Text('Zatwierdź'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AbRecordingPanel — panel na żywo podczas nagrywania linii AB przejazdem
// ─────────────────────────────────────────────────────────────────────────────

/// Overlay pokazywany podczas nagrywania linii AB przez fizyczny przejazd
/// (patrz `GeoUtils.fitLineThroughPoints` — dopasowanie najmniejszych
/// kwadratów po zatrzymaniu). Pokazuje liczbę zaakceptowanych punktów (tylko
/// jakości RTK Fixed — gorsze punkty są odrzucane na bieżąco, zanim tu
/// trafią), bieżącą jakość fixa i, gdy da się już policzyć, bieżącą długość
/// nagranego odcinka.
///
/// Osobny pływający panel (zamiast wpisu w modalnym panelu akcji "POLE") —
/// ten drugi jest budowany raz przy otwarciu i nie reaguje na `setState()`
/// rodzica, więc nie nadaje się do pokazywania zmieniającej się na żywo
/// liczby punktów.
class AbRecordingPanel extends StatelessWidget {
  const AbRecordingPanel({
    super.key,
    required this.pointCount,
    required this.lengthM,
    required this.fixStatus,
    required this.onStop,
    required this.onCancel,
  });

  final int pointCount;

  /// `null` dopóki nie da się policzyć długości (< 2 punkty).
  final double? lengthM;
  final GpsFixStatus fixStatus;

  /// Zatrzymuje nagrywanie i liczy dopasowanie — gdy przejazd jest za
  /// krótki/ma za mało punktów RTK Fixed, wywołujący pokazuje ostrzeżenie i
  /// NIE przerywa nagrywania (użytkownik może jechać dalej i spróbować
  /// ponownie), więc ten panel może zostać widoczny także po nieudanej próbie.
  final VoidCallback onStop;

  /// Przerywa nagrywanie i odrzuca zebrane punkty bez próby dopasowania.
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 240,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xCC000000),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Nagrywanie linii AB',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              FixQualityBadge(status: fixStatus, dense: true),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Punkty (RTK Fixed): $pointCount',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 2),
          Text(
            lengthM != null
                ? 'Długość: ${lengthM!.toStringAsFixed(1)} m'
                : 'Długość: —',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onCancel,
                  child: const Text('Anuluj'),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: FilledButton(
                  onPressed: onStop,
                  style: FilledButton.styleFrom(backgroundColor: Colors.green[700]),
                  child: const Text('Zakończ'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.all(2),
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24),
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}
