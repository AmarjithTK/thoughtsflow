import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

// Linux x86-64 ABI, pinned to the official v1.12.34 c-api.h:
// https://github.com/k2-fsa/sherpa-onnx/blob/v1.12.34/sherpa-onnx/c-api/c-api.h
// All native work and ownership stay on one worker. No imported libraries load.
final class _Vits extends Struct {
  external Pointer<Uint8> model;
  external Pointer<Uint8> lexicon;
  external Pointer<Uint8> tokens;
  external Pointer<Uint8> data;
  @Float()
  external double noise;
  @Float()
  external double noiseW;
  @Float()
  external double length;
  external Pointer<Uint8> dict;
}

final class _Matcha extends Struct {
  external Pointer<Uint8> acoustic;
  external Pointer<Uint8> vocoder;
  external Pointer<Uint8> lexicon;
  external Pointer<Uint8> tokens;
  external Pointer<Uint8> data;
  @Float()
  external double noise;
  @Float()
  external double length;
  external Pointer<Uint8> dict;
}

final class _Kokoro extends Struct {
  external Pointer<Uint8> model;
  external Pointer<Uint8> voices;
  external Pointer<Uint8> tokens;
  external Pointer<Uint8> data;
  @Float()
  external double length;
  external Pointer<Uint8> dict;
  external Pointer<Uint8> lexicon;
  external Pointer<Uint8> lang;
}

final class _Kitten extends Struct {
  external Pointer<Uint8> model;
  external Pointer<Uint8> voices;
  external Pointer<Uint8> tokens;
  external Pointer<Uint8> data;
  @Float()
  external double length;
}

final class _Zipvoice extends Struct {
  external Pointer<Uint8> tokens;
  external Pointer<Uint8> encoder;
  external Pointer<Uint8> decoder;
  external Pointer<Uint8> vocoder;
  external Pointer<Uint8> data;
  external Pointer<Uint8> lexicon;
  @Float()
  external double feat;
  @Float()
  external double shift;
  @Float()
  external double rms;
  @Float()
  external double guidance;
}

final class _Pocket extends Struct {
  external Pointer<Uint8> flow;
  external Pointer<Uint8> main;
  external Pointer<Uint8> encoder;
  external Pointer<Uint8> decoder;
  external Pointer<Uint8> conditioner;
  external Pointer<Uint8> vocab;
  external Pointer<Uint8> scores;
  @Int32()
  external int capacity;
}

final class _Supertonic extends Struct {
  external Pointer<Uint8> duration;
  external Pointer<Uint8> encoder;
  external Pointer<Uint8> estimator;
  external Pointer<Uint8> vocoder;
  external Pointer<Uint8> json;
  external Pointer<Uint8> indexer;
  external Pointer<Uint8> style;
}

final class _Model extends Struct {
  external _Vits vits;
  @Int32()
  external int threads;
  @Int32()
  external int debug;
  external Pointer<Uint8> provider;
  external _Matcha matcha;
  external _Kokoro kokoro;
  external _Kitten kitten;
  external _Zipvoice zipvoice;
  external _Pocket pocket;
  external _Supertonic supertonic;
}

final class _Config extends Struct {
  external _Model model;
  external Pointer<Uint8> fsts;
  @Int32()
  external int sentences;
  external Pointer<Uint8> fars;
  @Float()
  external double silence;
}

final class _Generation extends Struct {
  @Float()
  external double silence;
  @Float()
  external double speed;
  @Int32()
  external int speaker;
  external Pointer<Float> reference;
  @Int32()
  external int referenceLength;
  @Int32()
  external int referenceRate;
  external Pointer<Uint8> referenceText;
  @Int32()
  external int steps;
  external Pointer<Uint8> extra;
}

final class _Audio extends Struct {
  external Pointer<Float> samples;
  @Int32()
  external int count;
  @Int32()
  external int rate;
}

typedef _Progress = Int32 Function(Pointer<Float>, Int32, Float, Pointer<Void>);

class _Arena {
  static final _libc = DynamicLibrary.open('libc.so.6');
  static final _calloc = _libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr, IntPtr),
        Pointer<Void> Function(int, int)
      >('calloc');
  static final _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  final _owned = <Pointer<Void>>[];
  Pointer<T> allocate<T extends NativeType>(int bytes) {
    final p = _calloc(1, bytes);
    if (p == nullptr) throw StateError('Native allocation failed');
    _owned.add(p);
    return p.cast<T>();
  }

  Pointer<Uint8> string(String value) {
    if (value.contains('\u0000')) throw ArgumentError('NUL in model path/text');
    final bytes = utf8.encode(value);
    final p = allocate<Uint8>(bytes.length + 1);
    p.asTypedList(bytes.length).setAll(0, bytes);
    return p;
  }

  void close() {
    for (final p in _owned.reversed) {
      _free(p);
    }
    _owned.clear();
  }
}

