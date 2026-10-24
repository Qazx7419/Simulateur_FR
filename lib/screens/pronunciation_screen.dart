import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '../services/pronunciation_models.dart';
import '../services/kokoro_engine.dart';
import '../services/asr_engine.dart';
import '../services/kokoro_audio_cache.dart';
import '../services/kokoro_voice_preview_cache.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
// flutter_background — только Android; на Windows импорт убран (native crash risk).

/// Тренажёр французского (UI ABA English + Piper siwis + Zipformer FR).
/// TTS: Piper fr_FR-siwis | ASR: Zipformer FR (токены = слова).
///
/// Auto (браузер): TTS → пауза → сигнал → запись (VAD) → полное «Я» → повтор TTS → next
/// В Auto запись всегда проигрывается до конца до следующего TTS.
class PronunciationScreen extends StatefulWidget {
  const PronunciationScreen({super.key});

  @override
  State<PronunciationScreen> createState() => _PronunciationScreenState();
}

class _MemoryWavSource extends StreamAudioSource {
  _MemoryWavSource(this._bytes);
  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, _bytes.length).toInt();
    final to = (end ?? _bytes.length).clamp(from, _bytes.length).toInt();
    return StreamAudioResponse(
      sourceLength: _bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(_bytes.sublist(from, to)),
      contentType: 'audio/wav',
    );
  }
}

class _Phrase {
  _Phrase(this.text, {this.ipa = '', this.translation = ''});
  final String text;
  final String ipa;
  final String translation;
}

class _PronunciationScreenState extends State<PronunciationScreen> {
  static const _phrasesKey = 'french-full-trainer-phrases-v1';
  static const _pasteSkipDupKey = 'french-full-trainer-paste-skip-dup-v1';
  static const _posKey = 'french-full-trainer-position-v1';
  static const _modeKey = 'french-full-trainer-mode-v1';
  static const _listenRateKey = 'french-full-trainer-speed-v1';
  static const _espeakPromptKey = 'french-espeak-download-prompt-v1';
  static const _espeakDownloadUrl =
      'https://github.com/espeak-ng/espeak-ng/releases';
  static const _neuralRateKey = 'french-full-trainer-neural-speed-v1';
  static const _neuralRateLockKey = 'french-full-trainer-neural-speed-lock-v1';
  static const _splitKey = 'french-full-trainer-split-pattern-v1';
  static const _autoPlayRecKey = 'french-full-trainer-auto-play-record-v1';
  static const _analysisStyleKey = 'french-full-trainer-analysis-style-v1';
  static const _diffKey = 'french-full-trainer-difficulty-v1';
  static const _compareKey = 'french-full-trainer-compare-unit-v2';
  static const _keepKey = 'french-full-trainer-neural-keep-v1';
  static const _micSensKey = 'french-full-trainer-mic-sens-v1';
  static const _recordGainKey = 'french-full-trainer-record-gain-v1';
  static const _micAgcKey = 'french-full-trainer-mic-agc-v1';
  static const _beepKey = 'french-full-trainer-record-beep-v1';
  static const _asrVolKey = 'french-full-trainer-asr-volume-match-v1';
  static const _logKey = 'french-full-trainer-log-v1';
  static const _voiceKey = 'french-full-trainer-voice-v1';

  static const _bg = Color(0xFF111111);
  static const _card = Color(0xFF1A1A1A);
  static const _border = Color(0xFF2A2A2A);
  static const _accent = Color(0xFFFF9800);
  static const _ok = Color(0xFF65D69B);
  static const _muted = Color(0xFF888888);
  static const _text = Color(0xFFEEEEEE);

  FlutterTts? _tts;
  /// Текущий процесс eSpeak (озвучка в «Браузерном» режиме).
  Process? _espeakSpeakProc;
  AudioRecorder? _recorder;
  AudioPlayer? _playback;
  AudioPlayer? _beepPlayer;

  FlutterTts get _ttsEngine => _tts ??= FlutterTts();
  AudioRecorder get _rec => _recorder ??= AudioRecorder();
  AudioPlayer get _playbackEngine => _playback ??= AudioPlayer();
  AudioPlayer get _beepEngine => _beepPlayer ??= AudioPlayer();

  List<_Phrase> _phrases = [
    _Phrase("Bonjour, comment allez-vous ?"),
    _Phrase("Je voudrais pratiquer ma prononciation."),
    _Phrase("Pourriez-vous répéter plus lentement, s'il vous plaît ?"),
    _Phrase("Où se trouve la gare, s'il vous plaît ?"),
    _Phrase("Je ne parle pas très bien français."),
  ];
  int _index = 0;

  bool _browserMode = false;
  bool _pasteSkipDuplicates = true;
  double _listenRate = 1.0;
  double _neuralRate = 0.88;
  bool _neuralRateLocked = false;
  bool _useSplitPattern = true;
  bool _analysisSimple = true;
  bool _autoPlayRecorded = true;

  // Settings from userscript
  String _difficulty = 'mid'; // easy | mid | high
  String _compareUnit = 'word'; // phoneme | word
  String _neuralKeep = 'all'; // pair | all
  double _micSens = 1.0; // 0..1 — порог детектора речи (VAD), не gain микрофона
  /// Цифровое усиление записи (Windows-микрофоны часто тихие). 1.0 = без усиления.
  double _recordGain = 1.0;
  bool _micAgc = true;
  bool _recordBeep = true;
  bool _asrVolumeMatch = true;
  int _logLevel = 0; // 0 off, 1 normal, 2 extended — по умолчанию выкл.

  String _status = '';
  String _recStatus = '';
  String _logLine = '';
  bool _autoRunning = false;
  bool _autoStopRequested = false;
  int _autoToken = 0;
  bool _recording = false;
  bool _ttsActive = false;
  bool _ttsPaused = false;
  bool _playingMine = false;

  String? _lastRecordPath;
  final _log = <String>[];

  String _curInd = '—';
  String _nextInd = '—';
  Color _curIndColor = _muted;
  Color _nextIndColor = _muted;

  bool _ttsModelReady = false;
  bool _asrFilesReady = false;
  bool _asrModelReady = false;
  bool _modelsInitializing = true;
  String _voiceId = 'ff_siwis';
  String get _voiceName {
    final v = kKokoroVoices.where((e) => e.id == _voiceId);
    return v.isEmpty ? 'Emma' : v.first.name;
  }
  final _models = PronunciationModelsService();
  final _kokoro = KokoroEngine();
  final _asr = AsrEngine();
  final _audioCache = KokoroAudioCache();
  // Отдельный постоянный кэш пробников голосов. Он намеренно не входит
  // в кэш фраз и никогда не чистится кнопками очистки нейро-аудио.
  final _voicePreviewCache = KokoroVoicePreviewCache();
  int _voicePreviewToken = 0;
  // RAM-кэш — именно тот кэш, который должен давать мгновенное воспроизведение.
  // В режиме «2 файла» здесь находятся только текущая и следующая фразы.
  final Map<String, CachedWav> _ramAudioCache = {};
  final Map<String, Future<File?>> _generationFutures = {};
  Future<void>? _modelsInitFuture;
  Future<void>? _asrLoadFuture;
  Timer? _analysisAnimTimer;
  int _analysisAnimPhase = 0;
  int _audioCacheCount = 0;
  int _audioCacheBytes = 0;
  Float32List? _neuralReference16k;
  Float32List? _myAudio16k;
  bool _analysisRunning = false;
  int _asrActiveJobs = 0;
  String _analysisResult = '';
  String _translation = '';
  String _ipa = '';
  bool _translationVisible = false;
  int _transReq = 0;
  int? _lastScorePct;
  String _lastScoreLevel = '';

  // Быстрая индикация активности «как светодиод диска».
  // 140 мс заметно отличается от медленного сердечного пульса и почти не
  // создаёт нагрузки: setState вызывается только когда хотя бы один процесс занят.
  Timer? _activityBlinkTimer;
  bool _activityBlinkOn = false;
  bool _speedPanelExpanded = false;

  // Навигация по фразам: короткая визуальная вспышка + debounce генерации.
  Timer? _navFlashTimer;
  Timer? _neuralPrepareTimer;
  Timer? _idlePrefetchTimer;
  Timer? _asrPrepareTimer;
  int _navFlash = 0; // -1 = назад, +1 = вперёд
  int _phraseGenerationToken = 0;
  int _cacheEpoch = 0;
  int _indicatorToken = 0;
  bool _prefetchRunning = false;
  /// Отложенный первый warmup после включения «Нейро» (Windows: race ORT/Piper).
  Timer? _neuralWarmupTimer;
  /// Глобальная очередь: только одна native-генерация Piper за раз.
  Future<void> _kokoroSerial = Future<void>.value();
  bool _backgroundDownloadEnabled = false;
  Future<void>? _stopFuture;

  StreamSubscription<Amplitude>? _ampSub;
  double _liveLevel = -160; // dBFS live
  double _recPeakDb = -160;
  String _micTestHint = '';

