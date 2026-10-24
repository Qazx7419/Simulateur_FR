import 'dart:io';

import 'french_models.dart';
import 'french_runtime.dart';


class KokoroVoice {
  const KokoroVoice(this.id, this.name, this.accent, this.gender);
  final String id;
  final String name;
  final String accent;
  final String gender;
}

const List<KokoroVoice> kKokoroVoices = [
  KokoroVoice('ff_siwis', 'Siwis', '🇫🇷 Французский', 'женский'),
];
class PronunciationModelsStatus {
  const PronunciationModelsStatus({
    this.ttsReady = false,
    this.asrReady = false,
    this.progressText = '',
    this.bytesLoaded = 0,
    this.bytesTotal = 0,
    this.downloading = false,
    this.downloadStage = '',
    this.error = '',
  });
  final bool ttsReady;
  final bool asrReady;
  final String progressText;
  final int bytesLoaded;
  final int bytesTotal;
  final bool downloading;
  final String downloadStage; // 'tts' | 'asr' | ''
  final String error;

  double get fraction =>
      bytesTotal > 0 ? (bytesLoaded / bytesTotal).clamp(0.0, 1.0) : 0.0;

  String get pctLabel {
    if (bytesTotal <= 0) return bytesLoaded > 0 ? _fmt(bytesLoaded) : '—';
    final pct = (fraction * 100).clamp(0, 100).toStringAsFixed(0);
    return '$pct% · ${_fmt(bytesLoaded)} / ${_fmt(bytesTotal)}';
  }

  static String _fmt(int b) {
    if (b < 1024) return '${b} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

typedef ModelsLogFn = void Function(String msg, {int level});

/// Локальные нейромодели тренажёра (как в userscript 1.25.75).
/// Скачивание с HuggingFace + прогресс в лог.
/// Инференс ONNX — следующий слой (файлы уже на диске).






class DifficultyConfig {
  const DifficultyConfig({
    required this.id,
    required this.passPct,
    required this.phonemeSoft,
    required this.excellent,
    required this.good,
    required this.acceptable,
    required this.needWork,
    required this.wordGood,
    required this.wordMid,
  });
  final String id;
  final int passPct;
  final double phonemeSoft;
  final int excellent;
  final int good;
  final int acceptable;
  final int needWork;
  final double wordGood;
  final double wordMid;

  static DifficultyConfig of(String id) {
    switch (id) {
      case 'easy':
        return const DifficultyConfig(
          id: 'easy',
          passPct: 40,
          phonemeSoft: 0.72,
          excellent: 70,
          good: 55,
          acceptable: 40,
          needWork: 25,
          wordGood: 0.62,
          wordMid: 0.38,
        );
      case 'mid':
        return const DifficultyConfig(
          id: 'mid',
          passPct: 50,
          phonemeSoft: 0.85,
          excellent: 80,
          good: 65,
          acceptable: 50,
          needWork: 35,
          wordGood: 0.75,
          wordMid: 0.50,
        );
      default:
        return const DifficultyConfig(
          id: 'high',
          passPct: 60,
          phonemeSoft: 1.0,
          excellent: 88,
          good: 75,
          acceptable: 60,
          needWork: 45,
          wordGood: 0.85,
          wordMid: 0.60,
        );
    }
  }

  String levelFromPct(int pct) {
    if (pct >= excellent) return 'Отлично';
    if (pct >= good) return 'Хорошо';
    if (pct >= acceptable) return 'Приемлемо';
    if (pct >= needWork) return 'Нужно поработать';
    return 'Слабо';
  }

  bool analysisPassed(int? pct) => pct != null && pct >= passPct;
}

class AlignResult {
  AlignResult(this.distance, this.ops);
  final int distance;
  final List<String> ops;
}

AlignResult alignTokens(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  final bt = List.generate(n + 1, (_) => List<String?>.filled(m + 1, null));
  for (var i = 0; i <= n; i++) {
    dp[i][0] = i;
    if (i > 0) bt[i][0] = 'd';
  }
  for (var j = 0; j <= m; j++) {
    dp[0][j] = j;
    if (j > 0) bt[0][j] = 'i';
  }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final same = a[i - 1] == b[j - 1];
      var best = dp[i - 1][j - 1] + (same ? 0 : 1);
      var op = same ? 'o' : 's';
      if (dp[i - 1][j] + 1 < best) {
        best = dp[i - 1][j] + 1;
        op = 'd';
      }
      if (dp[i][j - 1] + 1 < best) {
        best = dp[i][j - 1] + 1;
        op = 'i';
      }
      dp[i][j] = best;
      bt[i][j] = op;
    }
  }
  final ops = <String>[];
  var i = n, j = m;
  while (i > 0 || j > 0) {
    final op = bt[i][j] ?? 'o';
    ops.add(op);
    if (op == 'o' || op == 's') {
      i--;
      j--;
    } else if (op == 'd') {
      i--;
    } else {
      j--;
    }
  }
  return AlignResult(dp[n][m], ops.reversed.toList());
}


