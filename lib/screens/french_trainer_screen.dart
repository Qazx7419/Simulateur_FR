import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/french_asr_engine.dart';
import '../services/french_models.dart';
import '../services/piper_engine.dart';
import '../utils/french_text_score.dart';

const _phrasesKey = 'french-trainer-phrases-v11';
const _posKey = 'french-trainer-pos-v11';

class _MemWav extends StreamAudioSource {
  _MemWav(this.bytes);
  final Uint8List bytes;
  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, bytes.length);
    final to = (end ?? bytes.length).clamp(from, bytes.length);
    return StreamAudioResponse(
      sourceLength: bytes.length,
      contentLength: to - from,
      offset: from,
      stream: Stream.value(bytes.sublist(from, to)),
      contentType: 'audio/wav',
    );
  }
}

class FrenchTrainerScreen extends StatefulWidget {
  const FrenchTrainerScreen({super.key});

  @override
  State<FrenchTrainerScreen> createState() => _FrenchTrainerScreenState();
}

class _FrenchTrainerScreenState extends State<FrenchTrainerScreen> {
  final _models = FrenchModelsService();
  final _piper = PiperEngine();
  final _asr = FrenchAsrEngine();
  final _player = AudioPlayer();
  final _recorder = AudioRecorder();
  final _log = <String>[];

  List<String> _phrases = const [
    'Bonjour, comment allez-vous ?',
    'Je voudrais pratiquer ma prononciation.',
    'Pourriez-vous répéter plus lentement, s\'il vous plaît ?',
    'Où se trouve la gare, s\'il vous plaît ?',
    'Je ne parle pas très bien français.',
  ];
  int _index = 0;
  bool _busy = false;
  bool _recording = false;
  String _status = 'Загрузка моделей…';
  String _lastAsr = '';
  TextScore? _score;
  double _speed = 1.0;

  String get _current =>
      _phrases.isEmpty ? '' : _phrases[_index.clamp(0, _phrases.length - 1)];

  @override
  void initState() {
    super.initState();
    _models.onLog = (m) {
      _logMsg(m);
    };
    _models.onStatus = () {
      if (!mounted) return;
      setState(() {
        if (_models.progressText.isNotEmpty) _status = _models.progressText;
        if (_models.error.isNotEmpty) _status = _models.error;
      });
    };
    _boot();
  }