  @override
  void initState() {
    super.initState();
    // Сначала рисуем UI, потом тяжёлый init — иначе native crash
    // в конструкторах плагинов валит process до первого кадра.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _activityBlinkTimer = Timer.periodic(const Duration(milliseconds: 140), (_) {
        if (!mounted) return;
        final busy = _models.status.downloading ||
            _ttsActive ||
            _generationFutures.isNotEmpty ||
            _analysisRunning ||
            _asrLoadFuture != null;
        if (busy) {
          setState(() => _activityBlinkOn = !_activityBlinkOn);
        }
      });
      _modelsInitFuture = _init().catchError((e, st) {
        _logMsg('FATAL init: $e', level: 1);
        _logMsg('$st', level: 2);
        if (mounted) {
          setState(() {
            _status = 'Ошибка инициализации: $e';
            _modelsInitializing = false;
          });
        }
      });
    });
  }

  Future<void> _init() async {
    _log.clear(); // каждый запуск — чистый лог
    _logMsg('init start (platform=${Platform.operatingSystem})', level: 1);
    if (mounted) setState(() => _status = 'Инициализация…');
    // FlutterTts на Windows инициализируем только в browser-режиме.
    if (!Platform.isWindows) {
      try {
        await _ttsEngine.setLanguage('fr-FR');
        await _ttsEngine.awaitSpeakCompletion(true);
      } catch (e) {
        _logMsg('tts init: $e', level: 1);
      }
    }
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_phrasesKey);
    if (raw != null && raw.trim().isNotEmpty) {
      final lines = raw
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (lines.isNotEmpty) {
        _phrases = lines.map((t) => _Phrase(t)).toList();
      }
    }
    _index = (p.getInt(_posKey) ?? 0).clamp(0, _phrases.length - 1);
    _browserMode = p.getString(_modeKey) == 'browser';
    _pasteSkipDuplicates = p.getBool(_pasteSkipDupKey) ?? true;
    _listenRate = (p.getDouble(_listenRateKey) ?? 1.0).clamp(0.5, 1.0);
    _neuralRate = (p.getDouble(_neuralRateKey) ?? 0.88).clamp(0.5, 1.2);
    _neuralRateLocked = p.getBool(_neuralRateLockKey) ?? false;
    _useSplitPattern = false; // split_pattern временно отключён и не влияет на генерацию/кэш.
    _autoPlayRecorded = p.getString(_autoPlayRecKey) != '0';
    _analysisSimple = p.getString(_analysisStyleKey) != 'detail';
    _difficulty = p.getString(_diffKey) ?? 'mid';
    _compareUnit = 'word'; // FR: только слова (Zipformer), фонемы EN отключены
    _neuralKeep = p.getString(_keepKey) ?? 'all';
    _micSens = (p.getDouble(_micSensKey) ?? 1.0).clamp(0.0, 1.0);
    _recordGain = 1.0; // UI убран; усиление через системный микрофон Windows
    _micAgc = p.getString(_micAgcKey) != '0';
    // true по умолчанию; миграция со старого string '0'/'1'
    try {
      if (p.containsKey(_beepKey)) {
        final b = p.getBool(_beepKey);
        if (b != null) {
          _recordBeep = b;
        } else {
          final s = p.getString(_beepKey);
          _recordBeep = s != '0';
        }
      } else {
        _recordBeep = true;
      }
    } catch (_) {
      _recordBeep = true;
    }
    _asrVolumeMatch = p.getString(_asrVolKey) != '0';
    _logLevel = p.getInt(_logKey) ?? 0;
    _voiceId = p.getString(_voiceKey) ?? 'ff_siwis';
    if (mounted) setState(() {});
    _refreshNeuralIndicators();
    _onPhraseChanged();
    // прогрев сигнала (на Windows just_audio_windows + setAsset при старте
    // экрана иногда конфликтует с фоновым плеером — пропускаем).
    if (!Platform.isWindows) {
      try {
        // asset blim.wav не используется
      } catch (_) {}
    }
    // На Windows не трогаем микрофон при старте экрана — record/wasapi
    // иногда даёт native crash ещё до первого кадра. Разрешение спросим
    // только в момент реальной записи.
    if (!Platform.isWindows) {
      try {
        final ok = await _rec.hasPermission().timeout(
          const Duration(seconds: 2),
          onTimeout: () => false,
        );
        if (!ok) {
          _logMsg('микрофон: нет разрешения (запросится при записи)', level: 1);
        }
      } catch (e) {
        _logMsg('mic perm: $e', level: 1);
      }
    }
    if (!Platform.isWindows) {
      try {
        await _ttsEngine.setSpeechRate((_listenRate * 0.55).clamp(0.2, 0.9));
      } catch (_) {}
    }

    _models.onLog = (msg, {int level = 1}) => _logMsg(msg, level: level);
    _models.onStatus = () {
      if (!mounted) return;
      setState(() {
        _ttsModelReady = _models.status.ttsReady;
        _asrFilesReady = _models.status.asrReady;
        if (_models.status.progressText.isNotEmpty) {
          _status = _models.status.progressText;
        }
      });
    };
    await _models.refreshReady(voiceId: _voiceId);
    _ttsModelReady = _models.status.ttsReady;
    _asrFilesReady = _models.status.asrReady;

    // Если при прошлом запуске был выбран «Нейро», не ждём переключения
    // Браузерный → Нейро. Сразу поднимаем модели, ASR и кэш.
    if (!_browserMode) {
      if (!_ttsModelReady || !_asrFilesReady) {
        await _startBackgroundDownloadGuard();
        try {
          await _models.ensureModels(voiceId: _voiceId);
        } catch (e) {
          _logMsg('ensureModels: $e', level: 1);
        } finally {
          await _stopBackgroundDownloadGuard();
        }
        _ttsModelReady = _models.status.ttsReady;
        _asrFilesReady = _models.status.asrReady;
      }
      // ASR загружаем лениво — только перед первым реальным сравнением.
      // Одновременная загрузка ASR и тяжёлого Piper на старте давала
      // пиковый расход памяти и могла уронить native runtime.
    }

    try {
          unawaited(_maybePromptEspeakDownload());
await _onPhraseChanged(prepareNeural: !_browserMode);
    } catch (e) {
      _logMsg('onPhraseChanged: $e', level: 1);
    }
    try {
      await _refreshAudioCacheStats();
    } catch (e) {
      _logMsg('cacheStats: $e', level: 1);
    }
    _modelsInitializing = false;
    if (mounted) setState(() {});
    // При старте уже выбранного «Нейро» — отложенный warmup (не в том же кадре).
    if (!_browserMode && _ttsModelReady) {
      _scheduleDeferredNeuralWarmup();
    }
  }

  Future<void> _refreshAudioCacheStats() async {
    try {
      final n = await _audioCache.count();
      final b = await _audioCache.bytes();
      if (!mounted) return;
      setState(() {
        _audioCacheCount = n;
        _audioCacheBytes = b;
      });
    } catch (_) {}
  }


  /// Не стартуем Piper сразу при переключении на «Нейро» —
  /// даём UI/native стеку «осесть», особенно на Windows.
  /// Политика кэша (pair/all) и prune не меняются — только момент старта.
  void _scheduleDeferredNeuralWarmup({int? delayMs}) {
    _neuralWarmupTimer?.cancel();
    _neuralWarmupTimer = null;
    if (_browserMode || !_ttsModelReady || _phrases.isEmpty || !mounted) return;
    final ms = delayMs ?? (Platform.isWindows ? 2800 : 500);
    final token = _phraseGenerationToken;
    _logMsg('Нейро: отложенный warmup через ${ms} ms', level: 2);
    _neuralWarmupTimer = Timer(Duration(milliseconds: ms), () {
      _neuralWarmupTimer = null;
      if (!mounted || _browserMode) return;
      if (token != _phraseGenerationToken) return;
      if (!_ttsModelReady || _phrases.isEmpty) return;
      unawaited(_runIdlePrefetch(_phraseGenerationToken));
    });
  }

  Future<T> _enqueueKokoro<T>(Future<T> Function() job) {
    final done = Completer<T>();
    _kokoroSerial = _kokoroSerial.then((_) async {
      try {
        final value = await job();
        if (!done.isCompleted) done.complete(value);
      } catch (e, st) {
        if (!done.isCompleted) done.completeError(e, st);
      }
    }).catchError((_) {});
    return done.future;
  }

  Future<void> _activateNeuralMode() async {
    final init = _modelsInitFuture;
    if (init != null) await init;
    if (_browserMode) return;
    if (!_ttsModelReady || !_asrFilesReady) {
      await _downloadModels();
    }
    // Не жжём Piper в тот же тик, что переключение режима (Windows race).
    // Warmup текущей+следующей — с задержкой; pair/all и prune без изменений.
    if (_ttsModelReady) {
      _scheduleDeferredNeuralWarmup();
    }
    if (mounted) setState(() {});
  }

  Future<void> _waitForNativeWorkBeforeModelReset() async {
    _cacheEpoch++;
    _phraseGenerationToken++;
    _neuralPrepareTimer?.cancel();
    _neuralPrepareTimer = null;
    _idlePrefetchTimer?.cancel();
    _idlePrefetchTimer = null;
    _neuralWarmupTimer?.cancel();
    _neuralWarmupTimer = null;
    _prefetchRunning = false;
    try { await _playbackEngine.stop(); } catch (_) {}
    try { await _ttsEngine.stop(); } catch (_) {}
    _ttsActive = false;
    _ttsPaused = false;

    // Не освобождаем native Piper, пока его generate() ещё работает.
    // Иначе именно на очистке/перезагрузке можно получить native crash.
    final pendingTts = List<Future<File?>>.from(_generationFutures.values);
    if (pendingTts.isNotEmpty) {
      if (mounted) setState(() => _status = 'Завершаю текущую генерацию…');
      try { await Future.wait(pendingTts, eagerError: false); } catch (_) {}
    }

    if (_models.status.downloading) {
      if (mounted) setState(() => _status = 'Жду завершения загрузки моделей…');
    }
    await _models.waitForIdle();
    try {
      await _asrLoadFuture;
    } catch (_) {}
    try { await _asr.dispose(); } catch (_) {}
    _asrModelReady = false;
    _neuralReference16k = null;
    _lastRefAsr = null;
    _lastRefAsrAudio = null;
    _lastMineAsr = null;
    _lastMineAsrAudio = null;
    try { await _kokoro.dispose(); } catch (_) {}
  }

  Future<void> _startBackgroundDownloadGuard() async {
    // Android-only (flutter_background). На Windows/desktop — no-op.
    if (!Platform.isAndroid || _backgroundDownloadEnabled) return;
    _logMsg('Фоновая загрузка: доступна только на Android', level: 2);
  }

  Future<void> _stopBackgroundDownloadGuard() async {
    _backgroundDownloadEnabled = false;
  }

  Future<void> _downloadModels({bool forceReload = false}) async {
    // Never start a second model load while the screen is still initializing.
    final init = _modelsInitFuture;
    if (init != null) await init;
    if (forceReload) {
      _asrFilesReady = false;
      _ttsModelReady = false;
      await _waitForNativeWorkBeforeModelReset();
      await _models.clearModels();
    }
    await _startBackgroundDownloadGuard();
    // Временно включить лог только для прогресса загрузки, не сохраняя в prefs.
    final prevLog = _logLevel;
    setState(() {
      if (_logLevel < 1) _logLevel = 1;
      _status = 'Загрузка нейромоделей…';
    });
    try {
      await _models.ensureModels(voiceId: _voiceId);
    } finally {
      await _stopBackgroundDownloadGuard();
    }
    // Вернуть уровень лога, если включали только для прогресса.
    if (prevLog < 1 && _logLevel != prevLog) {
      if (mounted) {
        setState(() => _logLevel = prevLog);
      } else {
        _logLevel = prevLog;
      }
    }
    _asrFilesReady = _models.status.asrReady;
    if (mounted) {
      setState(() {
        _ttsModelReady = _models.status.ttsReady;
        _asrFilesReady = _models.status.asrReady;
        _status = _models.status.error.isNotEmpty
            ? _models.status.error
            : (_models.status.ttsReady && _models.status.asrReady
                ? 'Модели готовы (ASR-файлы ✓ · TTS ✓, ASR Session загружается в фоне)'
                : _models.status.progressText);
      });
    }
    if (_ttsModelReady && !_browserMode) _scheduleNeuralIdleWork();
  }

  Future<void> _loadAsrSession() {
    if (_asrModelReady) return Future<void>.value();
    final running = _asrLoadFuture;
    if (running != null) return running;
    final future = _loadAsrSessionImpl();
    _asrLoadFuture = future;
    return future.whenComplete(() {
      if (identical(_asrLoadFuture, future)) _asrLoadFuture = null;
    });
  }

  Future<void> _loadAsrSessionImpl() async {
    try {
      await _models.refreshReady(voiceId: _voiceId);
      var onnx = await _models.asrOnnxFile();
      var vocab = await _models.asrVocabFile();
      if (onnx == null || vocab == null) {
        // Модели на диске есть, но runtime не заполнен — ensureModels.
        if (!_models.status.asrReady) {
          await _models.ensureModels(voiceId: _voiceId, asr: true, tts: false);
        } else {
          await _models.refreshReady(voiceId: _voiceId);
        }
        onnx = await _models.asrOnnxFile();
        vocab = await _models.asrVocabFile();
      }
      if (onnx == null || vocab == null) {
        throw StateError(
          'ASR files not found (Zipformer). Проверьте папку моделей / кнопку «Перезагрузить нейромодели».',
        );
      }
      _logMsg('ASR: загрузка Zipformer FR…');
      _logMsg('  enc=${onnx.path}', level: 2);
      _logMsg('  tok=${vocab.path}', level: 2);
      await _asr.load(onnxPath: onnx.path, vocabPath: vocab.path);
      _asrModelReady = true;
      _logMsg('✓ ASR Zipformer FR готов');
    } catch (e) {
      _asrModelReady = false;
      _logMsg('ASR Session error: $e');
    }
    if (mounted) setState(() {});
  }


  /// Windows: sherpa (Piper) и onnxruntime_v2 (ASR) делят ORT DLL.
  /// Параллельная работа часто роняет process (API version mismatch).
  /// Перед тяжёлым Piper временно гасим ASR Session.
  Future<T> _withKokoroExclusive<T>(Future<T> Function() body) async {
    final needAsrRestore = Platform.isWindows && (_asrModelReady || _asrLoadFuture != null);
    if (needAsrRestore) {
      try {
        await _asrLoadFuture;
      } catch (_) {}
      try {
        await _asr.dispose();
      } catch (_) {}
      _asrModelReady = false;
      _asrLoadFuture = null;
      if (mounted) setState(() {});
    }
    try {
      return await body();
    } finally {
      // ASR намеренно НЕ поднимаем здесь.
      // Session нужна только перед сравнением после записи с микрофона —
      // иначе на Windows конфликтует ORT с Piper при листании фраз.
    }
  }

  Future<void> _persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_phrasesKey, _phrases.map((e) => e.text).join('\n'));
    await p.setInt(_posKey, _index);
    await p.setString(_modeKey, _browserMode ? 'browser' : 'neural');
    await p.setBool(_pasteSkipDupKey, _pasteSkipDuplicates);
    await p.setDouble(_listenRateKey, _listenRate);
    await p.setDouble(_neuralRateKey, _neuralRate);
    await p.setBool(_neuralRateLockKey, _neuralRateLocked);
    await p.setString(_splitKey, '0');
    await p.setString(_autoPlayRecKey, _autoPlayRecorded ? '1' : '0');
    await p.setString(_analysisStyleKey, _analysisSimple ? 'simple' : 'detail');
    await p.setString(_diffKey, _difficulty);
    await p.setString(_compareKey, _compareUnit);
    await p.setString(_keepKey, _neuralKeep);
    await p.setDouble(_micSensKey, _micSens);
    await p.setDouble(_recordGainKey, _recordGain);
    await p.setString(_micAgcKey, _micAgc ? '1' : '0');
    await p.setBool(_beepKey, _recordBeep);
    await p.setString(_asrVolKey, _asrVolumeMatch ? '1' : '0');
    await p.setInt(_logKey, _logLevel);
    await p.setString(_voiceKey, _voiceId);
  }

  _Phrase get _current =>
      _phrases.isEmpty ? _Phrase('') : _phrases[_index.clamp(0, _phrases.length - 1)];

  void _logMsg(String s, {int level = 1}) {
    if (_logLevel < level) return;
    _log.add(s);
    if (_log.length > 200) _log.removeAt(0);
    if (mounted) setState(() => _logLine = s);
  }

  Future<CachedWav?> _loadRamOrDiskCache({required String text}) async {
    final key = _audioCache.key(
      text: text,
      voiceId: _voiceId,
      speed: _neuralRate,
      splitPattern: _useSplitPattern,
    );
    final ram = _ramAudioCache[key];
    if (ram != null) return ram;
    final file = await _audioCache.get(
      text: text,
      voiceId: _voiceId,
      speed: _neuralRate,
      splitPattern: _useSplitPattern,
    );
    if (file == null) return null;
    // В режиме «Все» на диске может лежать весь курс. Не декодируем WAV
    // в PCM при проверке кэша: это лишняя память и лишняя работа. В RAM
    // читаем только текущую/следующую фразу, остальные читаются при Play.
    if (!_allowedRamCacheKeys().contains(key)) return null;
    final wav = await _audioCache.read(file);
    _ramAudioCache[key] = wav;
    return wav;
  }

  Set<String> _allowedRamCacheKeys() {
    if (_phrases.isEmpty) return <String>{};
    final ids = <int>{_index};
    if (_phrases.length > 1) ids.add((_index + 1) % _phrases.length);
    return ids
        .map((i) => _audioCache.key(
              text: _phrases[i].text.trim(),
              voiceId: _voiceId,
              speed: _neuralRate,
              splitPattern: _useSplitPattern,
            ))
        .whereType<String>()
        .toSet();
  }

  Set<String> _allowedCacheKeys() {
    if (_phrases.isEmpty) return <String>{};
    if (_neuralKeep == 'all') {
      return _phrases
          .map((p) => _audioCache.key(
                text: p.text.trim(),
                voiceId: _voiceId,
                speed: _neuralRate,
                splitPattern: _useSplitPattern,
              ))
          .whereType<String>()
          .toSet();
    }
    final ids = <int>{_index, (_index + 1) % _phrases.length};
    return ids
        .map((i) => _audioCache.key(
              text: _phrases[i].text.trim(),
              voiceId: _voiceId,
              speed: _neuralRate,
              splitPattern: _useSplitPattern,
            ))
        .whereType<String>()
        .toSet();
  }

  void _pruneRamCache() {
    // Политика «Все» относится к диску, а не к оперативной памяти.
    final allowed = _allowedRamCacheKeys();
    _ramAudioCache.removeWhere((key, _) => !allowed.contains(key));
  }

  Future<void> _refreshNeuralIndicators() async {
    final request = ++_indicatorToken;
    if (_browserMode || _phrases.isEmpty) {
      if (!mounted) return;
      setState(() {
        _curInd = '—'; _nextInd = '—';
        _curIndColor = _muted; _nextIndColor = _muted;
      });
      return;
    }

    final texts = <String>[_current.text.trim()];
    if (_phrases.length > 1) {
      texts.add(_phrases[(_index + 1) % _phrases.length].text.trim());
    }
    final states = <String>[];
    for (final text in texts) {
      final key = _audioCache.key(
        text: text, voiceId: _voiceId, speed: _neuralRate,
        splitPattern: _useSplitPattern,
      );
      if (_generationFutures.containsKey(key)) {
        states.add('⏳ …');
        continue;
      }
      if (_ramAudioCache.containsKey(key)) {
        states.add('✓ готов');
        continue;
      }
      final file = await _audioCache.get(
        text: text, voiceId: _voiceId, speed: _neuralRate,
        splitPattern: _useSplitPattern,
      );
      states.add(file != null ? '✓ готов' : '—');
      if (request != _indicatorToken) return;
    }
    while (states.length < 2) states.add('—');
    if (!mounted || request != _indicatorToken) return;
    setState(() {
      _curInd = states[0];
      _nextInd = states[1];
      _curIndColor = states[0].startsWith('✓') ? _ok : states[0].startsWith('⏳') ? _accent : _muted;
      _nextIndColor = states[1].startsWith('✓') ? _ok : states[1].startsWith('⏳') ? _accent : _muted;
    });
  }

  bool _canBackgroundPrefetch() {
    // TTS generation lives in the dedicated Piper worker. Playback, recording,
    // ASR comparison and Auto are independent UI/native jobs and must not
    // prevent the worker from preparing the next phrase.
    return mounted &&
        !_browserMode &&
        _ttsModelReady &&
        !_models.status.downloading &&
        _phrases.isNotEmpty;
  }

  void _scheduleAsrIdleLoad() {
    // ASR не предзагружаем в idle и не при листании фраз.
    // ONNX Session поднимается только перед анализом записи (после микрофона).
    _asrPrepareTimer?.cancel();
    _asrPrepareTimer = null;
  }

  void _scheduleNeuralIdleWork() {
    _neuralPrepareTimer?.cancel();
    _neuralPrepareTimer = null;
    _idlePrefetchTimer?.cancel();
    _idlePrefetchTimer = null;
    final token = _phraseGenerationToken;
    if (_browserMode || !_ttsModelReady || _phrases.isEmpty) return;

    // В Auto генерация должна идти независимо от воспроизведения/записи,
    // поэтому запускаем подготовку сразу. В ручной навигации оставляем
    // короткий debounce, чтобы быстрый скролл не создавал лишние запросы.
    if (_autoRunning) {
      unawaited(_runIdlePrefetch(token));
      return;
    }
    _neuralPrepareTimer = Timer(const Duration(seconds: 1), () {
      if (token != _phraseGenerationToken || !_canBackgroundPrefetch()) return;
      unawaited(_runIdlePrefetch(token));
    });
  }

  Future<void> _runIdlePrefetch(int token) async {
    if (_prefetchRunning || token != _phraseGenerationToken || !_canBackgroundPrefetch()) return;
    _prefetchRunning = true;
    try {
      await _applyCachePolicy();
      if (token != _phraseGenerationToken || !_canBackgroundPrefetch()) return;
      // Сначала всегда текущая и следующая. Это нужно даже в режиме «Все».
      final first = _index;
      await _ensureCachedPhrase(first, background: false, token: token);
      if (token != _phraseGenerationToken || !_canBackgroundPrefetch()) return;
      if (_phrases.length > 1) {
        // Пауза между native generate — снижает ORT/Piper race на Windows.
        // На объём RAM не влияет: по-прежнему только текущая + следующая в этом шаге.
        if (Platform.isWindows) {
          await Future<void>.delayed(const Duration(milliseconds: 450));
          if (token != _phraseGenerationToken || !_canBackgroundPrefetch()) return;
        }
        await _ensureCachedPhrase((_index + 1) % _phrases.length, background: true, token: token);
      }

      // «Все»: последовательно создаём WAV для всего списка. Сами PCM
      // не накапливаем в RAM — остаются только текущая и следующая фразы.
      if (_neuralKeep == 'all' && token == _phraseGenerationToken) {
        for (var step = 2; step < _phrases.length; step++) {
          if (token != _phraseGenerationToken || !_canBackgroundPrefetch()) return;
          final idx = (_index + step) % _phrases.length;
          await _ensureCachedPhrase(idx, background: true, token: token);
        }
        if (token == _phraseGenerationToken) {
          await _shutdownPiperAfterAllCached(token);
        }
      }
    } finally {
      _prefetchRunning = false;
      if (mounted && token == _phraseGenerationToken) {
        unawaited(_refreshNeuralIndicators());
        _scheduleAsrIdleLoad();
      }
    }
  }

  Future<void> _shutdownPiperAfterAllCached(int token) async {
    if (token != _phraseGenerationToken || _neuralKeep != 'all') return;
    // Не выгружаем TTS, пока ещё идёт генерация или пользователь уже сменил
    // список/голос/режим. Проверяем только наличие файлов, не читаем WAV в RAM.
    for (final phrase in _phrases) {
      final file = await _audioCache.get(
        text: phrase.text.trim(), voiceId: _voiceId,
        speed: _neuralRate, splitPattern: _useSplitPattern,
      );
      if (file == null) return;
    }
    if (token != _phraseGenerationToken || _generationFutures.isNotEmpty) return;
    await _kokoro.dispose();
    _logMsg('TTS выгружен: WAV всех ${_phrases.length} фраз сохранены на диске');
  }

  Future<void> _applyCachePolicy() async {
    _pruneRamCache();
    if (_phrases.isEmpty) return;
    if (_neuralKeep == 'pair') {
      await _audioCache.pruneToKeys(_allowedCacheKeys());
      _pruneRamCache();
      await _refreshAudioCacheStats();
    } else {
      // В режиме «Все» сохраняем WAV всего списка на диске; PCM в RAM
      // ограничен текущей парой. Генерация выполняется последовательно ниже.
    }
  }

  Future<void> _prepareNeuralCache({int? token}) async {
    // Старые вызовы из UI/настроек оставляем совместимыми, но они больше
    // не имеют права запускать весь список. Фактическая работа — через idle.
    if (token != null && token != _phraseGenerationToken) return;
    _scheduleNeuralIdleWork();
  }

  Future<File?> _ensureCachedPhrase(int idx, {bool background = false, int? token}) async {
    if (_browserMode || !_ttsModelReady || _phrases.isEmpty) return null;
    final generationToken = token ?? _phraseGenerationToken;
    final cacheEpoch = _cacheEpoch;
    if (generationToken != _phraseGenerationToken) return null;
    final text = _phrases[idx].text.trim();
    if (text.isEmpty) return null;
    final voiceId = _voiceId;
    final speed = _neuralRate;
    final splitPattern = _useSplitPattern;
    final key = _audioCache.key(text: text, voiceId: voiceId, speed: speed, splitPattern: splitPattern);
    final existingFuture = _generationFutures[key];
    if (existingFuture != null) {
      if (!background) await existingFuture;
      return existingFuture;
    }

    final existingFile = await _audioCache.get(
      text: text, voiceId: voiceId, speed: speed, splitPattern: splitPattern,
    );
    if (generationToken != _phraseGenerationToken ||
        cacheEpoch != _cacheEpoch || voiceId != _voiceId ||
        speed != _neuralRate || splitPattern != _useSplitPattern) {
      return null;
    }
    if (existingFile != null) {
      // Существующий WAV — готовый результат. Не загружаем его PCM в память
      // при фоновой проверке; Play сам прочитает текущую фразу при необходимости.
      if (_allowedRamCacheKeys().contains(key)) {
        await _loadRamOrDiskCache(text: text);
      }
      await _refreshNeuralIndicators();
      return existingFile;
    }

    final Future<File?> future = () async {
      if (mounted) setState(() {
        if (idx == _index) { _curInd = '⏳ …'; _curIndColor = _accent; }
        if (idx == (_index + 1) % _phrases.length) { _nextInd = '⏳ …'; _nextIndColor = _accent; }
      });
      try {
        _logMsg('${background ? 'фон' : 'текущая'}: генерирую «$text»');
        final modelDir = await _models.sherpaTtsModelDir();
        final t0 = DateTime.now();
        final samples = await _withKokoroExclusive(
          () => _enqueueKokoro(() => _kokoro.synthesize(
            text: text, modelDir: modelDir.path, speed: speed,
            voiceId: voiceId, useSplitPattern: splitPattern,
          )),
        );
        // Если пользователь успел перелистнуть фразы, не превращаем старый
        // результат в «готовый» для новой пары и не раздуваем кэш.
        final stillRelevant = _allowedCacheKeys().contains(key);
        if (cacheEpoch != _cacheEpoch ||
            !stillRelevant ||
            voiceId != _voiceId ||
            speed != _neuralRate ||
            splitPattern != _useSplitPattern) {
          _logMsg('TTS результат устарел — не сохраняю «$text»', level: 2);
          return null;
        }
        final file = await _audioCache.put(
          text: text, voiceId: voiceId, speed: speed,
          splitPattern: splitPattern, samples: samples, sampleRate: 16000,
        );
        if (_allowedRamCacheKeys().contains(key)) {
          _ramAudioCache[key] = CachedWav(samples, 16000);
        }
        _logMsg('CACHE STORE: «$text» · ${(DateTime.now().difference(t0).inMilliseconds / 1000).toStringAsFixed(1)} s');
        await _refreshAudioCacheStats();
        return file;
      } catch (e) {
        _logMsg('CACHE generation error: $e');
        return null;
      } finally {
        _generationFutures.remove(key);
        _pruneRamCache();
        await _refreshNeuralIndicators();
      }
    }();
    _generationFutures[key] = future;
    return future;
  }

  int _autoPauseMs(String text) {
    final words =
        text.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
    double sec;
    if (words <= 3) {
      sec = 0.7;
    } else if (words >= 20) {
      sec = 6;
    } else {
      sec = 0.7 + (words - 3) * (5.3 / 17);
    }
    sec = (sec * 10).round() / 10;
    return (sec * 1000).round();
  }

  Future<bool> _sleepMs(int ms) async {
    final step = 100;
    var left = ms;
    while (left > 0) {
      if (_autoStopRequested) return false;
      final d = left > step ? step : left;
      await Future<void>.delayed(Duration(milliseconds: d));
      left -= d;
    }
    return !_autoStopRequested;
  }

  Future<void> _speakBrowser(String text) async {
    if (text.isEmpty) return;
    final stop = _stopFuture;
    if (stop != null) { try { await stop; } catch (_) {} }
    setState(() {
      _ttsActive = true;
      _ttsPaused = false;
      _status = 'eSpeak…';
    });

    // Сначала eSpeak (французский offline), иначе системный FlutterTts.
    final viaEspeak = await _speakViaEspeak(text);
    if (!viaEspeak) {
      if (mounted) setState(() => _status = 'Браузерный TTS…');
      try {
        await _ttsEngine.setSpeechRate((_listenRate * 0.55).clamp(0.2, 0.9));
        await _ttsEngine.setLanguage('fr-FR');
      } catch (_) {}
      try {
        await _ttsEngine.speak(text);
      } catch (e) {
        _logMsg('FlutterTts: $e', level: 2);
      }
    }

    if (mounted) {
      setState(() {
        _ttsActive = false;
        _status = '';
      });
    }
  }

  /// Озвучка через eSpeak NG (-v fr). true = удалось.
  Future<bool> _speakViaEspeak(String text) async {
    final exe = _espeakExecutableCandidates();
    // eSpeak по умолчанию ~175 wpm — слишком быстро; держим 75–130.
    // -p: чуть ниже тон, меньше «писка».
    final wpm = (75 + (_listenRate * 55)).round().clamp(70, 130);
    final pitch = 42; // 0..99, default 50
    for (final path in exe) {
      try {
        await _killEspeakSpeak();
        final proc = await Process.start(
          path,
          ['-v', 'fr', '-s', '$wpm', '-p', '$pitch', text],
          runInShell: false,
        );
        _espeakSpeakProc = proc;
        // Глотаем stdout/stderr, чтобы буфер не забивался
        proc.stdout.drain();
        proc.stderr.drain();
        final code = await proc.exitCode.timeout(
          const Duration(minutes: 2),
          onTimeout: () {
            proc.kill();
            return -1;
          },
        );
        if (identical(_espeakSpeakProc, proc)) _espeakSpeakProc = null;
        if (code == 0) return true;
      } catch (_) {
        /* следующий кандидат */
      }
    }
    return false;
  }

  List<String> _espeakExecutableCandidates() {
    return <String>[
      if (Platform.isWindows) ...[
        r'C:\Program Files\eSpeak NG\espeak-ng.exe',
        r'C:\Program Files (x86)\eSpeak NG\espeak-ng.exe',
        r'C:\Program Files\eSpeak\command_line\espeak.exe',
      ],
      'espeak-ng',
      'espeak',
    ];
  }

  Future<bool> _isEspeakAvailable() async {
    for (final path in _espeakExecutableCandidates()) {
      if (path.contains('\\') || path.contains('/') || path.endsWith('.exe')) {
        if (await File(path).exists()) return true;
      } else {
        try {
          final r = await Process.run(
            Platform.isWindows ? 'where' : 'which',
            [path],
            runInShell: false,
          ).timeout(const Duration(seconds: 2));
          if (r.exitCode == 0 && '${r.stdout}'.trim().isNotEmpty) return true;
        } catch (_) {}
      }
    }
    // where may miss; try running --version on path names
    for (final path in _espeakExecutableCandidates()) {
      try {
        final r = await Process.run(
          path,
          ['--version'],
          runInShell: false,
        ).timeout(const Duration(seconds: 3));
        if (r.exitCode == 0) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _openExternalUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url], runInShell: false);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
    } catch (e) {
      _logMsg('open url: $e', level: 2);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Откройте вручную: $url')),
        );
      }
    }
  }

  /// Один раз за жизнь установок: если eSpeak нет — предложить скачать.
  Future<void> _maybePromptEspeakDownload() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_espeakPromptKey) == true) return;
      await prefs.setBool(_espeakPromptKey, true);
      final has = await _isEspeakAvailable();
      if (has || !mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          title: const Text('eSpeak NG', style: TextStyle(color: _text)),
          content: const Text(
            'Для французской озвучки в режиме «Браузерный» и для IPA '
            'рекомендуется установить eSpeak NG (бесплатно, offline).\n\n'
            'Без него используется системный голос Windows (часто хуже для французского).',
            style: TextStyle(color: _muted, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Позже'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _openExternalUrl(_espeakDownloadUrl);
              },
              child: const Text('Скачать'),
            ),
          ],
        ),
      );
    } catch (e) {
      _logMsg('espeak prompt: $e', level: 2);
    }
  }


  Future<void> _killEspeakSpeak() async {
    final p = _espeakSpeakProc;
    _espeakSpeakProc = null;
    if (p == null) return;
    try {
      p.kill();
    } catch (_) {}
    try {
      await p.exitCode.timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  Future<void> _stopSpeak() async {
    await _killEspeakSpeak();
    try {
      await _ttsEngine.stop();
    } catch (_) {}
    if (mounted) setState(() => _ttsActive = false);
  }

  Future<void> _toggleSpeechPlayback() async {
    if (!_ttsActive) return;
    try {
      if (_browserMode) {
        if (_ttsPaused) {
          _ttsPaused = false;
          // Повтор фразы (eSpeak не умеет resume с середины).
          unawaited(_speakBrowser(_current.text));
        } else {
          await _killEspeakSpeak();
          try { await _ttsEngine.pause(); } catch (_) {}
          try { await _ttsEngine.stop(); } catch (_) {}
          _ttsPaused = true;
          if (mounted) setState(() {
            _ttsActive = false;
            _status = 'Пауза';
          });
        }
      } else {
        if (_playbackEngine.playing) {
          await _playbackEngine.pause();
          _ttsPaused = true;
          if (mounted) setState(() => _status = 'Пауза');
        } else {
          _ttsPaused = false;
          await _playbackEngine.play();
          if (mounted) setState(() => _status = 'Нейро TTS…');
        }
      }
    } catch (e) {
      _logMsg('pause/resume: $e', level: 2);
    }
  }

  Future<bool> _playNeural() async {
    if (_ttsActive) return false;
    final init = _modelsInitFuture;
    if (init != null) await init;
    if (_browserMode) return false;
    if (!_ttsModelReady) {
      if (mounted) setState(() => _status = 'Нейро-модель ещё не готова');
      return false;
    }
    final text = _current.text.trim();
    if (text.isEmpty) return false;
    final stop = _stopFuture;
    if (stop != null) { try { await stop; } catch (_) {} }

    setState(() { _ttsActive = true; _ttsPaused = false; _status = 'Нейро TTS…'; });
    final key = _audioCache.key(text: text, voiceId: _voiceId, speed: _neuralRate, splitPattern: _useSplitPattern);
    try {
      CachedWav? cached = _ramAudioCache[key];
      if (cached != null) {
        _logMsg('CACHE HIT RAM: «$text»');
      } else {
        cached = await _loadRamOrDiskCache(text: text);
        if (cached != null) _logMsg('CACHE HIT DISK → RAM: «$text»');
      }
      if (cached == null) {
        final file = await _ensureCachedPhrase(_index);
        if (file == null) return false;
        cached = _ramAudioCache[key] ?? await _loadRamOrDiskCache(text: text);
        if (cached == null) throw StateError('Кэш создан, но аудио не прочиталось');
      }

      _neuralReference16k = _resample(cached.samples, cached.sampleRate, 16000);
      _lastRefAsr = null; _lastRefAsrAudio = null;
      _lastMineAsr = null; _lastMineAsrAudio = null;
      _analysisResult = '';
      // preAnalyze только после микрофона, не при прослушивании эталона.

      // В RAM уже лежит PCM — никаких повторных чтений диска и генерации перед Play.
      final wav = KokoroEngine.floatToWav(cached.samples, sampleRate: cached.sampleRate);
      // Воспроизводим прямо из RAM-кэша. Файл kokoro_play_*.wav больше не
      // создаётся перед каждым нажатием — это убирает лишнюю задержку.
      await _playbackEngine.stop();
      await _playbackEngine.setAudioSource(_MemoryWavSource(wav));
      await _playbackEngine.setVolume(1.0);
      // Listen speed is playback-only: it does not change the generated/cache
      // variant. just_audio/ExoPlayer keeps pitch at the normal playback pitch.
      await _playbackEngine.setSpeed(_listenRate);
      await _playbackEngine.play();
      await _playbackEngine.playerStateStream.firstWhere((s) =>
        s.processingState == ProcessingState.completed || s.processingState == ProcessingState.idle,
      ).timeout(const Duration(seconds: 120), onTimeout: () => _playbackEngine.playerState);
      if (mounted) setState(() => _status = 'Нейро TTS ✓');
      return true;
    } catch (e, st) {
      _logMsg('Piper error: $e');
      _logMsg('$st', level: 2);
      if (mounted) setState(() => _status = 'Нейро TTS ошибка: $e');
      return false;
    } finally {
      if (mounted) setState(() { _ttsActive = false; _ttsPaused = false; });
    }
  }

  /// Сигнал перед записью — assets/blim.wav.
  Future<void> _playBeep() async {
    try {
      await _beepEngine.stop();
      final bytes = await rootBundle.load('assets/blim.wav');
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/blim_beep_fr.wav';
      await File(path).writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: true,
      );
      await _beepEngine.setFilePath(path);
      await _beepEngine.setVolume(1.0);
      await _beepEngine.seek(Duration.zero);
      await _beepEngine.play();
      await _beepEngine.playerStateStream
          .firstWhere(
            (st) =>
                st.processingState == ProcessingState.completed ||
                st.processingState == ProcessingState.idle,
          )
          .timeout(const Duration(seconds: 3), onTimeout: () => _beepEngine.playerState);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    } catch (e) {
      _logMsg('beep: $e', level: 2);
      try {
        SystemSound.play(SystemSoundType.alert);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  /// Колокольчик: фундаментала + обертоны с экспоненциальным затуханием.
  Uint8List _makeBellWav() {
    const sampleRate = 22050;
    final samples = <int>[];
    void chime(List<double> partials, int ms, double vol) {
      final n = (sampleRate * ms / 1000).round();
      for (var i = 0; i < n; i++) {
        final t = i / sampleRate;
        final env = math.exp(-t * 4.5) * (1 - math.exp(-t * 80));
        var s = 0.0;
        for (var p = 0; p < partials.length; p++) {
          final amp = 1.0 / (p + 1);
          s += math.sin(2 * math.pi * partials[p] * t) * amp;
        }
        final v = (s * vol * env * 28000).round();
        samples.add(v.clamp(-32768, 32767));
      }
    }
    // два удара «колокольчика»
    chime([1046.5, 2093.0, 3139.5], 280, 0.85); // C6
    for (var i = 0; i < (sampleRate * 0.08).round(); i++) {
      samples.add(0);
    }
    chime([784.0, 1568.0, 2352.0], 420, 0.7); // G5

    final dataSize = samples.length * 2;
    final bytes = BytesBuilder();
    void u32(int v) {
      bytes.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    }
    void u16(int v) {
      bytes.add([v & 0xff, (v >> 8) & 0xff]);
    }
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
      final v = s < 0 ? s + 65536 : s;
      bytes.add([v & 0xff, (v >> 8) & 0xff]);
    }
    return bytes.toBytes();
  }

  /// VAD: ждём начало речи, пишем, режем по тишине ~1.2 с.
  Future<bool> _runRecordingSession({required bool auto}) async {
    if (_recording) return false;
    try {
      final hasPerm = await _rec.hasPermission();
      if (!hasPerm) {
        setState(() => _recStatus = 'Нет доступа к микрофону');
        return false;
      }

      final needBeep = auto || _recordBeep;
      if (needBeep) {
        setState(() => _recStatus = 'Сигнал…');
        await _playBeep();
        if (_autoStopRequested) return false;
      }

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/pron_rec_${DateTime.now().millisecondsSinceEpoch}.wav';

      setState(() {
        _recording = true;
        _recStatus = 'Жду голос…';
        _micTestHint = 'Жду голос…';
        _recPeakDb = -160;
        _liveLevel = -160;
      });

      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );

      // Порог: при чувствительности 1.0 ≈ -28 dB, при 0.0 ≈ -12 dB (строже = тише игнор)
      // Порог начала записи: 100% → легче ловит речь (−48 dB); 0% → только громкая (−12 dB)
      final thresholdDb = -48 + (1.0 - _micSens) * 36;
      const silenceMs = 1200;
      const preRollMs = 12000;
      const maxMs = 45000;

      var speechStarted = false;
      var lastSpeechAt = DateTime.now();
      final t0 = DateTime.now();

      final ampCompleter = Completer<void>();
      await _ampSub?.cancel();
      _ampSub = _rec
          .onAmplitudeChanged(const Duration(milliseconds: 80))
          .listen((amp) {
        if (!_recording || _autoStopRequested) return;
        final level = amp.current; // dBFS
        final now = DateTime.now();
        final elapsed = now.difference(t0).inMilliseconds;

        _liveLevel = level;
        if (level > _recPeakDb) _recPeakDb = level;
        if (level >= thresholdDb) {
          if (!speechStarted) {
            speechStarted = true;
            if (mounted) {
              setState(() {
                _recStatus = 'Запись… говорите';
                _micTestHint = 'Голос обнаружен';
              });
            }
          } else if (mounted) {
            // лёгкое обновление индикатора уровня
            setState(() {});
          }
          lastSpeechAt = now;
        }

        if (!speechStarted && elapsed > preRollMs) {
          // не дождались голоса
          if (!ampCompleter.isCompleted) ampCompleter.complete();
          return;
        }
        if (speechStarted &&
            now.difference(lastSpeechAt).inMilliseconds >= silenceMs) {
          if (!ampCompleter.isCompleted) ampCompleter.complete();
          return;
        }
        if (elapsed >= maxMs) {
          if (!ampCompleter.isCompleted) ampCompleter.complete();
        }
      });

      // fallback если amplitude stream не сработает
      final fallback = Future<void>.delayed(const Duration(milliseconds: maxMs));
      await Future.any([ampCompleter.future, fallback]);

      await _ampSub?.cancel();
      _ampSub = null;

      String? outPath;
      try {
        outPath = await _rec.stop();
      } catch (_) {}
      outPath ??= path;

      if (!speechStarted) {
        if (mounted) {
          setState(() {
            _recording = false;
            _recStatus = 'Голос не обнаружен';
          });
        }
        try {
          if (outPath != null) File(outPath).deleteSync();
        } catch (_) {}
        return false;
      }

      Float32List? recordedPcm;
      try {
        if (outPath != null && File(outPath).existsSync()) {
          recordedPcm = await _readWavPcm16(File(outPath));
          final before = recordedPcm.length;
          recordedPcm = _trimSilenceForAsr(recordedPcm);
          _logMsg(
            'PCM: ${(before / 16000).toStringAsFixed(2)} с → trim ${(recordedPcm.length / 16000).toStringAsFixed(2)} с · peak=${recordedPcm.isEmpty ? 0 : recordedPcm.map((e) => e.abs()).reduce((a, b) => a > b ? a : b).toStringAsFixed(3)}',
            level: 2,
          );
        }
      } catch (e) {
        _logMsg('ASR: чтение WAV: $e');
      }
      if (recordedPcm != null) {
        // Цифровой gain (особенно нужен на Windows).
        final g = _recordGain.clamp(0.5, 12.0);
        if ((g - 1.0).abs() > 0.01) {
          final boosted = Float32List(recordedPcm.length);
          for (var i = 0; i < recordedPcm.length; i++) {
            var s = recordedPcm[i] * g;
            if (s > 1.0) s = 1.0;
            if (s < -1.0) s = -1.0;
            boosted[i] = s;
          }
          recordedPcm = boosted;
        }
        _logMsg(
            'запись для ASR: ${(recordedPcm.length / 16000).toStringAsFixed(2)} с · gain×${g.toStringAsFixed(1)}',
            level: 2);
      }
      if (mounted) {
        setState(() {
          _recording = false;
          _lastRecordPath = outPath;
          _myAudio16k = recordedPcm;
          _lastMineAsr = null;
          _lastMineAsrAudio = null;
          _recStatus = recordedPcm != null ? '✓ записано · PCM 16 кГц' : '✓ записано';
        });
      }

      final forcePlay = auto || _autoPlayRecorded;
      if (forcePlay && outPath != null && File(outPath).existsSync()) {
        await _playMyRecording(outPath);
      }

      // ASR Session поднимается внутри _startAnalysis — не ждать _asrModelReady заранее.
      if (!_browserMode && _neuralReference16k != null && _myAudio16k != null) {
        await _startAnalysis();
      } else if (!_browserMode && _myAudio16k != null && _neuralReference16k == null) {
        _logMsg('ASR: нет эталона (сначала сгенерируйте/прослушайте нейро-фразу)', level: 1);
      }

      return true;
    } catch (e) {
      await _ampSub?.cancel();
      _ampSub = null;
      if (mounted) {
        setState(() {
          _recording = false;
          _recStatus = 'Ошибка записи: $e';
        });
      }
      _logMsg('rec: $e');
      return false;
    }
  }

  Future<void> _playMyRecording([String? path]) async {
    final p = path ?? _lastRecordPath;
    if (p == null || !File(p).existsSync()) {
      _logMsg('play mine: файл не найден');
      return;
    }
    setState(() {
      _playingMine = true;
      _recStatus = '▶️ играет…';
    });
    try {
      await _playbackEngine.stop();
      await _playbackEngine.setFilePath(p);
      // «Я» всегда воспроизводится в исходной скорости записи.
      // Ползунок «Скорость прослушивания» относится только к эталонному
      // аудио: в браузерном режиме — к системному TTS, в нейро-режиме —
      // к сгенерированному нейро-аудио. Запись пользователя не ускоряем.
      await _playbackEngine.setSpeed(1.0);
      // Громкость «Я»: нормальная; AGC только слегка выравнивает очень тихие/громкие
      var boost = 1.0;
      if (_micAgc) {
        final peak = _recPeakDb;
        if (peak > -6) {
          boost = 0.7; // чуть тише, если запись очень громкая
        } else if (peak < -32) {
          boost = 1.45; // чуть громче, если запись тихая
        } else if (peak < -22) {
          boost = 1.2;
        }
      }
      await _playbackEngine.setVolume(boost);
      _logMsg(
          'Я vol=${boost.toStringAsFixed(2)} peak=${_recPeakDb.toStringAsFixed(1)}dB agc=$_micAgc',
          level: 2);
      await _playbackEngine.play();
      await _playbackEngine.playerStateStream.firstWhere(
        (s) =>
            s.processingState == ProcessingState.completed ||
            s.processingState == ProcessingState.idle,
      ).timeout(const Duration(seconds: 60), onTimeout: () {
        return _playbackEngine.playerState;
      });
    } catch (e) {
      _logMsg('play mine: $e');
      if (mounted) setState(() => _recStatus = 'Ошибка воспроизведения');
    } finally {
      if (mounted) {
        setState(() {
          _playingMine = false;
          if (_recStatus.startsWith('▶️')) _recStatus = '✓';
        });
      }
    }
  }

  Widget _levelBar() {
    // dBFS обычно -60..0; нормируем в 0..1
    final n = ((_liveLevel + 55) / 55).clamp(0.0, 1.0);
    final color = n > 0.7
        ? _ok
        : (n > 0.35 ? const Color(0xFFE6B422) : _muted);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _recording ? n : 0,
            minHeight: 8,
            backgroundColor: const Color(0xFF2A2A3A),
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _recording
              ? 'Уровень: ${_liveLevel.isFinite ? _liveLevel.toStringAsFixed(0) : "—"} dB · пик ${_recPeakDb.toStringAsFixed(0)}'
              : (_micTestHint.isEmpty ? ' ' : _micTestHint),
          style: const TextStyle(color: _muted, fontSize: 11),
        ),
      ],
    );
  }

  Future<void> _stopRecording() async {
    if (!_recording) return;
    setState(() => _recording = false);
    await _ampSub?.cancel();
    _ampSub = null;
    try {
      final p = await _rec.stop();
      if (p != null) {
        _lastRecordPath = p;
        try {
          final raw = await _readWavPcm16(File(p));
          final before = raw.length;
          _myAudio16k = _trimSilenceForAsr(raw);
          _logMsg(
            'запись для ASR: ${(before / 16000).toStringAsFixed(2)}→${(_myAudio16k!.length / 16000).toStringAsFixed(2)} с после trim',
            level: 2,
          );
          _lastMineAsr = null;
          _lastMineAsrAudio = null;
          _recStatus = '✓ записано · PCM 16 кГц';
          if (!_browserMode && _neuralReference16k != null && _myAudio16k != null) {
            await _startAnalysis();
          }
        } catch (e) {
          _logMsg('ASR: чтение WAV: $e');
        }
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }


  static const _arpabet = {
    'AA': 'ɑ', 'AE': 'æ', 'AH': 'ə', 'AO': 'ɔ', 'AW': 'aʊ', 'AY': 'aɪ',
    'EH': 'ɛ', 'ER': 'ɝ', 'EY': 'eɪ', 'IH': 'ɪ', 'IY': 'i', 'OW': 'oʊ',
    'OY': 'ɔɪ', 'UH': 'ʊ', 'UW': 'u',
    'B': 'b', 'CH': 'tʃ', 'D': 'd', 'DH': 'ð', 'F': 'f', 'G': 'ɡ', 'HH': 'h',
    'JH': 'dʒ', 'K': 'k', 'L': 'l', 'M': 'm', 'N': 'n', 'NG': 'ŋ', 'P': 'p',
    'R': 'ɹ', 'S': 's', 'SH': 'ʃ', 'T': 't', 'TH': 'θ', 'V': 'v', 'W': 'w',
    'Y': 'j', 'Z': 'z', 'ZH': 'ʒ',
  };

  String _arpabetToIpa(String pron) {
    final tokens = pron.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty);
    final out = <String>[];
    for (final token in tokens) {
      final m = RegExp(r'^([A-Z]+)([012]?)$').firstMatch(token);
      if (m == null || !_arpabet.containsKey(m.group(1))) return pron;
      final base = m.group(1)!;
      final digit = m.group(2) ?? '';
      var ipa = _arpabet[base]!;
      if (base == 'AH' && digit == '1') ipa = 'ʌ';
      if (base == 'ER' && digit == '0') ipa = 'ɚ';
      if (base == 'ER' && digit == '1') ipa = 'ɝ';
      if (digit == '1') out.add('ˈ');
      if (digit == '2') out.add('ˌ');
      out.add(ipa);
    }
    return out.join();
  }

  Float32List _resample(Float32List input, int from, int to) {
    if (input.isEmpty || from == to) return input;
    final n = math.max(1, (input.length * to / from).round()).toInt();
    final out = Float32List(n);
    final scale = from / to;
    for (var i = 0; i < n; i++) {
      final pos = i * scale;
      final a = pos.floor().clamp(0, input.length - 1).toInt();
      final b = math.min(a + 1, input.length - 1).toInt();
      final f = pos - a;
      out[i] = input[a] * (1 - f) + input[b] * f;
    }
    return out;
  }

  Future<Float32List> _readWavPcm16(File file) async {
    final b = await file.readAsBytes();
    if (b.length < 44 || String.fromCharCodes(b.sublist(0, 4)) != 'RIFF') {
      throw StateError('не WAV PCM');
    }
    final bd = ByteData.sublistView(b);
    var pos = 12;
    var channels = 1;
    var sampleRate = 16000;
    var bits = 16;
    var dataStart = -1, dataLen = 0;
    while (pos + 8 <= b.length) {
      final id = String.fromCharCodes(b.sublist(pos, pos + 4));
      final len = bd.getUint32(pos + 4, Endian.little);
      final start = pos + 8;
      if (id == 'fmt ' && len >= 16 && start + 16 <= b.length) {
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
    if (dataStart < 0 || bits != 16 || channels < 1) {
      throw StateError('неподдерживаемый WAV: channels=$channels bits=$bits');
    }
    final frames = dataLen ~/ (2 * channels);
    final mono = Float32List(frames);
    for (var i = 0; i < frames; i++) {
      var sum = 0.0;
      for (var c = 0; c < channels; c++) {
        final off = dataStart + (i * channels + c) * 2;
        sum += bd.getInt16(off, Endian.little) / 32768.0;
      }
      mono[i] = sum / channels;
    }
    var out = _resample(mono, sampleRate, 16000);
    // Windows: системный mic часто даёт очень тихий PCM — поднимаем пик ~0.7
    if (Platform.isWindows && out.isNotEmpty) {
      var peak = 0.0;
      for (final v in out) {
        final a = v.abs();
        if (a > peak) peak = a;
      }
      if (peak > 1e-6 && peak < 0.35) {
        final g = 0.7 / peak;
        final boosted = Float32List(out.length);
        for (var i = 0; i < out.length; i++) {
          final x = out[i] * g;
          boosted[i] = x.clamp(-1.0, 1.0);
        }
        out = boosted;
      }
    }
    return out;
  }

  AsrResult? _lastRefAsr;
  AsrResult? _lastMineAsr;
  Float32List? _lastRefAsrAudio;
  Float32List? _lastMineAsrAudio;

  DifficultyConfig _difficultyConfig() => DifficultyConfig.of(_difficulty);

  /// Нормализация французского слова для сравнения.
  String _normFrWord(String w) {
    return w
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll('`', "'")
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('ä', 'a')
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('ë', 'e')
        .replaceAll('ï', 'i')
        .replaceAll('î', 'i')
        .replaceAll('ô', 'o')
        .replaceAll('ù', 'u')
        .replaceAll('û', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ÿ', 'y')
        .replaceAll('ç', 'c')
        .replaceAll('æ', 'ae')
        .replaceAll('œ', 'oe');
  }

  List<String> _tokenizeFrPhrase(String text) {
    // Как в AsrEngine: est-ce / l'homme → отдельные слова.
    final norm = text
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll('`', "'")
        .replaceAll("'", ' ')
        .replaceAll('-', ' ')
        .replaceAll(RegExp(r"[^\wàâäéèêëïîôùûüÿçæœ\s]+", unicode: true), ' ');
    return norm
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  AsrResult _refFromPhraseText() {
    final text = _current.text.trim();
    return AsrResult(tokens: _tokenizeFrPhrase(text), text: text);
  }

  /// Сравнение по словам: эталон = текст фразы, гипотеза = ASR пользователя.
  List<Map<String, dynamic>> _wordDetails(List<String> ref, List<String> mine) {
    final cfg = _difficultyConfig();
    final rows = alignTokenRows(
      ref.map(_normFrWord).toList(),
      mine.map(_normFrWord).toList(),
    );
    final out = <Map<String, dynamic>>[];
    var ri = 0;
    for (final r in rows) {
      if (r.op == 'i') continue; // вставка в гипотезе — не отдельное слово эталона
      if (ri >= ref.length) break;
      final word = ref[ri];
      ri++;
      double score;
      if (r.op == 'o') {
        score = 1.0;
      } else if (r.op == 's') {
        score = 0.35;
      } else {
        score = 0.0; // deletion
      }
      out.add({
        'word': word,
        'score': score,
        'level': score >= cfg.wordGood
            ? 'good'
            : score >= cfg.wordMid
                ? 'mid'
                : 'bad',
        'phon': <String>[
          if (r.op == 'o') word,
          if (r.op == 's') '$word→${r.mine ?? ''}',
          if (r.op == 'd') '$word→∅',
        ],
      });
    }
    while (ri < ref.length) {
      out.add({
        'word': ref[ri],
        'score': 0.0,
        'level': 'bad',
        'phon': <String>['${ref[ri]}→∅'],
      });
      ri++;
    }
    return out;
  }


  int _editDist(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final m = b.length;
    var prev = List<int>.generate(m + 1, (j) => j);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(m + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= m; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        cur[j] = [
          prev[j] + 1,
          cur[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      prev = cur;
    }
    return prev[m];
  }

  bool _wordsClose(String a, String b) {
    if (a == b) return true;
    if (a.isEmpty || b.isEmpty) return false;
    final d = _editDist(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    if (maxLen <= 3) return d <= 1;
    return d / maxLen <= 0.34;
  }

  /// Сопоставление слов эталона с ASR (порядок). exact=good, близкие=mid, нет=bad.
  List<Map<String, dynamic>> _wordDetailsStrict(List<String> ref, List<String> mine) {
    final refN = ref.map(_normFrWord).toList();
    final hypN = mine.map(_normFrWord).toList();
    final out = <Map<String, dynamic>>[];
    var j = 0;
    for (var i = 0; i < refN.length; i++) {
      var found = -1;
      var exact = false;
      // Сначала точное в окне вперёд
      final window = j + 6 < hypN.length ? j + 6 : hypN.length;
      for (var k = j; k < window; k++) {
        if (hypN[k] == refN[i]) {
          found = k;
          exact = true;
          break;
        }
      }
      if (found < 0) {
        for (var k = j; k < window; k++) {
          if (_wordsClose(refN[i], hypN[k])) {
            found = k;
            exact = false;
            break;
          }
        }
      }
      if (found >= 0) {
        out.add({
          'word': ref[i],
          'score': exact ? 1.0 : 0.55,
          'level': exact ? 'good' : 'mid',
          'phon': <String>[exact ? ref[i] : '${ref[i]}≈${mine[found]}'],
        });
        j = found + 1;
      } else {
        out.add({
          'word': ref[i],
          'score': 0.0,
          'level': 'bad',
          'phon': <String>['${ref[i]}→∅'],
        });
      }
    }
    return out;
  }

  Future<void> _preAnalyzeReference() async {
    // FR: эталон — текст фразы, ASR эталона по TTS не нужен.
    if (_neuralReference16k == null) return;
    final ref = _neuralReference16k!;
    final result = _refFromPhraseText();
    _lastRefAsr = result;
    _lastRefAsrAudio = ref;
    _logMsg('эталон (текст): ${result.tokens.join(' ')}', level: 2);
  }

  Future<void> _startAnalysis() async {
    if (_analysisRunning || _neuralReference16k == null || _myAudio16k == null) return;
    if (!_asrModelReady) {
      // ASR поднимается лениво, после записи, а не одновременно с Piper.
      _logMsg('ASR: загружаю ONNX Session для анализа…');
      await _loadAsrSession();
    }
    if (!_asrModelReady) {
      _logMsg('ASR: Session не готова — анализ пропущен', level: 1);
      if (mounted) {
        setState(() {
          _status = 'ASR не загрузился';
          _lastScorePct = 0;
          _lastScoreLevel = 'Слабо';
        });
      }
      return;
    }
    if (_analysisRunning || _neuralReference16k == null || _myAudio16k == null) return;
    _analysisRunning = true;
    _asrActiveJobs++;
    _analysisAnimPhase = 0;
    _analysisAnimTimer?.cancel();
    _analysisAnimTimer = Timer.periodic(const Duration(milliseconds: 180), (_) {
      if (!mounted || !_analysisRunning) return;
      setState(() => _analysisAnimPhase++);
    });
    if (mounted) setState(() { _status = 'Анализ произношения…'; _analysisResult = ''; });
    try {
      final ref = _neuralReference16k!;
      final mine = _myAudio16k!;

      // Эталон = ПОЛНЫЙ текст текущей фразы (ASR по TTS отключён).
      final refResult = _refFromPhraseText();
      _logMsg('эталон (текст фразы, ${refResult.tokens.length} слов): ${refResult.text}');
      _lastRefAsr = refResult;
      _lastRefAsrAudio = ref;

      if (!identical(_myAudio16k, mine)) return;

      AsrResult mineResult;
      if (_lastMineAsr != null && identical(_lastMineAsrAudio, mine)) {
        mineResult = _lastMineAsr!;
        _logMsg('ASR: моя запись взята из кэша');
      } else {
        final mineInput = _asrVolumeMatch ? _prepareMineForAsr(ref, mine) : mine;
        _logMsg('ASR: анализ моей записи…');
        mineResult = await _asr.infer(mineInput);
        if (identical(_myAudio16k, mine)) {
          _lastMineAsr = mineResult;
          _lastMineAsrAudio = mine;
        }
      }

      if (!identical(_neuralReference16k, ref) || !identical(_myAudio16k, mine)) return;

      // Строго: эталон = слова фразы; гипотеза = ASR пользователя.
      // Частичные (mid) совпадения не раздувают процент.
      final cfg = _difficultyConfig();
      final refN = refResult.tokens.map(_normFrWord).toList();
      final hypN = mineResult.tokens.map(_normFrWord).toList();
      final words = _wordDetailsStrict(refResult.tokens, mineResult.tokens);
      int pct;
      String unitLabel;
      if (refN.isEmpty) {
        pct = 0;
        unitLabel = 'по словам · 0/0';
      } else if (hypN.isEmpty) {
        pct = 0;
        unitLabel = 'по словам · 0/${refN.length} (ASR пустой)';
        _logMsg('ASR вернул пустой текст — проверьте микрофон/уровень', level: 1);
      } else {
        final sum = words.fold<double>(
            0, (s, w) => s + ((w['score'] as num?)?.toDouble() ?? 0));
        pct = ((100 * sum) / refN.length).round().clamp(0, 100);
        final exact = words.where((w) => w['level'] == 'good').length;
        final mid = words.where((w) => w['level'] == 'mid').length;
        unitLabel = 'по словам · $exact+$mid/${refN.length}';
      }

      final level = cfg.levelFromPct(pct);
      _analysisResult = '$level\n$unitLabel';
      _lastScorePct = pct;
      _lastScoreLevel = level;
      _logMsg('сравнение: $unitLabel · $pct% · $level');
      _logMsg('эталон: ${refResult.text}', level: 2);
      _logMsg('моя запись: ${mineResult.text}', level: 2);
      _logMsg('эталон токены: ${refResult.tokens.join(' ')}', level: 2);
      _logMsg('моя запись токены: ${mineResult.tokens.join(' ')}', level: 2);
    } catch (e) {
      _analysisResult = 'Ошибка анализа: $e';
      _logMsg('analysis: $e');
    } finally {
      _analysisRunning = false;
      _asrActiveJobs = math.max(0, _asrActiveJobs - 1);
      _analysisAnimTimer?.cancel();
      _analysisAnimTimer = null;
      if (mounted) setState(() => _status = _analysisResult.isEmpty ? '' : 'Анализ готов');
    }
  }

  /// Точная обрезка тишины по краям из userscript 1.25.75.
  Float32List _trimSilenceForAsr(Float32List samples) {
    try {
      if (samples.isEmpty) return samples;
      const sr = 16000;
      final beforeSec = samples.length / sr;
      // Слишком короткое уже — не режем.
      if (samples.length < (sr * 0.4).floor()) return samples;

      const frameMs = 20;
      final frame = math.max(32, (sr * frameMs / 1000).floor());
      final hop = math.max(16, (frame / 2).floor());
      var peak = 0.0;
      for (final v in samples) peak = math.max(peak, v.abs()).toDouble();
      if (peak < 0.001) return samples;

      // Мягкий порог: раньше peak*0.04 срезал тихую речь/диктофон до 0.2 с.
      final thresh = math.max(0.0025, peak * 0.012).toDouble();
      final nFrames = math.max(1, ((samples.length - frame) / hop).floor() + 1);
      final voiced = List<bool>.filled(nFrames, false);
      for (var f = 0; f < nFrames; f++) {
        final off = f * hop;
        final end = math.min(samples.length, off + frame).toInt();
        var sum = 0.0;
        for (var i = off; i < end; i++) sum += samples[i] * samples[i];
        final rms = math.sqrt(sum / math.max(1, end - off));
        voiced[f] = rms >= thresh;
      }
      var first = -1, last = -1;
      for (var f = 0; f < nFrames; f++) {
        if (voiced[f]) { first = f; break; }
      }
      for (var f = nFrames - 1; f >= 0; f--) {
        if (voiced[f]) { last = f; break; }
      }
      if (first < 0 || last < 0 || last < first) return samples;

      final pad = (sr * 0.15).floor(); // больше запаса по краям
      final start = math.max(0, first * hop - pad).toInt();
      final end = math.min(samples.length, last * hop + frame + pad).toInt();
      final cut = end - start;
      // Не оставляем меньше 0.8 с и не режем сильнее чем до 50% исходного (если >1 с).
      if (cut < (sr * 0.8).floor()) return samples;
      if (beforeSec >= 1.0 && cut < samples.length * 0.5) return samples;
      if (cut > samples.length * 0.98) return samples;
      return Float32List.fromList(samples.sublist(start, end));
    } catch (_) {
      return samples;
    }
  }

  /// Точная логика подготовки копии микрофона для ASR из userscript 1.25.75.
  /// Оригинальная запись НЕ изменяется — усиливается только копия, отправляемая в ASR.
  Float32List _prepareMineForAsr(Float32List ref, Float32List mine) {
    Float32List trimSilence(Float32List samples) => _trimSilenceForAsr(samples);

    double rmsForASRLevel(Float32List samples) {
      if (samples.isEmpty) return 0;
      var sum = 0.0;
      var count = 0;
      var peak = 0.0;
      for (final v in samples) peak = math.max(peak, v.abs()).toDouble();
      final gate = math.max(0.003, peak * 0.06).toDouble();
      for (final v in samples) {
        if (v.abs() < gate) continue;
        sum += v * v;
        count++;
      }
      if (count == 0) return 0;
      return math.sqrt(sum / count);
    }

    if (!_asrVolumeMatch || ref.isEmpty || mine.isEmpty) return mine;
    try {
      final refTrim = trimSilence(ref);
      final mineTrim = trimSilence(mine);
      final refRms = rmsForASRLevel(refTrim);
      final mineRms = rmsForASRLevel(mineTrim);
      if (refRms <= 0.001 || mineRms <= 0.001) {
        _logMsg('ASR level: нормализация пропущена — слишком тихий сигнал', level: 2);
        return mine;
      }
      final gain = refRms / mineRms;
      final out = Float32List(mine.length);
      var peak = 0.0;
      for (var i = 0; i < mine.length; i++) {
        out[i] = mine[i] * gain;
        peak = math.max(peak, out[i].abs()).toDouble();
      }
      if (peak > 0.98) {
        final k = 0.98 / peak;
        for (var i = 0; i < out.length; i++) out[i] *= k;
      }
      final db = 20 * math.log(mineRms) / math.ln10;
      final refDb = 20 * math.log(refRms) / math.ln10;
      final gainDb = 20 * math.log(gain) / math.ln10;
      _logMsg(
        'ASR level: ref=${refDb.toStringAsFixed(1)} dB, mic=${db.toStringAsFixed(1)} dB, gain=${gainDb >= 0 ? '+' : ''}${gainDb.toStringAsFixed(1)} dB',
        level: 2,
      );
      return out;
    } catch (e) {
      _logMsg('ASR level: ошибка нормализации — $e', level: 2);
      return mine;
    }
  }

  double _maxAmp(Float32List a) { var m=0.0; for(final v in a) m=math.max(m,v.abs()).toDouble(); return m; }

  Future<void> _loadTranslation(String text, {bool reveal = true}) async {
    final req = ++_transReq;
    if (text.trim().isEmpty) return;
    try {
      final googleUrl = Uri.parse(
          'https://translate.googleapis.com/translate_a/single?client=gtx&sl=fr&tl=ru&dt=t&q=${Uri.encodeComponent(text)}');
      String translated = '';
      try {
        final r = await http.get(googleUrl).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body);
          if (data is List && data.isNotEmpty && data[0] is List) {
            translated = (data[0] as List)
                .map((x) => x is List && x.isNotEmpty ? '${x[0]}' : '')
                .where((s) => s.isNotEmpty)
                .join();
          }
        }
      } catch (_) {}
      if (translated.isEmpty) {
        final mem = Uri.parse(
            'https://api.mymemory.translated.net/get?q=${Uri.encodeComponent(text)}&langpair=fr|ru');
        final r = await http.get(mem).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body);
          translated = '${data['responseData']?['translatedText'] ?? ''}'.trim();
        }
      }
      if (req != _transReq) return;
      if (mounted) {
        setState(() {
          _translation = translated.isEmpty ? (reveal ? 'перевод недоступен' : '') : translated;
        });
      }
    } catch (e) {
      if (req != _transReq) return;
      if (mounted) setState(() => _translation = reveal ? 'перевод недоступен' : '');
      _logMsg('перевод: $e', level: 2);
    }
  }

  Future<void> _loadIpa(String text) async {
    final src = text.trim();
    if (src.isEmpty) {
      if (mounted) setState(() => _ipa = '');
      return;
    }

    // 1) Целая фраза через espeak-ng (offline, стабильный FR IPA).
    //    Лучше пословного Wiktionary: нет «дыр» (·) и liaison учитывается грубо.
    final es = await _ipaViaEspeak(src);
    if (es != null && es.isNotEmpty) {
      if (mounted) setState(() => _ipa = _formatIpaLine(es));
      return;
    }

    // 2) Онлайн: fr.wiktionary по словам (если espeak не установлен).
    final words = src
        .toLowerCase()
        .replaceAll('’', "'")
        .replaceAll(RegExp(r"[^\wàâäéèêëïîôùûüÿçæœ'\-]+", unicode: true), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      if (mounted) setState(() => _ipa = '');
      return;
    }

    final parts = <String>[];
    var hit = 0;
    for (final w in words.take(24)) {
      var ipa = await _ipaFromWiktionaryFr(w);
      ipa ??= await _ipaFromDictionaryApi(w);
      if (ipa != null && ipa.isNotEmpty) {
        hit++;
        parts.add(ipa.replaceAll(RegExp(r'^/|/$'), '').trim());
      }
    }
    // Показываем только если нашли ≥ половины слов — иначе лучше пусто, чем «· · ·».
    if (mounted) {
      if (hit * 2 >= words.take(24).length && parts.isNotEmpty) {
        setState(() => _ipa = _formatIpaLine(parts.join(' ')));
      } else {
        setState(() => _ipa = '');
      }
    }
  }

  /// Единый вид: /bɔ̃ʒuʁ kɔmɑ̃…/
  String _formatIpaLine(String raw) {
    var s = raw.trim();
    s = s.replaceAll(RegExp(r'^/+|/+$'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return '';
    return '/$s/';
  }

  /// IPA с французского Викисловаря (MediaWiki API).
  Future<String?> _ipaFromWiktionaryFr(String word) async {
    try {
      final title = word.replaceAll("'", "’"); // типографский апостроф в заголовках
      final url = Uri.parse(
        'https://fr.wiktionary.org/w/api.php'
        '?action=query&prop=revisions&rvprop=content&rvslots=main'
        '&format=json&origin=*&titles=${Uri.encodeComponent(title)}',
      );
      final r = await http.get(url).timeout(const Duration(seconds: 8));
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      final pages = data['query']?['pages'];
      if (pages is! Map) return null;
      String? wikitext;
      for (final page in pages.values) {
        final revs = page['revisions'];
        if (revs is List && revs.isNotEmpty) {
          final slot = revs[0]['slots']?['main']?['*'] ?? revs[0]['*'];
          if (slot is String) {
            wikitext = slot;
            break;
          }
        }
      }
      if (wikitext == null || wikitext.isEmpty) return null;

      // {{pron|ʒə|fr}} / {{pron|pron=...|fr}} / {{phon|...|fr}}
      final patterns = <RegExp>[
        RegExp(r'\{\{pron\|([^}|]+)\|fr\}\}', caseSensitive: false),
        RegExp(r'\{\{pron\|pron=([^}|]+)\|fr\}\}', caseSensitive: false),
        RegExp(r'\{\{phon\|([^}|]+)\|fr\}\}', caseSensitive: false),
        RegExp(r'\{\{IPAchar\|/([^/]+)/\}\}'),
        RegExp(r'\[\[File:.*\]\]'), // skip
        RegExp(r'/([^/\n\[\]]{1,40})/'), // /ipa/ в секции произношения
      ];
      for (final re in patterns) {
        if (re.pattern.contains('File')) continue;
        final m = re.firstMatch(wikitext);
        if (m != null) {
          var ipa = m.group(1)!.trim();
          if (ipa.startsWith('pron=')) ipa = ipa.substring(5);
          if (ipa.isNotEmpty && !ipa.contains('{{') && ipa.length < 80) {
            if (!ipa.startsWith('/') && !ipa.startsWith('[')) {
              ipa = '/$ipa/';
            }
            return ipa;
          }
        }
      }
      // Секция === {{S|prononciation}} ===
      final pronSec = RegExp(
        r'\{\{S\|prononciation[^}]*\}\}([\s\S]{0,1200})',
        caseSensitive: false,
      ).firstMatch(wikitext);
      if (pronSec != null) {
        final chunk = pronSec.group(1)!;
        final m2 = RegExp(r'\{\{pron\|([^}|]+)').firstMatch(chunk) ??
            RegExp(r'/([^/\n]{1,40})/').firstMatch(chunk);
        if (m2 != null) {
          var ipa = m2.group(1)!.trim();
          if (ipa.isNotEmpty) {
            if (!ipa.startsWith('/')) ipa = '/$ipa/';
            return ipa;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _ipaFromDictionaryApi(String word) async {
    try {
      final url = Uri.parse(
          'https://api.dictionaryapi.dev/api/v2/entries/fr/${Uri.encodeComponent(word)}');
      final r = await http.get(url).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return null;
      final data = jsonDecode(r.body);
      if (data is! List || data.isEmpty) return null;
      final entry = data[0];
      final phonetics = entry['phonetics'];
      if (phonetics is List) {
        for (final ph in phonetics) {
          final t = '${ph['text'] ?? ''}'.trim();
          if (t.isNotEmpty) return t;
        }
      }
      final pt = '${entry['phonetic'] ?? ''}'.trim();
      return pt.isEmpty ? null : pt;
    } catch (_) {
      return null;
    }
  }

  /// IPA через espeak-ng / espeak (голос fr) — основной offline-источник.
  Future<String?> _ipaViaEspeak(String text) async {
    if (text.trim().isEmpty) return null;

    Future<String?> run(String exe, {List<String>? extraArgs}) async {
      try {
        final args = <String>[
          ...?extraArgs,
          '-v', 'fr',
          '-q',
          '--ipa',
          text,
        ];
        final r = await Process.run(
          exe,
          args,
          runInShell: false,
          // Windows иначе читает IPA как CP1251 → «Й"Mŕsw…»
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        ).timeout(const Duration(seconds: 6));
        if (r.exitCode != 0) return null;
        final out = '${r.stdout}'.trim();
        if (out.isEmpty) return null;
        // espeak иногда клеит слова; нормализуем пробелы.
        return out.replaceAll(RegExp(r'\s+'), ' ');
      } catch (_) {
        return null;
      }
    }

    // Типичные пути Windows + PATH.
    final candidates = <String>[
      'espeak-ng',
      'espeak',
      if (Platform.isWindows) ...[
        r'C:\Program Files\eSpeak NG\espeak-ng.exe',
        r'C:\Program Files (x86)\eSpeak NG\espeak-ng.exe',
        r'C:\Program Files\eSpeak\command_line\espeak.exe',
      ],
    ];
    for (final exe in candidates) {
      final ipa = await run(exe);
      if (ipa != null && ipa.isNotEmpty) return ipa;
    }
    return null;
  }

  Future<void> _safeStopPlaybackAndSpeech() async {
    try { await _playbackEngine.stop(); } catch (_) {}
    try { await _killEspeakSpeak(); } catch (_) {}
    try { await _ttsEngine.stop(); } catch (_) {}
    if (mounted) {
      setState(() {
        _ttsActive = false;
        _ttsPaused = false;
      });
    }
  }

  Future<void> _onPhraseChanged({bool prepareNeural = true}) async {
    final token = ++_phraseGenerationToken;
    // При листании удаляем PCM прежних фраз: в RAM остаётся только новая пара.
    _pruneRamCache();
    _neuralPrepareTimer?.cancel();
    _neuralPrepareTimer = null;
    _idlePrefetchTimer?.cancel();
    _idlePrefetchTimer = null;
    _prefetchRunning = false;

    // Навигация не ждёт native audio. Остановка запускается отдельно, а уже
    // начавшийся Piper-инференс не прерываем и не освобождаем его engine.
    _stopFuture = _safeStopPlaybackAndSpeech();
    unawaited(_stopFuture!);

    final text = _current.text;
    if (mounted) {
      setState(() {
        _translation = ''; _ipa = ''; _translationVisible = false;
        _lastScorePct = null; _lastScoreLevel = '';
        _neuralReference16k = null; _myAudio16k = null;
        _lastRefAsr = null; _lastRefAsrAudio = null;
        _lastMineAsr = null; _lastMineAsrAudio = null;
        _analysisResult = '';
        _status = '';
        _curInd = '—'; _nextInd = '—';
        _curIndColor = _muted; _nextIndColor = _muted;
      });
    }

    // Перевод и транскрипция не должны блокировать листание.
    unawaited(_loadTranslation(text, reveal: false));
    unawaited(_loadIpa(text));

    // При листании фраз ASR не нужен — только Piper TTS в фоне.
    _asrPrepareTimer?.cancel();
    _asrPrepareTimer = null;
    if (Platform.isWindows && _asrModelReady && !(_recording || _analysisRunning)) {
      // Освобождаем ORT, чтобы быстрый скролл + Piper не роняли process.
      unawaited(() async {
        try {
          await _asr.dispose();
        } catch (_) {}
        _asrModelReady = false;
        _asrLoadFuture = null;
      }());
    }

    if (prepareNeural && !_browserMode && _ttsModelReady) {
      _scheduleNeuralIdleWork();
    } else {
      unawaited(_refreshNeuralIndicators());
    }
  }

  Future<void> _autoRunBrowserCycle(int token) async {
    while (_autoRunning &&
        token == _autoToken &&
        !_autoStopRequested &&
        mounted) {
      final phrase = _current.text;
      if (phrase.isEmpty) break;

      setState(() => _status = 'Auto: браузерный TTS…');
      await _speakBrowser(phrase);
      if (_autoStopRequested || token != _autoToken) break;

      final pause = _autoPauseMs(phrase);
      setState(
          () => _status = 'Auto: пауза ${(pause / 1000).toStringAsFixed(1)} с');
      if (!await _sleepMs(pause)) break;

      setState(() => _status = 'Auto: запись…');
      final okRec = await _runRecordingSession(auto: true);
      if (!okRec || _autoStopRequested || token != _autoToken) {
        if (!okRec) setState(() => _status = 'Auto: запись не удалась — стоп');
        break;
      }

      setState(() => _status = 'Auto: повтор фразы…');
      await _speakBrowser(phrase);
      if (_autoStopRequested || token != _autoToken) break;

      if (_index >= _phrases.length - 1) {
        setState(() => _status = 'Auto: список завершён');
        break;
      }
      setState(() => _index++);
      await _persist();
      await _onPhraseChanged();
      await _sleepMs(300);
    }
  }

  Future<void> _autoRunNeuralCycle(int token) async {
    while (_autoRunning &&
        token == _autoToken &&
        !_autoStopRequested &&
        mounted) {
      final phrase = _current.text;
      if (phrase.isEmpty) break;

      if (!_ttsModelReady) {
        setState(() => _status =
            'Auto: нейро-модель не загружена — переключитесь на «Браузерный»');
        break;
      }

      var attempt = 0;
      var passed = false;
      while (attempt < 3 &&
          !passed &&
          !_autoStopRequested &&
          token == _autoToken) {
        setState(() => _status = 'Auto: нейро TTS…');
        final played = await _playNeural();
        if (!played || _autoStopRequested || token != _autoToken) break;

        final pause = _autoPauseMs(phrase);
        setState(
            () => _status = 'Auto: пауза ${(pause / 1000).toStringAsFixed(1)} с');
        if (!await _sleepMs(pause)) break;

        setState(() => _status = 'Auto: запись…');
        final okRec = await _runRecordingSession(auto: true);
        if (!okRec || _autoStopRequested || token != _autoToken) {
          if (!okRec) setState(() => _status = 'Auto: запись не удалась — стоп');
          _autoStopRequested = true;
          break;
        }
        // Дождаться окончания ASR-сравнения (оно стартует внутри записи).
        for (var i = 0; i < 100 && _analysisRunning; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (_autoStopRequested || token != _autoToken) break;
        }
        final cfg = _difficultyConfig();
        final pct = _lastScorePct;
        final okScore = cfg.analysisPassed(pct);
        final level = _lastScoreLevel.isNotEmpty
            ? _lastScoreLevel
            : cfg.levelFromPct(pct ?? 0);
        if (okScore) {
          passed = true;
          setState(() => _status =
              'Auto: $level${pct != null ? ' · $pct%' : ''} — далее');
          await _sleepMs(2500);
          break;
        }
        attempt++;
        setState(() => _status =
            'Auto: $level${pct != null ? ' · $pct%' : ''} — повтор ${attempt + 1}/3');
        _logMsg(
            'Auto: не пройдено (нужно ≥${cfg.passPct}%, есть ${pct ?? 0}%) — попытка $attempt',
            level: 1);
        await _sleepMs(1200);
      }

      if (_autoStopRequested || token != _autoToken) break;
      if (!passed) break;

      if (_index >= _phrases.length - 1) {
        setState(() => _status = 'Auto: список завершён');
        break;
      }
      setState(() => _index++);
      await _persist();
      await _onPhraseChanged();
      await _sleepMs(350);
    }
  }

  Future<void> _startAuto() async {
    if (_autoRunning) return;
    try {
      final perm = await _rec.hasPermission();
      if (!perm) {
        if (mounted) {
          setState(() => _status = 'Auto: нет доступа к микрофону');
        }
        return;
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Auto: микрофон $e');
      return;
    }
    setState(() {
      _autoRunning = true;
      _autoStopRequested = false;
      _autoToken++;
      _status = 'Auto: старт';
    });
    try {
      await WakelockPlus.enable();
    } catch (e) {
      _logMsg('wakelock: $e', level: 2);
    }
    final token = _autoToken;
    if (!_browserMode && _ttsModelReady) {
      // Auto сам по себе явный старт — короткая задержка только на Windows.
      _scheduleDeferredNeuralWarmup(delayMs: Platform.isWindows ? 800 : 200);
    }
    try {
      if (_browserMode) {
        await _autoRunBrowserCycle(token);
      } else {
        await _autoRunNeuralCycle(token);
      }
    } catch (e) {
      _logMsg('auto: $e');
      if (mounted) setState(() => _status = 'Auto: ошибка $e');
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      if (token == _autoToken && mounted) {
        setState(() {
          _autoRunning = false;
          _autoStopRequested = false;
        });
      }
    }
  }

  void _stopAuto() {
    _autoStopRequested = true;
    _autoRunning = false;
    _stopSpeak();
    _stopRecording();
    _playbackEngine.stop();
    try {
      WakelockPlus.disable();
    } catch (_) {}
    if (mounted) setState(() => _status = 'Auto: остановлен');
  }

  void _toggleAuto() {
    if (_autoRunning) {
      _stopAuto();
    } else {
      _startAuto();
    }
  }

  Future<void> _prev() async {
    if (_autoRunning || _phrases.isEmpty) return;
    _showNavFlash(-1);
    setState(() {
      _index = (_index - 1 + _phrases.length) % _phrases.length;
    });
    unawaited(_persist());
    unawaited(_onPhraseChanged());
  }

  Future<void> _next() async {
    if (_autoRunning || _phrases.isEmpty) return;
    _showNavFlash(1);
    setState(() {
      _index = (_index + 1) % _phrases.length;
    });
    unawaited(_persist());
    unawaited(_onPhraseChanged());
  }

  void _showNavFlash(int direction) {
    _navFlashTimer?.cancel();
    if (mounted) setState(() => _navFlash = direction);
    _navFlashTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _navFlash = 0);
    });
  }

  /// Собирает строки субтитров в предложения так же, как userscript 1.25.75.
  /// Перенос строки сам по себе не заканчивает предложение.
  /// Конец предложения определяется по . ! ?; закрывающая кавычка/скобка
  /// остаётся частью предыдущего предложения.
  List<String> _splitSentenceText(String text) {
    final src = text
        .replaceFirst(RegExp(r'^\uFEFF'), '')
        .replaceAll('\r', '\n')
        .trim();

    if (src.isEmpty) return <String>[];

    final out = <String>[];
    var buf = '';

    void flush() {
      final value = buf.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (value.isNotEmpty) out.add(value);
      buf = '';
    }

    final lines = src
        .split(RegExp(r'\n+'))
        .map((x) => x.trim())
        .where((x) => x.isNotEmpty);

    // Аналог JS: /[.!?]+(?:["'”’»)]*)(?=\s|$)/g
    final sentenceEnd = RegExp(r'''[.!?]+(?:["'”’»)]*)(?=\s|$)''');

    for (final line in lines) {
      var start = 0;
      for (final match in sentenceEnd.allMatches(line)) {
        final end = match.end;
        final part = line.substring(start, end).trim();
        if (part.isNotEmpty) {
          buf = buf.isEmpty ? part : '$buf $part';
          flush();
        }
        start = end;
        while (start < line.length && RegExp(r'\s').hasMatch(line[start])) {
          start++;
        }
      }

      final rest = line.substring(start).trim();
      if (rest.isNotEmpty) {
        buf = buf.isEmpty ? rest : '$buf $rest';
      }
    }

    flush();
    return out;
  }

  /// Точно как normalizePhraseList() в userscript: удаляет пустые строки
  /// и точные дубликаты, сохраняя первое вхождение.
  List<String> _normalizeImportedPhrases(Iterable<String> items) {
    final seen = <String>{};
    final out = <String>[];
    for (final raw in items) {
      final value = raw.replaceFirst(RegExp(r'^\uFEFF'), '').trim();
      if (value.isEmpty || seen.contains(value)) continue;
      seen.add(value);
      out.add(value);
    }
    return out;
  }

  Future<void> _pastePhrases() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      setState(() => _status = 'Буфер обмена пуст');
      return;
    }

    final sentences = _splitSentenceText(text);
    final incoming = _pasteSkipDuplicates
        ? _normalizeImportedPhrases(sentences)
        : sentences
            .map((e) => e.replaceFirst(RegExp(r'^\uFEFF'), '').trim())
            .where((e) => e.isNotEmpty)
            .toList();
    if (incoming.isEmpty) {
      setState(() => _status = 'В буфере нет фраз');
      return;
    }

    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Вставка из буфера'),
        content: Text(
          'Найдено фраз: ${incoming.length}.\n'
          'Добавить к текущему списку или заменить его?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'add'),
            child: const Text('Добавить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'replace'),
            child: const Text('Заменить'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;

    late final List<String> phrases;
    if (action == 'add') {
      if (_pasteSkipDuplicates) {
        phrases = _normalizeImportedPhrases([
          ..._phrases.map((e) => e.text),
          ...incoming,
        ]);
      } else {
        phrases = [
          ..._phrases.map((e) => e.text),
          ...incoming,
        ];
      }
    } else {
      phrases = incoming;
    }
    if (phrases.isEmpty) return;

    _cacheEpoch++;
    _phraseGenerationToken++;
    setState(() {
      _phrases = phrases.map((t) => _Phrase(t)).toList();
      if (action == 'replace') {
        _index = 0;
      } else {
        _index = _index.clamp(0, _phrases.length - 1);
      }
      _status = action == 'add'
          ? 'Добавлено. Всего фраз: ${phrases.length}'
          : 'Заменено. Фраз: ${phrases.length}';
    });
    unawaited(_audioCache.pruneToKeys(_allowedCacheKeys()));
    await _persist();
    await _onPhraseChanged();
  }

  Future<void> _clearNeuralAudioCache() async {
    _cacheEpoch++;
    _phraseGenerationToken++;
    _neuralPrepareTimer?.cancel();
    try { await _playbackEngine.stop(); } catch (_) {}
    try {
      final n = await _audioCache.clear();
      _ramAudioCache.clear();
      _neuralReference16k = null;
      _lastRefAsr = null;
      _lastRefAsrAudio = null;
      await _refreshAudioCacheStats();
      await _refreshNeuralIndicators();
      if (mounted) setState(() => _status = 'Очищен кэш нейро-аудио: $n фраз');
      _logMsg('Кэш нейро-аудио очищен: $n файлов');
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка очистки кэша: $e');
    }
  }

  Future<void> _clearTempFiles() async {
    _cacheEpoch++;
    _phraseGenerationToken++;
    _neuralPrepareTimer?.cancel();
    try { await _playbackEngine.stop(); } catch (_) {}
    try {
      final dir = await getTemporaryDirectory();
      var n = 0;
      await for (final e in dir.list()) {
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith('pron_rec_') || name.startsWith('pron_beep') || name.startsWith('kokoro_play_') || name.startsWith('blim_beep_')) {
          try { await e.delete(); n++; } catch (_) {}
        }
      }
      final cacheN = await _audioCache.clear();
      _ramAudioCache.clear();
      await _refreshAudioCacheStats();
      await _refreshNeuralIndicators();
      if (mounted) setState(() => _status = 'Очищено: temp $n + нейро-аудио $cacheN');
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка очистки: $e');
    }
  }

  @override
  void dispose() {
    _neuralWarmupTimer?.cancel();
    _neuralWarmupTimer = null;
    // В режиме «2 файла» стараемся оставить на диске только текущую пару
    // даже при обычном закрытии экрана. При аварийном убийстве процесса
    // следующий запуск повторит ту же очистку перед idle-генерацией.
    if (_neuralKeep == 'pair') {
      unawaited(_audioCache.pruneToKeys(_allowedCacheKeys()));
    }
    unawaited(_stopBackgroundDownloadGuard());
    // Drop references to decoded speech immediately on leaving the trainer.
    // WAV files on disk remain intact; only in-memory PCM/ASR results are cleared.
    _ramAudioCache.clear();
    _neuralReference16k = null;
    _myAudio16k = null;
    _lastRefAsrAudio = null;
    _lastMineAsrAudio = null;
    _lastRefAsr = null;
    _lastMineAsr = null;
    unawaited(_kokoro.dispose());
    unawaited(_asr.dispose());
    try { WakelockPlus.disable(); } catch (_) {}
    _autoStopRequested = true;
    _ampSub?.cancel();
    _analysisAnimTimer?.cancel();
    _activityBlinkTimer?.cancel();
    _navFlashTimer?.cancel();
    _neuralPrepareTimer?.cancel();
    _idlePrefetchTimer?.cancel();
    _asrPrepareTimer?.cancel();
    try { _tts?.stop(); } catch (_) {}
    try { _recorder?.dispose(); } catch (_) {}
    try { _playback?.dispose(); } catch (_) {}
    try { _beepPlayer?.dispose(); } catch (_) {}
    super.dispose();
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final locked = _autoRunning;
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  _buildModeRow(locked),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: locked ? null : () => setState(() => _speedPanelExpanded = !_speedPanelExpanded),
                    child: Container(
                      height: 22,
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF181818),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: _border),
                      ),
                      child: Icon(
                        _speedPanelExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                        color: _accent,
                        size: 20,
                      ),
                    ),
                  ),
                  if (_speedPanelExpanded) ...[
                    if (!_browserMode) ...[
                      _label('Скорость нейросети ${_neuralRate.toStringAsFixed(2)}'),
                      Row(
                        children: [
                          Expanded(
                            child: SliderTheme(
                              data: _sliderTheme(),
                              child: Slider(
                                value: _neuralRate,
                                min: 0.5,
                                max: 1.2,
                                onChanged: locked || _neuralRateLocked
                                    ? null
                                    : (v) {
                                        _cacheEpoch++;
                                        _phraseGenerationToken++;
                                        setState(() {
                                          _neuralRate = v;
                                          _curInd = '—'; _nextInd = '—';
                                          _curIndColor = _muted; _nextIndColor = _muted;
                                        });
                                        unawaited(_persist());
                                        _scheduleNeuralIdleWork();
                                      },
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              _neuralRateLocked ? Icons.lock : Icons.lock_open,
                              color: _neuralRateLocked ? _accent : _muted,
                              size: 18,
                            ),
                            onPressed: locked
                                ? null
                                : () {
                                    setState(() => _neuralRateLocked = !_neuralRateLocked);
                                    unawaited(_persist());
                                  },
                          ),
                        ],
                      ),
                    ],
                    _label('Скорость прослушивания ${_listenRate.toStringAsFixed(2)} (тембр сохранён)'),
                    SliderTheme(
                      data: _sliderTheme(active: const Color(0xFF2196F3)),
                      child: Slider(
                        value: _listenRate,
                        min: 0.5,
                        max: 1.0,
                        onChanged: locked
                            ? null
                            : (v) {
                                setState(() => _listenRate = v);
                                unawaited(_persist());
                                if (!_browserMode && _playbackEngine.playing) {
                                  unawaited(_playbackEngine.setSpeed(v));
                                }
                              },
                      ),
                    ),
                  ],
                  _buildReadyIndicators(),
                  const SizedBox(height: 8),
                  _buildPhraseCard(locked),
                  const SizedBox(height: 8),
                  _buildMyRecording(locked),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _radio(
                        selected: _analysisSimple,
                        label: 'Простой',
                        onTap: () {
                          setState(() => _analysisSimple = true);
                          _persist();
                        },
                      ),
                      const SizedBox(width: 12),
                      _radio(
                        selected: !_analysisSimple,
                        label: 'Подробный',
                        onTap: () {
                          setState(() => _analysisSimple = false);
                          _persist();
                        },
                      ),
                    ],
                  ),
                  _buildAnalysisBusy(),
                  _buildAnalysisResult(),
                  _buildLogPanel(),
                  const SizedBox(height: 10),
                  _bigBtn(
                    icon: Icons.content_paste,
                    label: 'Вставить из буфера обмена',
                    onTap: locked ? null : _pastePhrases,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Simulateur de prononciation française',
              style: TextStyle(
                color: _text,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: 'Настройки',
            icon: const Icon(Icons.settings, color: _text, size: 22),
            onPressed: _openSettings,
          ),
          IconButton(
            tooltip: 'Справка',
            icon: const Icon(Icons.lightbulb_outline, color: _text, size: 22),
            onPressed: _openHelp,
          ),
        ],
      ),
    );
  }

  Widget _buildLogPanel() {
    // Если лог выключен, не оставляем ни панели, ни ссылки «Показать лог».
    if (_logLevel <= 0) return const SizedBox.shrink();
    final lines = _log.isEmpty ? ['лог пуст — загрузка моделей появится здесь'] : List<String>.from(_log.reversed.take(40));
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 140),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF14141C),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Лог',
                    style: TextStyle(
                        color: _muted, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
              if (_models.status.downloading)
                Text(_models.status.pctLabel,
                    style: const TextStyle(color: _accent, fontSize: 11)),
              TextButton(
                onPressed: () async {
                  // _log хранится newest-first — для буфера отдаём хронологию.
                  final text = _log.isEmpty ? '' : _log.reversed.join('\n');
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        text.isEmpty
                            ? 'Лог пуст'
                            : 'Лог скопирован (${_log.length} строк)',
                      ),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('Копировать', style: TextStyle(fontSize: 11)),
              ),
              TextButton(
                onPressed: () {
                  setState(() => _log.clear());
                },
                style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('Очистить', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          if (_models.status.downloading) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: _models.status.bytesTotal > 0
                  ? _models.status.fraction
                  : null,
              minHeight: 4,
              backgroundColor: const Color(0xFF2A2A3A),
              color: _accent,
            ),
          ],
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              itemCount: lines.length,
              itemBuilder: (_, i) => Text(
                lines[i],
                style: const TextStyle(
                    color: Color(0xFFB0B0B8), fontSize: 11, height: 1.25),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeRow(bool locked) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _radio(
          selected: _browserMode,
          label: 'Браузерный',
          compact: true,
          onTap: locked
              ? null
              : () {
                  setState(() => _browserMode = true);
                  _persist();
                  unawaited(_onPhraseChanged(prepareNeural: false));
                },
        ),
        _radio(
          selected: !_browserMode,
          label: 'Нейро',
          compact: true,
          onTap: locked || _modelsInitializing || _models.status.downloading
              ? null
              : () {
                  setState(() => _browserMode = false);
                  _persist();
                  unawaited(_activateNeuralMode());
                },
        ),
        InkWell(
          onTap: locked ? null : _pickVoice,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2A3A),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Text('$_voiceName ▾',
                style: const TextStyle(color: _text, fontSize: 12)),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _activityDot(
              ready: _asrModelReady,
              busy: _models.status.downloadStage == 'asr' || _asrLoadFuture != null,
              active: _analysisRunning || _asrActiveJobs > 0,
            ),
            const Text('ASR ', style: TextStyle(color: _muted, fontSize: 11)),
            _activityDot(
              ready: _ttsModelReady,
              busy: _models.status.downloadStage == 'tts',
              active: _ttsActive || _generationFutures.isNotEmpty,
            ),
            const Text('TTS', style: TextStyle(color: _muted, fontSize: 11)),
          ],
        ),
      ],
    );
  }

  Widget _activityDot({
    required bool ready,
    required bool busy,
    required bool active,
  }) {
    final color = busy
        ? (_activityBlinkOn ? _accent : const Color(0xFF6B4520))
        : active
            ? (_activityBlinkOn ? _ok : const Color(0xFF356B50))
            : (ready ? _ok : const Color(0xFF555555));
    return AnimatedContainer(
      duration: const Duration(milliseconds: 60),
      width: 8,
      height: 8,
      margin: const EdgeInsets.only(right: 3),
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }

  Widget _buildReadyIndicators() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                  child: Text('Текущая фраза',
                      style: TextStyle(color: _muted, fontSize: 12))),
              Text(_curInd,
                  style: TextStyle(color: _curIndColor, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              const Expanded(
                  child: Text('Следующая фраза',
                      style: TextStyle(color: _muted, fontSize: 12))),
              Text(_nextInd,
                  style: TextStyle(color: _nextIndColor, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPhraseCard(bool locked) {
    final p = _current;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Фраза ${_phrases.isEmpty ? 0 : _index + 1} / ${_phrases.length}',
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
              const Spacer(),
              _iconBtn(
                Icons.arrow_back,
                locked ? null : () => unawaited(_prev()),
                size: 36,
                highlight: _navFlash == -1,
              ),
              const SizedBox(width: 4),
              _iconBtn(
                Icons.arrow_forward,
                locked ? null : () => unawaited(_next()),
                size: 36,
                highlight: _navFlash == 1,
              ),
            ],
          ),
          const SizedBox(height: 8),
          GestureDetector(
            onTap: () async {
              if (_translation.isEmpty) {
                await _loadTranslation(p.text, reveal: true);
              }
              setState(() => _translationVisible = !_translationVisible);
            },
            child: Text(
              p.text,
              style: const TextStyle(
                color: _text,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
          ),
          if (_translationVisible && _translation.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _translation,
              style: const TextStyle(
                color: Color(0xFF65D69B),
                fontSize: 17,
                height: 1.35,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          if (_ipa.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _ipa,
              style: const TextStyle(
                color: Color(0xFF6B9BD1),
                fontSize: 16,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 142,
                child: _actionBtn(
                  icon: _ttsActive && _browserMode
                      ? (_ttsPaused ? Icons.play_arrow : Icons.stop)
                      : Icons.record_voice_over,
                  label: _ttsActive && _browserMode
                      ? (_ttsPaused ? 'Продолжить' : 'Стоп')
                      : 'Браузер',
                  compact: true,
                  highlight: _ttsActive && _browserMode,
                  onTap: locked
                      ? null
                      : () async {
                          if (_ttsActive && _browserMode) {
                            await _toggleSpeechPlayback();
                            return;
                          }
                          setState(() => _browserMode = true);
                          await _persist();
                          await _refreshNeuralIndicators();
                          await _speakBrowser(p.text);
                        },
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 142,
                child: _actionBtn(
                  icon: _ttsActive && !_browserMode
                    ? (_ttsPaused ? Icons.play_arrow : Icons.stop)
                    : Icons.play_arrow,
                label: _ttsActive && !_browserMode
                    ? (_ttsPaused ? 'Продолжить' : 'Стоп')
                    : 'Нейро',
                color: _accent,
                compact: true,
                highlight: _ttsActive && !_browserMode,
                onTap: locked || _modelsInitializing || _models.status.downloading
                    ? null
                    : () async {
                        if (_ttsActive && !_browserMode) {
                          await _toggleSpeechPlayback();
                          return;
                        }
                        setState(() => _browserMode = false);
                        await _persist();
                        await _activateNeuralMode();
                        await _playNeural();
                      },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _wordColor(double score) {
    final x = score.clamp(0.0, 1.0).toDouble();
    final cfg = _difficultyConfig();
    // Пороги берутся из той же difficultyConfig, что и userscript.
    // Внутри диапазонов цвет плавный: красный → оранжевый → жёлтый → зелёный.
    if (x >= cfg.wordGood) {
      return Color.lerp(const Color(0xFFFFCC66), _ok, ((x - cfg.wordGood) / math.max(0.0001, 1 - cfg.wordGood)).clamp(0.0, 1.0).toDouble())!;
    }
    if (x >= cfg.wordMid) {
      return Color.lerp(const Color(0xFFFF9966), const Color(0xFFFFCC66), ((x - cfg.wordMid) / math.max(0.0001, cfg.wordGood - cfg.wordMid)).clamp(0.0, 1.0).toDouble())!;
    }
    return Color.lerp(const Color(0xFFFF5555), const Color(0xFFFF9966), (x / math.max(0.0001, cfg.wordMid)).clamp(0.0, 1.0).toDouble())!;
  }

  Widget _buildAnalysisBusy() {
    if (!_analysisRunning) return const SizedBox.shrink();
    const waves = ['〰〰〰', '〰≋〰', '≋〰≋', '〰≋〰'];
    final n = _analysisAnimPhase % waves.length;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(color: const Color(0xFF151515), borderRadius: BorderRadius.circular(10)),
      child: Column(
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Transform.translate(offset: Offset(0, (n == 1 || n == 3) ? -2 : 0), child: const Text('🗣️', style: TextStyle(fontSize: 34))),
            const SizedBox(width: 14),
            Text(waves[n], style: const TextStyle(color: _text, fontSize: 26, letterSpacing: 2)),
            const SizedBox(width: 14),
            Transform.scale(scale: n == 2 ? 1.08 : 1.0, child: const Text('🧠', style: TextStyle(fontSize: 30))),
          ]),
          const SizedBox(height: 6),
          const Text('Нейросеть анализирует произношение…', style: TextStyle(color: _muted, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildPhonemeComparison(List<String> ref, List<String> mine) {
    final rows = alignTokenRows(ref, mine);
    final refWidgets = <Widget>[];
    final mineWidgets = <Widget>[];

    Color matchColor(String op) {
      switch (op) {
        case 'o':
          return _ok;
        case 'i':
          return const Color(0xFFFFA726);
        default:
          return const Color(0xFFFF5C5C);
      }
    }

    for (final row in rows) {
      final c = matchColor(row.op);
      if (row.ref != null && row.ref!.isNotEmpty && row.ref != '|') {
        refWidgets.add(Text(
          row.ref!,
          style: TextStyle(color: c, fontSize: 16, fontWeight: FontWeight.w600),
        ));
      }
      if (row.mine != null && row.mine!.isNotEmpty && row.mine != '|') {
        final mineColor = row.op == 'o'
            ? _ok
            : (row.op == 'i' ? const Color(0xFFFFA726) : const Color(0xFFFF5C5C));
        mineWidgets.add(Text(
          row.mine!,
          style: TextStyle(color: mineColor, fontSize: 16, fontWeight: FontWeight.w600),
        ));
      }
    }

    Widget line(String title, List<Widget> items) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(title,
                  style: const TextStyle(color: _muted, fontSize: 11)),
            ),
            Expanded(
              child: Wrap(
                spacing: 6,
                runSpacing: 2,
                children: items,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line('Эталон', refWidgets),
        line('Моя', mineWidgets),
        const SizedBox(height: 3),
        const Text(
          'зелёный — совпало · красный — ошибка · оранжевый — лишняя фонема',
          style: TextStyle(color: _muted, fontSize: 10),
        ),
      ],
    );
  }

  Widget _buildAnalysisResult() {
    if (_analysisResult.isEmpty || _analysisRunning) return const SizedBox.shrink();
    final words = _lastRefAsr != null && _lastMineAsr != null
        ? _wordDetails(_lastRefAsr!.tokens, _lastMineAsr!.tokens)
        : const <Map<String, dynamic>>[];
    final cfg = _difficultyConfig();
    final level = _lastScoreLevel.isNotEmpty ? _lastScoreLevel : cfg.levelFromPct(_lastScorePct ?? 0);
    final levelColor = switch (level) {
      'Отлично' => _ok,
      'Хорошо' => const Color(0xFF8CFFB8),
      'Приемлемо' => const Color(0xFFFFCC66),
      'Нужно поработать' => const Color(0xFFFF9966),
      _ => const Color(0xFFFF6666),
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF151515),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$level${_lastScorePct != null ? ' · ${_lastScorePct}%' : ''}',
            style: TextStyle(color: levelColor, fontSize: 20, fontWeight: FontWeight.w700),
          ),
          if (!_analysisSimple) ...[
            const SizedBox(height: 8),
            if (_compareUnit == 'word' && words.isNotEmpty)
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: words.map((w) {
                  final score = (w['score'] as num?)?.toDouble() ?? 0;
                  final c = _wordColor(score);
                  final word = '${w['word']}';
                  final phon = (w['phon'] as List?)?.map((e) => '$e').join(' ') ?? '';
                  return Tooltip(
                    message: phon.isEmpty ? word : phon,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                      decoration: BoxDecoration(
                        color: c.withOpacity(.14),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: c.withOpacity(.55)),
                      ),
                      child: Text(word, style: TextStyle(color: c, fontSize: 14, fontWeight: FontWeight.w500)),
                    ),
                  );
                }).toList(),
              )
            else if (_compareUnit == 'phoneme' && _lastRefAsr != null && _lastMineAsr != null)
              _buildPhonemeComparison(_lastRefAsr!.tokens, _lastMineAsr!.tokens)
            else if (_compareUnit == 'phoneme')
              const Text('Фонемный анализ пока не готов', style: TextStyle(color: _muted, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _buildMyRecording(bool locked) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Моя запись',
              style: TextStyle(
                  color: _text, fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: _actionBtn(
                icon: Icons.mic,
                label: _recording ? 'Стоп' : 'Запись',
                compact: true,
                highlight: _recording,
                highlightColor: Colors.redAccent,
                onTap: locked
                    ? null
                    : () async {
                        if (_recording) {
                          await _stopRecording();
                        } else {
                          await _runRecordingSession(auto: false);
                        }
                      },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _actionBtn(
                  icon: Icons.play_arrow,
                label: 'Я',
                color: _accent,
                compact: true,
                highlight: _playingMine,
                onTap: locked || _lastRecordPath == null
                    ? null
                    : () => _playMyRecording(),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _actionBtn(
                  icon: _autoRunning ? Icons.stop : Icons.play_arrow,
                label: _autoRunning ? 'Стоп' : 'Старт',
                color: _accent,
                compact: true,
                highlight: _autoRunning,
                onTap: _toggleAuto,
                ),
              ),
            ],
          ),
          if (_recStatus.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(_recStatus,
                style: const TextStyle(color: _muted, fontSize: 11)),
          ],
          if (_recording) ...[
            const SizedBox(height: 8),
            _levelBar(),
          ],
        ],
      ),
    );
  }

  String _voicePreviewText(KokoroVoice v) =>
      "Hi, I'm ${v.name}, how are you?";

  Future<void> _previewVoice(
    KokoroVoice v,
    void Function(bool busy) setBusy,
  ) async {
    final text = _voicePreviewText(v);
    final requestToken = ++_voicePreviewToken;
    setBusy(true);
    try {
      await _playbackEngine.stop();
      // Пробник всегда звучит на 1.0x. Он не зависит от ползунка
      // прослушивания и не меняет сохранённую скорость генерации фраз.
      if (!_ttsModelReady) {
        final init = _modelsInitFuture;
        if (init != null) await init;
      }
      if (!_ttsModelReady) {
        await _downloadModels();
      }
      if (!_ttsModelReady) {
        throw StateError('Piper: Piper ещё не готов');
      }
      if (!mounted || requestToken != _voicePreviewToken) return;

      CachedWav? cached;
      final file = await _voicePreviewCache.get(voiceId: v.id, text: text);
      if (file != null) {
        cached = await _audioCache.read(file);
        _logMsg('VOICE PREVIEW CACHE HIT: ${v.name}');
      } else {
        final modelDir = await _models.sherpaTtsModelDir();
        _logMsg('VOICE PREVIEW: генерирую ${v.name}');
        final samples = await _withKokoroExclusive(
          () => _enqueueKokoro(() => _kokoro.synthesize(
            text: text,
            modelDir: modelDir.path,
            speed: 1.0,
            voiceId: v.id,
            useSplitPattern: false,
          )),
        );
        await _voicePreviewCache.put(
          voiceId: v.id,
          text: text,
          samples: samples,
          sampleRate: 16000,
        );
        cached = CachedWav(samples, 16000);
        _logMsg('VOICE PREVIEW CACHE STORE: ${v.name}');
      }

      // Между двумя быстрыми нажатиями предыдущая генерация может завершиться
      // позже новой. Старый запрос не имеет права перехватить общий плеер.
      if (!mounted || requestToken != _voicePreviewToken) return;

      final ready = cached;
      if (ready == null) return;
      final wav = KokoroEngine.floatToWav(
        ready.samples,
        sampleRate: ready.sampleRate,
      );
      await _playbackEngine.stop();
      await _playbackEngine.setAudioSource(_MemoryWavSource(wav));
      await _playbackEngine.setVolume(1.0);
      await _playbackEngine.setSpeed(1.0);
      await _playbackEngine.play();
      await _playbackEngine.playerStateStream.firstWhere(
        (s) =>
            s.processingState == ProcessingState.completed ||
            s.processingState == ProcessingState.idle,
      ).timeout(
        const Duration(seconds: 30),
        onTimeout: () => _playbackEngine.playerState,
      );
    } catch (e, st) {
      _logMsg('VOICE PREVIEW error: $e');
      _logMsg('$st', level: 2);
      if (mounted) {
        setState(() => _status = 'Пробник голоса: ошибка');
      }
    } finally {
      setBusy(false);
    }
  }

  void _pickVoice() {
    final us = kKokoroVoices.where((v) => v.id.startsWith('a')).toList();
    final uk = kKokoroVoices.where((v) => v.id.startsWith('b')).toList();
    final size = MediaQuery.sizeOf(context);
    // Узкая колонка почти на всю высоту окна (desktop).
    final sheetWidth = (size.width * 0.28).clamp(260.0, 340.0);
    final sheetHeight = size.height * 0.90;

    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxWidth: sheetWidth,
        minWidth: sheetWidth,
        maxHeight: sheetHeight,
      ),
      builder: (ctx) {
        String? previewingId;

        Widget header(String title) => Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Text(
                title,
                style: const TextStyle(
                  color: _muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );

        Widget tile(KokoroVoice v, StateSetter sheetSetState) {
          final sel = v.id == _voiceId;
          final previewing = previewingId == v.id;
          return InkWell(
            onTap: () async {
              // Повторный выбор того же голоса ничего не очищает.
              if (v.id == _voiceId) {
                if (ctx.mounted) Navigator.pop(ctx);
                return;
              }
              _cacheEpoch++;
              final token = ++_phraseGenerationToken;
              _neuralPrepareTimer?.cancel();
              _idlePrefetchTimer?.cancel();
              _voicePreviewToken++;
              try { await _playbackEngine.stop(); } catch (_) {}
              // Дожидаемся уже начатых генераций до очистки/выгрузки, чтобы
              // старый voice worker не пересекался с новым кэшем.
              final pending = List<Future<File?>>.from(_generationFutures.values);
              if (pending.isNotEmpty) {
                try { await Future.wait(pending, eagerError: false); } catch (_) {}
              }
              try { await _kokoro.dispose(); } catch (_) {}
              try { await _audioCache.clear(); } catch (_) {}
              _ramAudioCache.clear();
              if (!mounted || token != _phraseGenerationToken) return;
              setState(() {
                _voiceId = v.id;
                _curInd = '—';
                _nextInd = '—';
                _curIndColor = _muted;
                _nextIndColor = _muted;
                _neuralReference16k = null;
                _lastRefAsr = null;
                _lastRefAsrAudio = null;
              });
              await _persist();
              await _refreshAudioCacheStats();
              if (ctx.mounted) Navigator.pop(ctx);
              if (!_browserMode && _ttsModelReady) {
                try {
                  if (Platform.isWindows) {
                    try { await _asrLoadFuture; } catch (_) {}
                    try { await _asr.dispose(); } catch (_) {}
                    _asrModelReady = false;
                    _asrLoadFuture = null;
                  }
                  _scheduleNeuralIdleWork();
                  // ASR и Auto-повторы не меняем; ASR поднимается как раньше.
                } catch (e) {
                  _logMsg('voice change: $e', level: 1);
                }
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          v.name,
                          style: TextStyle(
                            color: _text,
                            fontSize: 14,
                            fontWeight:
                                sel ? FontWeight.bold : FontWeight.w500,
                          ),
                        ),
                        Text(
                          v.gender,
                          style: const TextStyle(color: _muted, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  if (sel)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(Icons.check, color: _ok, size: 18),
                    ),
                  IconButton(
                    tooltip: 'Прослушать голос',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    onPressed: previewing
                        ? null
                        : () {
                            sheetSetState(() => previewingId = v.id);
                            unawaited(_previewVoice(v, (busy) {
                              if (!mounted) return;
                              try {
                                sheetSetState(() {
                                  if (busy) {
                                    previewingId = v.id;
                                  } else if (previewingId == v.id) {
                                    previewingId = null;
                                  }
                                });
                              } catch (_) {}
                            }));
                          },
                    icon: Icon(
                      previewing ? Icons.hourglass_top : Icons.play_arrow,
                      color: previewing ? _accent : _ok,
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          );
        }

        return SizedBox(
          width: sheetWidth,
          height: sheetHeight,
          child: StatefulBuilder(
            builder: (ctx, sheetSetState) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Text(
                      'Голос Piper',
                      style: TextStyle(
                        color: _text,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        header('Français (Piper)'),
                        ...us.map((v) => tile(v, sheetSetState)),
                        if (us.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'Голос Siwis (fr_FR)',
                              style: TextStyle(color: _muted),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }


  Future<bool> _confirmModelAction({required bool reload}) async {
    final title = reload ? 'Перезагрузить нейромодели?' : 'Очистить нейромодели?';
    final message = reload
        ? 'Текущие файлы ASR и Piper будут удалены после завершения уже начатых native-операций, затем модели будут скачаны заново.'
        : 'Файлы ASR и Piper будут удалены с устройства. Сгенерированные аудиофайлы кэша не удаляются этой кнопкой.';
    return await showDialog<bool>(
          context: context,
          builder: (dctx) => AlertDialog(
            backgroundColor: _card,
            title: Text(title, style: const TextStyle(color: _text)),
            content: Text(message, style: const TextStyle(color: _muted, height: 1.4)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: _accent, foregroundColor: Colors.black),
                onPressed: () => Navigator.pop(dctx, true),
                child: Text(reload ? 'Очистить и скачать' : 'Очистить'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _clearNeuralModelsOnly() async {
    await _waitForNativeWorkBeforeModelReset();
    try {
      await _models.clearModels();
      _ttsModelReady = false;
      _asrFilesReady = false;
      _asrModelReady = false;
      if (mounted) {
        setState(() => _status = 'Нейромодели удалены');
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Ошибка удаления моделей: $e');
    }
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.92,
          minChildSize: 0.55,
          maxChildSize: 0.96,
          builder: (ctx, scrollCtrl) {
            return StatefulBuilder(
              builder: (ctx, setLocal) {
                void upd(VoidCallback fn) {
                  setState(fn);
                  setLocal(() {});
                  _persist();
                }

                return ListView(
                  controller: scrollCtrl,
                  padding: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.of(ctx).padding.bottom + 32),
                  children: [
                    const Text('Настройки тренажёра',
                        style: TextStyle(
                            color: _text,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    // Tabs visual
                    Row(
                      children: [
                        Expanded(
                          child: _tabChip('Настройки', true, () {}),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: _tabChip('Память', false, () {
                            Navigator.pop(ctx);
                            _openMemorySheet();
                          }),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Модели ASR/TTS: Piper-82M + wav2vec2 · локальный ONNX.\n'
                      'Эталон для сравнения — непосредственно аудио Piper.',
                      style: const TextStyle(color: _muted, fontSize: 11, height: 1.35),
                    ),
                    const SizedBox(height: 14),
                    _sectionTitle('eSpeak NG'),
                    const Text(
                      'Озвучка в режиме «Браузерный» и IPA-транскрипция. '
                      'Голос роботизированный, зато французский offline.',
                      style: TextStyle(color: _muted, fontSize: 11, height: 1.35),
                    ),
                    const SizedBox(height: 6),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'Скачать eSpeak NG',
                        style: TextStyle(color: _accent, fontSize: 14),
                      ),
                      subtitle: const Text(
                        'github.com/espeak-ng/espeak-ng/releases',
                        style: TextStyle(color: _muted, fontSize: 11),
                      ),
                      trailing: const Icon(Icons.open_in_new, color: _accent, size: 18),
                      onTap: () => _openExternalUrl(_espeakDownloadUrl),
                    ),
                    const SizedBox(height: 14),
                    _sectionTitle('Сравнение'),
                    const Text(
                      'Сравнение по словам (Zipformer FR). Фонемы английского ASR отключены.',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    _sectionTitle('Сложность'),
                    Wrap(
                      spacing: 10,
                      children: [
                        _radio(
                          selected: _difficulty == 'easy',
                          label: 'Лёгкий',
                          onTap: () => upd(() => _difficulty = 'easy'),
                        ),
                        _radio(
                          selected: _difficulty == 'mid',
                          label: 'Средний',
                          onTap: () => upd(() => _difficulty = 'mid'),
                        ),
                        _radio(
                          selected: _difficulty == 'high',
                          label: 'Высокий',
                          onTap: () => upd(() => _difficulty = 'high'),
                        ),
                      ],
                    ),
                    const Text(
                      'Высокий — как раньше. Средний/лёгкий — мягче пороги в Auto.',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                    const SizedBox(height: 12),
                    _sectionTitle('Кэш нейро-аудио'),
                    _radio(
                      selected: _neuralKeep == 'pair',
                      label: '2 файла (текущий + следующий)',
                      onTap: () {
                        upd(() => _neuralKeep = 'pair');
                        if (!_browserMode && _ttsModelReady) {
                          unawaited(_applyCachePolicy());
                          _scheduleNeuralIdleWork();
                        }
                      },
                    ),
                    const SizedBox(height: 4),
                    _radio(
                      selected: _neuralKeep == 'all',
                      label: 'Все фразы списка',
                      onTap: () {
                        upd(() => _neuralKeep = 'all');
                        // «Все» хранит WAV всего списка на диске, но не PCM в RAM.
                        // Последовательно генерируем отсутствующие файлы в idle.
                        if (!_browserMode && _ttsModelReady) _scheduleNeuralIdleWork();
                      },
                    ),
                    const SizedBox(height: 12),
                    const SizedBox(height: 12),
                    _label('Вставка из буфера'),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        'Пропускать дубликаты',
                        style: TextStyle(color: _text, fontSize: 13),
                      ),
                      subtitle: const Text(
                        'Да — точные совпадения не добавляются. Нет — все фразы из буфера попадают в список.',
                        style: TextStyle(color: _muted, fontSize: 11),
                      ),
                      value: _pasteSkipDuplicates,
                      activeColor: _ok,
                      onChanged: (v) =>
                          upd(() => _pasteSkipDuplicates = v ?? true),
                    ),
                    const SizedBox(height: 12),
                    // Microphone expandable
                    Theme(
                      data: Theme.of(context).copyWith(
                        dividerColor: Colors.transparent,
                        unselectedWidgetColor: _muted,
                      ),
                      child: ExpansionTile(
                        initiallyExpanded: false,
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Микрофон и запись',
                            style: TextStyle(color: _text, fontSize: 14)),
                        iconColor: _muted,
                        collapsedIconColor: _muted,
                        children: [
                          _label(
                              'Порог начала записи (детектор речи)'),
                          SliderTheme(
                            data: _sliderTheme(active: const Color(0xFF2196F3)),
                            child: Slider(
                              value: _micSens,
                              min: 0,
                              max: 1,
                              onChanged: (v) => upd(() => _micSens = v),
                            ),
                          ),
                          Text(
                            'Сейчас: ${(_micSens * 100).round()}%\n'
                            'Правее — легче «услышать» речь (тише звуки запускают запись).\n'
                            'Левее — только более громкая речь; тихие шумы игнорируются.\n'
                            'На громкость самой записи не влияет — только когда запись начинается и заканчивается.',
                            style: const TextStyle(color: _muted, fontSize: 11, height: 1.35),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text(
                                'Выравнивать громкость «Моя запись»',
                                style: TextStyle(color: _text, fontSize: 13)),
                            subtitle: const Text(
                              'При воспроизведении «Я»: чуть тише/громче по пику записи. Сам файл не меняется.',
                              style: TextStyle(color: _muted, fontSize: 11),
                            ),
                            value: _micAgc,
                            activeColor: _ok,
                            onChanged: (v) =>
                                upd(() => _micAgc = v ?? true),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text('Сигнал перед началом записи',
                                style: TextStyle(color: _text, fontSize: 13)),
                            subtitle: const Text(
                              'В ручном можно выключить. В Auto сигнал всегда.',
                              style: TextStyle(color: _muted, fontSize: 11),
                            ),
                            value: _recordBeep,
                            activeColor: _ok,
                            onChanged: (v) =>
                                upd(() => _recordBeep = v ?? true),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text(
                                'Автоматически воспроизводить мою запись',
                                style: TextStyle(color: _text, fontSize: 13)),
                            subtitle: const Text(
                              'В ручном — по настройке. В Auto — всегда.',
                              style: TextStyle(color: _muted, fontSize: 11),
                            ),
                            value: _autoPlayRecorded,
                            activeColor: _ok,
                            onChanged: (v) =>
                                upd(() => _autoPlayRecorded = v ?? true),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            dense: true,
                            title: const Text(
                                'Выравнивать громкость записи для ASR',
                                style: TextStyle(color: _text, fontSize: 13)),
                            subtitle: const Text(
                              'Только копия для ASR; на кнопку «Я» не влияет.',
                              style: TextStyle(color: _muted, fontSize: 11),
                            ),
                            value: _asrVolumeMatch,
                            activeColor: _ok,
                            onChanged: (v) =>
                                upd(() => _asrVolumeMatch = v ?? true),
                          ),
                          const SizedBox(height: 6),
                          OutlinedButton(
                            onPressed: () async {
                              setState(() {
                                _recStatus = 'Тест микрофона…';
                                _micTestHint = 'Говорите…';
                              });
                              setLocal(() {});
                              // обновляем индикатор уровня, пока идёт запись
                              final ticker = Stream.periodic(
                                      const Duration(milliseconds: 120))
                                  .listen((_) {
                                if (_recording) setLocal(() {});
                              });
                              final ok =
                                  await _runRecordingSession(auto: false);
                              await ticker.cancel();
                              setState(() {
                                _status = ok
                                    ? 'Тест: OK — запись проиграна'
                                    : 'Тест: ${_recStatus.isNotEmpty ? _recStatus : "не удалось"}';
                                _micTestHint = ok
                                    ? 'Тест завершён'
                                    : (_recStatus.isNotEmpty
                                        ? _recStatus
                                        : 'Нет голоса / ошибка');
                              });
                              setLocal(() {});
                            },
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _text,
                              side: const BorderSide(color: _border),
                            ),
                            child: const Text(
                                'Тест микрофона (запись → воспроизведение)'),
                          ),
                          const SizedBox(height: 10),
                          _levelBar(),
                          const SizedBox(height: 4),
                          Text(
                            _recStatus.isEmpty ? ' ' : _recStatus,
                            style: const TextStyle(color: _muted, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    _sectionTitle('Лог'),
                    Wrap(
                      spacing: 10,
                      children: [
                        _radio(
                          selected: _logLevel == 0,
                          label: 'Выкл',
                          onTap: () => upd(() => _logLevel = 0),
                        ),
                        _radio(
                          selected: _logLevel == 1,
                          label: 'Обычный',
                          onTap: () => upd(() => _logLevel = 1),
                        ),
                        _radio(
                          selected: _logLevel == 2,
                          label: 'Расширенный',
                          onTap: () => upd(() => _logLevel = 2),
                        ),
                      ],
                    ),
                    const Text(
                      'По умолчанию выкл. Расширенный — детали записи/сравнения.',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton(
                      onPressed: () async {
                        await _clearTempFiles();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _text,
                        side: const BorderSide(color: _border),
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('Очистить временные файлы тренажёра'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Удаляет сгенерированные нейро-файлы и временные WAV. Модели не трогает.',
                      style: TextStyle(color: _muted, fontSize: 11),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton(
                      onPressed: () async {
                        final ok = await _confirmModelAction(reload: false);
                        if (!ok) return;
                        Navigator.pop(ctx);
                        await _clearNeuralModelsOnly();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _text,
                        side: const BorderSide(color: _border),
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('Очистить нейромодели'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () async {
                        final ok = await _confirmModelAction(reload: true);
                        if (!ok) return;
                        Navigator.pop(ctx);
                        await _downloadModels(forceReload: true);
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _text,
                        side: const BorderSide(color: _border),
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child:
                          const Text('Очистить и перезагрузить нейромодели'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _downloadModels();
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _accent,
                        side: const BorderSide(color: _accent),
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('Скачать нейромодели сейчас'),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF2A2A2A),
                        foregroundColor: _text,
                        minimumSize: const Size.fromHeight(44),
                      ),
                      child: const Text('Закрыть'),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  String _formatBytes(int b) {
    if (b < 1024) return '${b} B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1024 * 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(b / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _openMemorySheet() async {
    await _refreshAudioCacheStats();
    var modelsBytes = 0;
    var modelsPath = '—';
    try {
      modelsBytes = await _models.modelsDirBytes();
      final root = await _models.rootDir();
      modelsPath = root.path;
    } catch (_) {}
    var sherpaBytes = 0;
    try {
      final sherpaDir = await _models.sherpaTtsModelDir();
      if (await sherpaDir.exists()) {
        await for (final e in sherpaDir.list(recursive: true, followLinks: false)) {
          if (e is File) sherpaBytes += await e.length();
        }
      }
    } catch (_) {}
    final totalModels = modelsBytes + sherpaBytes;

    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      showDragHandle: true,
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Память и кэш тренажёра',
                  style: TextStyle(
                    color: _text,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Нейромодели и сгенерированные фразы хранятся отдельно.\n'
                  'Фразы Piper не генерируются повторно: кэш учитывает текст, голос и скорость.',
                  style: TextStyle(color: _muted, fontSize: 12, height: 1.35),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141414),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _border),
                  ),
                  child: Text(
                    'Нейромодели на диске: ${_formatBytes(totalModels)}\n'
                    '  · ASR + служебные: ${_formatBytes(modelsBytes)}\n'
                    '  · Piper TTS: ${_formatBytes(sherpaBytes)}\n'
                    'ASR Session: ${_asrModelReady ? 'готов' : 'нет'}\n'
                    'Нейро-аудио (фразы): $_audioCacheCount · ${_formatBytes(_audioCacheBytes)}\n'
                    'Каталог моделей:\n$modelsPath',
                    style: const TextStyle(color: _text, fontSize: 13, height: 1.45),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _clearNeuralAudioCache();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _accent,
                    side: const BorderSide(color: _accent),
                    minimumSize: const Size.fromHeight(44),
                  ),
                  child: const Text('Очистить кэш нейро-аудио'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF2A2A2A),
                    foregroundColor: _text,
                  ),
                  child: const Text('Закрыть'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Как пользоваться', style: TextStyle(color: _text)),
        content: const SingleChildScrollView(
          child: Text(
            'Первый запуск\n\n'
            '1. Включите «Нейро» и дождитесь зелёных точек ASR и TTS. Первый раз модели скачиваются из интернета и это может занять несколько минут.\n\n'
            '2. Если загрузка зависла, проверьте интернет/VPN. В ⚙️ есть «Очистить и перезагрузить нейромодели».\n\n'
            '3. Пока модели грузятся, можно пользоваться «Браузерным» режимом — он не требует нейромоделей.\n\n'
            'Режимы и кнопки\n\n'
            '• «Браузерный» — системный голос телефона, быстро, без нейромоделей.\n'
            '• «Нейро» — Piper + нейроанализ произношения. Голос выбирается рядом с режимом.\n'
            '• «Текущая / Следующая» — состояние конкретного аудиофайла: ✓ готов, ⏳ генерация, — файла ещё нет.\n'
            '• «Браузер / Нейро» в карточке — воспроизведение эталона. Во время воспроизведения кнопка становится «Стоп»; повторное нажатие продолжает воспроизведение там, где это поддерживает движок.\n'
            '• «Запись» — после сигнала говорите; запись останавливается после паузы.\n'
            '• «Я» — воспроизведение вашей последней записи.\n'
            '• «Старт» — автоматический цикл тренировки.\n'
            '• «Простой / Подробный» — краткий или детальный результат сравнения.\n'
            '• ⚙️ — сравнение по словам/фонемам, сложность, кэш, микрофон и лог.\n\n'
            'Кэш\n\n'
            'В режиме «2 файла» хранятся только текущая и следующая фразы. При смене голоса, скорости или split_pattern старые варианты не считаются готовыми и создаются заново.\n\n'
            'В режиме «Все фразы списка» сохраняются все варианты текущего списка с учётом голоса, скорости и split_pattern.\n\n'
            'Оценка\n\n'
            'При сравнении по словам цвет слова показывает качество: зелёный — совпадение, жёлтый/оранжевый — промежуточный результат, красный — заметное расхождение. В подробном режиме можно посмотреть фонемные детали.\n\n'
            'Фонемный режим показывает соответствие отдельных фонем: зелёные совпали, красные отличаются, оранжевые обозначают лишние фонемы.\n\n'
            'Индикаторы ASR и TTS\n\n'
            'Зелёный — движок готов. Быстро мигающий оранжевый — загрузка/подготовка. Быстро мигающий зелёный — сейчас идёт TTS или ASR-анализ.',
            style: TextStyle(color: _muted, fontSize: 13, height: 1.45),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно')),
        ],
      ),
    );
  }

  Widget _tabChip(String label, bool selected, VoidCallback onTap) {
    return Material(
      color: selected ? const Color(0xFF2A2A2A) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _border),
          ),
          child: Text(label,
              style: TextStyle(
                  color: _text,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
        ),
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t,
            style: const TextStyle(
                color: _text, fontWeight: FontWeight.w600, fontSize: 14)),
      );

  SliderThemeData _sliderTheme({Color active = const Color(0xFF2196F3)}) {
    return SliderTheme.of(context).copyWith(
      activeTrackColor: active,
      inactiveTrackColor: const Color(0xFF333333),
      thumbColor: Colors.white,
      overlayColor: active.withOpacity(0.15),
      trackHeight: 3,
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 0, top: 2),
        child: Text(t, style: const TextStyle(color: _muted, fontSize: 11)),
      );

  Widget _radio({
    required bool selected,
    required String label,
    VoidCallback? onTap,
    bool compact = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: compact ? 16 : 18,
            color: selected ? const Color(0xFF2196F3) : _muted,
          ),
          SizedBox(width: compact ? 4 : 6),
          Text(label,
              style: TextStyle(
                  color: _text, fontSize: compact ? 12 : 13)),
        ],
      ),
    );
  }

  Widget _iconBtn(
    IconData icon,
    VoidCallback? onTap, {
    double size = 40,
    bool highlight = false,
  }) {
    return Material(
      color: highlight ? const Color(0xFF315A8A) : const Color(0xFF2A2A2A),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: highlight ? const Color(0xFF4C8DFF) : Colors.transparent,
              width: highlight ? 2 : 0,
            ),
          ),
          child: Transform.translate(
            offset: highlight ? const Offset(0, -1) : Offset.zero,
            child: Icon(icon, size: 18, color: onTap == null ? _muted : _text),
          ),
        ),
      ),
    );
  }

  Widget _actionBtn({
    required IconData icon,
    required String label,
    Color color = _text,
    bool highlight = false,
    Color highlightColor = const Color(0xFF4C8DFF),
    bool compact = false,
    VoidCallback? onTap,
  }) {
    final border = highlight
        ? Border.all(color: highlightColor, width: 2)
        : Border.all(color: _border);
    return Material(
      color: const Color(0xFF222222),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: EdgeInsets.symmetric(
              vertical: compact ? 8 : 11, horizontal: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: border,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: compact ? 15 : 17,
                  color: onTap == null ? _muted : color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: onTap == null ? _muted : color,
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 12 : 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bigBtn({
    IconData? icon,
    required String label,
    VoidCallback? onTap,
  }) {
    return Material(
      color: const Color(0xFF1E1E1E),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _border),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, color: _text, size: 18),
                const SizedBox(width: 8),
              ],
              Text(label,
                  style: const TextStyle(
                      color: _text, fontSize: 14, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}