class AlignRow {
  const AlignRow({required this.op, this.ref, this.mine});
  final String op;
  final String? ref;
  final String? mine;
}

List<AlignRow> alignTokenRows(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  final bt = List.generate(n + 1, (_) => List<String?>.filled(m + 1, null));
  for (var i = 0; i <= n; i++) { dp[i][0] = i; if (i > 0) bt[i][0] = 'd'; }
  for (var j = 0; j <= m; j++) { dp[0][j] = j; if (j > 0) bt[0][j] = 'i'; }
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      final same = a[i - 1] == b[j - 1];
      var best = dp[i - 1][j - 1] + (same ? 0 : 1);
      var op = same ? 'o' : 's';
      if (dp[i - 1][j] + 1 < best) { best = dp[i - 1][j] + 1; op = 'd'; }
      if (dp[i][j - 1] + 1 < best) { best = dp[i][j - 1] + 1; op = 'i'; }
      dp[i][j] = best; bt[i][j] = op;
    }
  }
  final rows = <AlignRow>[];
  var i = n, j = m;
  while (i > 0 || j > 0) {
    final op = bt[i][j] ?? 'o';
    if (op == 'o' || op == 's') { rows.add(AlignRow(op: op, ref: a[i - 1], mine: b[j - 1])); i--; j--; }
    else if (op == 'd') { rows.add(AlignRow(op: op, ref: a[i - 1])); i--; }
    else { rows.add(AlignRow(op: op, mine: b[j - 1])); j--; }
  }
  return rows.reversed.toList();
}

int phonemePct(AlignResult ar, int refLen, int hypLen, double soft) {
  final den = (refLen > hypLen ? refLen : hypLen);
  if (den <= 0) return 100;
  final softDist = ar.distance * soft;
  final pct = ((1 - softDist / den) * 100).round();
  return pct < 0 ? 0 : pct;
}

class ModelFileSpec {
  const ModelFileSpec(this.url, this.relPath, {this.optional = false});
  final String url;
  final String relPath;
  final bool optional;
}

/// Минимальный набор для локальной работы (quantized, без всех вариантов fp16/q4).
const asrModelId = 'onnx-community/wav2vec2-ljspeech-gruut-ONNX';
const ttsModelId = 'onnx-community/Kokoro-82M-v1.0-ONNX';

List<ModelFileSpec> asrEssentialFiles() {
  const base = 'https://huggingface.co/$asrModelId/resolve/main';
  return const [
    ModelFileSpec('$base/config.json', 'asr/config.json'),
    ModelFileSpec('$base/preprocessor_config.json', 'asr/preprocessor_config.json'),
    ModelFileSpec('$base/vocab.json', 'asr/vocab.json'),
    ModelFileSpec('$base/tokenizer_config.json', 'asr/tokenizer_config.json'),
    ModelFileSpec('$base/onnx/model_q4.onnx', 'asr/onnx/model_q4.onnx'),
  ];
}

List<ModelFileSpec> ttsEssentialFiles({String voiceId = 'bf_emma'}) {
  const base = 'https://huggingface.co/$ttsModelId/resolve/main';
  return [
    const ModelFileSpec('$base/config.json', 'tts/config.json'),
    const ModelFileSpec('$base/tokenizer.json', 'tts/tokenizer.json'),
    const ModelFileSpec('$base/tokenizer_config.json', 'tts/tokenizer_config.json'),
    const ModelFileSpec(
        '$base/onnx/model_quantized.onnx', 'tts/onnx/model_quantized.onnx'),
    ModelFileSpec('$base/voices/$voiceId.bin', 'tts/voices/$voiceId.bin'),
  ];
}




class PronunciationModelsService {
  PronunciationModelsStatus status = const PronunciationModelsStatus();
  void Function(String message, {int level})? onLog;
  void Function()? onStatus;

  final FrenchModelsService _fr = FrenchModelsService();
  Future<void>? _ensureFuture;

  void _emit(String msg, {int level = 1}) => onLog?.call(msg, level: level);

  void _setStatus(PronunciationModelsStatus s) {
    status = s;
    onStatus?.call();
  }

  Future<Directory> rootDir() => _fr.rootDir();