  Future<void> _boot() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_phrasesKey);
    if (raw != null && raw.trim().isNotEmpty) {
      _phrases = raw.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }
    _index = (p.getInt(_posKey) ?? 0).clamp(0, _phrases.isEmpty ? 0 : _phrases.length - 1);
    if (mounted) setState(() {});
    try {
      await _models.ensureModels();
      final t = await _models.ttsPaths();
      final a = await _models.asrPaths();
      await _asr.load(
        encoder: a.encoder,
        decoder: a.decoder,
        joiner: a.joiner,
        tokens: a.tokens,
      );
      if (!mounted) return;
      setState(() => _status = 'Готово · Piper siwis + Zipformer FR');
      _logMsg('✓ ASR и TTS загружены');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Ошибка: $e');
      _logMsg('$e');
    }
  }

  void _logMsg(String m) {
    _log.insert(0, m);
    if (_log.length > 80) _log.removeLast();
    if (mounted) setState(() {});
  }

  Future<void> _savePhrases() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_phrasesKey, _phrases.join('\n'));
    await p.setInt(_posKey, _index);
  }

  Future<void> _playReference() async {
    if (_busy || !_models.ttsReady) return;
    setState(() {
      _busy = true;
      _status = 'Синтез Piper…';
      _score = null;
      _lastAsr = '';
    });
    try {
      final t = await _models.ttsPaths();
      final samples = await _piper.synthesize(
        text: _current,
        modelPath: t.model,
        tokensPath: t.tokens,
        dataDir: t.dataDir,
        speed: _speed,
      );
      final wav = PiperEngine.floatToWav(samples, sampleRate: 16000);
      await _player.setAudioSource(_MemWav(wav));
      await _player.play();
      setState(() => _status = 'Воспроизведение эталона');
    } catch (e) {
      setState(() => _status = 'TTS: $e');
      _logMsg('TTS error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleRecord() async {
    if (_recording) {
      await _stopRecordAndScore();
      return;
    }
    if (_busy || !_models.asrReady) return;
    final ok = await _recorder.hasPermission();
    if (!ok) {
      setState(() => _status = 'Нет доступа к микрофону');
      return;
    }
    setState(() {
      _recording = true;
      _busy = true;
      _status = 'Запись…';
      _score = null;
      _lastAsr = '';
    });
    try {
      // PCM stream 16 kHz mono
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      final chunks = <int>[];
      final sub = stream.listen((data) => chunks.addAll(data));
      // храним подписку в объекте через zone — упростим: ждём stop
      _recChunks = chunks;
      _recSub = sub;
    } catch (e) {
      setState(() {
        _recording = false;
        _busy = false;
        _status = 'Запись: $e';
      });
      _logMsg('record: $e');
    }
  }

  List<int> _recChunks = [];
  StreamSubscription<List<int>>? _recSub;

  Future<void> _stopRecordAndScore() async {
    try {
      await _recorder.stop();
      await _recSub?.cancel();
      _recSub = null;
      final bytes = Uint8List.fromList(_recChunks);
      _recChunks = [];
      if (bytes.length < 3200) {
        setState(() {
          _recording = false;
          _busy = false;
          _status = 'Слишком короткая запись';
        });
        return;
      }
      // pcm16 → float32
      final n = bytes.length ~/ 2;
      final samples = Float32List(n);
      final bd = ByteData.sublistView(bytes);
      for (var i = 0; i < n; i++) {
        samples[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
      }
      setState(() => _status = 'ASR Zipformer FR…');
      final text = await _asr.recognize(samples: samples, sampleRate: 16000);
      final score = scoreFrench(_current, text);
      if (!mounted) return;
      setState(() {
        _lastAsr = text;
        _score = score;
        _status =
            'ASR: «$text» · ${score.percent}% · ${score.label} (${score.matched}/${score.total})';
        _recording = false;
        _busy = false;
      });
      _logMsg(_status);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _recording = false;
        _busy = false;
        _status = 'ASR: $e';
      });
      _logMsg('ASR error: $e');
    }
  }

  Future<void> _editPhrases() async {
    final ctrl = TextEditingController(text: _phrases.join('\n'));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Фразы (по одной на строку)'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: ctrl,
            maxLines: 12,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
        ],
      ),
    );
    if (ok == true) {
      final list = ctrl.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (list.isNotEmpty) {
        setState(() {
          _phrases = list;
          _index = _index.clamp(0, list.length - 1);
        });
        await _savePhrases();
      }
    }
  }

  @override
  void dispose() {
    _recSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    _piper.dispose();
    _asr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _models.ttsReady && _models.asrReady;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Тренажёр FR · Piper + Zipformer'),
        actions: [
          IconButton(
            tooltip: 'Фразы',
            onPressed: _editPhrases,
            icon: const Icon(Icons.edit_note),
          ),
          IconButton(
            tooltip: 'Перекачать модели',
            onPressed: _busy
                ? null
                : () async {
                    await _models.clear();
                    await _boot();
                  },
            icon: const Icon(Icons.cloud_download_outlined),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Фраза ${_phrases.isEmpty ? 0 : _index + 1} / ${_phrases.length}',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _current,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (_lastAsr.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('Вы: $_lastAsr',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                          )),
                    ],
                    if (_score != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        '${_score!.percent}% · ${_score!.label}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Скорость'),
                Expanded(
                  child: Slider(
                    value: _speed,
                    min: 0.7,
                    max: 1.3,
                    divisions: 12,
                    label: _speed.toStringAsFixed(2),
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _speed = v),
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: !ready || _busy ? null : _playReference,
                  icon: const Icon(Icons.volume_up),
                  label: const Text('Эталон (Piper)'),
                ),
                FilledButton.tonalIcon(
                  onPressed: !ready || (_busy && !_recording)
                      ? null
                      : _toggleRecord,
                  icon: Icon(_recording ? Icons.stop : Icons.mic),
                  label: Text(_recording ? 'Стоп + оценка' : 'Запись'),
                ),
                OutlinedButton(
                  onPressed: _phrases.isEmpty || _busy
                      ? null
                      : () async {
                          setState(() {
                            _index = (_index - 1 + _phrases.length) % _phrases.length;
                            _score = null;
                            _lastAsr = '';
                          });
                          await _savePhrases();
                        },
                  child: const Text('←'),
                ),
                OutlinedButton(
                  onPressed: _phrases.isEmpty || _busy
                      ? null
                      : () async {
                          setState(() {
                            _index = (_index + 1) % _phrases.length;
                            _score = null;
                            _lastAsr = '';
                          });
                          await _savePhrases();
                        },
                  child: const Text('→'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Лог', style: Theme.of(context).textTheme.titleSmall),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
