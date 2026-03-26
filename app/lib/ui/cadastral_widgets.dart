import 'package:flutter/material.dart';

import '../models/field_model.dart';
import '../services/geoportal_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TerytSearchSheet — bottomSheet do wyszukiwania działek po numerze TERYT
// ─────────────────────────────────────────────────────────────────────────────

/// Wyświetla bottomSheet z polem tekstowym do wpisania numeru ewidencyjnego
/// i wywołuje [GeoportalService.fetchAndCacheByTeryt].
///
/// Po pobraniu działki wywołuje [onFieldFetched] z nowym [FieldModel].
class TerytSearchSheet extends StatefulWidget {
  const TerytSearchSheet({super.key, required this.onFieldFetched});

  final void Function(FieldModel field) onFieldFetched;

  static Future<void> show(
    BuildContext context, {
    required void Function(FieldModel) onFieldFetched,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => TerytSearchSheet(onFieldFetched: onFieldFetched),
    );
  }

  @override
  State<TerytSearchSheet> createState() => _TerytSearchSheetState();
}

class _TerytSearchSheetState extends State<TerytSearchSheet> {
  final _ctrl = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final id = _ctrl.text.trim();
    if (id.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final field = await GeoportalService.instance.fetchAndCacheByTeryt(id);
      if (!mounted) return;
      Navigator.pop(context);
      widget.onFieldFetched(field);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1C1C1C),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Uchwyt ─────────────────────────────────────────────────────
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── Tytuł ──────────────────────────────────────────────────────
            Row(
              children: const [
                Icon(Icons.search_rounded, color: Colors.greenAccent, size: 20),
                SizedBox(width: 8),
                Text(
                  'Szukaj działki po numerze TERYT',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Np.: 141201_2.0001.1234/2',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 14),

            // ── Pole tekstowe ──────────────────────────────────────────────
            TextField(
              controller: _ctrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Numer ewidencyjny działki',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Colors.greenAccent),
                ),
                suffixIcon: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.greenAccent,
                          ),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.send_rounded,
                            color: Colors.greenAccent),
                        onPressed: _fetch,
                      ),
              ),
              onSubmitted: (_) => _fetch(),
            ),

            // ── Komunikat błędu ────────────────────────────────────────────
            if (_error != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 12),

            // ── Przycisk pobierz ──────────────────────────────────────────
            SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.green[800],
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: _loading ? null : _fetch,
                icon: const Icon(Icons.download_rounded),
                label: const Text('Pobierz i zapisz działkę'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

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
