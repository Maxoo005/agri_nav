import 'dart:typed_data';

/// Przyrostowy dekoder `Transfer-Encoding: chunked` (HTTP/1.1, NTRIP v2).
///
/// Pakiety TCP nie pokrywają się z porcjami HTTP, więc stan jest trzymany
/// między wywołaniami [add]. Rozszerzenia porcji (`;...`) są ignorowane.
class ChunkedDecoder {
  static const _kMaxSizeLine = 64;
  static const _kMaxChunkDigits = 7; // do 256 MB — więcej to śmieci

  final StringBuffer _sizeLine = StringBuffer();
  int _remaining = 0; // bajty danych do końca porcji
  int _crlfLeft = 0; // bajty CRLF po danych porcji

  /// `true` po porcji o długości 0 — koniec strumienia.
  bool get isDone => _done;
  bool _done = false;

  /// Zwraca same dane z [data]. Rzuca [FormatException] przy złym formacie.
  Uint8List add(Uint8List data) {
    final out = BytesBuilder(copy: false);
    var i = 0;
    while (i < data.length && !_done) {
      if (_remaining > 0) {
        final end = (i + _remaining).clamp(0, data.length);
        out.add(Uint8List.sublistView(data, i, end));
        _remaining -= end - i;
        if (_remaining == 0) _crlfLeft = 2;
        i = end;
      } else if (_crlfLeft > 0) {
        if (data[i] != (_crlfLeft == 2 ? 13 : 10)) {
          throw const FormatException('Brak CRLF po porcji danych');
        }
        _crlfLeft--;
        i++;
      } else {
        final b = data[i++];
        if (b != 10) {
          _sizeLine.writeCharCode(b);
          if (_sizeLine.length > _kMaxSizeLine) {
            throw const FormatException('Zbyt długa linia rozmiaru porcji');
          }
          continue;
        }
        final hex = _sizeLine.toString().split(';').first.trim();
        _sizeLine.clear();
        if (hex.length > _kMaxChunkDigits ||
            !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) {
          throw FormatException('Niepoprawny rozmiar porcji: "$hex"');
        }
        _remaining = int.parse(hex, radix: 16);
        if (_remaining == 0) _done = true;
      }
    }
    return out.takeBytes();
  }
}
