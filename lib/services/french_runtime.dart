/// Shared paths after FrenchModelsService.ensureModels().
library;

class FrenchRuntime {
  static String? piperModel;
  static String? piperTokens;
  static String? piperDataDir;
  static String? asrEncoder;
  static String? asrDecoder;
  static String? asrJoiner;
  static String? asrTokens;

  static bool get ttsOk =>
      piperModel != null && piperTokens != null && piperDataDir != null;
  static bool get asrOk =>
      asrEncoder != null &&
      asrDecoder != null &&
      asrJoiner != null &&
      asrTokens != null;
}
