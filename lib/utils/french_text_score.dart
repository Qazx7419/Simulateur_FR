/// Сравнение эталонной французской фразы с распознанным текстом ASR.
library;

final _punct = RegExp(r"[^\wàâäéèêëïîôùûüÿçæœÀÂÄÉÈÊËÏÎÔÙÛÜŸÇÆŒ'\-]+", unicode: true);

List<String> tokenizeFr(String text) {
  final norm = text
      .toLowerCase()
      .replaceAll('’', "'")
      .replaceAll('`', "'");
  return norm
      .split(_punct)
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
}

class TextScore {
  TextScore({
    required this.percent,
    required this.matched,
    required this.total,
    required this.refWords,
    required this.hypWords,
  });
  final int percent;
  final int matched;
  final int total;
  final List<String> refWords;
  final List<String> hypWords;

  String get label {
    if (percent >= 85) return 'Отлично';
    if (percent >= 65) return 'Хорошо';
    if (percent >= 45) return 'Приемлемо';
    return 'Слабо';
  }
}

/// Простое покрытие слов эталона гипотезой (порядок учитывается жадно).
TextScore scoreFrench(String reference, String hypothesis) {
  final ref = tokenizeFr(reference);
  final hyp = tokenizeFr(hypothesis);
  if (ref.isEmpty) {
    return TextScore(
      percent: hypothesis.trim().isEmpty ? 0 : 50,
      matched: 0,
      total: 0,
      refWords: ref,
      hypWords: hyp,
    );
  }
  var i = 0;
  var matched = 0;
  for (final w in hyp) {
    if (i < ref.length && w == ref[i]) {
      matched++;
      i++;
    } else if (ref.contains(w)) {
      // слово есть, но порядок сбит — половинный вклад не даём, только точное продвижение
      final idx = ref.indexOf(w, i);
      if (idx >= 0) {
        matched++;
        i = idx + 1;
      }
    }
  }
  final pct = ((100 * matched) / ref.length).round().clamp(0, 100);
  return TextScore(
    percent: pct,
    matched: matched,
    total: ref.length,
    refWords: ref,
    hypWords: hyp,
  );
}