  Future<void> refreshReady({String voiceId = 'ff_siwis'}) async {
    _fr.onLog = (m) => _emit(m);
    await _fr.refreshReady();
    await _syncFrenchRuntimeFromDisk();
    _setStatus(PronunciationModelsStatus(
      ttsReady: _fr.ttsReady,
      asrReady: _fr.asrReady,
      downloading: _fr.downloading,
      progressText: _fr.progressText,
      bytesLoaded: _fr.bytesLoaded,
      bytesTotal: _fr.bytesTotal,
      downloadStage: _fr.downloadStage,
      error: _fr.error,
    ));
  }

  Future<int> modelsDirBytes() async {
    final r = await rootDir();
    var total = 0;
    if (!await r.exists()) return 0;
    await for (final e in r.list(recursive: true, followLinks: false)) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  Future<void> clearModels() async {
    await _fr.clear();
    FrenchRuntime.piperModel = null;
    FrenchRuntime.piperTokens = null;
    FrenchRuntime.piperDataDir = null;
    FrenchRuntime.asrEncoder = null;
    FrenchRuntime.asrDecoder = null;
    FrenchRuntime.asrJoiner = null;
    FrenchRuntime.asrTokens = null;
    await refreshReady();
  }

  Future<void> waitForIdle() async {
    final running = _ensureFuture;
    if (running != null) await running;
  }

  Future<void> ensureModels({
    String voiceId = 'ff_siwis',
    bool asr = true,
    bool tts = true,
  }) async {
    final running = _ensureFuture;
    if (running != null) {
      await running;
      return;
    }
    final future = _ensureModelsImpl();
    _ensureFuture = future;
    try {
      await future;
    } finally {
      if (identical(_ensureFuture, future)) _ensureFuture = null;
    }
  }

  Future<void> _ensureModelsImpl() async {
    try {
      _fr.onLog = (m) => _emit(m);
      _fr.onStatus = () {
        _setStatus(PronunciationModelsStatus(
          ttsReady: _fr.ttsReady,
          asrReady: _fr.asrReady,
          downloading: _fr.downloading,
          progressText: _fr.progressText,
          bytesLoaded: _fr.bytesLoaded,
          bytesTotal: _fr.bytesTotal,
          downloadStage: _fr.downloadStage,
          error: _fr.error,
        ));
      };
      await _fr.ensureModels();
      final t = await _fr.ttsPaths();
      final a = await _fr.asrPaths();
      FrenchRuntime.piperModel = t.model;
      FrenchRuntime.piperTokens = t.tokens;
      FrenchRuntime.piperDataDir = t.dataDir;
      FrenchRuntime.asrEncoder = a.encoder;
      FrenchRuntime.asrDecoder = a.decoder;
      FrenchRuntime.asrJoiner = a.joiner;
      FrenchRuntime.asrTokens = a.tokens;
      await refreshReady();
      _emit('Готово. Piper=${status.ttsReady} ZipformerFR=${status.asrReady}');
    } catch (e) {
      _setStatus(PronunciationModelsStatus(
        ttsReady: false,
        asrReady: false,
        error: '$e',
        progressText: '$e',
      ));
      rethrow;
    }
  }

  Future<Directory> sherpaTtsModelDir() => _fr.ttsDir();

  /// Подтягивает пути Zipformer с диска (не только из RAM-кэша FrenchRuntime).
  Future<void> _syncFrenchRuntimeFromDisk() async {
    try {
      await _fr.refreshReady();
      if (_fr.ttsReady) {
        final tp = await _fr.ttsPaths();
        FrenchRuntime.piperModel = tp.model;
        FrenchRuntime.piperTokens = tp.tokens;
        FrenchRuntime.piperDataDir = tp.dataDir;
      }
      if (_fr.asrReady) {
        final a = await _fr.asrPaths();
        FrenchRuntime.asrEncoder = a.encoder;
        FrenchRuntime.asrDecoder = a.decoder;
        FrenchRuntime.asrJoiner = a.joiner;
        FrenchRuntime.asrTokens = a.tokens;
      }
    } catch (e) {
      _emit('sync paths: $e', level: 2);
    }
  }

  Future<File?> asrOnnxFile() async {
    if (FrenchRuntime.asrEncoder == null) {
      await _syncFrenchRuntimeFromDisk();
    }
    if (FrenchRuntime.asrEncoder == null) return null;
    final f = File(FrenchRuntime.asrEncoder!);
    return f.existsSync() ? f : null;
  }

  Future<File?> asrVocabFile() async {
    if (FrenchRuntime.asrTokens == null) {
      await _syncFrenchRuntimeFromDisk();
    }
    if (FrenchRuntime.asrTokens == null) return null;
    final f = File(FrenchRuntime.asrTokens!);
    return f.existsSync() ? f : null;
  }

  Future<List<double>?> generateTts(String text,
      {required String voice, required double speed, bool splitPattern = true}) async {
    return null;
  }
}
