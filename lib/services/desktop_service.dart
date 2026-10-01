import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Linux window controls. Other platforms keep their existing app lifecycle.
class DesktopService {
  static const MethodChannel _channel = MethodChannel(
    'com.atherpulse.solasflow/desktop',
  );
  static const String _backgroundKey = 'DesktopBackgroundEnabled';
  static const String _alwaysOnTopKey = 'DesktopAlwaysOnTop';

  /// GTK requests this hint; the compositor decides whether to honor it.
  static const String alwaysOnTopNote =
      'Always on top is a window-manager hint. Some Wayland desktops ignore it; '
      'use the compositor’s window rules if needed.';

  final ValueNotifier<bool> backgroundEnabled = ValueNotifier(false);
  final ValueNotifier<bool> alwaysOnTop = ValueNotifier(false);

  /// Includes both a hidden background window and an iconified/minimized one.
  final ValueNotifier<bool> hidden = ValueNotifier(false);

  /// Flush app state and dispose speech, then call [quit] to exit the process.
  VoidCallback? onQuitRequested;

  SharedPreferences? _preferences;
  Future<void>? _initialization;
  Future<void> _updates = Future<void>.value();
  bool _disposed = false;

  bool get isSupported => !kIsWeb && Platform.isLinux;

  void _ensureAlive() {
    if (_disposed) throw StateError('DesktopService has been disposed');
  }

  Future<void> initialize() {
    _ensureAlive();
    if (!isSupported) return Future<void>.value();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    _channel.setMethodCallHandler(_handleNativeCall);
    final preferences = await SharedPreferences.getInstance();
    _ensureAlive();
    final background = preferences.getBool(_backgroundKey) ?? false;
    final top = preferences.getBool(_alwaysOnTopKey) ?? false;
    await _configure(background: background, top: top);
    _ensureAlive();
    _preferences = preferences;
    backgroundEnabled.value = background;
    alwaysOnTop.value = top;
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (_disposed) return false;
    switch (call.method) {
      case 'visibilityChanged':
        if (call.arguments is! bool) {
          throw PlatformException(
            code: 'invalid-arguments',
            message: 'visibilityChanged requires a boolean.',
          );
        }
        hidden.value = call.arguments as bool;
        return null;
      case 'quitRequested':
        final callback = onQuitRequested;
        if (callback == null) return false;
        callback();
        return true;
      default:
        throw MissingPluginException(
          'Unknown desktop callback: ${call.method}',
        );
    }
  }

  Future<void> _configure({required bool background, required bool top}) async {
    final isHidden = await _channel.invokeMethod<bool>('configure', {
      'background': background,
      'alwaysOnTop': top,
    });
    _ensureAlive();
    if (isHidden != null) hidden.value = isHidden;
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    _ensureAlive();
    if (!isSupported) return Future<void>.value();
    _updates = _updates
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Previous desktop operation failed: $error');
        })
        .then((_) async {
          await initialize();
          _ensureAlive();
          await operation();
        });
    return _updates;
  }

  Future<void> setBackgroundEnabled(bool enabled) => _enqueue(() async {
    await _configure(background: enabled, top: alwaysOnTop.value);
    backgroundEnabled.value = enabled;
    final written = await _preferences!.setBool(_backgroundKey, enabled);
    if (!written) {
      throw StateError('SharedPreferences rejected desktop background setting');
    }
  });

  Future<void> setAlwaysOnTop(bool enabled) => _enqueue(() async {
    await _configure(background: backgroundEnabled.value, top: enabled);
    alwaysOnTop.value = enabled;
    final written = await _preferences!.setBool(_alwaysOnTopKey, enabled);
    if (!written) {
      throw StateError(
        'SharedPreferences rejected desktop always-on-top setting',
      );
    }
  });

  Future<void> hide() => _enqueue(() => _channel.invokeMethod<void>('hide'));

  Future<void> show() => _enqueue(() => _channel.invokeMethod<void>('show'));

  /// No maximum window geometry is imposed, so fullscreen and landscape work.
  Future<void> setFullscreen(bool enabled) =>
      _enqueue(() => _channel.invokeMethod<void>('fullscreen', enabled));

  Future<void> notify(String title, String body) => _enqueue(
    () => _channel.invokeMethod<void>('notify', {'title': title, 'body': body}),
  );

  /// Final native exit, not a request for Dart cleanup. Call after app cleanup.
  Future<void> quit() async {
    _ensureAlive();
    if (!isSupported) return;
    try {
      await _updates;
    } catch (error) {
      // A failed preference write must not make explicit Quit impossible.
      debugPrint('Desktop operation failed before quit: $error');
    }
    _ensureAlive();
    await _channel.invokeMethod<void>('quit');
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onQuitRequested = null;
    if (isSupported) _channel.setMethodCallHandler(null);
    backgroundEnabled.dispose();
    alwaysOnTop.dispose();
    hidden.dispose();
  }
}
