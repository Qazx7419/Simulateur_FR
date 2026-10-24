/// Shim: API KokoroEngine, внутри Piper fr_FR-siwis.
library;

import 'dart:typed_data';

import 'french_runtime.dart';
import 'piper_engine.dart';

class KokoroEngine {
  final PiperEngine _piper = PiperEngine();

  static const Map<String, int> voiceToSid = {
    'ff_siwis': 0,
  };

  static int sidForVoice(String voiceId) => 0;

  Future<Float32List> synthesize({
    required String text,
    required String modelDir,
    double speed = 0.88,
    String voiceId = 'ff_siwis',
    bool useSplitPattern = false,
  }) async {
    final model = FrenchRuntime.piperModel ?? '$modelDir/fr_FR-siwis-low.onnx';
    final tokens = FrenchRuntime.piperTokens ?? '$modelDir/tokens.txt';
    final dataDir = FrenchRuntime.piperDataDir ?? '$modelDir/espeak-ng-data';
    return _piper.synthesize(
      text: text,
      modelPath: model,
      tokensPath: tokens,
      dataDir: dataDir,
      speed: speed,
    );
  }

  Future<void> dispose() => _piper.dispose();

  /// Piper siwis: 16 kHz.
  static Uint8List floatToWav(Float32List samples, {int sampleRate = 16000}) {
    return PiperEngine.floatToWav(samples, sampleRate: sampleRate);
  }
}
