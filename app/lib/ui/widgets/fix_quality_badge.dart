import 'package:flutter/material.dart';

import '../../services/gps_location_service.dart';

/// Kolorowa kropka + etykieta pokazująca aktualną jakość fixa GNSS.
///
/// Kolory (zgodnie z konwencją "czerwony = za mało dokładne do prowadzenia,
/// zielony = gotowe do precyzyjnej nawigacji"):
/// - czerwony/szary — brak fixa / GPS autonomiczny (za mało dokładne)
/// - pomarańczowy — DGPS (lepiej, ale wciąż nie RTK)
/// - żółty — RTK Float (poprawki RTK jeszcze się nie domknęły, dm-level)
/// - zielony — RTK Fixed (1-3 cm, gotowe do prowadzenia po liniach)
class FixQualityBadge extends StatelessWidget {
  const FixQualityBadge({super.key, required this.status, this.dense = false});

  final GpsFixStatus status;

  /// `true` — sama kropka (do zwartego HUD-a), `false` — kropka + etykieta.
  final bool dense;

  static const _dotSize = 10.0;

  (Color, String) get _visual => switch (status) {
        GpsFixStatus.inactive => (Colors.grey, 'Nieaktywny'),
        GpsFixStatus.searching => (Colors.grey, 'Szukanie sygnału…'),
        GpsFixStatus.gps => (Colors.redAccent, 'GPS (niska dokładność)'),
        GpsFixStatus.dgps => (Colors.orangeAccent, 'DGPS'),
        GpsFixStatus.rtkFloat => (Colors.amber, 'RTK Float'),
        GpsFixStatus.rtkFixed => (Colors.greenAccent, 'RTK Fixed'),
      };

  @override
  Widget build(BuildContext context) {
    final (color, label) = _visual;

    final dot = Container(
      width: _dotSize,
      height: _dotSize,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 4),
        ],
      ),
    );

    if (dense) {
      return Tooltip(message: label, child: dot);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12),
        ),
      ],
    );
  }
}
