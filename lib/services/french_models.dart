import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Загрузка и проверка моделей:
/// - TTS: Piper VITS fr_FR-siwis-low
/// - ASR: streaming zipformer French (CommonVoice)
class FrenchModelsService {
  static const ttsUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-fr_FR-siwis-low.tar.bz2';
  static const asrUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-fr-2023-04-14.tar.bz2';

  static const ttsFolder = 'vits-piper-fr_FR-siwis-low';
  static const asrFolder = 'sherpa-onnx-streaming-zipformer-fr-2023-04-14';

  Directory? _root;
  void Function(String message)? onLog;
  void Function()? onStatus;

  bool downloading = false;
  String progressText = '';
  String error = '';
  bool ttsReady = false;
  bool asrReady = false;
  /// Прогресс текущего файла (полоска в окне лога, как в ABA English).
  int bytesLoaded = 0;
  int bytesTotal = 0;
  String downloadStage = ''; // 'tts' | 'asr' | ''

  Future<Directory> rootDir() async {
    if (_root != null) return _root!;
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory(p.join(docs.path, 'french_pronunciation_models_v1'));
    if (!await _root!.exists()) await _root!.create(recursive: true);
    return _root!;
  }

  Future<Directory> ttsDir() async {
    final d = Directory(p.join((await rootDir()).path, ttsFolder));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> asrDir() async {
    final d = Directory(p.join((await rootDir()).path, asrFolder));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Пути Piper.
  Future<({String model, String tokens, String dataDir})> ttsPaths() async {
    final d = await ttsDir();
    return (
      model: p.join(d.path, 'fr_FR-siwis-low.onnx'),
      tokens: p.join(d.path, 'tokens.txt'),
      dataDir: p.join(d.path, 'espeak-ng-data'),
    );
  }

  /// Пути Zipformer FR: ищем encoder/decoder/joiner/tokens в папке модели.
  Future<({String encoder, String decoder, String joiner, String tokens})>
      asrPaths() async {
    final d = await asrDir();
    if (!await d.exists()) {
      throw StateError('Нет папки ASR: ${d.path}');
    }

    final files = <File>[];
    await for (final e in d.list(recursive: true, followLinks: false)) {
      if (e is File) files.add(e);
    }

    List<File> onnxNamed(String key) {
      return files
          .where((f) {
            final n = p.basename(f.path).toLowerCase();
            return n.contains(key) && n.endsWith('.onnx');
          })
          .toList();
    }

    File? tokensFile;
    for (final f in files) {
      if (p.basename(f.path).toLowerCase() == 'tokens.txt') {
        tokensFile = f;
        break;
      }
    }

    // Один комплект: либо все int8, либо все fp32 (не смешивать).
    String? pickSet(String key, {required bool int8}) {
      final matches = onnxNamed(key).where((f) {
        final isInt8 = f.path.toLowerCase().contains('int8');
        return int8 ? isInt8 : !isInt8;
      }).toList();
      if (matches.isEmpty) return null;
      matches.sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
      return matches.first.path;
    }

    String? encoder = pickSet('encoder', int8: true);
    String? decoder = pickSet('decoder', int8: true);
    String? joiner = pickSet('joiner', int8: true);
    if (encoder == null || decoder == null || joiner == null) {
      encoder = pickSet('encoder', int8: false);
      decoder = pickSet('decoder', int8: false);
      joiner = pickSet('joiner', int8: false);
    }

    if (encoder == null || decoder == null || joiner == null || tokensFile == null) {
      final listing =
          files.map((f) => '  ${p.basename(f.path)} (${f.lengthSync()})').join('\n');
      throw StateError(
        'Не полные файлы Zipformer FR в ${d.path}.\n'
        'encoder=$encoder\ndecoder=$decoder\njoiner=$joiner\ntokens=${tokensFile?.path}\n'
        'Найдено:\n$listing',
      );
    }

    onLog?.call(
      'ASR files:\n  enc=$encoder\n  dec=$decoder\n  join=$joiner\n  tok=${tokensFile.path}',
    );

    return (
      encoder: encoder,
      decoder: decoder,
      joiner: joiner,
      tokens: tokensFile.path,
    );
  }

  Future<void> refreshReady() async {
    try {
      final t = await ttsPaths();
      ttsReady = File(t.model).existsSync() &&
          File(t.model).lengthSync() > 1 * 1024 * 1024 &&
          File(t.tokens).existsSync() &&
          Directory(t.dataDir).existsSync();
    } catch (_) {
      ttsReady = false;
    }
    try {
      final a = await asrPaths();
      asrReady = File(a.encoder).existsSync() &&
          File(a.encoder).lengthSync() > 1000 &&
          File(a.decoder).existsSync() &&
          File(a.joiner).existsSync() &&
          File(a.tokens).existsSync() &&
          File(a.tokens).lengthSync() > 10;
    } catch (_) {
      asrReady = false;
    }
    onStatus?.call();
  }

  Future<void> ensureModels() async {
    if (downloading) return;
    downloading = true;
    error = '';
    bytesLoaded = 0;
    bytesTotal = 0;
    downloadStage = '';
    onStatus?.call();
    try {
      await refreshReady();
      if (!ttsReady) {
        downloadStage = 'tts';
        progressText = 'Загрузка Piper fr_FR-siwis…';
        bytesLoaded = 0;
        bytesTotal = 0;
        onStatus?.call();
        await _downloadAndExtract(ttsUrl, await ttsDir(), 'Piper TTS FR');
      }
      if (!asrReady) {
        downloadStage = 'asr';
        progressText = 'Загрузка Zipformer FR ASR…';
        bytesLoaded = 0;
        bytesTotal = 0;
        onStatus?.call();
        await _downloadAndExtract(asrUrl, await asrDir(), 'Zipformer FR ASR');
      }
      await refreshReady();
      if (!ttsReady || !asrReady) {
        throw StateError(
            'Модели не готовы (tts=$ttsReady asr=$asrReady). Проверьте файлы в ${(await rootDir()).path}');
      }
      progressText = 'Модели готовы';
      downloadStage = '';
      bytesLoaded = 0;
      bytesTotal = 0;
      onLog?.call('✓ Piper + Zipformer FR готовы');
    } catch (e) {
      error = '$e';
      onLog?.call('Ошибка моделей: $e');
      rethrow;
    } finally {
      downloading = false;
      downloadStage = '';
      onStatus?.call();
    }
  }

  Future<void> _downloadAndExtract(
      String url, Directory dest, String label) async {
    final root = await rootDir();
    final archivePath = p.join(root.path, '${p.basename(url)}');
    final archiveFile = File(archivePath);

    if (!await archiveFile.exists() || await archiveFile.length() < 10000) {
      onLog?.call('↓ $label\n  $url');
      final req = http.Request('GET', Uri.parse(url));
      req.headers['User-Agent'] = 'FrenchPronunciationTrainer/1.1';
      final res = await req.send().timeout(const Duration(minutes: 90));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw StateError('HTTP ${res.statusCode} для $label');
      }
      final sink = archiveFile.openWrite();
      var loaded = 0;
      final total = res.contentLength ?? 0;
      bytesLoaded = 0;
      bytesTotal = total;
      onStatus?.call();
      var lastEmitMs = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        loaded += chunk.length;
        bytesLoaded = loaded;
        bytesTotal = total;
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastEmitMs >= 120 || (total > 0 && loaded >= total)) {
          lastEmitMs = nowMs;
          if (total > 0) {
            final pct = (100 * loaded / total).clamp(0, 100).toStringAsFixed(0);
            progressText = '$label $pct%';
          } else {
            progressText = '$label ${_fmtBytes(loaded)}';
          }
          onStatus?.call();
        }
      }
      await sink.close();
      bytesLoaded = loaded;
      bytesTotal = total > 0 ? total : loaded;
      onStatus?.call();
      onLog?.call('✓ скачано $label: ${await archiveFile.length()} bytes');
    } else {
      onLog?.call('✓ архив $label уже на диске');
    }

