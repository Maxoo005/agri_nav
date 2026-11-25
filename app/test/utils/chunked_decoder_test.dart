import 'dart:convert';
import 'dart:typed_data';

import 'package:agri_nav/utils/chunked_decoder.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(latin1.encode(s));

void main() {
  const stream = '3\r\nabc\r\nA;ext=1\r\n0123456789\r\n0\r\n\r\n';

  test('wynik nie zależy od podziału na pakiety', () {
    for (var size = 1; size <= stream.length; size++) {
      final d = ChunkedDecoder();
      final out = StringBuffer();
      for (var i = 0; i < stream.length; i += size) {
        final end = (i + size).clamp(0, stream.length);
        out.write(latin1.decode(d.add(_b(stream.substring(i, end)))));
      }
      expect(out.toString(), 'abc0123456789', reason: 'pakiet $size B');
      expect(d.isDone, isTrue);
    }
  });

  test('pusty pakiet i dane po końcu', () {
    final d = ChunkedDecoder();
    expect(d.add(Uint8List(0)), isEmpty);
    expect(d.add(_b('0\r\n\r\nśmieci'.replaceAll('ś', 's'))), isEmpty);
    expect(d.isDone, isTrue);
    expect(d.add(_b('3\r\nabc')), isEmpty);
  });

  test('błędny format', () {
    for (final bad in [
      'xyz\r\n',
      '\r\n',
      '-1\r\n',
      'FFFFFFFFFF\r\n',
      '1\r\naXX',
      'a' * 100,
    ]) {
      expect(() => ChunkedDecoder().add(_b(bad)), throwsFormatException,
          reason: bad);
    }
  });
}
