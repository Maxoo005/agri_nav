# Plan przejazdu próbnego

Checklista przed scaleniem gałęzi `add-ci-tests`, `format-lib` i `fixes-2`. Testy automatyczne sprawdzają obliczenia; ten plan sprawdza to, czego nie sprawdzają: ekran, prawdziwy odbiornik i zachowanie maszyny.

| | |
|---|---|
| Data / operator | |
| Commit (`git rev-parse --short HEAD`) | |
| Urządzenie / odbiornik | |
| Maszyna i szerokość robocza | |

**Wynik punktu:** ✅ zgodnie z opisem, ❌ inaczej (zapisz zrzut ekranu i commit), ➖ nie wykonano.
**Nie scalaj**, jeśli którykolwiek punkt oznaczony 🛑 ma wynik ❌.

## 0. Przygotowanie

- [ ] Zainstaluj build z gałęzi `fixes-2`. Zrób kopię danych lub użyj urządzenia bez ważnych pól.
- [ ] Zanotuj **przed aktualizacją** jeden istniejący plan z zakładką i uwrociem (zrzut ekranu) — będzie potrzebny w punkcie 1.
- [ ] Maszyna bez cieczy i nasion, wyłączone narzędzie, wolna przestrzeń co najmniej 5 m poza granicą pola.
- [ ] Miej taśmę mierniczą i paliki do zaznaczenia granicy.

**Gdzie wykonać:** punkty oznaczone [S] da się zrobić przy biurku (telefon lub emulator Androida z odtwarzaniem trasy GPX). Wbudowany symulator C++ jest odłączony, więc go nie używaj. Punkty [P] wymagają pola i odbiornika RTK. Pozycja z emulatora nie ma dokładności RTK — można ocenić rozkład ścieżek, ale nie centymetry.

---

## 1. Tory i pasy z zakładką — przesunięcie o połowę zakładki 🛑 [S + P]

**Zrób:** na polu prostokątnym ustaw szerokość 6,0 m, zakładkę 0,50 m, uwrocie 1, **Generuj**. Zmierz odległość od granicy. Powtórz z zakładką 0 oraz z uwrociem 0.

**Oczekiwane:**

| Ustawienia | Tor uwrocia od granicy | Pierwszy pas od granicy |
|---|---|---|
| 6 m, zakładka 0,50, uwrocie 1 | **3,00 m** (wcześniej 2,75) | **8,50 m** (wcześniej 8,25) |
| 6 m, zakładka 0,50, uwrocie 2 | 3,00 m i 8,50 m | 14,00 m |
| 6 m, zakładka 0, uwrocie 1 | 3,00 m | 9,00 m |
| uwrocie 0 | brak | bez zmian względem poprzedniej wersji |

- Odstęp tor–pas i pas–pas to 5,50 m. Ostatni odstęp może być mniejszy, bo ostatni pas jest dosuwany do przeciwległej granicy.
- Plan zapisany przed aktualizacją po ponownym wygenerowaniu różni się o 0,25 m. Jeśli praca na polu została zaczęta w starej wersji, dokończ ją albo skoryguj ręcznym przesunięciem.

**Błąd oznacza:** tor 2,75 m — działa stara wersja biblioteki C++ (sprawdź build). Odstęp tor–pas inny niż 5,50 m — niespójne przesunięcie uwrocia i pasów, powstanie omijak lub podwójna dawka.

## 2. Uwrocie z zakładką nie wychodzi poza granicę 🛑 [P]

**Zrób:** zaznacz palikami granicę. Przejedź pierwszy tor uwrocia z planu 6 m / 0,50 m, tryb **Uwrocie**, odchyłka bliska zeru. Zmierz odległość zewnętrznej krawędzi narzędzia od palików na prostej i w narożniku.

**Oczekiwane:** krawędź na granicy (± dokładność RTK i prowadzenia, ok. 5 cm), nie 25 cm poza nią. W ostrych narożnikach tor jest zaokrąglony.

**Błąd oznacza:** krawędź systematycznie poza granicą — przesunięcie uwrocia nie działa albo granica lub antena są źle ustawione (sprawdź z zakładką 0: jeśli błąd zostaje, to nie wina planera).

## 3. Pole z przesmykiem (hantel) 🛑 [S]

**Zrób:** narysuj lub zaimportuj dwa kwadraty ok. 100 × 100 m połączone przesmykiem 8 m. Szerokość 10 m, uwrocie 1, **Generuj**, potem **Zoptymalizuj kierunek**. W Trybie Pracy przejedź (lub odtwórz GPX) przez obie części.

**Oczekiwane:** uwrocie i pasy w **obu** częściach (wcześniej tylko w jednej). Prowadzenie działa w obu. Przesmyk węższy niż maszyna pozostaje bez ścieżek — to zamierzone. Po włączeniu 2 uwroci w każdej części są po dwa tory.

**Błąd oznacza:** pusta jedna część — fragment pola zostanie nieobrobiony. Pasy przecinające teren między częściami — nie jedź, ścieżka wychodzi poza pole.

## 4. Scalanie działek 🛑 [S, wymaga internetu]

**Zrób:** pobierz z ULDK 2–4 sąsiadujące działki i scal w jedno pole. Porównaj powierzchnię z sumą z ewidencji. Powtórz dla działek niestykających się i dla zestawu z „dziurą” (np. las w środku).

**Oczekiwane:** żadna działka nie znika; powierzchnia = suma ± 1% (bufor 2–5 cm nieco ją zwiększa). Niestykające się działki dają pole wieloczęściowe.

**Błąd oznacza:** powierzchnia mniejsza o wielkość działki — działka zgubiona. Kierunku obiegu nie widać ani nie da się ustawić z ekranu, więc zapisz numery działek: posłużą jako dane do testu automatycznego.

