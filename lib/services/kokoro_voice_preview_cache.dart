/// Permanent cache for Kokoro voice preview samples.
///
/// Preview files live outside the lesson-audio cache on purpose: normal
/// phrase-cache pruning/clearing must never remove them. They remain until
/// Android app data is removed/uninstalled.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'kokoro_engine.dart';

class KokoroVoicePreviewCache {
  static const _version = 'v1';
  Directory? _root;

  Future<Directory> rootDir() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory(p.join(
      docs.path,
      'kokoro_voice_preview_cache_$_version',
    ));
    if (!await _root!.exists()) await _root!.create(recursive: true);
    return _root!;
  }

  String key({required String voiceId, required String text}) {
    final raw = '$_version|$voiceId|$text';
    return _fnv1a32(utf8.encode(raw));
  }

  Future<File> fileFor({required String voiceId, required String text}) async {
    final dir = await rootDir();
    return File(p.join(dir.path, '${key(voiceId: voiceId, text: text)}.wav'));
  }

  Future<File?> get({required String voiceId, required String text}) async {
    final file = await fileFor(voiceId: voiceId, text: text);
    if (!await file.exists() || await file.length() < 46) return null;
    return file;
  }

  Future<File> put({
    required String voiceId,
    required String text,
    required Float32List samples,
    required int sampleRate,
  }) async {
    final file = await fileFor(voiceId: voiceId, text: text);
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(
      KokoroEngine.floatToWav(samples, sampleRate: sampleRate),
      flush: true,
    );
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
    return file;
  }

  static String _fnv1a32(List<int> bytes) {
    var hash = 0x811c9dc5;
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}
