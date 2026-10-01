import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_tts_engine.dart';
import 'desktop_tts_model.dart';

class DesktopTtsController {
  DesktopTtsController(this.baseDirectory, this.bundledModelsDirectory);
  final String baseDirectory;
  final String? bundledModelsDirectory;
  final engine = DesktopTtsEngine();
  final status = ValueNotifier<String>(
    'Built-in English and Malayalam voices selected',
  );
  final _selected = <String, Map<String, dynamic>>{};
  Future<void>? _initializing;
  bool _changing = false;
  bool _closed = false;
  String get library =>
      '$baseDirectory/native-v1.12.34/sherpa-onnx-v1.12.34-linux-x64-shared-lib/lib/libsherpa-onnx-c-api.so';
  String get sharedData => '$bundledModelsDirectory/espeak-ng-data';
  Future<String> _sha(File file) async {
    final result = await Process.run('sha256sum', [file.path]);
    if (result.exitCode != 0) {
      throw StateError('sha256sum is required to verify offline assets');
    }
    return result.stdout.toString().trim().split(RegExp(r'\s+')).first;
  }

  Future<void> _extractAsset(
    String name,
    String digest,
    String destination,
  ) async {
    final archive = File('$baseDirectory/$name');
    final bundled = await rootBundle.load('assets/tts/$name');
    await archive.parent.create(recursive: true);
    await archive.writeAsBytes(
      bundled.buffer.asUint8List(bundled.offsetInBytes, bundled.lengthInBytes),
      flush: true,
    );
    try {
      if (await _sha(archive) != digest) {
        throw StateError('Bundled offline asset integrity failure: $name');
      }
      await Directory(destination).create(recursive: true);
      final result = await Process.run('tar', [
        '-xjf',
        archive.path,
        '-C',
        destination,
      ]);
      if (result.exitCode != 0) {
        throw StateError('Unable to unpack offline assets: ${result.stderr}');
      }
    } finally {
      if (await archive.exists()) await archive.delete();
    }
  }