## 5. Pusty plan czyści prowadzenie 🛑 [S]

**Zrób:** wczytaj pole A, wygeneruj plan z uwrociem 1. Wczytaj pole B oddalone o mniej niż 50 m. **Zanim** wygenerujesz plan dla B, przejedź w pobliżu ścieżek pola A. Potem wygeneruj B z uwrociem 0. Wróć do A i zmień uwrocie z 1 na 0.

**Oczekiwane:** po wczytaniu B na mapie i lightbarze nie ma ścieżek A. Przy uwrociu 0 nie ma przełącznika **Uwrocie** ani odchyłki liczonej względem dawnego toru.

Plan całkowicie pusty jest z ekranu trudny do wywołania (suwaki nie pozwalają na szerokość 0), dlatego sam ten przypadek pokrywa test automatyczny „pusta lista czyści prowadzenie”.

**Błąd oznacza:** lightbar prowadzi po niewidocznych ścieżkach — operator może jechać według planu innego pola.

## 6. Import pliku z zamkniętym pierścieniem [S]

**Zrób:** zaimportuj `app/test/fixtures/pole_200x100.kml`, potem `pole_200x100.geojson` (oba mają powtórzony pierwszy wierzchołek na końcu). Wygeneruj ścieżki.

**Oczekiwane:** jedno pole „Pole testowe”, 4 narożniki, ok. 2,0 ha, z obu plików to samo. Punkt „Gospodarstwo” z GeoJSON jest pomijany. Pola zaimportowane wcześniej pozostają bez zmian.

**Błąd oznacza:** 5 narożników — punkt zamykający nie został usunięty (środek pola i korekta granic będą przesunięte).

## 7. Import pliku z NaN i innymi wadami [S]

**Zrób:** w kopii pliku KML zamień jedną długość geograficzną na `NaN` i zaimportuj. W kopii GeoJSON: (a) wpisz współrzędną jako tekst `"a"`, (b) ustaw `"name": 12`.

**Oczekiwane:** NaN i (a) — czytelny komunikat, pole **nie** powstaje, aplikacja działa dalej. (b) — import udany, nazwa „12”.

**Błąd oznacza:** pole powstało mimo NaN — planer odrzuci je w całości i nie da ścieżek. Zamknięcie aplikacji — nieobsłużony wyjątek, zapisz plik.

## 8. Utrata i odzyskanie korekcji NTRIP 🛑 [P]

Wykonaj na postoju, potem w ruchu. Obserwuj Ustawienia GPS oraz znacznik jakości fixa.

| Krok | Zrób | Oczekiwane |
|---|---|---|
| 8a | Poprawna konfiguracja | „Połączono — poprawki płyną”, po chwili RTK Fixed |
| 8b | Wyłącz dane komórkowe na 2 min | Stan zmienia się na ponawianie (może to potrwać, jeśli sieć znika bez zamknięcia połączenia). Fix spada do Float/DGPS zależnie od odbiornika |
| 8c | Włącz dane | Samoczynne połączenie (przerwa między próbami rośnie do 30 s), powrót RTK Fixed |
| 8d | Nieistniejący mountpoint | „Błąd połączenia / zły mountpoint”, komunikat z nazwą mountpointu, bez ponawiania w kółko |
| 8e | Złe hasło | „Błąd logowania (login/hasło)”, bez ponawiania |
| 8f | Port innej usługi lub adres strony WWW | Czytelny błąd, odbiornik nadal podaje pozycję |
| 8g | Poprawna konfiguracja ponownie | Jak w 8a, bez restartu aplikacji |

**Błąd oznacza:**
- 8a nie łączy się, a przed zmianą łączyło — caster odpowiada w nietypowy sposób i został odrzucony. Zapisz dokładny komunikat. **To najważniejszy punkt tej sekcji**: nowa wersja przyjmuje tylko `ICY 200 OK`, `gnss/data` albo (bez typu treści) dane zaczynające się od RTCM3.
- 8d–8f: „poprawki płyną” — do odbiornika trafia coś, co nie jest RTCM.
- Utrata RTK w trybie ścieżek **nie gasi lightbara** (zachowanie dotychczasowe, bez zmian): przy fixie innym niż RTK Fixed nie ufaj centymetrom.

## 9. Postój i ruszanie (kurs nieznany) [P]

**Zrób:** zatrzymaj się na 30 s z odbiornikiem RTK, rusz, zatrzymaj się, cofnij kilka metrów.

**Oczekiwane:** na postoju prędkość bliska 0, strzałka nie kręci się i nie znika, brak „NaN” na ekranie. Po ruszeniu kurs wraca.

**Błąd oznacza:** skoki strzałki lub mapy na postoju — kurs liczony z szumu pozycji. „NaN” — nieznany kurs dotarł do obliczeń.

## 10. Dolewka ponad pojemność [S]

**Zrób:** maszyna ze zbiornikiem 800 l, start pracy z napełnieniem 1000 l (jeśli ekran na to pozwala), następnie dolej 10 l. Zakończ pracę.

**Oczekiwane:** poziom 800 l. Zużycie w podsumowaniu nie zawiera obciętych 200 l.

**Błąd oznacza:** zużycie 200 l bez jazdy — obcięcie policzone jako wylane.

---

## Decyzja

- [ ] Wszystkie punkty 🛑 mają ✅
- [ ] Każde ❌ ma zgłoszenie z commitem i zrzutem ekranu
- [ ] Znane ograniczenia z README są akceptowalne dla planowanego użycia

Wynik: **scalamy / nie scalamy** — data, podpis:
