import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/sound_option.dart';
import '../providers/app_state.dart';
import '../models/speech_model_download_status.dart';

class SettingsPanel extends ConsumerStatefulWidget {
  // ── Side-effect callbacks only (audio, TTS, foreground service) ──
  final List<SoundOption> soundList;
  final List<double> volumeLists;
  final bool isSpeechActive;
  final int speechQueueLength;
  final List<Map<dynamic, dynamic>> voices;
  final List<String> availableEngines;
  final String speechEngineRuntime;
  final String speechEngineRuntimeDetail;
  final bool showEnglishVoiceDownload;
  final ValueListenable<SpeechModelDownloadStatus> speechModelDownloadStatus;
  final ValueListenable<String> customModelStatus;
  final Future<void> Function(String directory, String language)
  onImportDesktopModel;
  final Future<void> Function(String language) onClearDesktopModel;
  final String sleepStartLabel;
  final String sleepEndLabel;
  final ValueChanged<String?> onSoundChanged;
  final ValueChanged<double?> onNoiseVolumeChanged;
  final ValueChanged<double?> onSpeakVolumeChanged;
  final ValueChanged<bool?> onMaximumSpeechVolumeChanged;
  final ValueChanged<bool?> onSpeechMasterOnChanged;
  final ValueChanged<bool?> onAppDarkThemeChanged;
  final ValueChanged<double?> onAppFontSizeMultiplierChanged;
  final ValueChanged<bool?> onFullscreenDarkThemeChanged;
  final ValueChanged<bool?> onFullscreenDimBrightnessChanged;
  final ValueChanged<double?> onFullscreenDimBrightnessLevelChanged;
  final ValueChanged<bool?> onFullscreenStartLandscapeChanged;
  final ValueChanged<bool?> onMuteSpeechAfterMidnightChanged;
  final ValueChanged<double?>? onFullscreenClockScaleChanged;
  final ValueChanged<bool?>? onFullscreenShowClockChanged;
  final ValueChanged<String?> onNightMuteModeChanged;
  final VoidCallback onPickSleepStart;
  final VoidCallback onPickSleepEnd;
  final ValueChanged<String?> onVoiceListModeChanged;
  final ValueChanged<String?> onSpeechEngineModeChanged;
  final ValueChanged<String?> onFavoriteVoiceChanged;
  final VoidCallback onTestSpeech;
  final VoidCallback onDownloadEnglishVoice;
  final VoidCallback onCancelEnglishVoiceDownload;
  final VoidCallback onOpenHelp;
  final VoidCallback? onBackupSettings;
  final VoidCallback? onRestoreSettings;

  const SettingsPanel({
    super.key,
    required this.soundList,
    required this.volumeLists,
    required this.isSpeechActive,
    required this.speechQueueLength,
    required this.voices,
    this.availableEngines = const [],
    required this.speechEngineRuntime,
    required this.speechEngineRuntimeDetail,
    required this.showEnglishVoiceDownload,
    required this.speechModelDownloadStatus,
    required this.customModelStatus,
    required this.onImportDesktopModel,
    required this.onClearDesktopModel,
    required this.sleepStartLabel,
    required this.sleepEndLabel,
    required this.onSoundChanged,
    required this.onNoiseVolumeChanged,
    required this.onSpeakVolumeChanged,
    required this.onMaximumSpeechVolumeChanged,
    required this.onSpeechMasterOnChanged,
    required this.onAppDarkThemeChanged,
    required this.onAppFontSizeMultiplierChanged,
    required this.onFullscreenDarkThemeChanged,
    required this.onFullscreenDimBrightnessChanged,
    required this.onFullscreenDimBrightnessLevelChanged,
    required this.onFullscreenStartLandscapeChanged,
    this.onFullscreenClockScaleChanged,
    this.onFullscreenShowClockChanged,
    required this.onMuteSpeechAfterMidnightChanged,
    required this.onNightMuteModeChanged,
    required this.onPickSleepStart,
    required this.onPickSleepEnd,
    required this.onVoiceListModeChanged,
    required this.onSpeechEngineModeChanged,
    required this.onFavoriteVoiceChanged,
    required this.onOpenHelp,
    required this.onTestSpeech,
    required this.onDownloadEnglishVoice,
    required this.onCancelEnglishVoiceDownload,
    this.onBackupSettings,
    this.onRestoreSettings,
  });

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  String _desktopModelLanguage = 'en';
  bool _modelOperationBusy = false;

