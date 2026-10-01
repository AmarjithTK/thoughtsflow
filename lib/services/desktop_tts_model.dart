import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

// Reads the protobuf envelope without loading model weights into Dart memory.
// External tensors are not supported: imported models cannot reference files
// outside the app-owned model directory.
class _OnnxReader {
  _OnnxReader(this.file);
  final RandomAccessFile file;
  final metadata = <String, String>{};
  int _varint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      final b = file.readByteSync();
      if (b < 0) throw const FormatException('Truncated ONNX file');
      value |= (b & 127) << shift;
      if (b < 128) return value;
    }
    throw const FormatException('Invalid ONNX integer');
  }

  String _string(int end) {
    final size = end - file.positionSync();
    if (size > 65536) throw const FormatException('Oversized ONNX metadata');
    return utf8.decode(file.readSync(size));
  }

  void message(int end, String kind, [int depth = 0]) {
    if (depth > 64) throw const FormatException('ONNX nesting is too deep');
    String? key;
    String? value;
    while (file.positionSync() < end) {
      final tag = _varint();
      final field = tag >> 3;
      final wire = tag & 7;
      if (field == 0) throw const FormatException('Invalid ONNX field');
      if ((kind == 'graph' && field == 15) ||
          (kind == 'attribute' && (field == 22 || field == 23))) {
        throw const FormatException('Sparse ONNX tensor data is unsupported');
      }
      if (kind == 'tensor' && field == 13) {
        throw const FormatException('External ONNX tensor data is unsupported');
      }
      if (kind == 'tensor' && field == 14) {
        if (wire != 0 || _varint() != 0) {
          throw const FormatException(
            'External ONNX tensor data is unsupported',
          );
        }
        continue;
      }
      if (wire == 0) {
        _varint();
        continue;
      }
      int size;
      if (wire == 2) {
        size = _varint();
      } else if (wire == 1) {
        size = 8;
      } else if (wire == 5) {
        size = 4;
      } else {
        throw const FormatException('Unsupported ONNX wire format');
      }
      final next = file.positionSync() + size;
      if (size < 0 || next > end) {
        throw const FormatException('Truncated ONNX data');
      }
      String? child;
      if (wire == 2) {
        if (kind == 'model' && field == 7) child = 'graph';
        if (kind == 'model' && field == 14) child = 'metadata';
        if (kind == 'model' && field == 25) child = 'function';
        if (kind == 'function' && field == 7) child = 'node';
        if (kind == 'function' && field == 11) child = 'attribute';
        if (kind == 'graph' && field == 5) child = 'tensor';
        if (kind == 'graph' && field == 1) child = 'node';
        if (kind == 'node' && field == 5) child = 'attribute';
        if (kind == 'attribute' && (field == 5 || field == 10)) {
          child = 'tensor';
        }
        if (kind == 'attribute' && (field == 6 || field == 11)) child = 'graph';
        if (kind == 'metadata' && field == 1) key = _string(next);
        if (kind == 'metadata' && field == 2) value = _string(next);
      }
      if (child != null) message(next, child, depth + 1);
      file.setPositionSync(next);
    }
    if (kind == 'metadata' && key != null && value != null) {
      metadata[key] = value;
    }
  }
}