    progressText = 'Распаковка $label…';
    // На этапе распаковки точный % неизвестен — indeterminate полоска.
    bytesLoaded = 0;
    bytesTotal = 0;
    onStatus?.call();
    await _extractTarBz2(archiveFile, dest.parent);
    // Архив обычно создаёт папку с именем модели рядом с dest.parent
    // Если dest пуст — ищем распакованную папку.
    await refreshReady();
    if (!(label.contains('Piper') ? ttsReady : asrReady)) {
      // Иногда tar кладёт файлы прямо в dest
      onLog?.call('Проверка структуры после распаковки…');
      await for (final e in dest.parent.list()) {
        onLog?.call('  ${e.path}');
      }
    }
  }

  Future<void> _extractTarBz2(File archiveFile, Directory outDir) async {
    // .tar.bz2 на сотни МБ — только в isolate, иначе UI «Не отвечает».
    progressText = 'Распаковка в фоне (не закрывайте окно)…';
    onStatus?.call();
    final archivePath = archiveFile.absolute.path;
    final outPath = outDir.absolute.path;
    onLog?.call('Распаковка isolate: $archivePath');
    // Tear-off top-level function (не метод класса).
    await Isolate.run(() => extractFrenchTarBz2(archivePath, outPath));
    onLog?.call('✓ распаковка завершена');
  }

  Future<void> clear() async {
    final root = await rootDir();
    if (await root.exists()) await root.delete(recursive: true);
    _root = null;
    ttsReady = false;
    asrReady = false;
    bytesLoaded = 0;
    bytesTotal = 0;
    downloadStage = '';
    onStatus?.call();
  }

  static String _fmtBytes(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Top-level entry for [Isolate.run] (must not be a class method).
void extractFrenchTarBz2(String archivePath, String outDirPath) {
  final bytes = File(archivePath).readAsBytesSync();
  final tarBytes = BZip2Decoder().decodeBytes(bytes);
  final archive = TarDecoder().decodeBytes(tarBytes);
  for (final file in archive) {
    final name = file.name;
    // security: skip absolute / parent paths
    if (name.startsWith('/') || name.startsWith('\\') || name.contains('..')) {
      continue;
    }
    final outPath = p.join(outDirPath, name);
    if (file.isFile) {
      final out = File(outPath);
      out.parent.createSync(recursive: true);
      final content = file.content;
      if (content is List<int>) {
        out.writeAsBytesSync(content);
      }
    } else {
      Directory(outPath).createSync(recursive: true);
    }
  }
}
