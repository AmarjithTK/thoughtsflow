import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/timer_runtime.dart';
import 'settings_service.dart';

class TimerRuntimeStore {
  static const String stopwatchKey = 'StopwatchRuntimeV1';
  static const String runtimeKey = 'TimerRuntimeV1';

  static Future<void> _writeTail = Future<void>.value();

  Future<TimerRuntime> load() async {
    await _writeTail;
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload();
    } catch (_) {}
    final encoded = prefs.getString(runtimeKey);
    if (encoded == null) return TimerRuntime.idle();
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map<String, dynamic>
          ? TimerRuntime.fromJson(decoded)
          : TimerRuntime.idle();
    } catch (error) {
      debugPrint('Ignoring corrupt timer runtime: $error');
      return TimerRuntime.idle();
    }
  }

  Future<void> save(TimerRuntime runtime) {
    final encoded = jsonEncode(runtime.toJson());
    _writeTail = _writeTail
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Previous timer runtime write failed: $error');
        })
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          final written = await prefs.setString(runtimeKey, encoded);
          if (!written) {
            throw StateError('SharedPreferences rejected timer runtime write');
          }
        });
    return _writeTail;
  }

  Future<StopwatchRuntime> loadStopwatch() async {
    await _writeTail;
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload();
    } catch (_) {}
    final encoded = prefs.getString(stopwatchKey);
    if (encoded == null) return StopwatchRuntime.idle();
    try {
      final decoded = jsonDecode(encoded);
      return decoded is Map<String, dynamic>
          ? StopwatchRuntime.fromJson(decoded)
          : StopwatchRuntime.idle();
    } catch (error) {
      debugPrint('Ignoring corrupt stopwatch runtime: $error');
      return StopwatchRuntime.idle();
    }
  }

  Future<void> saveStopwatch(StopwatchRuntime runtime) {
    final encoded = jsonEncode(runtime.toJson());
    _writeTail = _writeTail
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Previous runtime write failed: $error');
        })
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          final written = await prefs.setString(stopwatchKey, encoded);
          if (!written) {
            throw StateError(
              'SharedPreferences rejected stopwatch runtime write',
            );
          }
        });
    return _writeTail;
  }

  Future<AppSettings> loadTaskSettings() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      await prefs.reload();
    } catch (_) {}
    AppSettings settings = AppSettings.defaults();
    final encoded = prefs.getString(SettingsService.snapshotKey);
    if (encoded != null) {
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is Map<String, dynamic>) {
          settings = AppSettings.fromJson(decoded);
        }
      } catch (error) {
        debugPrint('Ignoring corrupt task settings: $error');
      }
    }
    final override = prefs.getBool(SettingsService.speechMasterOverrideKey);
    return override == null
        ? settings
        : settings.copyWith(speechMasterOn: override);
  }

  Future<void> saveSpeechMasterOverride(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    final written = await prefs.setBool(
      SettingsService.speechMasterOverrideKey,
      enabled,
    );
    if (!written) {
      throw StateError('SharedPreferences rejected speech master override');
    }
  }
}
