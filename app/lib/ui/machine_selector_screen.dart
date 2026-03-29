import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/field_model.dart';
import '../models/machine_model.dart';
import '../services/machine_service.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Wynik wyboru — maszyna + zaktualizowana szerokość robocza dla pola
// ─────────────────────────────────────────────────────────────────────────────

class MachineSelectorResult {
  const MachineSelectorResult({
    required this.machine,
  });
  final MachineModel machine;
}

// ─────────────────────────────────────────────────────────────────────────────
// MachineSelectorScreen
// ─────────────────────────────────────────────────────────────────────────────

class MachineSelectorScreen extends StatefulWidget {
  const MachineSelectorScreen({super.key, required this.field});

  final FieldModel field;

  static Future<MachineSelectorResult?> open(
    BuildContext context, {
    required FieldModel field,
  }) =>
      Navigator.push<MachineSelectorResult>(
        context,
        MaterialPageRoute(
          builder: (_) => MachineSelectorScreen(field: field),
        ),
      );

  @override
  State<MachineSelectorScreen> createState() => _MachineSelectorScreenState();
}

class _MachineSelectorScreenState extends State<MachineSelectorScreen> {
  String? _selectedId;

  void _select(MachineModel m) => setState(() => _selectedId = m.id);

  void _confirm(List<MachineModel> machines) {
    final m = machines.firstWhere((m) => m.id == _selectedId);
    Navigator.pop(context, MachineSelectorResult(machine: m));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E1E),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Wybierz maszynę do pracy',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            Text(
              'Wybór maszyny dla pola  "${widget.field.name}"',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Podgląd schematu pola ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              height: 140,
              decoration: BoxDecoration(
                color: const Color(0xFF1A2A1A),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white12),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CustomPaint(
                  painter: _FieldSchemaPainter(
                    field: widget.field,
                    workingWidthM: _currentWidth(null),
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 18, bottom: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Schemat pola: ${widget.field.name}'
                '  •  ${widget.field.boundaryLats.length} wierzchołków',
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ),
          ),

          // ── Lista maszyn ─────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: const [
                Icon(Icons.agriculture_outlined,
                    size: 16, color: Colors.white38),
                SizedBox(width: 6),
                Text('Maszyny w bazie',
                    style: TextStyle(color: Colors.white38, fontSize: 12)),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          Expanded(
            child: ValueListenableBuilder<Box>(
              valueListenable: MachineService.instance.listenable,
              builder: (context, _, __) {
                final machines = MachineService.instance.getAll();

                if (machines.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.agriculture_outlined,
                            size: 48, color: Colors.white24),
                        const SizedBox(height: 12),
                        const Text(
                          'Brak maszyn w bazie.\nDodaj maszynę w ekranie\n"Zarządzanie maszynami".',
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemCount: machines.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (_, i) => _MachineSelectorTile(
                    machine: machines[i],
                    isSelected: machines[i].id == _selectedId,
                    onSelect: () => _select(machines[i]),
                  ),
                );
              },
            ),
          ),

          // ── Przycisk Rozpocznij pracę ─────────────────────────────────
          ValueListenableBuilder<Box>(
            valueListenable: MachineService.instance.listenable,
            builder: (context, _, __) {
              final machines = MachineService.instance.getAll();
              final canStart = _selectedId != null &&
                  machines.any((m) => m.id == _selectedId);
              final selected = canStart
                  ? machines.firstWhere((m) => m.id == _selectedId)
                  : null;

              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (selected != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.check_circle_outline,
                                  color: Colors.greenAccent, size: 16),
                              const SizedBox(width: 6),
                              Text(
                                'Wybrano: ${selected.name}'
                                '${selected.workingWidthM != null ? '  •  ${selected.workingWidthM!.toStringAsFixed(1)} m' : ''}',
                                style: const TextStyle(
                                    color: Colors.greenAccent, fontSize: 13),
                              ),
                            ],
                          ),
                        ),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor:
                                canStart ? Colors.green[700] : Colors.grey[800],
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 22),
                          label: const Text(
                            'Rozpocznij pracę z wybraną maszyną',
                            style: TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                          onPressed: canStart ? () => _confirm(machines) : null,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  double _currentWidth(MachineModel? m) =>
      m?.workingWidthM ?? widget.field.workingWidthM;
}