  Future<void> _changeDesktopModel({required bool clear}) async {
    if (_modelOperationBusy) return;
    final language = _desktopModelLanguage;
    setState(() => _modelOperationBusy = true);
    try {
      if (clear) {
        await widget.onClearDesktopModel(language);
      } else {
        final directory = await FilePicker.platform.getDirectoryPath(
          dialogTitle: 'Choose a Sherpa-converted model folder',
        );
        if (directory == null || !mounted) return;
        await widget.onImportDesktopModel(directory, language);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Offline model ${clear ? 'clear' : 'import'} failed: $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _modelOperationBusy = false);
    }
  }

  Widget _desktopModelCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Local offline model',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Import a trusted Sherpa-converted Piper/VITS folder or English Kokoro folder. '
            'One self-contained ONNX file and tokens.txt are required; Kokoro also needs '
            'voices.bin and an English lexicon. HF source weights and arbitrary ONNX models '
            'are not supported. Only model data is copied; no imported code is executed.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _desktopModelLanguage,
            decoration: const InputDecoration(labelText: 'Model language'),
            items: const [
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'ml', child: Text('Malayalam')),
            ],
            onChanged: _modelOperationBusy
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => _desktopModelLanguage = value);
                    }
                  },
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: widget.customModelStatus,
            builder: (context, value, _) =>
                Text(value, style: const TextStyle(fontSize: 12)),
          ),
          if (_modelOperationBusy) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _modelOperationBusy
                    ? null
                    : () => _changeDesktopModel(clear: false),
                icon: const Icon(Icons.folder_open),
                label: const Text('Import folder'),
              ),
              OutlinedButton(
                onPressed: _modelOperationBusy
                    ? null
                    : () => _changeDesktopModel(clear: true),
                child: const Text('Use built-in voice'),
              ),
              OutlinedButton.icon(
                onPressed: _modelOperationBusy
                    ? null
                    : () {
                        widget.onVoiceListModeChanged(
                          _desktopModelLanguage == 'ml'
                              ? 'malayalam'
                              : 'english',
                        );
                        widget.onTestSpeech();
                      },
                icon: const Icon(Icons.volume_up_outlined),
                label: Text(
                  'Test ${_desktopModelLanguage == 'ml' ? 'Malayalam' : 'English'}',
                ),
              ),
            ],
          ),
          const Text(
            'Voice test also selects this speech language. System-only mode bypasses offline models.',
            style: TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }

  String _getVolTitle(double v) {
    if (v == 0.1) return 'Very Low';
    if (v == 0.2) return 'Low';
    if (v == 0.6) return 'Medium';
    if (v == 0.8) return 'High';
    return 'Very High';
  }

  Widget _speechModelDownloadCard(
    BuildContext context,
    SpeechModelDownloadStatus status,
  ) {
    final cs = Theme.of(context).colorScheme;
    final canStart =
        status.phase == SpeechModelDownloadPhase.notDownloaded ||
        status.canRetry;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_download_outlined, color: cs.primary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Kokoro English voice',
                  style: TextStyle(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            status.message,
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          if (status.isBusy) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: status.progress,
              minHeight: 4,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
          if (canStart || status.phase == SpeechModelDownloadPhase.downloading)
            Align(
              alignment: Alignment.centerRight,
              child: canStart
                  ? FilledButton.tonalIcon(
                      onPressed: widget.onDownloadEnglishVoice,
                      icon: Icon(
                        status.canRetry
                            ? Icons.refresh_rounded
                            : Icons.download_rounded,
                      ),
                      label: Text(status.canRetry ? 'Retry' : 'Download'),
                    )
                  : TextButton.icon(
                      onPressed: widget.onCancelEnglishVoiceDownload,
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Cancel'),
                    ),
            ),
        ],
      ),
    );
  }

  String _soundTitle(String link) {
    for (final sound in widget.soundList) {
      if (sound.link == link) return sound.title;
    }
    return widget.soundList.isEmpty ? 'None' : widget.soundList.first.title;
  }

  String _voiceCharacterName(String name, String locale) {
    final lower = name.toLowerCase();
    final isMl = locale.toLowerCase().startsWith('ml');
    if (lower.contains('veena')) return 'Veena';
    if (lower.contains('rishi')) return 'Rishi';
    if (isMl) {
      if (lower.contains('female')) return 'Malayalam Female';
      if (lower.contains('male')) return 'Malayalam Male';
      return 'Malayalam Native';
    }
    if (lower.contains('female')) return 'Female';
    if (lower.contains('male')) return 'Male';
    if (locale.toLowerCase().startsWith('en-in')) return 'Indian English';
    if (locale.toLowerCase().startsWith('en-us')) return 'US English';
    if (locale.toLowerCase().startsWith('en-gb')) return 'UK English';
    return 'Standard';
  }

  String _speechEngineLabel(String value) {
    switch (value) {
      case 'system_only':
        return 'System TTS only';
      case 'sherpa_only':
        return 'Sherpa-ONNX only';
      case 'auto':
        return 'Auto (best available)';
      case 'com.google.android.tts':
        return 'Google Speech Services';
      case 'com.samsung.SMT':
        return 'Samsung Text-to-Speech';
      default:
        if (value.startsWith('com.')) {
          final parts = value.split('.');
          return parts.length > 1 ? parts.sublist(1).join(' ') : value;
        }
        return value.isNotEmpty ? value : 'Auto';
    }
  }

  String _voiceListLabel(String value) {
    switch (value) {
      case 'english':
        return 'English';
      case 'malayalam':
        return 'Malayalam';
      default:
        return 'Auto';
    }
  }

  String _favoriteVoiceLabel() {
    final s = ref.read(settingsProvider);
    if (s.favoriteVoiceName == null || s.favoriteVoiceLocale == null) {
      final lang = s.voiceListMode.toLowerCase();
      if (lang == 'malayalam') return 'Best voice for Malayalam';
      if (lang == 'english') return 'Best voice for English';
      return 'Best voice for selected language';
    }
    return '${_voiceCharacterName(s.favoriteVoiceName!, s.favoriteVoiceLocale!)} - ${s.favoriteVoiceLocale}';
  }

  String _favoriteVoiceKey() {
    final s = ref.read(settingsProvider);
    if (s.favoriteVoiceName == null || s.favoriteVoiceLocale == null) {
      return '__auto__';
    }
    return '${s.favoriteVoiceName}|${s.favoriteVoiceLocale}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = ref.watch(settingsProvider);

    final speechEngineOptions = <(String, String, String?)>[
      ('auto', 'Auto (System default)', 'Use device default speech engine'),
      ('system_only', 'System TTS only', 'Use the device speech engine'),
      for (final engine in widget.availableEngines)
        if (engine != 'auto' &&
            engine != 'system_only' &&
            engine != 'sherpa_only')
          (engine, _speechEngineLabel(engine), engine),
      if (!kIsWeb)
        ('sherpa_only', 'Sherpa-ONNX only', 'Linux/Windows fallback voice'),
    ];
    final voiceModeOptions = <(String, String, String?)>[
      ('auto', 'Auto', 'Automatically pick based on content'),
      ('english', 'English', null),
      ('malayalam', 'Malayalam', null),
    ];
    final nightModeOptions = <(String, String, String?)>[
      ('manual', 'Manual mode', 'Use the selected quiet hours'),
      ('automatic', 'Automatic mode', 'Mute after idle time at night'),
    ];

    final currentLanguageMode = s.voiceListMode.toLowerCase();
    final List<Map<dynamic, dynamic>> languageVoices;
    if (currentLanguageMode == 'malayalam') {
      final ml = widget.voices.where((v) {
        final loc = (v['locale']?.toString() ?? '').toLowerCase().replaceAll(
          '_',
          '-',
        );
        return loc.startsWith('ml');
      }).toList();
      languageVoices = ml.isNotEmpty
          ? ml
          : [
              {'name': 'Standard Malayalam', 'locale': 'ml-IN'},
            ];
    } else if (currentLanguageMode == 'english') {
      languageVoices = widget.voices.where((v) {
        final loc = (v['locale']?.toString() ?? '').toLowerCase().replaceAll(
          '_',
          '-',
        );
        return loc.startsWith('en');
      }).toList();
    } else {
      final ml = widget.voices.where((v) {
        final loc = (v['locale']?.toString() ?? '').toLowerCase().replaceAll(
          '_',
          '-',
        );
        return loc.startsWith('ml');
      }).toList();
      final en = widget.voices.where((v) {
        final loc = (v['locale']?.toString() ?? '').toLowerCase().replaceAll(
          '_',
          '-',
        );
        return loc.startsWith('en');
      }).toList();
      languageVoices = [
        if (ml.isNotEmpty)
          ...ml
        else
          {'name': 'Standard Malayalam', 'locale': 'ml-IN'},
        ...en,
      ];
    }

    final voiceOptions = <(String, String, String?)>[
      (
        '__auto__',
        currentLanguageMode == 'malayalam'
            ? 'Best voice for Malayalam'
            : (currentLanguageMode == 'english'
                  ? 'Best voice for English'
                  : 'Best voice for selected language'),
        null,
      ),
      ...languageVoices.map((voice) {
        final name = voice['name']?.toString() ?? 'Unknown';
        final locale = voice['locale']?.toString() ?? 'en';
        final key = '$name|$locale';
        return (key, '${_voiceCharacterName(name, locale)} - $locale', name);
      }),
    ];
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(title: const Text('Settings'), centerTitle: true),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _settingsSwitch(
            context,
            icon: Icons.dark_mode_rounded,
            title: 'Dark theme',
            subtitle: 'Use dark colors throughout the app',
            value: s.appDarkTheme,
            onChanged: widget.onAppDarkThemeChanged,
          ),
          _settingsDivider(context),
          _settingsSwitch(
            context,
            icon: s.speechMasterOn
                ? Icons.volume_up_rounded
                : Icons.volume_off_rounded,
            title: 'Master Audio',
            subtitle: s.speechMasterOn ? 'All audio on' : 'All audio off',
            value: s.speechMasterOn,
            onChanged: (val) {
              widget.onSpeechMasterOnChanged(val);
            },
          ),
          _settingsDivider(context),
          _settingsOption(
            context,
            icon: Icons.music_note_rounded,
            title: 'Background sound',
            value: _soundTitle(s.soundChosen),
            onTap: () => _showStringPicker(
              context,
              title: 'Background sound',
              currentValue: s.soundChosen,
              options: widget.soundList
                  .map((s) => (s.link, s.title, null))
                  .toList(),
              onChanged: (val) {
                widget.onSoundChanged(val);
              },
            ),
          ),
          _settingsDivider(context),
          _settingsOption(
            context,
            icon: Icons.volume_up_rounded,
            title: 'Noise volume',
            value: _getVolTitle(s.noiseVolume),
            onTap: () => _showDoublePicker(
              context,
              title: 'Noise volume',
              currentValue: s.noiseVolume,
              onChanged: (val) {
                widget.onNoiseVolumeChanged(val);
              },
            ),
          ),
          _settingsDivider(context),
          _settingsOption(
            context,
            icon: Icons.record_voice_over_rounded,
            title: 'Speech volume',
            value: _getVolTitle(s.speakVolume),
            onTap: () => _showDoublePicker(
              context,
              title: 'Speech volume',
              currentValue: s.speakVolume,
              onChanged: (val) {
                widget.onSpeakVolumeChanged(val);
              },
            ),
          ),
          _settingsDivider(context),
          _settingsSwitch(
            context,
            icon: Icons.volume_up_rounded,
            title: 'Boost TTS Volume',
            subtitle: 'Maximum volume for speech announcements only',
            value: s.maximumSpeechVolume,
            onChanged: (val) {
              widget.onMaximumSpeechVolumeChanged(val);
            },
          ),
          _settingsOption(
            context,
            icon: Icons.spatial_audio_off_rounded,
            title: 'Speech engine',
            value: _speechEngineLabel(s.speechEngineMode),
            onTap: () => _showStringPicker(
              context,
              title: 'Speech engine',
              currentValue: s.speechEngineMode,
              options: speechEngineOptions,
              onChanged: (val) {
                widget.onSpeechEngineModeChanged(val);
              },
            ),
          ),
          if (widget.speechEngineRuntime.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 14, 8),
              child: Text(
                '${widget.speechEngineRuntime} — ${widget.speechEngineRuntimeDetail}',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 11),
                maxLines: 2,
              ),
            ),
          if (widget.showEnglishVoiceDownload)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
              child: ValueListenableBuilder<SpeechModelDownloadStatus>(
                valueListenable: widget.speechModelDownloadStatus,
                builder: (context, status, _) =>
                    _speechModelDownloadCard(context, status),
              ),
            ),
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
              child: _desktopModelCard(context),
            ),
          _settingsOption(
            context,
            icon: Icons.play_circle_outline_rounded,
            title: 'Test voice',
            value: 'Play sample',
            onTap: widget.onTestSpeech,
          ),
          _settingsDivider(context),
          _settingsOption(
            context,
            icon: Icons.language_rounded,
            title: 'Language list',
            value: _voiceListLabel(s.voiceListMode),
            onTap: () => _showStringPicker(
              context,
              title: 'Language list',
              currentValue: s.voiceListMode,
              options: voiceModeOptions,
              onChanged: (val) {
                widget.onVoiceListModeChanged(val);
              },
            ),
          ),
          _settingsDivider(context),
          _settingsOption(
            context,
            icon: Icons.person_search_rounded,
            title: 'Preferred voice',
            value: _favoriteVoiceLabel(),
            onTap: () => _showStringPicker(
              context,
              title: 'Voice',
              currentValue: _favoriteVoiceKey(),
              options: voiceOptions,
              onChanged: (val) {
                widget.onFavoriteVoiceChanged(val);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(52, 8, 14, 0),
            child: Row(
              children: [
                Text(
                  'Font size',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: cs.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  '${s.appFontSizeMultiplier.toStringAsFixed(1)}x',
                  style: TextStyle(
                    color: cs.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          Slider(
            value: s.appFontSizeMultiplier,
            min: 0.8,
            max: 1.5,
            divisions: 7,
            label: '${s.appFontSizeMultiplier.toStringAsFixed(1)}x',
            onChanged: (val) {
              widget.onAppFontSizeMultiplierChanged(val);
            },
          ),
          _settingsDivider(context),
          _settingsSwitch(
            context,
            icon: Icons.dark_mode_rounded,
            title: 'Dark fullscreen',
            value: s.fullscreenDarkTheme,
            onChanged: (val) {
              widget.onFullscreenDarkThemeChanged(val);
            },
          ),
          _settingsDivider(context),
          _settingsSwitch(
            context,
            icon: Icons.brightness_4_rounded,
            title: 'Dim brightness',
            value: s.fullscreenDimBrightness,
            onChanged: (val) {
              widget.onFullscreenDimBrightnessChanged(val);
            },
          ),
          if (s.fullscreenDimBrightness) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    Icons.brightness_low_rounded,
                    size: 18,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withAlpha(150),
                  ),
                  Expanded(
                    child: Slider(
                      value: s.fullscreenDimBrightnessLevel,
                      min: 0.01,
                      max: 0.5,
                      divisions: 49,
                      label:
                          '${(s.fullscreenDimBrightnessLevel * 100).round()}%',
                      onChanged: (val) {
                        widget.onFullscreenDimBrightnessLevelChanged(val);
                      },
                    ),
                  ),
                  Icon(
                    Icons.brightness_high_rounded,
                    size: 18,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withAlpha(150),
                  ),
                ],
              ),
            ),
          ],
          _settingsDivider(context),
          _settingsSwitch(
            context,
            icon: Icons.screen_rotation_rounded,
            title: 'Start landscape',
            value: s.fullscreenStartLandscape,
            onChanged: (val) {
              widget.onFullscreenStartLandscapeChanged(val);
            },
          ),
          _settingsDivider(context),
          _settingsSwitch(
            context,
            icon: Icons.access_time_rounded,
            title: 'Show clock in fullscreen',
            subtitle: 'Display current time overlay in fullscreen focus',
            value: s.fullscreenShowClock,
            onChanged: (val) {
              widget.onFullscreenShowClockChanged?.call(val);
            },
          ),
          if (s.fullscreenShowClock) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 8, 14, 0),
              child: Row(
                children: [
                  Text(
                    'Fullscreen clock size',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: cs.onSurface,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${s.fullscreenClockScale.toStringAsFixed(1)}x',
                    style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Slider(
              value: s.fullscreenClockScale.clamp(0.8, 2.0),
              min: 0.8,
              max: 2.0,
              divisions: 6,
              label: '${s.fullscreenClockScale.toStringAsFixed(1)}x',
              onChanged: (val) {
                widget.onFullscreenClockScaleChanged?.call(val);
              },
            ),
          ],
          _settingsDivider(context),
          _settingsSwitch(
            context,
            icon: Icons.nightlight_round,
            title: 'Enable sleep mode',
            subtitle: 'Quiet hours for speech',
            value: s.muteSpeechAfterMidnight,
            onChanged: (val) {
              widget.onMuteSpeechAfterMidnightChanged(val);
            },
          ),
          if (s.muteSpeechAfterMidnight) ...[
            _settingsDivider(context),
            _settingsOption(
              context,
              icon: Icons.bedtime_rounded,
              title: 'Mode',
              value: s.nightMuteMode == 'automatic' ? 'Automatic' : 'Manual',
              onTap: () => _showStringPicker(
                context,
                title: 'Sleep mode',
                currentValue: s.nightMuteMode,
                options: nightModeOptions,
                onChanged: (val) {
                  widget.onNightMuteModeChanged(val);
                },
              ),
            ),
            _settingsDivider(context),
            _settingsOption(
              context,
              icon: Icons.schedule_rounded,
              title: 'Starts at',
              value: widget.sleepStartLabel,
              onTap: widget.onPickSleepStart,
            ),
            _settingsDivider(context),
            _settingsOption(
              context,
              icon: Icons.alarm_rounded,
              title: 'Ends at',
              value: widget.sleepEndLabel,
              onTap: widget.onPickSleepEnd,
            ),
          ],
          ListTile(
            leading: Icon(Icons.backup_rounded, color: cs.primary, size: 22),
            title: Text(
              'Backup settings',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: cs.onSurface,
              ),
            ),
            subtitle: Text(
              'Export all settings as JSON',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            trailing: Icon(
              Icons.file_download_outlined,
              color: cs.onSurfaceVariant,
              size: 20,
            ),
            onTap: widget.onBackupSettings,
          ),
          _settingsDivider(context),
          ListTile(
            leading: Icon(Icons.restore_rounded, color: cs.primary, size: 22),
            title: Text(
              'Restore settings',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: cs.onSurface,
              ),
            ),
            subtitle: Text(
              'Import settings from a JSON backup',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            ),
            trailing: Icon(
              Icons.file_upload_outlined,
              color: cs.onSurfaceVariant,
              size: 20,
            ),
            onTap: widget.onRestoreSettings,
          ),
          _settingsDivider(context),
          ListTile(
            leading: Icon(
              Icons.help_outline_rounded,
              color: cs.primary,
              size: 22,
            ),
            title: Text(
              'Help / Working',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: cs.onSurface,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: cs.onSurfaceVariant,
            ),
            onTap: widget.onOpenHelp,
          ),
          _settingsDivider(context),
          ListTile(
            leading: Icon(
              Icons.info_outline_rounded,
              color: cs.primary,
              size: 22,
            ),
            title: Text(
              'Built by Amarjith TK',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: cs.onSurface,
              ),
            ),
            subtitle: Text(
              'Atherpulse Technologies',
              style: TextStyle(
                fontWeight: FontWeight.w500,
                fontSize: 12,
                color: cs.onSurfaceVariant,
              ),
            ),
            trailing: Icon(
              Icons.open_in_new_rounded,
              color: cs.onSurfaceVariant,
              size: 20,
            ),
            onTap: () async {
              final url = Uri.parse('https://atherpulse.in');
              await launchUrl(url, mode: LaunchMode.externalApplication);
            },
          ),
        ],
      ),
    );
  }

  Widget _settingsSwitch(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required bool value,
    required ValueChanged<bool?> onChanged,
  }) {
    final cs = Theme.of(context).colorScheme;
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeThumbColor: cs.onPrimary,
      activeTrackColor: cs.primary,
      secondary: Icon(icon, color: cs.primary, size: 22),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: cs.onSurface,
        ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle,
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
            )
          : null,
    );
  }

  Widget _settingsOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: cs.primary, size: 22),
      title: Text(
        title,
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          color: cs.onSurface,
        ),
      ),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 160),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: cs.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              color: cs.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
      onTap: onTap,
    );
  }

  Widget _settingsDivider(BuildContext context) {
    return Divider(
      height: 1,
      indent: 52,
      endIndent: 16,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }

  // ── Bottom sheet pickers ────────────────────────────────────
  Future<void> _showStringPicker(
    BuildContext context, {
    required String title,
    required String currentValue,
    required List<(String, String, String?)> options,
    required ValueChanged<String?> onChanged,
  }) async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: cs.surfaceContainerLow,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (listCtx, i) {
                    final o = options[i];
                    final selected = o.$1 == currentValue;
                    return ListTile(
                      selected: selected,
                      selectedTileColor: cs.primaryContainer.withAlpha(80),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      leading: Icon(
                        selected
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        color: selected ? cs.primary : cs.onSurfaceVariant,
                      ),
                      title: Text(
                        o.$2,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      subtitle: o.$3 != null
                          ? Text(
                              o.$3!,
                              style: const TextStyle(fontSize: 12),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            )
                          : null,
                      onTap: () {
                        onChanged(o.$1);
                        Navigator.of(ctx).pop();
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDoublePicker(
    BuildContext context, {
    required String title,
    required double currentValue,
    required ValueChanged<double?> onChanged,
  }) async {
    final cs = Theme.of(context).colorScheme;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      backgroundColor: cs.surfaceContainerLow,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              ...widget.volumeLists.map((volume) {
                final selected = volume == currentValue;
                return ListTile(
                  selected: selected,
                  selectedTileColor: cs.primaryContainer.withAlpha(80),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    color: selected ? cs.primary : cs.onSurfaceVariant,
                  ),
                  title: Text(
                    _getVolTitle(volume),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  subtitle: Text(
                    '${(volume * 100).round()}%',
                    style: const TextStyle(fontSize: 12),
                  ),
                  onTap: () {
                    onChanged(volume);
                    Navigator.of(ctx).pop();
                  },
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}