class _Runtime {
  _Runtime(String path) {
    final lib = DynamicLibrary.open(path);
    final version = lib
        .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
          'SherpaOnnxGetVersionStr',
        )();
    var length = 0;
    while (length < 64 && version[length] != 0) {
      length++;
    }
    final value = utf8.decode(version.asTypedList(length));
    if (value != '1.12.34') {
      throw StateError('Unsupported Sherpa ABI $value; expected 1.12.34');
    }
    create = lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<_Config>),
          Pointer<Void> Function(Pointer<_Config>)
        >('SherpaOnnxCreateOfflineTts');
    destroy = lib
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('SherpaOnnxDestroyOfflineTts');
    generate = lib
        .lookupFunction<
          Pointer<_Audio> Function(
            Pointer<Void>,
            Pointer<Uint8>,
            Pointer<_Generation>,
            Pointer<NativeFunction<_Progress>>,
            Pointer<Void>,
          ),
          Pointer<_Audio> Function(
            Pointer<Void>,
            Pointer<Uint8>,
            Pointer<_Generation>,
            Pointer<NativeFunction<_Progress>>,
            Pointer<Void>,
          )
        >('SherpaOnnxOfflineTtsGenerateWithConfig');
    freeAudio = lib
        .lookupFunction<
          Void Function(Pointer<_Audio>),
          void Function(Pointer<_Audio>)
        >('SherpaOnnxDestroyOfflineTtsGeneratedAudio');
    writeWave = lib
        .lookupFunction<
          Int32 Function(Pointer<Float>, Int32, Int32, Pointer<Uint8>),
          int Function(Pointer<Float>, int, int, Pointer<Uint8>)
        >('SherpaOnnxWriteWave');
    speakers = lib
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('SherpaOnnxOfflineTtsNumSpeakers');
  }
  late final Pointer<Void> Function(Pointer<_Config>) create;
  late final void Function(Pointer<Void>) destroy;
  late final Pointer<_Audio> Function(
    Pointer<Void>,
    Pointer<Uint8>,
    Pointer<_Generation>,
    Pointer<NativeFunction<_Progress>>,
    Pointer<Void>,
  )
  generate;
  late final void Function(Pointer<_Audio>) freeAudio;
  late final int Function(Pointer<Float>, int, int, Pointer<Uint8>) writeWave;
  late final int Function(Pointer<Void>) speakers;
  final _engines = <String, ({String key, Pointer<Void> handle})>{};
  int loads = 0;
  Pointer<Void> load(Map<String, dynamic> model) {
    final language = model['language'] as String;
    final key = jsonEncode(
      Map<String, dynamic>.from(model)..remove('cancelAddress'),
    );
    final previous = _engines[language];
    if (previous?.key == key) return previous!.handle;
    final arena = _Arena();
    try {
      final p = arena.allocate<_Config>(sizeOf<_Config>());
      final config = p.ref;
      config.model.threads = 2;
      config.model.provider = arena.string('cpu');
      config.sentences = 1;
      config.silence = 0.2;
      if (model['type'] == 'kokoro') {
        final k = config.model.kokoro;
        k.model = arena.string(model['model'] as String);
        k.tokens = arena.string(model['tokens'] as String);
        k.voices = arena.string(model['voices'] as String);
        k.data = arena.string(model['data'] as String);
        k.lexicon = arena.string(model['lexicon'] as String? ?? '');
        k.lang = arena.string('en-us');
        k.length = 1;
      } else {
        final v = config.model.vits;
        v.model = arena.string(model['model'] as String);
        v.tokens = arena.string(model['tokens'] as String);
        v.data = arena.string(model['data'] as String);
        v.lexicon = arena.string(model['lexicon'] as String? ?? '');
        v.noise = 0.667;
        v.noiseW = 0.8;
        v.length = 1;
      }
      final handle = create(p);
      if (handle == nullptr) {
        throw StateError('Sherpa rejected model configuration');
      }
      final sid = model['speaker'] as int? ?? 0;
      if (sid < 0 || sid >= speakers(handle)) {
        destroy(handle);
        throw StateError('Speaker $sid is unavailable in this model');
      }
      if (previous != null) destroy(previous.handle);
      _engines[language] = (key: key, handle: handle);
      loads++;
      return handle;
    } finally {
      arena.close();
    }
  }

  void synthesize(Map<String, dynamic> model, String text, String output) {
    final cancel = Pointer<Int32>.fromAddress(
      model['cancelAddress'] as int? ?? 0,
    );
    if (cancel != nullptr && cancel.value != 0) return;
    final handle = load(model);
    final arena = _Arena();
    Pointer<_Audio> audio = nullptr;
    try {
      final config = arena.allocate<_Generation>(sizeOf<_Generation>());
      config.ref.silence = 0.2;
      config.ref.speed = 1;
      config.ref.speaker = model['speaker'] as int? ?? 0;
      audio = generate(
        handle,
        arena.string(text),
        config,
        Pointer.fromFunction<_Progress>(_progress, 0),
        cancel.cast<Void>(),
      );
      if (cancel != nullptr && cancel.value != 0) return;
      if (audio == nullptr || audio.ref.count <= 0 || audio.ref.rate <= 0) {
        throw StateError('Model generated no playable speech');
      }
      if (writeWave(
            audio.ref.samples,
            audio.ref.count,
            audio.ref.rate,
            arena.string(output),
          ) !=
          1) {
        throw StateError('Unable to save generated speech');
      }
    } finally {
      if (audio != nullptr) freeAudio(audio);
      arena.close();
    }
  }

  void unload(String language) {
    final entry = _engines.remove(language);
    if (entry != null) destroy(entry.handle);
  }

  void close() {
    for (final engine in _engines.values) {
      destroy(engine.handle);
    }
    _engines.clear();
  }
}