// ─────────────────────────────────────────────────────────────────────────────
// Wiersz maszyny z przyciskiem Wybierz
// ─────────────────────────────────────────────────────────────────────────────

class _MachineSelectorTile extends StatelessWidget {
  const _MachineSelectorTile({
    required this.machine,
    required this.isSelected,
    required this.onSelect,
  });

  final MachineModel machine;
  final bool isSelected;
  final VoidCallback onSelect;

  static IconData _iconFor(MachineType t) {
    switch (t) {
      case MachineType.tractor:
        return Icons.agriculture;
      case MachineType.sprayer:
        return Icons.water_drop_outlined;
      case MachineType.seeder:
        return Icons.grain;
      case MachineType.cultivator:
        return Icons.construction;
      case MachineType.harvester:
        return Icons.content_cut;
      case MachineType.other:
        return Icons.build_outlined;
    }
  }

  static Color _colorFor(MachineType t) {
    switch (t) {
      case MachineType.tractor:
        return Colors.greenAccent;
      case MachineType.sprayer:
        return Colors.lightBlueAccent;
      case MachineType.seeder:
        return Colors.amberAccent;
      case MachineType.cultivator:
        return Colors.orangeAccent;
      case MachineType.harvester:
        return Colors.deepOrangeAccent;
      case MachineType.other:
        return Colors.white54;
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = machine.workingWidthM;
    final subtitle = w != null
        ? '${machine.type.label}  •  ${w.toStringAsFixed(1)} m'
        : '${machine.type.label}  •  N/A (napęd)';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      color: isSelected
          ? Colors.green.withValues(alpha: 0.12)
          : Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: isSelected
                ? Colors.green.withValues(alpha: 0.25)
                : const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(8),
            border: isSelected
                ? Border.all(color: Colors.greenAccent, width: 1.5)
                : Border.all(color: Colors.white12),
          ),
          child: Icon(_iconFor(machine.type),
              color: _colorFor(machine.type), size: 24),
        ),
        title: Text(
          machine.name,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
        subtitle: Text(subtitle,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        trailing: isSelected
            ? FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.greenAccent,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  minimumSize: const Size(80, 36),
                ),
                onPressed: onSelect,
                child: const Text('Wybrano',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              )
            : OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white30),
                  foregroundColor: Colors.white70,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  minimumSize: const Size(80, 36),
                ),
                onPressed: onSelect,
                child: const Text('Wybierz'),
              ),
        onTap: onSelect,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CustomPainter — schemat pola z zaplanowaną trasą swathów
// ─────────────────────────────────────────────────────────────────────────────

class _FieldSchemaPainter extends CustomPainter {
  const _FieldSchemaPainter({
    required this.field,
    required this.workingWidthM,
  });

  final FieldModel field;
  final double workingWidthM;