  Future<void> initialize() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        status.value = 'Offline voice setup failed: $error';
        throw error;
      });
  Future<void> _initialize() async {
    if (_closed) throw StateError('Speech service is closed');
    if (Abi.current() != Abi.linuxX64) {
      throw UnsupportedError(
        'Bundled offline runtime supports Linux x86-64 only',
      );
    }
    if (!File(library).existsSync()) {
      await _extractAsset(
        'sherpa-linux-x64-runtime.tar.bz2',
        '325273bfbfdd16a59128dd35da474fb70ca3cfca4115e70d21bc927abd083397',
        '$baseDirectory/native-v1.12.34',
      );
    }
    final hashes = {
      library:
          '4320a05441c3fe6ed84c177b722aa1f208d7dc423d703b18f45649b51ebd5634',
      '${File(library).parent.path}/libonnxruntime.so':
          '7a6019216c8b6194101291ab8cd1ad9803f087306b10f6f0ef384c52fe879138',
    };
    for (final entry in hashes.entries) {
      if (await _sha(File(entry.key)) != entry.value) {
        throw StateError('Offline native library integrity failure');
      }
    }
    if (bundledModelsDirectory == null ||
        !File('$sharedData/phontab').existsSync()) {
      throw StateError(
        'Bundled voices/espeak-ng-data are missing. Restore the application assets/tts/models folder; no model download was attempted.',
      );
    }
    final preferences = await SharedPreferences.getInstance();
    for (final language in ['en', 'ml']) {
      final folder = preferences.getString('desktop_tts_model_$language');
      if (folder == null) continue;
      if (!RegExp(r'^(en|ml)-[0-9]+$').hasMatch(folder) ||
          !folder.startsWith('$language-')) {
        status.value =
            'Invalid saved $language model selection; built-in voice will be used';
        continue;
      }
      try {
        _selected[language] = await inspectDesktopTtsModel(
          '$baseDirectory/custom-models/$folder',
          language,
          sharedData,
        );
      } catch (error) {
        status.value =
            'Saved $language model is unavailable: $error. Clear or import it again.';
      }
    }
    if (_selected.isNotEmpty) _refreshStatus();
  }

  void _refreshStatus() {
    status.value = ['en', 'ml']
        .map((language) {
          final label = language == 'en' ? 'English' : 'Malayalam';
          final model = _selected[language];
          return '$label: ${model == null ? 'built-in voice' : model['name']}';
        })
        .join('\n');
  }

  Map<String, dynamic>? selected(String language) => _selected[language];
  Future<Map<String, dynamic>> builtIn(String language) async {
    await initialize();
    final model = '$bundledModelsDirectory/$language/primary/model.onnx';
    final tokens = '$bundledModelsDirectory/$language/primary/tokens.txt';
    if (!File(model).existsSync() || !File(tokens).existsSync()) {
      throw StateError('The bundled $language voice is missing');
    }
    return {
      'language': language,
      'type': 'vits',
      'model': model,
      'tokens': tokens,
      'data': sharedData,
      'speaker': 0,
      'name': language == 'en' ? 'Piper English' : 'Piper Malayalam Meera',
    };
  }

  Future<void> importModel(String directory, String language) async {
    if (_changing) {
      throw StateError('A model import or clear is already running');
    }
    _changing = true;
    Directory? staging;
    try {
      await initialize();
      status.value =
          'Validating local ${language == 'en' ? 'English' : 'Malayalam'} model data…';
      final source = await inspectDesktopTtsModel(
        directory,
        language,
        sharedData,
      );
      final folder = '$language-${DateTime.now().microsecondsSinceEpoch}';
      staging = Directory('$baseDirectory/custom-models/$folder');
      await staging.create(recursive: true);
      for (final key in ['model', 'tokens', 'voices', 'lexicon']) {
        final path = source[key] as String?;
        if (path != null) {
          await File(
            path,
          ).copy('${staging.path}/${File(path).uri.pathSegments.last}');
        }
      }
      if (source['ownData'] == true) {
        final root = source['data'] as String;
        await for (final entry in Directory(
          root,
        ).list(recursive: true, followLinks: false)) {
          final target =
              '${staging.path}/espeak-ng-data/${entry.path.substring(root.length + 1)}';
          if (entry is Directory) {
            await Directory(target).create(recursive: true);
          } else if (entry is File) {
            await File(target).parent.create(recursive: true);
            await entry.copy(target);
          } else {
            throw const FormatException(
              'Model data cannot contain symlinks or special files',
            );
          }
        }
      }
      final imported = await inspectDesktopTtsModel(
        staging.path,
        language,
        sharedData,
      );
      status.value = 'Loading and validating the imported voice…';
      await engine.warm(library, imported);
      if (_closed) throw StateError('Speech service was closed during import');
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.setString('desktop_tts_model_$language', folder)) {
        throw StateError('Unable to persist model selection');
      }
      final previous = _selected[language];
      _selected[language] = imported;
      staging = null;
      _refreshStatus();
      if (previous != null) {
        await Directory(
          File(previous['model'] as String).parent.path,
        ).delete(recursive: true);
      }
    } catch (error) {
      status.value = 'Model import failed: $error';
      rethrow;
    } finally {
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
      _changing = false;
    }
  }

  Future<void> clearModel(String language) async {
    if (language != 'en' && language != 'ml') {
      throw ArgumentError('Choose en or ml');
    }
    if (_changing) {
      throw StateError('A model import or clear is already running');
    }
    _changing = true;
    try {
      await initialize();
      final preferences = await SharedPreferences.getInstance();
      if (!await preferences.remove('desktop_tts_model_$language')) {
        throw StateError('Unable to clear saved model selection');
      }
      await engine.unload(library, language);
      final previous = _selected.remove(language);
      if (previous != null) {
        await Directory(
          File(previous['model'] as String).parent.path,
        ).delete(recursive: true);
      }
      _refreshStatus();
    } catch (error) {
      status.value = 'Unable to clear model: $error';
      rethrow;
    } finally {
      _changing = false;
    }
  }

  Future<void> close() async {
    _closed = true;
    await engine.close();
  }
}
