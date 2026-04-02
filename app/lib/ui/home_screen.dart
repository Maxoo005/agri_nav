import 'package:flutter/material.dart';

import 'field_builder_screen.dart';
import 'field_manager_screen.dart';
import 'machine_manager_screen.dart';
import 'map_view.dart';

// ═══════════════════════════════════════════════════════════════════════════════
// HomeScreen — panel główny aplikacji AgriNav
// ═══════════════════════════════════════════════════════════════════════════════

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D150D),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Nagłówek ───────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 8),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B5E20),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Icon(
                      Icons.agriculture,
                      color: Colors.greenAccent,
                      size: 30,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AgriNav',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.4,
                        ),
                      ),
                      Text(
                        'Panel główny',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Divider(color: Colors.white10, height: 1),
            ),

            // ── Kafelki ────────────────────────────────────────────────────────
            Expanded(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Column(
                  children: [
                    // Wiersz 1
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _MenuTile(
                              icon: Icons.map_outlined,
                              label: 'Mapa',
                              subtitle: 'Nawigacja GPS',
                              accentColor: Colors.greenAccent,
                              bgColor: const Color(0xFF0D2B0D),
                              onTap: () => Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const MapView()),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: _MenuTile(
                              icon: Icons.add_location_alt_outlined,
                              label: 'Dodaj pole',
                              subtitle: 'Kreator geodezyjny',
                              accentColor: Colors.lightBlueAccent,
                              bgColor: const Color(0xFF0D1E2E),
                              onTap: () => FieldBuilderScreen.open(context),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // Wiersz 2
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: _MenuTile(
                              icon: Icons.landscape_outlined,
                              label: 'Widok pól',
                              subtitle: 'Lista i zarządzanie',
                              accentColor: Colors.orangeAccent,
                              bgColor: const Color(0xFF2B1A05),
                              onTap: () => FieldManagerScreen.open(context),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: _MenuTile(
                              icon: Icons.agriculture_outlined,
                              label: 'Maszyny',
                              subtitle: 'Dodaj / edytuj',
                              accentColor: Colors.purpleAccent,
                              bgColor: const Color(0xFF1A0D2E),
                              onTap: () => MachineManagerScreen.open(context),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _MenuTile
// ─────────────────────────────────────────────────────────────────────────────

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.accentColor,
    required this.bgColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final Color accentColor;
  final Color bgColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        splashColor: accentColor.withValues(alpha: 0.15),
        highlightColor: accentColor.withValues(alpha: 0.08),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: accentColor, size: 40),
              const Spacer(),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(color: Colors.white38, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
