import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class AudioService {
  final AudioPlayer _backgroundPlayer = AudioPlayer();
  final AudioPlayer _notificationPlayer = AudioPlayer();

  Future<void> _operationTail = Future<void>.value();
  Timer? _notificationStopTimer;
  int _backgroundRevision = 0;
  int _notificationRevision = 0;
  int _volumeRevision = 0;
  double _configuredVolume = 1;
  bool _speechDucking = false;
  String? _activeAsset;
  double? _activeVolume;
  bool _backgroundPlaying = false;
  bool _disposed = false;

  Future<void> init() => _enqueue(() async {
    await _backgroundPlayer.setReleaseMode(ReleaseMode.loop);
  });

  Future<void> applyBackground({
    required bool shouldPlay,
    required String assetPath,
    required double volume,
  }) {
    final revision = ++_backgroundRevision;
    final safeVolume = volume.clamp(0, 1).toDouble();
    _configuredVolume = safeVolume;
    ++_volumeRevision;
    return _enqueue(() async {
      if (_disposed || revision != _backgroundRevision) return;
      if (!shouldPlay) {
        await _backgroundPlayer.pause();
        _backgroundPlaying = false;
        return;
      }
      final effectiveVolume = _effectiveVolume;
      if (_activeVolume != effectiveVolume) {
        await _backgroundPlayer.setVolume(effectiveVolume);
        _activeVolume = effectiveVolume;
      }
      if (!_backgroundPlaying || _activeAsset != assetPath) {
        await _backgroundPlayer.play(AssetSource(assetPath));
        _activeAsset = assetPath;
        _backgroundPlaying = true;
      }
    });
  }

  Future<void> stopBackground() {
    final revision = ++_backgroundRevision;
    ++_volumeRevision;
    return _enqueue(() async {
      if (_disposed || revision != _backgroundRevision) return;
      await _backgroundPlayer.pause();
      _backgroundPlaying = false;
    });
  }

  double get _effectiveVolume =>
      _configuredVolume * (_speechDucking ? 0.25 : 1);

  /// Temporarily attenuates ambient audio without changing its configured level.
  /// Calls share the player operation queue, and newer volume/mute requests
  /// invalidate any in-progress ramp before it can restore an obsolete level.
  Future<void> setSpeechDucking(bool active) {
    if (_disposed || active == _speechDucking) return _operationTail;
    _speechDucking = active;
    final revision = ++_volumeRevision;
    debugPrint('[AudioService] Speech ducking ${active ? 'on' : 'off'}');
    return _enqueue(() async {
      if (_disposed || revision != _volumeRevision || !_backgroundPlaying) {
        return;
      }
      await _rampBackgroundVolume(revision);
    });
  }

  Future<void> _rampBackgroundVolume(int revision) async {
    final target = _effectiveVolume;
    final start = _activeVolume ?? target;
    if (start == target) return;
    const duration = Duration(milliseconds: 350);
    const interval = Duration(milliseconds: 25);
    final elapsed = Stopwatch()..start();
    debugPrint('[AudioService] Ambient volume ramp $start -> $target');
    while (!_disposed && revision == _volumeRevision) {
      final progress = (elapsed.elapsedMicroseconds / duration.inMicroseconds)
          .clamp(0.0, 1.0);
      // Smoothstep eases both ends while still reaching the requested level.
      final eased = progress * progress * (3 - 2 * progress);
      final volume = start + (target - start) * eased;
      await _backgroundPlayer.setVolume(volume);
      _activeVolume = volume;
      if (progress >= 1) {
        debugPrint('[AudioService] Ambient volume ramp complete');
        return;
      }
      await Future<void>.delayed(interval);
    }
    debugPrint('[AudioService] Ambient volume ramp cancelled');
  }

  Future<void> playNotification({
    required String assetPath,
    Duration stopAfter = const Duration(seconds: 10),
  }) {
    final revision = ++_notificationRevision;
    _notificationStopTimer?.cancel();
    return _enqueue(() async {
      if (_disposed || revision != _notificationRevision) return;
      await _notificationPlayer.play(AssetSource(assetPath));
      _notificationStopTimer = Timer(stopAfter, () {
        if (revision == _notificationRevision) {
          unawaited(_stopNotification(revision));
        }
      });
    });
  }

  Future<void> stopNotification() {
    final revision = ++_notificationRevision;
    _notificationStopTimer?.cancel();
    return _stopNotification(revision);
  }

  Future<void> _stopNotification(int revision) => _enqueue(() async {
    if (_disposed || revision != _notificationRevision) return;
    await _notificationPlayer.pause();
    await _notificationPlayer.seek(Duration.zero);
  });

  Future<void> _enqueue(Future<void> Function() operation) {
    _operationTail = _operationTail
        .catchError((Object _) {})
        .then((_) => operation());
    return _operationTail;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    ++_volumeRevision;
    _notificationStopTimer?.cancel();
    await _operationTail.catchError((Object _) {});
    await _backgroundPlayer.dispose();
    await _notificationPlayer.dispose();
  }
}
