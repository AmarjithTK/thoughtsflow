import 'dart:async';

import 'package:flutter/material.dart';

enum DriveMode { clock, timer, stopwatch }

/// A large-control presentation of the owner's live clock and timing state.
/// Start callbacks also resume paused sessions; this view never resets a session.
/// It has no window/orientation effects, so it works in a route or floating panel.
class DriveModeView extends StatefulWidget {
  final String Function() clockTextBuilder;
  final String Function() timerTextBuilder;
  final String Function() stopwatchTextBuilder;
  final bool Function() isTimerRunningBuilder;
  final bool Function() isStopwatchRunningBuilder;
  final bool Function() isTimerPausedBuilder;
  final bool Function() isStopwatchPausedBuilder;
  final bool Function() audioEnabledBuilder;
  final VoidCallback onTimerStart;
  final VoidCallback onTimerPause;
  final VoidCallback onStopwatchStart;
  final VoidCallback onStopwatchPause;
  final ValueChanged<bool> onAudioEnabledChanged;
  final ValueChanged<DriveMode> onSpeakNow;
  final VoidCallback onClose;
  final DriveMode initialMode;
  final ValueChanged<DriveMode>? onModeChanged;
  final ValueChanged<int>? onTimerPresetSelected;

  const DriveModeView({
    super.key,
    required this.clockTextBuilder,
    required this.timerTextBuilder,
    required this.stopwatchTextBuilder,
    required this.isTimerRunningBuilder,
    required this.isStopwatchRunningBuilder,
    required this.isTimerPausedBuilder,
    required this.isStopwatchPausedBuilder,
    required this.audioEnabledBuilder,
    required this.onTimerStart,
    required this.onTimerPause,
    required this.onStopwatchStart,
    required this.onStopwatchPause,
    required this.onAudioEnabledChanged,
    required this.onSpeakNow,
    required this.onClose,
    this.initialMode = DriveMode.clock,
    this.onModeChanged,
    this.onTimerPresetSelected,
  });

  @override
  State<DriveModeView> createState() => _DriveModeViewState();
}

class _DriveModeViewState extends State<DriveModeView> {
  static const _background = Color(0xFF080D16);
  static const _surface = Color(0xFF182235);
  static const _accent = Color(0xFFB4DEFF);
  static const _muted = Color(0xFFCAD4E4);

