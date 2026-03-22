# AgriNav — Rolnicza Nawigacja

Projekt łączący rdzeń C++ z interfejsem Flutter.

## Architektura

```
agri_nav/
├── core/          # Rdzeń C++ — logika nawigacyjna
│   ├── include/
│   └── src/
├── bridge/        # Warstwa FFI (C API eksponowane do Fluttera)
└── app/           # Aplikacja Flutter
    └── lib/
        ├── ffi/   # Wiązania Dart ↔ C++
        └── ui/    # Widoki
```

## Warstwy

| Warstwa   | Technologia | Odpowiedzialność                                 |
|-----------|-------------|--------------------------------------------------|
| `core`    | C++17       | GNSS, przeliczenia geometryczne, śledzenie ścieżki |
| `bridge`  | C           | Czyste C API eksponowane przez `dart:ffi`        |
| `app`     | Flutter/Dart | UI, mapy, ustawienia                             |

## Zależności C++

- Eigen 3 — algebra liniowa / transformacje
- (opcjonalnie) PROJ — odwzorowania kartograficzne

## Zależności Flutter

- `ffi` — wiązania natywne
- `flutter_map` — mapa podkładowa

## Budowanie rdzenia

```bash
cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Release
cmake --build build/core
```
