/// Shim: API AsrEngine, внутри Zipformer FR (текст → токены-слова).
library;

import 'dart:typed_data';

import 'french_asr_engine.dart';
import 'french_runtime.dart';

class AsrResult {
  const AsrResult({required this.tokens, required this.text});
  final List<String> tokens;
  final String text;
}

List<String> tokenizeFrenchAsrText(String text) {
  final norm = text
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll('`', "'")
      .replaceAll("'", ' ') // l'homme → l homme
      .replaceAll('-', ' ') // est-ce → est ce
      .replaceAll(RegExp(r'[^\wàâäéèêëïîôùûüÿçæœ\s]+', unicode: true), ' ');
  return norm
      .split(RegExp(r'\s+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

class AsrEngine {
  final FrenchAsrEngine _impl = FrenchAsrEngine();
  bool _loaded = false;

  Future<void> load({required String onnxPath, required String vocabPath}) async {
    if (!FrenchRuntime.asrOk) {
      throw StateError(
        'French ASR paths not set. Сначала ensureModels (Piper+Zipformer).',
      );
    }
    await _impl.load(
      encoder: FrenchRuntime.asrEncoder!,
      decoder: FrenchRuntime.asrDecoder!,
      joiner: FrenchRuntime.asrJoiner!,
      tokens: FrenchRuntime.asrTokens!,
    );
    _loaded = true;
  }

  Future<AsrResult> infer(Float32List audio16k) async {
    if (!_loaded) throw StateError('ASR Session not ready');
    final text = await _impl.recognize(samples: audio16k, sampleRate: 16000);
    final tokens = tokenizeFrenchAsrText(text);
    return AsrResult(tokens: tokens, text: text);
  }

  Future<void> dispose() async {
    _impl.dispose();
    _loaded = false;
  }
}
