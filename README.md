# AgriNav

**Nawigacja precyzyjna dla maszyn rolniczych — Flutter + C++, z obsługą RTK.**

![Platform](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)
![Flutter](https://img.shields.io/badge/Flutter-3-02569B?logo=flutter&logoColor=white)
![C++](https://img.shields.io/badge/C%2B%2B-17-00599C?logo=cplusplus&logoColor=white)
![Status](https://img.shields.io/badge/status-testy%20terenowe-yellow)
![License](https://img.shields.io/badge/license-All%20Rights%20Reserved-red)

AgriNav to aplikacja nawigacyjna do jazdy równoległymi pasami po polu — z korekcją RTK sprowadzającą błąd pozycji z kilku metrów do kilku centymetrów. Rdzeń obliczeniowy (geometria, prowadzenie, planowanie ścieżek) jest napisany w C++17 i połączony z interfejsem we Flutterze przez `dart:ffi`. Projekt jest rozwijany solo, iteracyjnie, z testowaniem w realnym polu — ten dokument opisuje go możliwie rzetelnie, łącznie z tym, co jeszcze nie działa idealnie.

## Spis treści

1. [Wprowadzenie](#1-wprowadzenie)
2. [Instrukcja obsługi](#2-instrukcja-obsługi)
3. [Charakterystyka funkcjonalna](#3-charakterystyka-funkcjonalna)
4. [Architektura techniczna](#4-architektura-techniczna)
5. [Stos technologiczny](#5-stos-technologiczny)
6. [Historia rozwoju projektu](#6-historia-rozwoju-projektu)
7. [Stan projektu i ograniczenia](#7-stan-projektu-i-ograniczenia)
8. [Moje autorskie podejście i podsumowanie](#8-moje-autorskie-podejście-i-podsumowanie)

---

## 1. Wprowadzenie

Telefon w kabinie ciągnika potrafi pokazać Twoją pozycję na mapie z dokładnością do kilku metrów. Brzmi nieźle, dopóki nie spróbujesz pojechać równoległym pasem obok poprzedniego przejazdu opryskiwaczem — przy błędzie rzędu 3-5 metrów albo zostawisz nieopryskany pas, albo podwoisz dawkę na zakładce. Profesjonalne systemy prowadzenia równoległego (John Deere, Trimble, Topcon) rozwiązują ten problem korekcją RTK, sprowadzając błąd do 1-3 centymetrów — ale kosztują tyle, że dla mniejszego gospodarstwa inwestycja bywa nieopłacalna.

AgriNav powstał jako odpowiedź na ten konkretny problem: własny system prowadzenia równoległego, który korzysta z tego samego rodzaju korekcji RTK (moduł u-blox ZED-F9P + poprawki sieciowe ASG-EUPOS), ale jako aplikacja na telefon/tablet z Androidem zamiast dedykowanego terminala za kilkanaście tysięcy złotych.

Aplikacja pozwala:
- wyznaczyć granicę pola na kilka sposobów (import z rejestru gruntów, z pliku, albo obejściem z odbiornikiem RTK),
- automatycznie wygenerować optymalny układ ścieżek roboczych dla zadanej szerokości maszyny,
- prowadzić operatora wzdłuż tych ścieżek z dokładnością rzędu centymetrów (przy fixie RTK Fixed),
- śledzić, ile pola zostało już pokryte, i ile materiału (nawóz, środek ochrony) zużyto,
- prowadzić historię wykonanych prac i eksportować ją jako raport PDF.

Adresatem jest rolnik lub operator maszyny, niekoniecznie techniczny — dlatego rozdział 2 opisuje aplikację z perspektywy użytkownika, a szczegóły inżynierskie zostawiono do rozdziałów 3 i 4.

---

## 2. Instrukcja obsługi

### 2.1 Konfiguracja sprzętu

W ekranie **Ustawienia → GPS** wybiera się źródło pozycji przełącznikiem *„Zewnętrzny odbiornik RTK (Bluetooth)”*:

- **Wyłączony** — aplikacja korzysta z wbudowanego GPS telefonu (dokładność zwykle 3-8 m, w dobrych warunkach do ok. 5 m po wygładzeniu).
- **Włączony** — aplikacja łączy się z zewnętrznym odbiornikiem RTK po Bluetooth Classic (profil SPP), typowo modułem opartym o u-blox ZED-F9P.

Po włączeniu trybu RTK dochodzą trzy dodatkowe elementy konfiguracji:

1. **Wybór urządzenia** — lista urządzeń już sparowanych w systemowych ustawieniach Bluetooth Androida (aplikacja nie skanuje sama, tylko odczytuje listę parowań). Wskaźnik stanu łącza pokazuje: rozłączony / łączenie / połączony / ponawiam próbę.
2. **Status satelitów** — liczba widocznych satelitów i HDOP, aktualizowane na żywo z odbiornika, nawet zanim pojawi się pełny fix (przydatne do diagnozy: „widzę satelity, ale nie mam jeszcze fixa” to inny problem niż brak jakiejkolwiek transmisji).
3. **Konfiguracja NTRIP** — dane dostępowe do serwisu poprawek sieciowych (w Polsce typowo ASG-EUPOS): adres serwera, port (domyślnie 2101), nazwa firmy, użytkownik, hasło i punkt montażowy (*mountpoint*). Login budowany jest w formacie `Firma/Użytkownik` — to wymóg samego ASG-EUPOS, nie wymysł aplikacji. Listę dostępnych mountpointów można pobrać jednym przyciskiem bezpośrednio z serwera. Hasło NTRIP nigdy nie trafia na dysk w postaci jawnej — jest przechowywane w Android Keystore.

Połączenie z NTRIP startuje automatycznie razem z połączeniem Bluetooth — nie jest osobnym krokiem. Poprawki RTCM3 płynące z NTRIP są przekazywane do odbiornika tym samym kanałem szeregowym, którym odbierane są dane NMEA (transmisja dwukierunkowa po jednym porcie).

Na górze ekranu zawsze widoczny jest ogólny wskaźnik jakości fixa (kolorowa plakietka): szary = brak/szukanie, czerwony = GPS, pomarańczowy = DGPS, żółty = RTK Float, zielony = RTK Fixed.

### 2.2 Tworzenie pola

Kafelek **„Utwórz pole”** na ekranie głównym otwiera wybór jednej z trzech metod:

**Import działek (ULDK)** — wyszukiwanie działek po numerze ewidencyjnym (numer TERYT, np. `141201_1.0001.AR_1.1`), z możliwością dodania kilku numerów naraz i opcjonalnym filtrem po kodzie grupy upraw. Dostępny jest wybór dokładności granicy (Pełna / Wysoka 5 cm / Standardowa 30 cm / Uproszczona 1 m) — to parametr upraszczania geometrii, nie jakości samych danych źródłowych. Znalezione działki pokazują się na liście z checkboxami i kolorowymi znacznikami grupy uprawy; po zatwierdzeniu silnik C++ scala je w jeden obrys pola (usuwając mikroszczeliny między sąsiadującymi działkami), a podsumowanie ostrzega, jeśli wynik ma dziury albo składa się z kilku niestykających się części. Działa też offline z lokalnego cache, jeśli dana działka była już wcześniej pobrana.

**Import z pliku** — wczytanie gotowej granicy z pliku KML lub GeoJSON (np. wyrysowanej wcześniej w Google Earth albo QGIS). Format pliku jest rozpoznawany automatycznie po zawartości. Jeśli plik zawiera kilka wielokątów, można wybrać, które zaimportować — każdy trafia jako osobne pole, z podglądem na mapie przed zapisem. Granica z pliku jest traktowana jako już dokładna — nie przechodzi przez mechanizm korekty opisany niżej.

**Obejście granicy (RTK)** — najdokładniejsza metoda: operator idzie pieszo (albo jedzie maszyną) wzdłuż granicy pola z aktywnym modułem RTK, a aplikacja nagrywa trasę. Przycisk pauzy pozwala ominąć przeszkodę (np. słup, drzewo) bez przerywania nagrywania. Po zakończeniu trasa jest upraszczana (Ramer–Douglas–Peucker) i sprawdzana: czy zebrano wystarczająco punktów, czy pętla się domyka (ostrzeżenie przy luce większej niż 25 m) i czy trasa się nie przecina samej siebie.

Poza tymi trzema metodami dostępne jest też swobodne rysowanie granicy bezpośrednio na mapie — przeciągnięcie palcem po ekranie w trybie „Rysuj”, z automatyczną redukcją punktów co ok. 3 metry i dialogiem zapisu, w którym ustawia się od razu szerokość roboczą maszyny.

### 2.3 Korekta granic

Dane katastralne (ULDK/LPIS) bywają przesunięte względem rzeczywistego obrazu satelitarnego o kilka metrów — to typowa niedokładność źródeł geodezyjnych, nie błąd aplikacji. AgriNav daje dwa niezależne narzędzia korekty:

**Przesunięcie (Korekta)** — prosty krzyżak strzałek przesuwający całą granicę o stały wektor, krok 25 cm. Nie zmienia kształtu, tylko pozycję.

**Punkty kontrolne** — precyzyjniejsza metoda: stukasz najpierw blisko krawędzi granicy (aplikacja sama znajduje najbliższy punkt na dowolnym odcinku obwodu, nie tylko na wierzchołku), potem w miejsce na ortofotomapie, gdzie ta krawędź naprawdę powinna się znaleźć. Każde takie stuknięcie dodaje jedną parę punktów. Metoda dopasowania przełącza się **automatycznie**, bez wyboru użytkownika:

| Liczba par | Metoda | Charakter |
|---|---|---|
| 2–3 | Transformacja podobieństwa (obrót + skala + przesunięcie) | Sztywna — cały kształt przesuwa się i obraca jako jedna bryła |
| 4+ | Korekta elastyczna (IDW) | Lokalna — każda część granicy „ciągnięta” jest przez najbliższe punkty kontrolne z siłą malejącą z kwadratem odległości |

Podgląd korekty jest widoczny na żywo przed zatwierdzeniem, pojedyncze pary można usuwać, a całą korektę cofnąć.

### 2.4 Tworzenie zadania i generowanie ścieżek

Nowe zadanie robocze powstaje w pięciokrokowym kreatorze: **pole → maszyna → rodzaj zadania** (oprysk, siew, nawożenie, uprawka, zbiór, inne — z polem dawki dla zadań zużywających materiał) **→ dostosowanie ścieżek → zapis**.

Kierunek ścieżek roboczych można ustalić na trzy sposoby:

1. **Automatyczna optymalizacja** (domyślna) — od razu po wybraniu pola aplikacja sama przeszukuje możliwe kierunki i proponuje ten, który minimalizuje łączny dystans jazdy i liczbę zawrotów na uwrociu. Wynik pojawia się w kilka chwil z informacją w stylu „Znaleziono: 14 przejazdów”. Przycisk **„Zoptymalizuj kierunek”** pozwala przeliczyć to ponownie w dowolnym momencie (dopóki nie ustawiono ręcznej linii AB).
2. **Ręczny kąt** — suwak kierunku ze szczegółowym polem liczbowym (precyzja do 0,01°).
3. **Linia AB** — klasyczne dwa punkty referencyjne, na dwa sposoby: **dwa stuknięcia** na mapie (szybkie, wystarczające przy wąskich maszynach), albo **przejazd z RTK** — jedziesz wzdłuż krawędzi, a aplikacja dopasowuje najlepszą prostą metodą najmniejszych kwadratów do zarejestrowanych punktów i pokazuje, jak bardzo trasa faktycznie była prosta (odchylenie RMS w centymetrach). Ustawienie linii AB blokuje suwak kąta i optymalizację automatyczną — trzeba jawnie wyczyścić AB, żeby do nich wrócić.

Pozostałe parametry: szerokość robocza (1–36 m), zakładka między przejazdami (0–1 m) i liczba objazdów uwrociowych (0–5). Wygenerowane ścieżki można też przesunąć bocznie w krokach 5 cm bez ponownego przeliczania całości — przydatne przy drobnej korekcie „na oko” już w polu.

### 2.5 Praca w Trybie Pracy

Tryb Pracy to pełnoekranowy widok prowadzenia, celowo pozbawiony kafelków mapy satelitarnej — cała geometria (granica, ścieżki, ślad pokrycia) jest rysowana bezpośrednio na kanwie, obracanej zgodnie z kierunkiem jazdy. Kluczowe elementy:

- **Lightbar** — pasek na dole ekranu z dwiema pulsującymi strzałkami wskazującymi, w którą stronę skorygować tor jazdy; kolor i tempo pulsowania rosną wraz z odchyleniem (zielony/neutralny poniżej 10 cm, żółty 10–30 cm, czerwony powyżej 30 cm).
- **Przełącznik trybu prowadzenia** — ścieżki robocze / uwrocie, widoczny tylko gdy pole ma wygenerowane pierścienie uwrociowe. Na uwrociu prowadzenie odbywa się względem najbliższego pierścienia, nie względem prostej ścieżki.
- **Pauza vs wyłącznik maszyny** — to dwa różne mechanizmy. *Pauza* zatrzymuje licznik czasu pracy (np. na czas tankowania) i zostawia znacznik na trasie. *Wyłącznik maszyny* nie zatrzymuje ani czasu, ani nawigacji — służy do jazdy z fizycznie wyłączonym narzędziem (np. dojazd drogą albo przejazd uwrociem bez robienia czegokolwiek), i tylko wstrzymuje malowanie pokrycia oraz zużycie materiału.
- **Wskaźnik zbiornika** — pasek wypełnienia z kolorami ostrzegawczymi, szacowany zasięg w hektarach do wyczerpania, możliwość zmiany dawki w trakcie pracy i dialog tankowania (pełny zbiornik jednym dotknięciem albo częściowe uzupełnienie).
- **Panel statystyk** — prędkość, wydajność (ha/h liczone z realnie zrobionej powierzchni i czasu, nie z prędkości), zrobiona/całkowita powierzchnia, czas pracy, jakość fixa GPS, aktywny numer pasa i ostrzeżenie o nakładce.

Sesja pracy działa w tle — jeśli wyjdziesz z Trybu Pracy (np. cofnij albo zablokuj telefon), czas dalej się liczy i po powrocie na ekran główny pojawia się baner z możliwością powrotu jednym dotknięciem. Zakończenie pracy pokazuje podsumowanie (powierzchnia, czas, wydajność, zużycie materiału) i zapisuje wpis do historii.

### 2.6 Historia i eksport raportów

Ekran **Historia** grupuje zakończone prace według pola. Każdy wpis może pochodzić z rejestracji GPS (automatycznie po „Zakończ pracę”) albo być dopisany ręcznie — przydatne, gdy praca była wykonana inną maszyną bez telefonu w kabinie; taki wpis jest jawnie oznaczony jako deklaracja, bez czasu pracy czy wydajności, bo nie ma z czego ich policzyć.

Eksport do PDF pozwala wybrać zakres dat i pola, pokazuje na żywo liczbę pasujących wpisów, a wygenerowany raport zawiera tabelę per pole (data, zabieg, maszyna, powierzchnia, czas pracy, materiał, źródło wpisu, notatka) i podsumowanie łączne. Czcionka z polskimi znakami diakrytycznymi jest dołączona do aplikacji jako plik, więc eksport działa w pełni offline, bez pobierania czegokolwiek z sieci.

---

## 3. Charakterystyka funkcjonalna

### Czym różni się od zwykłej nawigacji GPS

Aplikacje nawigacyjne (Google Maps i podobne) prowadzą Cię z punktu A do punktu B po drogach. AgriNav rozwiązuje inny problem: jak pokryć całą powierzchnię pola równoległymi, niezachodzącymi na siebie pasami, z dokładnością wystarczającą, żeby nie zostawić nieopryskanego skrawka ani nie podwoić dawki na zakładce. To wymaga innego rodzaju prowadzenia — nie „skręć w prawo za 200 m”, tylko ciągła informacja o bocznym odchyleniu od zaplanowanej linii, aktualizowana kilka razy na sekundę.

### Dokładność w zależności od źródła pozycji

| Źródło / fix | Przyjęta dokładność | Zastosowanie |
|---|---|---|
| RTK Fixed | ~2 cm | Precyzyjne prowadzenie równoległe, korekta granic |
| RTK Float | ~40 cm | Prowadzenie zgrubne — poprawki jeszcze się nie zbiegły |
| DGPS | ~2 m | Orientacyjna pozycja, niewystarczająca do pracy bez nakładek |
| GPS (autonomiczny) | ~8 m | Podgląd pozycji na mapie, nie do precyzyjnej jazdy |

Wartości dla GPS telefonu dodatkowo przechodzą przez filtr wygładzający (średnia wykładnicza) i bramkę dokładności — pozycje gorsze niż 10 m są oznaczane jako niewiarygodne i pomijane przez logikę prowadzenia i zliczania pokrycia, choć nadal mogą być pokazane na mapie jako przybliżony punkt. Pozycje z odbiornika RTK **nie** są wygładzane — przy fixie RTK Fixed wygładzanie tylko dodałoby opóźnienie bez poprawy dokładności.

### Rola silnika C++

Wszystkie obliczenia geometryczne — projekcja WGS-84 na lokalny układ metryczny, generowanie ścieżek, wyznaczanie uwroci, wyszukiwanie najbliższej ścieżki/pierścienia, siatka pokrycia, scalanie działek — wykonuje natywny kod C++ wywoływany przez `dart:ffi`. Dzięki temu strona Flutter/Dart zajmuje się wyłącznie stanem UI i renderowaniem, a cała matematyka jest deterministyczna, szybka i nie obciąża wątku interfejsu ani odśmiecacza pamięci Dart. Silniki prowadzenia (`SwathGuidance`, `HeadlandGuidance`) są jawnie thread-safe (odpowiednio `std::mutex` i `std::shared_mutex`), bo geometria jest przeliczana raz przy planowaniu, a odpytywana wielokrotnie na sekundę z wątku pozycji GPS.

### Automatyczny dobór kierunku ścieżek

`SwathPlanner::optimizeAngle` przeszukuje kierunki od 0° do 180° w trzech etapach: tani zgrubny skan co 1° (plus jeden kandydat z algorytmu rotating calipers jako dodatkowa podpowiedź), a następnie dwa etapy dogęszczania (±1° z krokiem 0,1°, potem ±0,1° z krokiem 0,01°) — łącznie ok. 42 kandydatów w fazie precyzyjnej. Każdy kandydat w fazie dogęszczania jest oceniany nie przez tanie przybliżenie (długość × szerokość), lecz przez **rzeczywistą niepokrytą powierzchnię** — pole pomniejszone o sumę (operacją boolowską Clipper2) wszystkich wygenerowanych pasów i pierścieni uwrociowych. Do wyniku dochodzi kara za każdy dodatkowy zawrot (ekwiwalent kilku szerokości roboczych) i kara za lukę w pokryciu. Geometria uwroci jest liczona raz i reużywana dla wszystkich testowanych kątów, żeby nie mnożyć kosztownych operacji Clipper2.

### Uwrocia (headland)

Przy generowaniu ścieżek z zadaną liczbą objazdów uwrociowych, każdy kolejny pierścień powstaje przez odsunięcie granicy pola do wewnątrz o `(k − 0.5) × szerokość_robocza` — tak, żeby zewnętrzna krawędź narzędzia w danym przejeździe dotykała granicy wyznaczonej przez poprzedni. Odsunięcie wykonuje Clipper2 (`InflatePaths`) ze złączeniem zaokrąglonym (*round join*), co eliminuje ostre, błędne wystrzały geometrii w ciasnych narożnikach pola.

### Section Control i pokrycie vs zużycie materiału

Pokrycie pola liczone jest na siatce kwadratowych komórek (domyślnie 1 m²) — każda komórka liczy się do powierzchni tylko raz, niezależnie od tego, ile razy przejedziesz przez to samo miejsce, więc nakładki nie zawyżają zaraportowanej powierzchni. Zużycie materiału liczone jest inaczej i celowo: dawka na hektar leci przez całą szerokość narzędzia przy **każdym** przejeździe, więc nakładka realnie zużywa więcej materiału — to musi się liczyć ponownie, nawet jeśli ten sam kawałek pola był już pokryty.

### Scalanie działek katastralnych i LPIS

Import wielu działek (czy to z ULDK, czy oznaczonych jako LPIS) przechodzi przez wspólny mechanizm: niewielkie odsunięcie każdej działki na zewnątrz (żeby zamknąć mikroszczeliny wynikające z niedokładności geodezyjnej), operację boolowską sumy (Clipper2, `FillRule::NonZero`), a dla LPIS dodatkowo uproszczenie geometrii (Ramer–Douglas–Peucker). Wynik jest klasyfikowany na pierścienie zewnętrzne i otwory (np. zagajnik w środku pola), z wykrywaniem sytuacji, gdy działki się nie stykają i wynikiem jest pole wieloczęściowe.

---

## 4. Architektura techniczna

```
                    ┌─────────────────────────────────────────────┐
                    │              Flutter UI (Dart)               │
                    │  map_view · work_mode_view · new_task_screen  │
                    │  gps_settings_screen · history_screen · ...   │
                    └───────────────────────┬───────────────────────┘
                                             │
                    ┌────────────────────────┴───────────────────────┐
                    │           Serwisy Dart (stan, integracje)        │
                    │  GpsLocationService · NtripClientService         │
                    │  BluetoothGnssService · FieldService              │
                    │  WorkSessionService · MaterialMonitorService      │
                    │  CoverageService · GeoportalService · LpisService │
                    └───────────────────────┬───────────────────────┘
                                             │ dart:ffi
                    ┌────────────────────────┴───────────────────────┐
                    │        bridge/agri_nav_ffi  (czyste C ABI)       │
                    └───────────────────────┬───────────────────────┘
                                             │
                    ┌────────────────────────┴───────────────────────┐
                    │           agri_nav_core (C++17, static lib)      │
                    │                                                   │
                    │  NavEngine          — cross-track linii AB        │
                    │  GnssProcessor/Sim  — abstrakcja pozycji, symulator│
                    │  SwathPlanner       — generowanie ścieżek + uwrocia│
                    │                       + optimizeAngle              │
                    │  SwathGuidance      — snap-to-nearest-swath        │
                    │  HeadlandGuidance   — snap-to-nearest-ring         │
                    │  SectionControl     — siatka pokrycia              │
                    │  ParcelMerger       — scalanie działek katastr.    │
                    │  GeometryProcessor  — scalanie + upraszczanie LPIS │
                    └───────────────────────┬───────────────────────┘
                                             │
                    ┌────────────────────────┴───────────────────────┐
                    │        Clipper2 1.4.0 (vendored, BSL-1.0)        │
                    │     operacje boolowskie i offset na wielokątach   │
                    └─────────────────────────────────────────────────┘

  Systemy zewnętrzne:  odbiornik RTK (Bluetooth SPP) ←→ NTRIP caster (ASG-EUPOS)
                        ULDK / GUGiK — REST (granice działek) + WMS (ortofoto, LPIS)
```

### Przepływ danych: od GNSS do ekranu

Pozycja może pochodzić z dwóch niezależnych źródeł — wbudowanego GPS telefonu (`geolocator`) albo zewnętrznego odbiornika RTK po Bluetooth. `GpsLocationService` ujednolica oba w jeden strumień (`SimPosition`), tak że reszta aplikacji — łącznie z mostami FFI — nie musi wiedzieć, skąd faktycznie przyszła pozycja. Przy każdym nowym punkcie: pozycja trafia przez FFI do `NavEngine` (cross-track do linii AB), `SwathGuidance`/`HeadlandGuidance` (odległość do najbliższej ścieżki/pierścienia) i `SectionControl` (aktualizacja pokrycia) — wyniki tych zapytań zasilają lightbar, wskaźniki i malowanie kanwy w Trybie Pracy.

Osobny, celowo luźno powiązany mechanizm spina `NtripClientService` (strumień poprawek RTCM3 z sieci) z `BluetoothGnssService` (fizyczny odbiornik): żaden z tych dwóch serwisów nic o drugim nie wie — to `GpsLocationService` przekazuje bajty RTCM z jednego do drugiego. Dzięki temu każdy z serwisów da się przetestować i zrozumieć osobno.

Cięższe operacje wywoływane przez FFI (scalanie działek, automatyczna optymalizacja kierunku) są uruchamiane w osobnym izolacie Dart, żeby wielosekundowe obliczenia na dużych wielokątach nie zamroziły interfejsu.

### Trwałość danych — dwa magazyny, celowo

Pola, ustawienia GPS/NTRIP i cache LPIS są trzymane w **Hive** (lekki, wbudowany magazyn klucz-wartość) — pasuje do prostych obiektów odczytywanych/zapisywanych w całości. Zadania robocze i historia prac są w **SQLite** (`sqflite`, z `sqflite_common_ffi` jako zapleczem na desktopie) — bo tam potrzebne są filtrowanie po dacie, agregacje per pole i relacyjne zapytania, do których Hive nie jest przeznaczone.

---

## 5. Stos technologiczny

| Technologia | Rola w projekcie |
|---|---|
| **Flutter / Dart** | Interfejs użytkownika, cross-platformowość, szybki cykl developmentu (hot reload) — dobry wybór dla projektu rozwijanego solo i testowanego iteracyjnie w polu. |
| **C++17 / CMake** | Rdzeń obliczeniowy — geometria, prowadzenie, planowanie ścieżek. Wydajność i determinizm ważniejsze niż wygoda pisania, a `dart:ffi` daje do C++ dostęp praktycznie bez narzutu. |
| **Clipper2 1.4.0** (vendored) | Solidna, sprawdzona biblioteka do operacji boolowskich i offsetu na wielokątach (union działek, odsuwanie granic uwrociowych) — pisanie własnej geometrii boolowskiej od zera to prosta droga do subtelnych błędów numerycznych. |
| **u-blox ZED-F9P** | Referencyjny moduł RTK, na którym aplikacja była testowana — odbiera poprawki RTCM3 i wysyła NMEA (GGA/RMC) po UART/Bluetooth. |
| **ASG-EUPOS / NTRIP v2** | Krajowa sieć stacji referencyjnych RTK w Polsce — źródło poprawek sieciowych (VRS) bez potrzeby stawiania własnej stacji bazowej. |
| **ULDK / GUGiK** | Publiczne, darmowe API rejestru gruntów — źródło granic działek katastralnych i (pod etykietą LPIS) rolnych, plus WMS do ortofotomapy. |
| **flutter_map + latlong2** | Renderowanie mapy i warstw WMS/wektorowych. |
| **Hive** | Magazyn pól, ustawień i cache — patrz rozdział 4. |
| **sqflite / sqflite_common_ffi** | Magazyn zadań i historii pracy — patrz rozdział 4. |
| **geolocator** | Dostęp do GPS telefonu, w tym foreground service utrzymujący nawigację aktywną przy zgaszonym ekranie. |
| **bluetooth_classic** | Połączenie SPP z zewnętrznym odbiornikiem RTK. |
| **flutter_secure_storage** | Hasło NTRIP w Android Keystore, nigdy na dysku jawnym tekstem. |
| **pdf + printing** | Generowanie i udostępnianie raportów PDF w pełni offline, z osadzoną czcionką obsługującą polskie znaki. |
| **file_picker + xml** | Import granic z plików KML/GeoJSON. |

---

## 6. Historia rozwoju projektu

Projekt liczy 44 commity rozłożone na niecałe pięć miesięcy (22 marca – 21 sierpnia 2026), z wyraźnymi seriami intensywnej pracy przeplatanymi dłuższymi przerwami — rytm typowy dla rozwoju testowanego w realnym polu, nie w laboratorium.

**Marzec 2026 — pierwszy szkielet.** Projekt zaczyna się od symulatora GPS (tor kołowy, zdania `$GPGGA`) i prostego prowadzenia po linii AB. 23 marca dochodzi planowanie ścieżek i mapa satelitarna. 25 marca to najbardziej intensywny dzień w historii projektu — w jednej sesji powstają `SwathGuidance`, `SectionControl`, `WorkModeView` i `CoverageService`, czyli komplet mechanizmu prowadzenia po wygenerowanych ścieżkach z wizualnym HUD-em. Kilka dni później dochodzi integracja katastralna — pierwsze połączenie z ULDK i `ParcelMerger` oparty o Clipper2.

**Koniec marca – kwiecień 2026 — uwrocia i pierwszy realny GPS.** Powstaje `HeadlandGuidance` wraz z trybem prowadzenia po uwrociu, offsetowanie granic przez Clipper2. Commit `2cd8c3e` — „refactor: deep architecture + critical bug hardening” — sygnalizuje moment porządkowania architektury przed dalszym rozwojem. Zaraz po nim aplikacja przechodzi z symulatora na prawdziwy GPS telefonu (`geolocator`).

**Czteromiesięczna przerwa, potem powrót i sprzątanie.** Między początkiem kwietnia a końcem lipca nie ma żadnych commitów. Gdy praca wraca, pierwsze, co się dzieje, to nie nowa funkcja, tylko seria porządkowych commitów usuwających martwy kod: nieużywany getter, martwą metodę, cały nieużywany widget (`TerytSearchSheet`, ~200 linii) — ślad audytu kodu przed kontynuowaniem, a nie przypadkowe sprzątanie.

**Sierpień 2026 — RTK zaczyna działać.** To najbardziej wyrazisty fragment historii commitów, widoczny wprost w ich treści: `„AduSimple added DGPS uart2 baudrate115200”` → `„RTK is working, NTRIP RTK FIX working, full nav is working jupi”` → `„FINALLY FIRST WORKING VERSION OF AGRI_NAV”` — trzy commity w jeden dzień (4 sierpnia), dokumentujące moment, w którym cały łańcuch odbiornik → NTRIP → poprawki → fix RTK Fixed zadziałał od początku do końca po raz pierwszy. Kilka dni później następuje uczciwa korekta nazewnictwa: `„Rename ARiMR terminology to LPIS/ULDK GUGiK”` — w miarę jak stawało się jasne, że aplikacja korzysta z publicznego API ULDK, a nie z żadnego oficjalnego systemu ARiMR, terminologia w kodzie i UI została poprawiona, żeby nie sugerować integracji, której nie ma (patrz też rozdział 7).

Dalej dochodzi korekta granic punktami kontrolnymi i wyznaczanie linii AB przejazdem RTK, seria poprawek wydajności i UX w Trybie Pracy, eksport historii do PDF, a ostatni commit (`63cd3e3`, 21 sierpnia) poprawia `SwathPlanner`.

### Konkretne problemy napotkane po drodze

**Błąd off-by-one w liczeniu pokrycia.** Wczesna wersja `SectionControl::_footprintKeys` zawyżała zliczaną powierzchnię o 33–67% — pętla próbkująca szerokość narzędzia miała błędny warunek brzegowy i wychodziła poza rzeczywisty footprint. Naprawa (obcięcie kroku do połowy szerokości zamiast pozwalać mu ją przekroczyć) jest udokumentowana wprost w kodzie, razem z fragmentem „przed” i „po” — rzadki przypadek błędu, który dało się precyzyjnie skwantyfikować.

**Zbyt tanie kryterium optymalizacji kierunku.** Pierwsza wersja `SwathPlanner::optimizeAngle` oceniała kandydujące kierunki przybliżeniem długość × szerokość. Okazało się to „aktywnie mylące” (cytat z komentarza w kodzie) na wklęsłych, wielowierzchołkowych granicach po odsunięciu uwrociowym — przybliżenie systematycznie wskazywało gorsze kierunki jako lepsze. Zastąpiono je dokładną oceną: rzeczywistą niepokrytą powierzchnią liczoną operacją boolowską Clipper2 dla każdego kandydata w fazie dogęszczania. Droższe obliczeniowo, ale poprawne — i to jest dokładnie ten rodzaj kompromisu, który był świadomie zaakceptowany.

**Geometria uwroci.** Zanim ustalono finalną formułę odsunięcia `(k − 0.5) × szerokość_robocza`, wcześniejsze podejścia do generowania pierścieni uwrociowych dawały skoki geometrii w ostrych narożnikach pola przy złączeniu typu *miter*. Przejście na złączenie *round* (z ograniczoną tolerancją łuku) w Clipper2 rozwiązało problem.

**Korekta granic — od sztywnej do elastycznej.** Pierwszym mechanizmem korekty była transformacja podobieństwa (obrót + skala + przesunięcie) dopasowana do par punktów kontrolnych. Działała dobrze dla drobnych, jednorodnych przesunięć całego pola, ale nie radziła sobie z sytuacją, gdy błąd geodezyjny nie był jednorodny wzdłuż granicy. Odpowiedzią było dodanie drugiej metody — korekty elastycznej opartej na interpolacji IDW (Inverse Distance Weighting), aktywowanej automatycznie od czterech par punktów, pozwalającej każdemu fragmentowi granicy odkształcić się niezależnie.

**Osobliwość pakietu `bluetooth_classic`.** Strumienie danych z tego pakietu na poziomie natywnym są pojedynczej subskrypcji, nie broadcast — można je nasłuchiwać dokładnie raz w całym cyklu życia aplikacji. Odkryto to przy próbie zbudowania standardowego cyklu połącz/rozłącz/reconnect z wielokrotnym `.listen()`; rozwiązaniem było przesunięcie subskrypcji do konstruktora singletonu, wywoływanej raz na zawsze, a cykl połączenia sterowany wyłącznie metodami `connect()`/`disconnect()` samego pakietu.

**Błędny układ współrzędnych WMS.** Commit `e122a73` naprawia pustą (białą) ortofotomapę — przyczyną był niewłaściwy układ współrzędnych żądany od serwera WMS Geoportalu, klasyczny, łatwy do popełnienia błąd przy integracji z zewnętrznym serwisem geoprzestrzennym.

---

## 7. Stan projektu i ograniczenia

**Co działa dobrze.** Pełna pętla prowadzenia — RTK, generowanie ścieżek (ręczne i automatycznie optymalizowane), snap-to-path, uwrocia, śledzenie pokrycia — jest funkcjonalna i była testowana w realnych warunkach polowych (widać to po rytmie i treści commitów). Trzy metody tworzenia pola, korekta granic, historia z eksportem PDF działają end-to-end.

**Etap testów terenowych.** To projekt rozwijany i testowany przez jedną osobę, iteracyjnie, bezpośrednio w polu — nie przeszedł formalnego procesu QA ani testów na wielu urządzeniach/odbiornikach. Może zawierać nieodkryte jeszcze przypadki brzegowe, szczególnie na nietypowych kształtach pól.

**Brak formalnego dostępu do systemów ARiMR.** Mimo że dane bywają w kodzie i UI nazywane „LPIS”, aplikacja korzysta wyłącznie z **publicznego API ULDK (GUGiK)** — nie z oficjalnego systemu LPIS/ARiMR wymagającego autoryzacji. Nazewnictwo zostało w toku projektu świadomie skorygowane (patrz rozdział 6), żeby nie sugerować integracji, której nie ma — ale warto to mieć na uwadze: granice „rolne” pochodzą z tego samego publicznego rejestru gruntów co granice katastralne, nie z rejestru dopłat ARiMR.

**Zależność od zasięgu komórkowego.** Poprawki NTRIP wymagają aktywnego połączenia internetowego. Bez zasięgu (typowe na części pól w terenie) odbiornik RTK degraduje się do zwykłego GPS/DGPS — nie ma trybu offline ani obsługi własnej stacji bazowej.

**Brak automatycznych testów i CI.** W repozytorium nie ma testów jednostkowych ani integracyjnych, ani pipeline'u CI — poprawność jest dziś weryfikowana ręcznie, w terenie.

**Tylko Android.** Projekt buduje się wyłącznie na Android; nie ma konfiguracji iOS/desktop/web.

**Licencja.** Kod jest udostępniony publicznie wyłącznie do wglądu — zobacz [`LICENSE`](LICENSE). Wszelkie prawa zastrzeżone; kopiowanie, modyfikowanie i wykorzystywanie kodu wymaga pisemnej zgody autora.

---

## 8. Moje autorskie podejście i podsumowanie

*Ten rozdział to szkic na bazie tego, co widać w kodzie i historii commitów — dopisz i skoryguj go swoimi słowami, znasz prawdziwe motywacje lepiej niż ktokolwiek z zewnątrz mógłby je zrekonstruować.*

AgriNav powstał z bardzo konkretnej potrzeby: prowadzenie równoległe z centymetrową dokładnością istnieje na rynku, ale w cenie, która dla mniejszego gospodarstwa jest trudna do uzasadnienia. Zamiast kupować gotowy system, powstała własna aplikacja robiąca to samo na telefonie.

Sposób, w jaki projekt był rozwijany, widać wyraźnie w historii commitów i w samym kodzie: to nie jest praca zaplanowana od początku do końca na papierze, tylko seria iteracji testowanych bezpośrednio w polu — stąd nierówny rytm commitów (dni intensywnej pracy przeplatane wielotygodniowymi przerwami) i stąd konkretne poprawki wynikające z rzeczywistych obserwacji („zrąbany guzik do poprawy”, „szerokość robocza”, poprawki wydajności zauważone dopiero przy realnej pracy w kabinie). Charakterystyczne jest też podejście do weryfikacji numerycznej przed przyjęciem rozwiązania — najlepszym przykładem jest odrzucenie tańszego, ale mylącego kryterium oceny kierunku ścieżek na rzecz dokładnej oceny przez operacje boolowskie, mimo wyższego kosztu obliczeniowego (rozdział 6). Kod jest też nietypowo gęsto skomentowany z naciskiem na *dlaczego*, nie tylko *co* — ślad świadomej decyzji, żeby uzasadnienia nietrywialnych wyborów (konwencje znaków, progi, kompromisy) zostały zapisane obok kodu, a nie tylko w pamięci autora.

Co dalej — to pytanie, na które najlepiej odpowiedzieć samodzielnie: czy priorytetem jest domknięcie ograniczeń z rozdziału 7 (testy, iOS, tryb offline), czy raczej rozwój nowych funkcji, czy może przygotowanie projektu do udostępnienia szerszemu gronu.