  @override
  void paint(Canvas canvas, Size size) {
    if (field.boundaryLats.isEmpty) return;

    // ── 1. Znormalizuj współrzędne do przestrzeni ekranu ─────────────────
    final lats = field.boundaryLats;
    final lons = field.boundaryLons;

    double minLat = lats[0], maxLat = lats[0];
    double minLon = lons[0], maxLon = lons[0];
    for (int i = 1; i < lats.length; i++) {
      if (lats[i] < minLat) minLat = lats[i];
      if (lats[i] > maxLat) maxLat = lats[i];
      if (lons[i] < minLon) minLon = lons[i];
      if (lons[i] > maxLon) maxLon = lons[i];
    }

    final dLat = maxLat - minLat;
    final dLon = maxLon - minLon;
    if (dLat < 1e-9 || dLon < 1e-9) return;

    const padding = 16.0;
    final w = size.width - padding * 2;
    final h = size.height - padding * 2;

    // Zachowaj proporcje względem rzeczywistości (Mercator approx)
    final cosLat = math.cos((minLat + maxLat) / 2.0 * math.pi / 180.0);
    final scaleX = w / (dLon * cosLat);
    final scaleY = h / dLat;
    final scale = math.min(scaleX, scaleY);

    final dispW = dLon * cosLat * scale;
    final dispH = dLat * scale;
    final offX = padding + (w - dispW) / 2;
    final offY = padding + (h - dispH) / 2;

    Offset toScreen(double lat, double lon) => Offset(
          offX + (lon - minLon) * cosLat * scale,
          offY + (maxLat - lat) * scale, // flip Y
        );

    // ── 2. Narysuj siatkę ────────────────────────────────────────────────
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 0.5;
    for (double x = offX; x < offX + dispW; x += 20) {
      canvas.drawLine(Offset(x, offY), Offset(x, offY + dispH), gridPaint);
    }
    for (double y = offY; y < offY + dispH; y += 20) {
      canvas.drawLine(Offset(offX, y), Offset(offX + dispW, y), gridPaint);
    }

    // ── 3. Narysuj swathy ────────────────────────────────────────────────
    // Oblicz kierunek AB lub domyślnie poziomy
    double abAngle = 0.0; // kąt względem osi X ekranu (0 = poziomy swath)
    if (field.lineA != null && field.lineB != null) {
      final a = toScreen(field.lineALat!, field.lineALon!);
      final b = toScreen(field.lineBLat!, field.lineBLon!);
      final dx = b.dx - a.dx;
      final dy = b.dy - a.dy;
      abAngle = math.atan2(dy, dx);
    }

    // Szerokość swatha w pikselach
    final latPerM = 1.0 / 111320.0;
    final swathPx = workingWidthM * latPerM * scale;
    final swathStep = swathPx.clamp(3.0, 40.0);

    final swathPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.35)
      ..strokeWidth = math.max(1.0, swathStep - 1.5)
      ..style = PaintingStyle.stroke;

    // Projekcja prostopadła do AB — rysuj linie równoległe
    final perpAngle = abAngle + math.pi / 2;
    final cosP = math.cos(perpAngle);
    final sinP = math.sin(perpAngle);
    final cosA = math.cos(abAngle);
    final sinA = math.sin(abAngle);

    final cx = offX + dispW / 2;
    final cy = offY + dispH / 2;
    final maxDist = math.sqrt(dispW * dispW + dispH * dispH);

    for (double d = -maxDist; d < maxDist; d += swathStep) {
      final lx = cx + cosP * d;
      final ly = cy + sinP * d;
      canvas.drawLine(
        Offset(lx - cosA * maxDist, ly - sinA * maxDist),
        Offset(lx + cosA * maxDist, ly + sinA * maxDist),
        swathPaint,
      );
    }

    // ── 4. Narysuj granicę pola ──────────────────────────────────────────
    final fillPaint = Paint()
      ..color = Colors.green.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final path = Path();
    final first = toScreen(lats[0], lons[0]);
    path.moveTo(first.dx, first.dy);
    for (int i = 1; i < lats.length; i++) {
      final p = toScreen(lats[i], lons[i]);
      path.lineTo(p.dx, p.dy);
    }
    path.close();

    canvas.drawPath(path, fillPaint);
    canvas.drawPath(path, borderPaint);

    // ── 5. Linia AB ──────────────────────────────────────────────────────
    if (field.lineA != null && field.lineB != null) {
      final a = toScreen(field.lineALat!, field.lineALon!);
      final b = toScreen(field.lineBLat!, field.lineBLon!);
      final abPaint = Paint()
        ..color = Colors.orangeAccent
        ..strokeWidth = 2.5;
      canvas.drawLine(a, b, abPaint);
      canvas.drawCircle(a, 4, Paint()..color = Colors.orangeAccent);
      // Etykieta A / B
      final tp = TextPainter(textDirection: TextDirection.ltr);
      tp.text = const TextSpan(
          text: 'A',
          style: TextStyle(color: Colors.orangeAccent, fontSize: 10));
      tp.layout();
      tp.paint(canvas, a.translate(5, -12));
      tp.text = const TextSpan(
          text: 'B',
          style: TextStyle(color: Colors.orangeAccent, fontSize: 10));
      tp.layout();
      tp.paint(canvas, b.translate(5, -12));
    }
  }

  @override
  bool shouldRepaint(_FieldSchemaPainter old) =>
      old.field != field || old.workingWidthM != workingWidthM;
}