Future<Map<String, dynamic>> inspectDesktopTtsModel(
  String directory,
  String language,
  String sharedData,
) => Isolate.run(() {
  if (language != 'en' && language != 'ml') {
    throw ArgumentError('Choose English (en) or Malayalam (ml)');
  }
  final root = Directory(directory).resolveSymbolicLinksSync();
  String requiredFile(String name) {
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(name)) {
      throw const FormatException('Unsafe model filename');
    }
    final path = '$root/$name';
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file ||
        File(path).lengthSync() == 0) {
      throw FormatException('Missing regular model data file: $name');
    }
    return path;
  }

  final models = Directory(root)
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) => f.path.endsWith('.onnx'))
      .toList();
  if (models.length != 1) {
    throw const FormatException(
      'Folder must contain exactly one self-contained Sherpa-converted .onnx model',
    );
  }
  final name = models.single.uri.pathSegments.last;
  final path = requiredFile(name);
  final file = File(path).openSync();
  final reader = _OnnxReader(file);
  try {
    reader.message(file.lengthSync(), 'model');
  } finally {
    file.closeSync();
  }
  final m = reader.metadata;
  final type = m['model_type'];
  if (type != 'vits' && type != 'kokoro') {
    throw const FormatException(
      'Only Sherpa-converted Piper/VITS or Kokoro models are supported (not arbitrary ONNX or HF source weights)',
    );
  }
  if (m['has_espeak'] != '1') {
    throw const FormatException(
      'This importer requires an espeak-based Sherpa model',
    );
  }
  final sampleRate = int.tryParse(m['sample_rate'] ?? '') ?? 0;
  final speakers = int.tryParse(m['n_speakers'] ?? '') ?? 0;
  if (sampleRate < 8000 ||
      sampleRate > 96000 ||
      speakers < 1 ||
      speakers > 4096) {
    throw const FormatException(
      'Invalid Sherpa sample_rate or n_speakers metadata',
    );
  }
  final declared = '${m['voice'] ?? ''} ${m['language'] ?? ''}'.toLowerCase();
  if (type == 'kokoro' && language != 'en') {
    throw const FormatException(
      'Kokoro does not support Malayalam; choose a Malayalam Piper/VITS model',
    );
  }
  if (type == 'vits' &&
      !(language == 'en'
          ? declared.contains('en-') || declared.contains('english')
          : declared.contains('ml') || declared.contains('malayalam'))) {
    throw FormatException(
      'Model language metadata does not match ${language == 'en' ? 'English' : 'Malayalam'}',
    );
  }
  final tokens = requiredFile('tokens.txt');
  final tokenText = File(tokens).readAsStringSync();
  if (tokenText.trim().isEmpty ||
      tokenText
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .any((line) => !RegExp(r'^.+\s+\d+\s*$').hasMatch(line))) {
    throw const FormatException('Invalid Sherpa tokens.txt');
  }
  final bundledData = Directory(sharedData);
  final ownData = Directory('$root/espeak-ng-data');
  final hasOwnData =
      FileSystemEntity.typeSync(ownData.path, followLinks: false) ==
      FileSystemEntityType.directory;
  final data = hasOwnData ? ownData.path : bundledData.path;
  if (!File('$data/phontab').existsSync() ||
      !File('$data/${language}_dict').existsSync()) {
    throw const FormatException('Valid espeak-ng-data is required');
  }
  if (hasOwnData) {
    for (final entity in ownData.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link || !(entity is File || entity is Directory)) {
        throw const FormatException(
          'Model data cannot contain symlinks or special files',
        );
      }
      final rel = entity.path.substring(ownData.path.length + 1);
      // Official eSpeak voice variants include "!v/Mr serious".
      if (rel
          .split('/')
          .any((part) => !RegExp(r'^[A-Za-z0-9_.+! -]+$').hasMatch(part))) {
        throw const FormatException('Unsafe espeak data filename');
      }
    }
  }
  final result = <String, dynamic>{
    'language': language,
    'type': type,
    'model': path,
    'tokens': tokens,
    'data': data,
    'speaker': 0,
    'name': name,
    'ownData': hasOwnData,
  };
  if (type == 'kokoro') {
    final voices = requiredFile('voices.bin');
    final dimensions = (m['style_dim'] ?? '')
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .toList();
    if (dimensions.length != 3 ||
        dimensions[0] < 2 ||
        dimensions[1] != 1 ||
        dimensions[2] < 1 ||
        File(voices).lengthSync() !=
            dimensions[0] * dimensions[2] * speakers * 4) {
      throw const FormatException(
        'Kokoro voices.bin does not match ONNX style_dim/n_speakers',
      );
    }
    result['voices'] = voices;
    result['lexicon'] = requiredFile(
      File('$root/lexicon-us-en.txt').existsSync()
          ? 'lexicon-us-en.txt'
          : 'lexicon.txt',
    );
  }
  return result;
});
