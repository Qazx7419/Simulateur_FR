/// Piper VITS French TTS via sherpa-onnx OfflineTts (isolate).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

class PiperEngine {
  Isolate? _isolate;
  SendPort? _send;
  ReceivePort? _receive;
  StreamSubscription? _subscription;
  int _nextId = 0;
  final Map<int, Completer<Float32List>> _pending = {};
  Future<void> _queue = Future<void>.value();
  Completer<void>? _workerStopped;
  int sampleRate = 16000;

  Future<void> _ensureWorker() async {
    if (_send != null) return;
    final ready = Completer<SendPort>();
    final receive = ReceivePort();
    _receive = receive;
    _workerStopped = Completer<void>();
    _subscription = receive.listen((message) {
      if (message is List && message.isNotEmpty && message[0] == -2) {
        final stopped = _workerStopped;
        if (stopped != null && !stopped.isCompleted) stopped.complete();
        return;
      }
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }
      if (message is List && message.length >= 3 && message[0] is int) {
        final id = message[0] as int;
        final ok = message[1] == true;
        final c = _pending.remove(id);
        if (c == null) return;
        if (ok) {
          final payload = message[2];
          if (payload is TransferableTypedData) {
            final data = payload.materialize();
            c.complete(data.asFloat32List());
          } else {
            c.completeError(StateError('bad audio payload'));
          }
        } else {
          c.completeError(StateError('${message[2]}'));
        }
      }
    });
    _isolate = await Isolate.spawn(_workerMain, receive.sendPort);
    _send = await ready.future;
  }

  Future<Float32List> synthesize({
    required String text,
    required String modelPath,
    required String tokensPath,
    required String dataDir,
    double speed = 1.0,
  }) {
    final done = Completer<Float32List>();
    _queue = _queue.then((_) async {
      try {
        await _ensureWorker();
        final id = ++_nextId;
        _pending[id] = done;
        _send!.send(<Object?>[id, text, modelPath, tokensPath, dataDir, speed]);
        await done.future;
      } catch (e, st) {
        if (!done.isCompleted) done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<void> dispose() async {
    final send = _send;
    if (send != null) {
      send.send(const <Object?>[-1]);
      try {
        await _workerStopped?.future.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await _subscription?.cancel();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _receive?.close();
    _receive = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('disposed'));
    }
    _pending.clear();
  }

  static void _workerMain(SendPort mainPort) async {
    final receive = ReceivePort();
    mainPort.send(receive.sendPort);
    try {
      sherpa.initBindings();
    } catch (e) {
      mainPort.send(<Object?>[-1, false, 'initBindings: $e']);
      return;
    }

    sherpa.OfflineTts? tts;
    String? loadedKey;

    Future<void> load(String model, String tokens, String dataDir) async {
      final key = '$model|$tokens|$dataDir';
      if (tts != null && loadedKey == key) return;
      tts?.free();
      tts = null;
      loadedKey = null;
      for (final path in [model, tokens]) {
        if (!File(path).existsSync()) {
          throw StateError('Нет файла Piper: $path');
        }
      }
      if (!Directory(dataDir).existsSync()) {
        throw StateError('Нет espeak-ng-data: $dataDir');
      }
      final config = sherpa.OfflineTtsConfig(
        model: sherpa.OfflineTtsModelConfig(
          vits: sherpa.OfflineTtsVitsModelConfig(
            model: model,
            tokens: tokens,
            dataDir: dataDir,
          ),
          numThreads: 2,
          provider: 'cpu',
          debug: false,
        ),
        maxNumSenetences: 1,
      );
      tts = sherpa.OfflineTts(config);
      loadedKey = key;
    }

    await for (final msg in receive) {
      if (msg is List && msg.isNotEmpty && msg[0] == -1) break;
      if (msg is! List || msg.length < 6) continue;
      final id = msg[0] as int;
      final text = msg[1] as String;
      final model = msg[2] as String;
      final tokens = msg[3] as String;
      final dataDir = msg[4] as String;
      final speed = (msg[5] as num).toDouble();
      try {
        if (text.trim().isEmpty) throw StateError('Пустой текст');
        await load(model, tokens, dataDir);
        final audio = tts!.generate(text: text, sid: 0, speed: speed);
        final samples = Float32List.fromList(audio.samples);
        mainPort.send(<Object?>[id, true, TransferableTypedData.fromList([samples])]);
      } catch (e) {
        mainPort.send(<Object?>[id, false, '$e']);
      }
    }
    try {
      tts?.free();
    } catch (_) {}
    mainPort.send(const <Object?>[-2]);
  }

  static Uint8List floatToWav(Float32List samples, {int sampleRate = 16000}) {
    final dataSize = samples.length * 2;
    final bytes = BytesBuilder();
    void u32(int v) =>
        bytes.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
    void u16(int v) => bytes.add([v & 255, (v >> 8) & 255]);
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
      final v = (s.clamp(-1.0, 1.0) * 32767).round();
      final x = v < 0 ? v + 65536 : v;
      bytes.add([x & 255, (x >> 8) & 255]);
    }
    return bytes.toBytes();
  }
}
