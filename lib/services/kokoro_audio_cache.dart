/// Persistent cache of generated Kokoro WAV files.
/// The cache key is phrase + voice + speed + split setting, so a cached
/// reference is always the exact audio variant used by the trainer.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class CachedWav {
  const CachedWav(this.samples, this.sampleRate);
  final Float32List samples;
  final int sampleRate;
}

class KokoroAudioCache {
  static const _version = 'v2';
  Directory? _root;

  Future<Directory> rootDir() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory(p.join(docs.path, 'kokoro_audio_cache_$_version'));
    if (!await _root!.exists()) await _root!.create(recursive: true);
    return _root!;
  }

  String key({
    required String text,
    required String voiceId,
    required double speed,
    required bool splitPattern,
  }) {
    final raw = '$_version|$voiceId|${speed.toStringAsFixed(4)}|${splitPattern ? 1 : 0}|$text';
    return _fnv1a32(utf8.encode(raw));
  }

  Future<File> fileForKey(String key) async {
    final dir = await rootDir();
    return File(p.join(dir.path, '$key.wav'));
  }

  Future<File?> get({
    required String text,
    required String voiceId,
    required double speed,
    required bool splitPattern,
  }) async {
    final keyValue = key(
      text: text,
      voiceId: voiceId,
      speed: speed,
      splitPattern: splitPattern,
    );
    final file = await fileForKey(keyValue);
    if (!await file.exists() || await file.length() < 46) return null;
    return file;
  }

  Future<File> put({
    required String text,
    required String voiceId,
    required double speed,
    required bool splitPattern,
    required Float32List samples,
    required int sampleRate,
  }) async {
    final keyValue = key(
      text: text,
      voiceId: voiceId,
      speed: speed,
      splitPattern: splitPattern,
    );
    final file = await fileForKey(keyValue);
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(_floatToWav(samples, sampleRate), flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
    return file;
  }

  Future<CachedWav> read(File file) async {
    final b = await file.readAsBytes();
    if (b.length < 44 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF') {
      throw StateError('Кэш: не WAV PCM');
    }
    final bd = ByteData.sublistView(b);
    var pos = 12;
    var channels = 1;
    var sampleRate = 24000;
    var bits = 16;
    var format = 1;
    var dataStart = -1;
    var dataLen = 0;
    while (pos + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(pos, pos + 4));
      final len = bd.getUint32(pos + 4, Endian.little);
      final start = pos + 8;
      if (start > b.length) break;
      if (id == 'fmt ' && len >= 16 && start + 16 <= b.length) {
        format = bd.getUint16(start, Endian.little);
        channels = bd.getUint16(start + 2, Endian.little);
        sampleRate = bd.getUint32(start + 4, Endian.little);
        bits = bd.getUint16(start + 14, Endian.little);
      } else if (id == 'data') {
        dataStart = start;
        dataLen = math.min(len, b.length - start).toInt();
        break;
      }
      pos = start + len + (len.isOdd ? 1 : 0);
    }
    if (dataStart < 0 || format != 1 || bits != 16 || channels < 1) {
      throw StateError('Кэш: неподдерживаемый WAV: format=$format channels=$channels bits=$bits');
    }
    final frames = dataLen ~/ (2 * channels);
    final samples = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      var sum = 0.0;
      for (var c = 0; c < channels; c++) {
        final off = dataStart + (i * channels + c) * 2;
        sum += bd.getInt16(off, Endian.little) / 32768.0;
      }
      samples[i] = sum / channels;
    }
    return CachedWav(samples, sampleRate);
  }

  Future<int> count() async {
    final dir = await rootDir();
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final e in dir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.wav')) n++;
    }
    return n;
  }

  Future<int> bytes() async {
    final dir = await rootDir();
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final e in dir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.wav')) total += await e.length();
    }
    return total;
  }


  Future<int> pruneToKeys(Set<String> keepKeys) async {
    final dir = await rootDir();
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final e in dir.list()) {
      if (e is! File || !e.path.toLowerCase().endsWith('.wav')) continue;
      final name = p.basenameWithoutExtension(e.path);
      if (keepKeys.contains(name)) continue;
      try {
        await e.delete();
        n++;
      } catch (_) {}
    }
    return n;
  }

  Future<int> clear() async {
    final dir = await rootDir();
    if (!await dir.exists()) return 0;
    var n = 0;
    await for (final e in dir.list()) {
      if (e is File && e.path.toLowerCase().endsWith('.wav')) {
        try {
          await e.delete();
          n++;
        } catch (_) {}
      }
    }
    return n;
  }

  static String _fnv1a32(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static Uint8List _floatToWav(Float32List samples, int sampleRate) {
    final dataSize = samples.length * 2;
    final bytes = BytesBuilder();
    void u32(int v) => bytes.add([
          v & 255,
          (v >> 8) & 255,
          (v >> 16) & 255,
          (v >> 24) & 255,
        ]);
    void u16(int v) => bytes.add([v & 255, (v >> 8) & 255]);
    bytes.add('RIFF'.codeUnits);
    u32(36 + dataSize);
    bytes.add('WAVE'.codeUnits);
    bytes.add('fmt '.codeUnits);
    u32(16);
    u16(1);
    u16(1);
    u32(sampleRate);
    u32(sampleRate * 2);
    u16(2);
    u16(16);
    bytes.add('data'.codeUnits);
    u32(dataSize);
    for (final s in samples) {
      final v = (s.clamp(-1.0, 1.0) * 32767).round();
      final x = v < 0 ? v + 65536 : v;
      bytes.add([x & 255, (x >> 8) & 255]);
    }
    return bytes.toBytes();
  }
}
