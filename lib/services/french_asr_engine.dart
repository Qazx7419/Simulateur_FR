/// French ASR: sherpa-onnx streaming Zipformer FR, offline batch after recording.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class FrenchAsrEngine {
  sherpa.OnlineRecognizer? _recognizer;
  String? _loadedKey;
  bool _bindings = false;

  Future<void> _ensureBindings() async {
    if (_bindings) return;
    sherpa.initBindings();
    _bindings = true;
  }

  Future<void> load({
    required String encoder,
    required String decoder,
    required String joiner,
    required String tokens,
  }) async {
    await _ensureBindings();
    final key = '$encoder|$decoder|$joiner|$tokens';
    if (_recognizer != null && _loadedKey == key) return;
    dispose();

    for (final path in [encoder, decoder, joiner, tokens]) {
      final f = File(path);
      if (!f.existsSync()) {
        throw StateError('ASR файл не найден: $path');
      }
      if (f.lengthSync() < 10) {
        throw StateError('ASR файл пустой: $path');
      }
    }

    final config = sherpa.OnlineRecognizerConfig(
      feat: const sherpa.FeatureConfig(
        sampleRate: 16000,
        featureDim: 80,
      ),
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: encoder,
          decoder: decoder,
          joiner: joiner,
        ),
        tokens: tokens,
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
      // Offline batch: endpoint-правила мешают, если весь файл скормили сразу.
      enableEndpoint: false,
    );

    try {
      _recognizer = sherpa.OnlineRecognizer(config);
    } catch (e) {
      // FeatureConfig имя может отличаться в 1.13.3 — fallback без feat.
      try {
        final config2 = sherpa.OnlineRecognizerConfig(
          model: sherpa.OnlineModelConfig(
            transducer: sherpa.OnlineTransducerModelConfig(
              encoder: encoder,
              decoder: decoder,
              joiner: joiner,
            ),
            tokens: tokens,
            numThreads: 2,
            provider: 'cpu',
            debug: false,
          ),
          enableEndpoint: false,
        );
        _recognizer = sherpa.OnlineRecognizer(config2);
      } catch (e2) {
        throw StateError(
          'OnlineRecognizer: $e | fallback: $e2\n'
          'enc=$encoder (${File(encoder).lengthSync()} b)\n'
          'dec=$decoder (${File(decoder).lengthSync()} b)\n'
          'join=$joiner (${File(joiner).lengthSync()} b)\n'
          'tok=$tokens (${File(tokens).lengthSync()} b)',
        );
      }
    }
    _loadedKey = key;
  }

  /// [samples] — mono float32, ideally 16 kHz.
  Future<String> recognize({
    required Float32List samples,
    required int sampleRate,
  }) async {
    final rec = _recognizer;
    if (rec == null) throw StateError('French ASR не загружен');
    if (samples.isEmpty) return '';

    // Нормализация уровня (тихий mic / диктофон).
    var peak = 0.0;
    for (final v in samples) {
      final a = v.abs();
      if (a > peak) peak = a;
    }
    Float32List input = samples;
    if (peak > 1e-6 && peak < 0.25) {
      final g = 0.6 / peak;
      input = Float32List(samples.length);
      for (var i = 0; i < samples.length; i++) {
        input[i] = (samples[i] * g).clamp(-1.0, 1.0);
      }
    }

    final stream = rec.createStream();
    try {
      // Chunked feed — стабильнее для streaming encoder, чем один большой кусок.
      const chunk = 16000; // 1 s @ 16k
      var off = 0;
      while (off < input.length) {
        final end = math.min(off + chunk, input.length);
        final slice = Float32List.sublistView(input, off, end);
        stream.acceptWaveform(samples: slice, sampleRate: sampleRate);
        while (rec.isReady(stream)) {
          rec.decode(stream);
        }
        off = end;
      }
      // Хвост тишины, чтобы flush внутренних буферов.
      final tail = Float32List(sampleRate);
      stream.acceptWaveform(samples: tail, sampleRate: sampleRate);
      try {
        stream.inputFinished();
      } catch (_) {}
      while (rec.isReady(stream)) {
        rec.decode(stream);
      }
      final result = rec.getResult(stream);
      var text = (result.text).trim();
      // Иногда модель оставляет BPE-маркеры.
      text = text.replaceAll('▁', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
      return text;
    } finally {
      try {
        stream.free();
      } catch (_) {}
    }
  }

  void dispose() {
    try {
      _recognizer?.free();
    } catch (_) {}
    _recognizer = null;
    _loadedKey = null;
  }
}