int _progress(
  Pointer<Float> samples,
  int count,
  double progress,
  Pointer<Void> arg,
) {
  return arg == nullptr || arg.cast<Int32>().value == 0 ? 1 : 0;
}

void _worker(SendPort parent) {
  final commands = ReceivePort();
  _Runtime? runtime;
  parent.send(commands.sendPort);
  commands.listen((dynamic raw) {
    final request = raw as List<dynamic>;
    final reply = request[0] as SendPort;
    final action = request[1] as String;
    try {
      if (action == 'close') {
        runtime?.close();
        commands.close();
        reply.send({'ok': true});
        return;
      }
      runtime ??= _Runtime(request[2] as String);
      if (action == 'unload') {
        runtime!.unload(request[3] as String);
      } else {
        final model = Map<String, dynamic>.from(request[3] as Map);
        if (action == 'speak') {
          runtime!.synthesize(
            model,
            request[4] as String,
            request[5] as String,
          );
        } else {
          runtime!.load(model);
        }
      }
      reply.send({'ok': true, 'loads': runtime!.loads});
    } catch (error) {
      reply.send({'error': error.toString()});
    }
  });
}

class DesktopTtsEngine {
  SendPort? _commands;
  Future<void>? _starting;
  Future<void> _queue = Future<void>.value();
  bool _closed = false;
  int modelLoadCount = 0;
  final _cancellations = <Pointer<Int32>>{};

  Future<void> _start() async {
    final ready = ReceivePort();
    try {
      await Isolate.spawn(_worker, ready.sendPort);
      _commands = await ready.first as SendPort;
    } finally {
      ready.close();
    }
  }

  Future<void> _request(
    String action,
    String library,
    dynamic model, [
    String? text,
    String? output,
  ]) {
    if (_closed) {
      return Future<void>.error(StateError('Speech engine is closed'));
    }
    final task = _queue.then((_) async {
      if (_commands == null) await (_starting ??= _start());
      final reply = ReceivePort();
      try {
        _commands!.send([reply.sendPort, action, library, model, text, output]);
        final response = await reply.first as Map;
        if (response['error'] != null) {
          throw StateError(response['error'] as String);
        }
        modelLoadCount = response['loads'] as int? ?? modelLoadCount;
      } finally {
        reply.close();
      }
    });
    _queue = task.catchError((Object _) {});
    return task;
  }

  Future<void> warm(String library, Map<String, dynamic> model) =>
      _request('warm', library, model);
  Future<void> synthesize(
    String library,
    Map<String, dynamic> model,
    String text,
    String output,
  ) async {
    final arena = _Arena();
    final flag = arena.allocate<Int32>(sizeOf<Int32>());
    _cancellations.add(flag);
    try {
      await _request(
        'speak',
        library,
        {...model, 'cancelAddress': flag.address},
        text,
        output,
      );
    } finally {
      _cancellations.remove(flag);
      arena.close();
    }
  }

  void cancel() {
    for (final flag in _cancellations) {
      flag.value = 1;
    }
  }

  Future<void> unload(String library, String language) =>
      _request('unload', library, language);
  Future<void> close() async {
    if (_closed) return;
    cancel();
    final task = _request('close', '', null);
    _closed = true;
    await task;
    _commands = null;
  }
}