  Timer? _ticker;
  late DriveMode _mode;
  String _clockText = '';
  String _timerText = '';
  String _stopwatchText = '';
  bool _timerRunning = false;
  bool _stopwatchRunning = false;
  bool _timerPaused = false;
  bool _stopwatchPaused = false;
  bool _audioEnabled = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _readState();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _refresh(),
    );
  }

  @override
  void didUpdateWidget(covariant DriveModeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _readState();
  }

  void _readState() {
    _clockText = widget.clockTextBuilder();
    _timerText = widget.timerTextBuilder();
    _stopwatchText = widget.stopwatchTextBuilder();
    _timerRunning = widget.isTimerRunningBuilder();
    _stopwatchRunning = widget.isStopwatchRunningBuilder();
    _timerPaused = widget.isTimerPausedBuilder();
    _stopwatchPaused = widget.isStopwatchPausedBuilder();
    _audioEnabled = widget.audioEnabledBuilder();
  }

  void _refresh() {
    if (!mounted) return;
    final clockText = _clockText;
    final timerText = _timerText;
    final stopwatchText = _stopwatchText;
    final timerRunning = _timerRunning;
    final stopwatchRunning = _stopwatchRunning;
    final timerPaused = _timerPaused;
    final stopwatchPaused = _stopwatchPaused;
    final audioEnabled = _audioEnabled;
    _readState();
    if ((_mode == DriveMode.clock && clockText != _clockText) ||
        (_mode == DriveMode.timer && timerText != _timerText) ||
        (_mode == DriveMode.stopwatch && stopwatchText != _stopwatchText) ||
        timerRunning != _timerRunning ||
        stopwatchRunning != _stopwatchRunning ||
        timerPaused != _timerPaused ||
        stopwatchPaused != _stopwatchPaused ||
        audioEnabled != _audioEnabled) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _label => switch (_mode) {
    DriveMode.clock => 'Clock',
    DriveMode.timer => 'Timer',
    DriveMode.stopwatch => 'Stopwatch',
  };

  bool get _running => switch (_mode) {
    DriveMode.clock => false,
    DriveMode.timer => _timerRunning,
    DriveMode.stopwatch => _stopwatchRunning,
  };

  bool get _paused => switch (_mode) {
    DriveMode.clock => false,
    DriveMode.timer => _timerPaused,
    DriveMode.stopwatch => _stopwatchPaused,
  };

  void _selectMode(DriveMode mode) {
    if (_mode == mode) return;
    setState(() => _mode = mode);
    widget.onModeChanged?.call(mode);
  }

  void _toggleTiming() {
    if (_mode == DriveMode.timer) {
      (_timerRunning ? widget.onTimerPause : widget.onTimerStart)();
    } else if (_mode == DriveMode.stopwatch) {
      (_stopwatchRunning ? widget.onStopwatchPause : widget.onStopwatchStart)();
    }
    _refresh();
  }

  ButtonStyle _buttonStyle({bool highlighted = false}) =>
      FilledButton.styleFrom(
        backgroundColor: highlighted ? _accent : _surface,
        foregroundColor: highlighted ? _background : Colors.white,
        disabledBackgroundColor: _surface,
        disabledForegroundColor: _muted.withValues(alpha: 0.5),
        minimumSize: const Size(64, 64),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      );

  Widget _button({
    required String label,
    required VoidCallback? onPressed,
    bool highlighted = false,
    IconData? icon,
  }) {
    final content = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 26), const SizedBox(width: 8)],
          Text(label),
        ],
      ),
    );
    return FilledButton(
      style: _buttonStyle(highlighted: highlighted),
      onPressed: onPressed,
      child: content,
    );
  }

  Widget _modeSelector() => Row(
    children: [
      for (final mode in DriveMode.values) ...[
        if (mode != DriveMode.clock) const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            selected: _mode == mode,
            child: _button(
              label: switch (mode) {
                DriveMode.clock => 'Clock',
                DriveMode.timer => 'Timer',
                DriveMode.stopwatch => 'Stopwatch',
              },
              highlighted: _mode == mode,
              onPressed: () => _selectMode(mode),
            ),
          ),
        ),
      ],
    ],
  );

  Widget _display() {
    final text = switch (_mode) {
      DriveMode.clock => _clockText,
      DriveMode.timer => _timerText,
      DriveMode.stopwatch => _stopwatchText,
    };
    final status = _mode == DriveMode.clock
        ? 'Current time'
        : _running
        ? 'Running'
        : _paused
        ? 'Paused'
        : 'Ready';
    return Column(
      children: [
        Text(_label, style: const TextStyle(color: _muted, fontSize: 22)),
        const SizedBox(height: 12),
        Expanded(
          child: Center(
            child: Semantics(
              label: '$_label: $text',
              excludeSemantics: true,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Text(
                  text,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 120,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(status, style: const TextStyle(color: _muted, fontSize: 18)),
      ],
    );
  }

  Widget _controls() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (_mode != DriveMode.clock) ...[
        _button(
          label:
              '${_running
                  ? 'Pause'
                  : _paused
                  ? 'Resume'
                  : 'Start'} $_label',
          icon: _running ? Icons.pause_rounded : Icons.play_arrow_rounded,
          highlighted: true,
          onPressed: _toggleTiming,
        ),
        const SizedBox(height: 12),
      ],
      if (_mode == DriveMode.timer && widget.onTimerPresetSelected != null) ...[
        Row(
          children: [
            for (final minutes in const [15, 25, 45]) ...[
              if (minutes != 15) const SizedBox(width: 8),
              Expanded(
                child: _button(
                  label: '$minutes min',
                  onPressed: _timerRunning || _timerPaused
                      ? null
                      : () {
                          widget.onTimerPresetSelected!(minutes);
                          _refresh();
                        },
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
      ],
      Row(
        children: [
          Expanded(
            child: Semantics(
              toggled: _audioEnabled,
              child: _button(
                label: _audioEnabled ? 'Audio on' : 'Audio off',
                icon: _audioEnabled
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
                highlighted: _audioEnabled,
                onPressed: () {
                  widget.onAudioEnabledChanged(!_audioEnabled);
                  _refresh();
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _button(
              label: 'Speak now',
              icon: Icons.record_voice_over_rounded,
              onPressed: () => widget.onSpeakNow(_mode),
            ),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Material(
    color: _background,
    child: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final landscape =
              constraints.maxWidth >= 600 &&
              constraints.maxWidth > constraints.maxHeight;
          final minHeight = landscape ? 340.0 : 560.0;
          final contentHeight = constraints.maxHeight < minHeight
              ? minHeight
              : constraints.maxHeight;
          final content = Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: landscape
                          ? _modeSelector()
                          : const Text(
                              'Drive Mode',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                    const SizedBox(width: 12),
                    _button(
                      label: 'Close',
                      icon: Icons.close_rounded,
                      onPressed: widget.onClose,
                    ),
                  ],
                ),
                if (!landscape) ...[
                  const SizedBox(height: 12),
                  _modeSelector(),
                ],
                const SizedBox(height: 20),
                Expanded(
                  child: landscape
                      ? Row(
                          children: [
                            Expanded(flex: 3, child: _display()),
                            const SizedBox(width: 24),
                            Expanded(flex: 2, child: _controls()),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(child: _display()),
                            const SizedBox(height: 24),
                            _controls(),
                          ],
                        ),
                ),
              ],
            ),
          );
          return constraints.maxHeight < minHeight
              ? SingleChildScrollView(
                  child: SizedBox(height: contentHeight, child: content),
                )
              : content;
        },
      ),
    ),
  );
}
