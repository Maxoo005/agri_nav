import 'package:flutter/material.dart';

import '../models/field_model.dart';

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
/// ortofotomapie). Aplikacja liczy z par transformację podobieństwa
/// (obrót + skala + przesunięcie) metodą najmniejszych kwadratów.
class ControlPointsPanel extends StatelessWidget {
  const ControlPointsPanel({
    super.key,
    required this.pairCount,
    required this.hasPendingSource,
    required this.onUndo,
    required this.onReset,
    required this.onCancel,
    required this.onConfirm,
  });

  final int pairCount;
  final bool hasPendingSource;
  final VoidCallback onUndo;
  final VoidCallback onReset;
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
