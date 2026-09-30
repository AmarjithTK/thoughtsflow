// ============================================================================
// SOLASFLOW - A Productivity Timer & Meditation App
// ============================================================================
//
// **Version:** 1.0.0
// **Platform:** Android, iOS, Web, macOS, Linux, Windows
// **Target:** Dart ^3.11.3, Flutter stable
//
// ## Architecture Overview
//
// This is a feature-modular, service-oriented app for managing focused work
// sessions, clock displays, and motivational quotes. Clean architecture:
//
// - **UI Layer:** Screens & Widgets (main tabs: Timer, Clock, Settings, Presets)
// - **Service Layer:** Business logic (TimerService, SettingsService, etc.)
// - **Features:** Domain-specific modules (motivation/ feature)
// - **Models:** Data classes representing app state
// - **Theme:** Centralized Material 3 styling via palette.dart
//
// ## Key Features
//
// 1. Timer Management: Countdown with customizable presets & chain mode
// 2. Speech: TTS announcements with Malayalam support
// 3. Background Audio: Ambient sounds (rain, waterfall, fire, stream)
// 4. Foreground Service: Persistent notifications during long sessions
// 5. Motivational Quotes: Category-based rotating quotes for focus
// 6. Night Mode: Auto-mute speech after midnight with configurable window
// 7. Localization: Multi-language support (English, Malayalam)
// 8. Theme System: Light/dark mode toggle with Material 3 theming
// 9. Health Checks: Periodic service recovery to prevent OS kills
// 10. Settable Presets: Pomodoro, Sprint, and Quick session types
//
// ## Service Initialization Pattern
//
// Services are initialized as class members in _MainScreenState:
// - SettingsService: Persists user preferences via SharedPreferences
// - TimerService: Manages countdown logic and announcements
// - SpeechService: Queues TTS/ringtone playback with concurrency control
// - AudioService: Plays ambient background sounds
// - ForegroundNotificationService: Android foreground service & notification
// - QuoteRotationService: Cycling logic for motivational quotes
// - MalayalamTtsService: Language-specific TTS selection
//
// ## Performance Optimizations
//
// - Display Ticker: 250ms frequency (up from 30ms) for reduced GPU pressure
// - Conditional setState(): Only rebuild if display actually changed
// - Idle Notification Throttle: 4:1 reduction in idle notification syncs
// - Lazy TTS initialization: Voices loaded only when needed
// - Health Check Interval: 30s periodic service recovery
//
// ## Future Roadmap
//
// - [ ] Custom preset creation UI
// - [ ] Session history & analytics
// - [ ] Haptic feedback on timer complete
// - [ ] Circular progress indicator widget
// - [ ] Cloud sync of settings & session history
// - [ ] Wear OS companion app
// - [ ] Export session data to Google Fit

import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:quick_actions/quick_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'core/pref_keys.dart';
import 'providers/app_state.dart';
import 'theme/app_theme.dart';

import 'l10n/app_localizations.dart';
import 'models/app_settings.dart';
import 'models/speech_model_download_status.dart';
import 'models/foreground_notification_state.dart';
import 'models/timer_runtime.dart';
import 'models/speech_item.dart';
import 'models/sound_option.dart';
import 'services/audio_service.dart';
import 'services/foreground_notification_service.dart';
import 'services/malayalam_tts_service.dart';
import 'services/settings_service.dart';
import 'services/speech_service.dart';
import 'services/timer_service.dart';
import 'services/timer_runtime_store.dart';
import 'features/motivation/motivation_content.dart';
import 'features/motivation/services/quote_rotation_service.dart';
import 'widgets/clock_panel.dart';
import 'widgets/fullscreen_focus_view.dart';
import 'widgets/timer_panel.dart';
import 'widgets/stopwatch_panel.dart';
import 'widgets/settings_panel.dart';
import 'widgets/help_panel.dart';
import 'widgets/bottom_nav_bar.dart';
import 'services/voice_session_manager.dart';
import 'services/speech_language_service.dart';
import 'services/session_log_service.dart';
import 'models/session_log.dart';
import 'widgets/dashboard_screen.dart';
import 'widgets/kokoro_download_consent_dialog.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(SolasFlowTaskHandler());
}

class SolasFlowTaskHandler extends TaskHandler {
  final TimerRuntimeStore _store = TimerRuntimeStore();
  int _lastPublishedRemaining = -1;
  int _lastStopwatchPublishedSeconds = -1;
  int _lastClockMinute = -1;
  Future<void> _operationTail = Future<void>.value();

  void _enqueue(Future<void> Function() operation) {
    _operationTail = _operationTail
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Background task operation failed: $error');
        })
        .then((_) => operation());
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await _reconcile(timestamp, force: true);
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _enqueue(() => _reconcile(timestamp));
  }

  Future<void> _reconcile(DateTime now, {bool force = false}) async {
    var runtime = await _store.load();
    final stopwatch = await _store.loadStopwatch();
    final settings = await _store.loadTaskSettings();
    if (runtime.status == TimerRuntimeStatus.running) {
      final remaining = runtime.remainingAt(now);
      if (remaining == 0) {
        runtime = runtime.copyWith(
          status: TimerRuntimeStatus.finished,
          remainingSeconds: 0,
          endAtEpochMs: () => null,
          revision: runtime.revision + 1,
        );
        await _store.save(runtime);
        force = true;
      } else if (remaining != runtime.remainingSeconds) {
        runtime = runtime.copyWith(remainingSeconds: remaining);
      }
    }

    final remaining = runtime.remainingAt(now);
    final stopwatchSeconds = stopwatch.elapsedMsAt(now) ~/ 1000;
    final clockMinute = now.millisecondsSinceEpoch ~/ 60000;
    final timerNeedsPublish =
        runtime.status == TimerRuntimeStatus.running &&
        remaining != _lastPublishedRemaining &&
        (remaining <= 10 || remaining % 60 == 0);
    final stopwatchNeedsPublish =
        stopwatch.isRunning &&
        stopwatchSeconds != _lastStopwatchPublishedSeconds &&
        stopwatchSeconds % 30 == 0;
    final clockNeedsPublish =
        settings.clockOn && clockMinute != _lastClockMinute;
    if (!force &&
        !timerNeedsPublish &&
        !stopwatchNeedsPublish &&
        !clockNeedsPublish) {
      return;
    }
    _lastPublishedRemaining = remaining;
    _lastStopwatchPublishedSeconds = stopwatchSeconds;
    _lastClockMinute = clockMinute;
    await _updateNotification(runtime, stopwatch, settings);
  }

  Future<void> _updateNotification(
    TimerRuntime runtime,
    StopwatchRuntime stopwatch,
    AppSettings settings,
  ) async {
    final now = DateTime.now();
    final remaining = runtime.remainingAt(now);
    final minutes = (remaining ~/ 60).toString().padLeft(2, '0');
    final seconds = (remaining % 60).toString().padLeft(2, '0');
    final stopwatchTotal = stopwatch.elapsedMsAt(now) ~/ 1000;
    final stopwatchMinutes = (stopwatchTotal ~/ 60).toString().padLeft(2, '0');
    final stopwatchSeconds = (stopwatchTotal % 60).toString().padLeft(2, '0');
    final currentTime =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    final state = ForegroundNotificationState(
      isTimerRunning: runtime.status == TimerRuntimeStatus.running,
      isStopwatchRunning: stopwatch.isRunning,
      timerValue: '$minutes:$seconds',
      stopwatchValue: '$stopwatchMinutes:$stopwatchSeconds',
      currentTimeDisplay: currentTime,
      speechMasterOn: settings.speechMasterOn,
      isTimerFinished: runtime.status == TimerRuntimeStatus.finished,
    );
    final result = await FlutterForegroundTask.updateService(
      notificationTitle: state.title,
      notificationText: state.text,
      notificationButtons: state.buttons,
    );
    if (result is ServiceRequestFailure) {
      debugPrint('Background notification update failed: ${result.error}');
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'open_app') {
      FlutterForegroundTask.launchApp();
      return;
    }
    _enqueue(() => _handleNotificationButton(id));
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  Future<void> _handleNotificationButton(String id) async {
    var runtime = await _store.load();
    var settings = await _store.loadTaskSettings();
    var stopwatch = await _store.loadStopwatch();
    if (id == 'audio:set:on' || id == 'audio:set:off') {
      final enabled = id == 'audio:set:on';
      await _store.saveSpeechMasterOverride(enabled);
      settings = settings.copyWith(speechMasterOn: enabled);
      await _updateNotification(runtime, stopwatch, settings);
      FlutterForegroundTask.sendDataToMain({
        'type': 'speechMaster',
        'value': enabled,
      });
      return;
    }

    if (id == 'btn_timer_repeat' && runtime.durationSeconds > 0) {
      runtime = TimerRuntime.running(
        durationSeconds: runtime.durationSeconds,
        remainingSeconds: runtime.durationSeconds,
        now: DateTime.now(),
        chainModeOn: runtime.chainModeOn,
        chainPresetKey: runtime.chainPresetKey,
        chainIndex: runtime.chainIndex,
        runId: runtime.runId,
        revision: runtime.revision + 1,
      );
      await _store.save(runtime);
      await _updateNotification(runtime, stopwatch, settings);
      FlutterForegroundTask.sendDataToMain({
        'type': 'runtime',
        'snapshot': runtime.toJson(),
      });
      return;
    }

    if (id == 'btn_timer_dismiss' || id == 'btn_exit') {
      runtime = TimerRuntime.idle().copyWith(revision: runtime.revision + 1);
      await _store.save(runtime);
      if (id == 'btn_exit') {
        stopwatch = StopwatchRuntime.idle().copyWith(
          revision: stopwatch.revision + 1,
        );
        await _store.saveStopwatch(stopwatch);
      }
      FlutterForegroundTask.sendDataToMain({
        'type': id == 'btn_exit' ? 'exit' : 'runtime',
        'snapshot': runtime.toJson(),
        'stopwatch': stopwatch.toJson(),
      });
      if (id == 'btn_exit' ||
          (!settings.backgroundPersistenceOn &&
              !stopwatch.isRunning &&
              !settings.clockOn)) {
        final result = await FlutterForegroundTask.stopService();
        if (result is ServiceRequestFailure) {
          debugPrint('Background service stop failed: ${result.error}');
        }
      } else {
        await _updateNotification(runtime, stopwatch, settings);
      }
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isForceRequest) async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  try {
    final settings = await SettingsService().load(
      defaultSound: 'audio/rain.mp3',
    );
    SettingsNotifier.bootstrap(settings);
  } catch (error, stackTrace) {
    debugPrint('Settings bootstrap failed: $error\n$stackTrace');
    SettingsNotifier.bootstrap(AppSettings.defaults());
  }
  runApp(const ProviderScope(child: SolasFlowApp()));
}

class SolasFlowApp extends ConsumerWidget {
  const SolasFlowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final themeMode = settings.appDarkTheme ? ThemeMode.dark : ThemeMode.light;
    final fontSizeMultiplier = settings.appFontSizeMultiplier;

    return WithForegroundTask(
      child: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return MaterialApp(
            title: l10n?.appTitle ?? 'SolasFlow',
            debugShowCheckedModeBanner: false,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            themeMode: themeMode,
            builder: (context, child) {
              return MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(fontSizeMultiplier)),
                child: child!,
              );
            },
            theme: AppTheme.light(),
            darkTheme: AppTheme.dark(),
            home: const MainScreen(),
          );
        },
      ),
    );
  }
}

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen>
    with WidgetsBindingObserver {
  bool get _supportsForegroundTask =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  bool get _supportsQuickActions {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// ============================================================================
  /// SERVICE LAYER - Dependency injection for business logic
  /// ============================================================================
  /// Each service is a singleton responsible for specific domain logic.
  /// Services handle persistence, calculations, and external system integration.

  /// Manages quick actions (home screen shortcuts) for rapid timer start
  final QuickActions _quickActions = const QuickActions();

  /// MethodChannel for receiving widget button actions from native Android
  static const MethodChannel _widgetChannel = MethodChannel(
    'com.atherpulse.solasflow/widget',
  );

  /// Plays ambient background sounds (rain, waterfall, fire, stream)
  /// Handles volume and audio session management
  final AudioService _audioService = AudioService();

  /// Loads/saves AppSettings from SharedPreferences with versioned migrations
  /// Ensures data compatibility across app versions
  final SettingsService _settingsService = SettingsService();

  /// Queues TTS (text-to-speech) and ringtone announcements
  /// Ensures speech items play sequentially (no overlaps)
  final SpeechService _speechService = SpeechService();

  /// Handles Malayalam-specific TTS voice selection and synthesis
  /// Provides fallback to English if Malayalam unavailable
  final MalayalamTtsService _malayalamTtsService = MalayalamTtsService();

  /// Singleton voice session manager for consistent language selection
  final VoiceSessionManager _voiceSessionManager = VoiceSessionManager();
  final SpeechLanguageService _speechLanguageService = SpeechLanguageService();

  /// Manages timer countdown logic: starts, pauses, resumes, calculates display
  /// Handles announcement timings based on user preferences
  final TimerService _timerService = TimerService();

  /// Cycles through motivational quotes by category
  /// Encapsulates quote rotation state and list management
  final QuoteRotationService _quoteRotationService = QuoteRotationService();

  /// Session log service for study/non-study tagging
  final SessionLogService _sessionLogService = SessionLogService();
  final TimerRuntimeStore _timerRuntimeStore = TimerRuntimeStore();
  TimerRuntime _timerRuntime = TimerRuntime.idle();
  bool _timerCompletionInFlight = false;
  int _alarmGeneration = 0;
  bool _bootstrapReady = false;
  final List<Future<void> Function()> _pendingExternalActions = [];
  Future<void> _widgetDrainTail = Future<void>.value();

  /// Session recording state — captured when timer starts
  DateTime? _sessionStartTime;

  /// Today's summary display string for the timer panel
  String _todaySummary = '';

  /// Manages Android foreground service & persistent notifications
  /// Keeps app alive during long timer sessions
  final ForegroundNotificationService _foregroundNotificationService =
      ForegroundNotificationService(
        notificationIconMetaDataName:
            'com.atherpulse.solasflow.service.NOTIFICATION_ICON',
      );

  /// ============================================================================
  /// TTS & SPEECH STATE - Text-to-speech management
  /// ============================================================================
  /// Manages voice synthesis, queue management, and concurrent speech exclusion

  /// Flutter TTS instance for speech synthesis
  FlutterTts flutterTts = FlutterTts();

  /// True when TTS engine is initialized and callable.
  bool _ttsReady = false;

  /// Single-flight guard to prevent concurrent init races.
  Future<void>? _ttsInitInFlight;

  /// Backoff gate for repeated initialization failures.
  DateTime _nextTtsInitAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);

  final Queue<SpeechItem> speechQueue = Queue<SpeechItem>();
  int _speechGeneration = 0;
  Future<void> _announcementTail = Future<void>.value();
  final Stopwatch _announcementClock = Stopwatch()..start();
  int _lastAnnouncementElapsedMs = -10000;

  /// Flag to prevent concurrent speech playback (TTS can't overlap)
  bool isSpeechActive = false;

  /// List of available TTS voices fetched from system
  List<Map<dynamic, dynamic>> voices = [];

  /// Current voice index in the voices list
  int voiceIndex = 0;

  /// Flag indicating if background audio is currently playing

  /// Flag indicating if background audio is currently playing
  bool audioPlaying = false;

  /// ============================================================================
  /// TIMER STATE - Timer display & countdown management
  /// ============================================================================
  /// Tracks timer value, intervals, and completion status

  /// Slider input value (0-120 minutes) from timer UI
  int sliderValue = 25;

  /// Current countdown seconds remaining
  int seconds = 0;

  /// Active countdown interval timer (null when stopped)
  Timer? timerInterval;

  /// Two-tap confirmation state: the preset value currently awaiting
  /// a second tap before the timer starts.  Null = no button armed.
  int? _armedPresetValue;

  /// 3-second auto-clear timer for the armed preset state.
  Timer? _armedPresetTimer;

  /// Two-tap confirmation for widget home-screen actions.
  /// Stores which widget action is awaiting confirmation ("toggle_speech_master"
  /// or "open_fullscreen_clock").  Null = no action armed.
  String? _widgetArmedAction;

  /// 3-second auto-clear timer for widget armed state.
  Timer? _widgetArmedTimer;

  /// Formatted display string (MM:SS)
  String timerValue = "00:00";

  /// Timer text used by UI (supports optional centiseconds)
  String timerDisplayValue = "00:00";

  /// ============================================================================
  /// CLOCK STATE - Clock display & periodic announcements
  /// ============================================================================
  /// Manages clock time display and interval-based time announcements

  /// Periodic timer for clock time updates
  Timer? clockTimer;
  DateTime? _nextClockAt;

  /// Display ticker: updates UI at 250ms intervals (reduced from 30ms for performance)
  Timer? displayTick;

  /// Current time formatted for display (HH:MM or HH:MM:SS)
  String currentTimeDisplay = "";

  /// 30-second health check timer for foreground service recovery
  /// Detects if OS killed the service and restarts it
  Timer? foregroundHealthTimer;

  /// Currently active tab index (0=SpeakClock, 1=Timer Setup, 2=Stopwatch, 3=Goals, 4=Settings)
  int currentTabIndex = 1;

  /// ============================================================================
  /// ANNOUNCEMENT TIMING - 10-second gap enforcement between speech segments
  /// ============================================================================
  /// Prevents rapid repeated announcements from overlapping

  /// Timestamp of last clock announcement (prevents <10s re-announcements)
  int lastClockSpoke = 0;

  /// Timestamp of last timer announcement (prevents <10s re-announcements)
  int lastTimerSpoke = 0;

  /// Timestamp of last stopwatch announcement (prevents <10s re-announcements)
  int lastStopwatchSpoke = 0;

  /// Timestamp of last goal reminder announcement
  int lastGoalReminderSpoke = 0;

  /// Stopwatch ticker interval
  Timer? stopwatchInterval;

  StopwatchRuntime _stopwatchRuntime = StopwatchRuntime.idle();

  /// Elapsed stopwatch seconds
  int stopwatchElapsedSeconds = 0;

  /// Formatted elapsed stopwatch display (MM:SS or HH:MM:SS)
  String stopwatchElapsedValue = '00:00';

  AppSettings get _settings => ref.read(settingsProvider);

  void _updateSettings(AppSettings Function(AppSettings current) transform) {
    ref.read(settingsProvider.notifier).update(transform);
  }

  bool get stopwatchSpeakOn => _settings.stopwatchSpeakOn;
  set stopwatchSpeakOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(stopwatchSpeakOn: value));
  bool get timerShowMilliseconds => _settings.timerShowMilliseconds;
  set timerShowMilliseconds(bool value) => _updateSettings(
    (settings) => settings.copyWith(timerShowMilliseconds: value),
  );
  bool get stopwatchShowMilliseconds => _settings.stopwatchShowMilliseconds;
  set stopwatchShowMilliseconds(bool value) => _updateSettings(
    (settings) => settings.copyWith(stopwatchShowMilliseconds: value),
  );
  int get stopwatchSpeakDelaySeconds => _settings.stopwatchSpeakDelaySeconds;
  set stopwatchSpeakDelaySeconds(int value) => _updateSettings(
    (settings) => settings.copyWith(stopwatchSpeakDelaySeconds: value),
  );
  String get soundChosen => _settings.soundChosen;
  set soundChosen(String value) =>
      _updateSettings((settings) => settings.copyWith(soundChosen: value));
  double get noiseVolume => _settings.noiseVolume;
  set noiseVolume(double value) =>
      _updateSettings((settings) => settings.copyWith(noiseVolume: value));
  double get speakVolume => _settings.speakVolume;
  set speakVolume(double value) =>
      _updateSettings((settings) => settings.copyWith(speakVolume: value));
  bool get maximumSpeechVolume => _settings.maximumSpeechVolume;
  set maximumSpeechVolume(bool value) => _updateSettings(
    (settings) => settings.copyWith(maximumSpeechVolume: value),
  );
  bool get speechMasterOn => _settings.speechMasterOn;
  set speechMasterOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(speechMasterOn: value));
  bool get clockOn => _settings.clockOn;
  set clockOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(clockOn: value));
  int get clockIntervalMins => _settings.clockIntervalMins;
  set clockIntervalMins(int value) => _updateSettings(
    (settings) => settings.copyWith(clockIntervalMins: value),
  );
  bool get clockShowMilliseconds => _settings.clockShowMilliseconds;
  set clockShowMilliseconds(bool value) => _updateSettings(
    (settings) => settings.copyWith(clockShowMilliseconds: value),
  );
  bool get clockShowSeconds => _settings.clockShowSeconds;
  set clockShowSeconds(bool value) =>
      _updateSettings((settings) => settings.copyWith(clockShowSeconds: value));
  bool get clockSpeakTime => _settings.clockSpeakTime;
  set clockSpeakTime(bool value) =>
      _updateSettings((settings) => settings.copyWith(clockSpeakTime: value));
  int get clockSpeakRepeatCount => _settings.clockSpeakRepeatCount;
  set clockSpeakRepeatCount(int value) => _updateSettings(
    (settings) => settings.copyWith(clockSpeakRepeatCount: value),
  );
  bool get clockNoiseOn => _settings.clockNoiseOn;
  set clockNoiseOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(clockNoiseOn: value));
  bool get motivationOn => _settings.motivationOn;
  set motivationOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(motivationOn: value));
  String get motivationCategory => _settings.motivationCategory;
  set motivationCategory(String value) => _updateSettings(
    (settings) => settings.copyWith(motivationCategory: value),
  );
  int get motivationDelaySeconds => _settings.motivationDelaySeconds;
  set motivationDelaySeconds(int value) => _updateSettings(
    (settings) => settings.copyWith(motivationDelaySeconds: value),
  );
  bool get timerNoiseOn => _settings.timerNoiseOn;
  set timerNoiseOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(timerNoiseOn: value));
  bool get goalReminderOn => _settings.goalReminderOn;
  set goalReminderOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(goalReminderOn: value));
  int get goalReminderIntervalMins => _settings.goalReminderIntervalMins;
  set goalReminderIntervalMins(int value) => _updateSettings(
    (settings) => settings.copyWith(goalReminderIntervalMins: value),
  );
  List<String> get goalReminderItems => _settings.goalReminderItems;
  set goalReminderItems(List<String> value) => _updateSettings(
    (settings) => settings.copyWith(goalReminderItems: value),
  );
  int get goalReminderNextIndex => _settings.goalReminderNextIndex;
  set goalReminderNextIndex(int value) => _updateSettings(
    (settings) => settings.copyWith(goalReminderNextIndex: value),
  );
  bool get appDarkTheme => _settings.appDarkTheme;
  set appDarkTheme(bool value) =>
      _updateSettings((settings) => settings.copyWith(appDarkTheme: value));
  bool get muteSpeechAfterMidnight => _settings.muteSpeechAfterMidnight;
  set muteSpeechAfterMidnight(bool value) => _updateSettings(
    (settings) => settings.copyWith(muteSpeechAfterMidnight: value),
  );
  String get nightMuteMode => _settings.nightMuteMode;
  set nightMuteMode(String value) =>
      _updateSettings((settings) => settings.copyWith(nightMuteMode: value));
  int get sleepStartMinutes => _settings.sleepStartMinutes;
  set sleepStartMinutes(int value) => _updateSettings(
    (settings) => settings.copyWith(sleepStartMinutes: value),
  );
  int get sleepEndMinutes => _settings.sleepEndMinutes;
  set sleepEndMinutes(int value) =>
      _updateSettings((settings) => settings.copyWith(sleepEndMinutes: value));
  bool get fullscreenDarkTheme => _settings.fullscreenDarkTheme;
  set fullscreenDarkTheme(bool value) => _updateSettings(
    (settings) => settings.copyWith(fullscreenDarkTheme: value),
  );
  bool get fullscreenDimBrightness => _settings.fullscreenDimBrightness;
  set fullscreenDimBrightness(bool value) => _updateSettings(
    (settings) => settings.copyWith(fullscreenDimBrightness: value),
  );
  bool get fullscreenStartLandscape => _settings.fullscreenStartLandscape;
  set fullscreenStartLandscape(bool value) => _updateSettings(
    (settings) => settings.copyWith(fullscreenStartLandscape: value),
  );
  bool get fullscreenShowClock => _settings.fullscreenShowClock;
  set fullscreenShowClock(bool value) => _updateSettings(
    (settings) => settings.copyWith(fullscreenShowClock: value),
  );
  double get fullscreenClockScale => _settings.fullscreenClockScale;
  set fullscreenClockScale(double value) => _updateSettings(
    (settings) => settings.copyWith(fullscreenClockScale: value),
  );
  bool get backgroundPersistenceOn => _settings.backgroundPersistenceOn;
  set backgroundPersistenceOn(bool value) => _updateSettings(
    (settings) => settings.copyWith(backgroundPersistenceOn: value),
  );
  bool get taggingOn => _settings.taggingOn;
  set taggingOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(taggingOn: value));
  String get sessionTag => _settings.sessionTag;
  set sessionTag(String value) =>
      _updateSettings((settings) => settings.copyWith(sessionTag: value));
  double get fullscreenDimBrightnessLevel =>
      _settings.fullscreenDimBrightnessLevel;
  set fullscreenDimBrightnessLevel(double value) => _updateSettings(
    (settings) => settings.copyWith(fullscreenDimBrightnessLevel: value),
  );
  bool get timerSpeakOn => _settings.timerSpeakOn;
  set timerSpeakOn(bool value) =>
      _updateSettings((settings) => settings.copyWith(timerSpeakOn: value));
  int get timerAnnounceEvery => _settings.timerAnnounceEvery;
  set timerAnnounceEvery(int value) => _updateSettings(
    (settings) => settings.copyWith(timerAnnounceEvery: value),
  );
  String get voiceListMode => _settings.voiceListMode;
  set voiceListMode(String value) =>
      _updateSettings((settings) => settings.copyWith(voiceListMode: value));
  String get speechEngineMode => _settings.speechEngineMode;
  set speechEngineMode(String value) =>
      _updateSettings((settings) => settings.copyWith(speechEngineMode: value));
  String? get favoriteVoiceName => _settings.favoriteVoiceName;
  set favoriteVoiceName(String? value) => _updateSettings(
    (settings) => settings.copyWith(favoriteVoiceName: () => value),
  );
  String? get favoriteVoiceLocale => _settings.favoriteVoiceLocale;
  set favoriteVoiceLocale(String? value) => _updateSettings(
    (settings) => settings.copyWith(favoriteVoiceLocale: () => value),
  );
  double get appFontSizeMultiplier => _settings.appFontSizeMultiplier;
  set appFontSizeMultiplier(double value) => _updateSettings(
    (settings) => settings.copyWith(appFontSizeMultiplier: value),
  );

  bool autoNightMuteActive = false;
  Timer? nightIdleTimer;
  Timer? nightResumeSpeechTimer;
  Timer? goalReminderTimer;
  DateTime? _nextGoalReminderAt;
  List<String> _installedEngines = [];
  int _lastStopwatchNotificationSecond = -1;

  int _lastStopwatchAutoAnnouncedSecond = -1;

  /// Enable/disable chain mode (consecutive presets)
  bool chainModeOn = false;

  /// Name of current preset being used in chain mode
  String chainPresetKey = 'Pomodoro 25-5x4';

  /// Index of current preset in chain sequence
  int chainIndex = 0;

  /// Currently running timer duration in seconds (used by "Repeat same timer")
  int _activeTimerDurationSeconds = 0;

  /// Last completed timer duration in seconds
  int _lastFinishedTimerDurationSeconds = 25 * 60;

  /// Guards against stacking multiple completion dialogs.
  bool _timerFinishedDialogOpen = false;

  /// True while the focus fullscreen route is on top.
  bool _fullscreenFocusOpen = false;

  /// True when the timer has finished but the dialog hasn't been
  /// dismissed yet.  Used by the foreground notification to show
  /// "Timer finished!" with action buttons.
  bool _isTimerFinished = false;

  /// Presets shown in the timer-finished popup.
  final List<int> _timerFinishedPresetMinutes = [
    1,
    2,
    3,
    5,
    10,
    15,
    20,
    25,
    30,
    35,
    40,
    45,
    50,
    60,
    75,
    90,
    120,
  ];

  /// ============================================================================
  /// PRESET CONFIGURATIONS - Predefined timer sequences & options
  /// ============================================================================
  /// These define user-selectable options for different timer modes

  /// Named chains of timer durations (in minutes) to run consecutively
  /// Useful for Pomodoro technique: work 25min, break 5min (4 cycles), long break 15min
  final Map<String, List<int>> chainPresets = {
    'Pomodoro 25-5x4': [25, 5, 25, 5, 25, 5, 25, 15], // Classic Pomodoro
    'Sprint 50-10x2': [50, 10, 50, 10], // Long focus + short breaks
    'Quick 15-3x3': [15, 3, 15, 3, 15, 3], // Fast-paced cycles
  };

  /// Sound file path for timer completion notification
  final String notifySound = "audio/notify.mp3";

  /// Available ambient background sounds with user-friendly names
  final List<SoundOption> soundList = [
    SoundOption("audio/rain.mp3", "Rain"),
    SoundOption("audio/waterfall.mp3", "Waterfall"),
    SoundOption("audio/fire.mp3", "Fire"),
    SoundOption("audio/stream.mp3", "Stream"),
  ];

  /// Available volume levels (0.0-1.0) for numerical selection
  final List<double> volumeLists = [0.1, 0.2, 0.6, 0.8, 1.0];

  /// Quick preset timer values (in minutes) for rapid timer setup
  final List<int> presetValues = [
    1,
    2,
    5,
    10,
    15,
    20,
    25,
    30,
    45,
    60,
    3,
    7,
    12,
    35,
    90,
  ];

  /// Available clock announcement intervals (in minutes)
  final List<int> clockIntervalOptions = [1, 2, 5, 10, 15, 20, 30, 60];

  /// Allowed repetitions for each clock speech announcement
  final List<int> clockSpeakRepeatOptions = [1, 2, 3];

  /// Timer announcement frequency options (announce every N minutes)
  final List<int> timerAnnounceOptions = [1, 2, 5, 10, 15, 20, 30];

  /// Stopwatch speech delay options (in seconds)
  final List<int> stopwatchSpeakDelayOptions = [
    15,
    30,
    45,
    60,
    120,
    300,
    600,
    900,
    1800,
  ];

  /// Delay options between motivational quote announcements (in seconds)
  final List<int> motivationDelayOptions = [5, 10, 20, 30, 40, 60];

  /// Goal reminder interval options in minutes
  final List<int> goalReminderIntervalOptions = [30, 60, 120, 180, 240];

  /// SharedPreferences key for last timer seconds via quick action
  static const String _lastTimerSecondsKey = 'QuickActionLastSeconds';

  // Flag to avoid asking for battery optimization multiple times
  static const String _batteryOptimizationAskedKey = 'BatteryOptAsked';

  Future<void> _requestPermissions() async {
    if (!_supportsForegroundTask) return;
    final prefs = await SharedPreferences.getInstance();
    final bool hasAskedBattery =
        prefs.getBool(_batteryOptimizationAskedKey) ?? false;

    if (!hasAskedBattery &&
        await FlutterForegroundTask.isIgnoringBatteryOptimizations == false) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      await prefs.setBool(_batteryOptimizationAskedKey, true);
    }
    final NotificationPermission status =
        await FlutterForegroundTask.checkNotificationPermission();
    if (status != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  void _initForegroundTask() {
    if (!_supportsForegroundTask) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'com.atherpulse.solasflow.timer_fg',
        channelName: 'SolasFlow Timer',
        channelDescription: 'Persistent timer & stopwatch service',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(1000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: false,
        allowAutoRestart: true,
        stopWithTask: false,
      ),
    );
  }

  String _formatCurrentTime(DateTime now) {
    final withMs = _timerService.formatCurrentTime(now);
    final parts = withMs.split(' ');
    final timePartWithFraction = parts.first; // e.g. 03:45:30.125
    final suffix = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    final timeWithoutFraction = timePartWithFraction
        .split('.')
        .first; // 03:45:30
    final hmParts = timeWithoutFraction.split(':');
    final hm = hmParts.length >= 2
        ? '${hmParts[0]}:${hmParts[1]}'
        : timeWithoutFraction;

    if (!clockShowSeconds) {
      return suffix.isEmpty ? hm : '$hm $suffix';
    }

    if (clockShowMilliseconds) {
      return withMs;
    }

    return suffix.isEmpty
        ? timeWithoutFraction
        : '$timeWithoutFraction $suffix';
  }

  ForegroundNotificationState _foregroundState() {
    final idleTime = currentTimeDisplay.isNotEmpty
        ? currentTimeDisplay
        : _formatCurrentTime(DateTime.now());

    return ForegroundNotificationState(
      isTimerRunning: timerInterval != null,
      isStopwatchRunning: stopwatchInterval != null,
      timerValue: timerDisplayValue,
      stopwatchValue: stopwatchElapsedValue,
      currentTimeDisplay: idleTime,
      speechMasterOn: speechMasterOn,
      isTimerFinished: _isTimerFinished,
    );
  }

  bool get _isAnythingActive =>
      backgroundPersistenceOn ||
      timerInterval != null ||
      stopwatchInterval != null ||
      clockOn ||
      _isTimerFinished;

  Future<void> _reconcileForeground({bool force = false}) async {
    final ok = await _foregroundNotificationService.reconcile(
      shouldRun: _isAnythingActive,
      state: _foregroundState(),
      callback: startCallback,
      force: force,
    );
    if (!ok && _foregroundNotificationService.lastError != null) {
      debugPrint(
        'Foreground state not applied: ${_foregroundNotificationService.lastError}',
      );
    }
  }

  Future<void> _syncForegroundNotification({bool force = false}) =>
      _reconcileForeground(force: force);

  Future<void> _initializeForegroundNotification() async {
    if (!_supportsForegroundTask) return;
    await _requestPermissions();
    await _reconcileForeground(force: true);
  }

  Future<void> _stopForegroundService() async {
    await _foregroundNotificationService.reconcile(
      shouldRun: false,
      state: _foregroundState(),
      callback: startCallback,
      force: true,
    );
  }

  void _startForegroundHealthCheck() {
    foregroundHealthTimer?.cancel();
    foregroundHealthTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted || !_isAnythingActive) return;
      unawaited(_reconcileForeground(force: true));
    });
  }

  Future<void> _saveLastTimerSeconds(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastTimerSecondsKey, value);
  }

  String _formatMinutesAs12Hour(int totalMinutes) {
    final normalized = totalMinutes % (24 * 60);
    final hour = normalized ~/ 60;
    final minute = normalized % 60;
    final ampm = hour >= 12 ? 'PM' : 'AM';
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;
    final minuteStr = minute.toString().padLeft(2, '0');
    return '$hour12:$minuteStr $ampm';
  }

  Future<void> _pickSleepStartTime() async {
    final initial = TimeOfDay(
      hour: sleepStartMinutes ~/ 60,
      minute: sleepStartMinutes % 60,
    );
    final selected = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (selected == null) return;

    setState(() {
      sleepStartMinutes = selected.hour * 60 + selected.minute;
      _lsSave();
      if (_isAudioMuted()) {
        speechQueue.clear();
      }
    });
  }

  Future<void> _pickSleepEndTime() async {
    final initial = TimeOfDay(
      hour: sleepEndMinutes ~/ 60,
      minute: sleepEndMinutes % 60,
    );
    final selected = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (selected == null) return;

    setState(() {
      sleepEndMinutes = selected.hour * 60 + selected.minute;
      _lsSave();
      if (_isAudioMuted()) {
        speechQueue.clear();
      }
    });
  }

  Future<int> _readLastTimerSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastTimerSecondsKey) ?? (sliderValue * 60);
  }

  Future<void> _handleQuickAction(String type) async {
    if (!mounted) return;
    switch (type) {
      case 'start_25m':
        setState(() {
          currentTabIndex = 1;
          chainModeOn = false;
          seconds = 25 * 60;
          timerValue = '25:00';
        });
        startTimer();
        break;
      case 'resume_last':
        final last = await _readLastTimerSeconds();
        if (!mounted) return;
        setState(() {
          currentTabIndex = 1;
          seconds = last;
          final mins = (last ~/ 60).toString().padLeft(2, '0');
          final secs = (last % 60).toString().padLeft(2, '0');
          timerValue = '$mins:$secs';
        });
        startTimer();
        break;
      case 'toggle_speech':
        setState(() {
          timerSpeakOn = !timerSpeakOn;
          _lsSave();
        });
        _syncForegroundNotification(force: true);
        break;
      case 'toggle_speech_master':
        await _setSpeechMaster(!speechMasterOn);
        break;
    }
  }

  void _initQuickActions() {
    if (!_supportsQuickActions) {
      _startForegroundHealthCheck();
      return;
    }

    try {
      _quickActions.initialize((type) {
        _dispatchExternal(() => _handleQuickAction(type));
      });

      _quickActions.setShortcutItems(<ShortcutItem>[
        const ShortcutItem(
          type: 'start_25m',
          localizedTitle: 'Start 25m',
          icon: 'icon_start',
        ),
        const ShortcutItem(
          type: 'resume_last',
          localizedTitle: 'Resume Last',
          icon: 'icon_resume',
        ),
        const ShortcutItem(
          type: 'toggle_speech',
          localizedTitle: 'Toggle Speech',
          icon: 'icon_speech',
        ),
      ]);
    } on MissingPluginException {
      debugPrint('QuickActions plugin unavailable on this platform/runtime.');
    } on PlatformException catch (e) {
      debugPrint('QuickActions failed: $e');
    }

    _startForegroundHealthCheck();
  }

  void _openSettings() async {
    if (Platform.isAndroid && _installedEngines.isEmpty) {
      _installedEngines = await _speechService.getInstalledEngines(flutterTts);
    }
    final settingsVoices = voices;
    if (!mounted) return;
    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (context, animation, secondaryAnimation) => SettingsPanel(
          onAppFontSizeMultiplierChanged: (val) {
            if (val != null) {
              setState(() {
                appFontSizeMultiplier = val;
                _lsSave();
              });
            }
          },
          onFullscreenClockScaleChanged: (val) {
            if (val == null) return;
            setState(() {
              fullscreenClockScale = val;
              _lsSave();
            });
          },
          onFullscreenShowClockChanged: (val) {
            setState(() {
              fullscreenShowClock = val ?? false;
              _lsSave();
            });
          },
          sleepStartLabel: _formatMinutesAs12Hour(
            ref.read(settingsProvider).sleepStartMinutes,
          ),
          sleepEndLabel: _formatMinutesAs12Hour(
            ref.read(settingsProvider).sleepEndMinutes,
          ),
          soundList: soundList,
          volumeLists: volumeLists,
          isSpeechActive: isSpeechActive,
          speechQueueLength: speechQueue.length,
          speechEngineRuntime: _speechService.lastEngineUsed,
          speechEngineRuntimeDetail: _speechService.lastEngineDetail,
          showEnglishVoiceDownload: Platform.isLinux,
          speechModelDownloadStatus: _speechService.kokoroDownloadStatus,
          onDownloadEnglishVoice: _downloadKokoroVoiceFromSettings,
          onCancelEnglishVoiceDownload: () =>
              unawaited(_speechService.cancelKokoroVoiceDownload()),
          onTestSpeech: _testSpeech,
          voices: settingsVoices,
          availableEngines: _installedEngines,
          onSoundChanged: (val) {
            setState(() {
              soundChosen = val!;
              _lsSave();
              _applyAudioSettings();
            });
          },
          onNoiseVolumeChanged: (val) {
            setState(() {
              noiseVolume = val!;
              _lsSave();
              _applyAudioSettings();
            });
          },
          onSpeakVolumeChanged: (val) {
            setState(() {
              speakVolume = val!;
              _lsSave();
            });
          },
          onMaximumSpeechVolumeChanged: (val) {
            setState(() {
              maximumSpeechVolume = val ?? false;
              _lsSave();
            });
          },
          onSpeechMasterOnChanged: (val) {
            unawaited(_setSpeechMaster(val ?? true));
          },
          onFullscreenDarkThemeChanged: (val) {
            setState(() {
              fullscreenDarkTheme = val ?? true;
              _lsSave();
            });
          },
          onFullscreenDimBrightnessChanged: (val) {
            setState(() {
              fullscreenDimBrightness = val ?? false;
              _lsSave();
            });
          },
          onFullscreenDimBrightnessLevelChanged: (val) {
            setState(() {
              fullscreenDimBrightnessLevel = val ?? 0.08;
              _lsSave();
            });
          },
          onFullscreenStartLandscapeChanged: (val) {
            setState(() {
              fullscreenStartLandscape = val ?? false;
              _lsSave();
            });
          },
          onMuteSpeechAfterMidnightChanged: (val) {
            setState(() {
              muteSpeechAfterMidnight = val ?? false;
              if (!muteSpeechAfterMidnight) {
                autoNightMuteActive = false;
                _cancelNightIdleTimer();
                nightResumeSpeechTimer?.cancel();
              } else if (nightMuteMode == 'automatic') {
                _startNightIdleTimerIfNeeded();
              }
              if (_isAudioMuted()) speechQueue.clear();
              _lsSave();
            });
          },
          onNightMuteModeChanged: (val) {
            if (val == null) return;
            setState(() {
              nightMuteMode = val;
              if (nightMuteMode == 'manual') {
                autoNightMuteActive = false;
                _cancelNightIdleTimer();
                nightResumeSpeechTimer?.cancel();
              } else if (muteSpeechAfterMidnight) {
                autoNightMuteActive = false;
                _startNightIdleTimerIfNeeded();
              }
              if (_isAudioMuted()) speechQueue.clear();
              _lsSave();
            });
          },
          onPickSleepStart: () => unawaited(_pickSleepStartTime()),
          onPickSleepEnd: () => unawaited(_pickSleepEndTime()),
          onVoiceListModeChanged: (val) {
            debugPrint('[SettingsPanel] onVoiceListModeChanged val=$val');
            if (val == null) return;
            _voiceSessionManager.resetSession();
            speechQueue.clear();
            unawaited(_stopTts());
            setState(() {
              final normalized = _speechService.normalizeVoiceLanguageMode(val);
              debugPrint('[SettingsPanel] normalized language=$normalized');
              voiceListMode = normalized;
              _speechLanguageService.setLanguage(normalized);
              final available = _availableVoicesForSettings();
              final hasFavorite = available.any(
                (voice) =>
                    voice['name']?.toString() == favoriteVoiceName &&
                    voice['locale']?.toString() == favoriteVoiceLocale,
              );
              if (!hasFavorite) {
                favoriteVoiceName = null;
                favoriteVoiceLocale = null;
              }
              _lsSave();
            });
            if (speechMasterOn) _applyAudioSettings();
          },
          onSpeechEngineModeChanged: (val) async {
            if (val == null) return;
            setState(() {
              speechEngineMode = val;
              _lsSave();
            });
            if (Platform.isAndroid &&
                val != 'auto' &&
                val != 'sherpa_only' &&
                val != 'system_only') {
              await _speechService.setSpeechEngine(
                flutterTts: flutterTts,
                engine: val,
              );
            }
            await _initTts(forceRebind: true);
          },
          onFavoriteVoiceChanged: (val) {
            debugPrint('[SettingsPanel] onFavoriteVoiceChanged val=$val');
            setState(() {
              if (val == null || val == '__auto__') {
                favoriteVoiceName = null;
                favoriteVoiceLocale = null;
              } else {
                final parts = val.split('|');
                if (parts.length == 2) {
                  favoriteVoiceName = parts[0];
                  favoriteVoiceLocale = parts[1];
                }
              }
              _lsSave();
            });
          },
          onOpenHelp: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => _buildHelpTab()));
          },
          onBackupSettings: () => unawaited(_handleBackupSettings()),
          onRestoreSettings: () => unawaited(_handleRestoreSettings()),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SlideTransition(
            position:
                Tween<Offset>(
                  begin: const Offset(1.0, 0.0),
                  end: Offset.zero,
                ).animate(
                  CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                  ),
                ),
            child: child,
          );
        },
      ),
    );
  }

  Future<void> _handleBackupSettings() async {
    if (!mounted) return;
    try {
      final filePath = await _settingsService.exportToUserFolder(
        defaultSound: soundList.first.link,
      );
      if (!mounted) return;
      if (filePath == null) return; // User cancelled directory picker

      final jsonStr = await _settingsService.exportToJson(
        defaultSound: soundList.first.link,
      );
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Backup Saved'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Settings exported successfully.'),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  filePath,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: jsonStr));
                Navigator.of(ctx).pop();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('JSON copied to clipboard')),
                  );
                }
              },
              child: const Text('Copy JSON'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
  }

  Future<void> _handleRestoreSettings() async {
    if (!mounted) return;
    try {
      final imported = await _settingsService.importFromFile();
      if (imported == null) return; // User cancelled or error
      if (!mounted) return;

      // Show a preview dialog before applying
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Restore Settings'),
          content: const Text(
            'This will replace all current settings with the imported backup. '
            'The app will reload to apply the changes. Continue?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Restore'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      _applyRestoredSettings(imported);
      setState(() {});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings restored successfully!')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
  }

  void _applyRestoredSettings(AppSettings settings) {
    final normalized = settings.normalized();
    ref.read(settingsProvider.notifier).replace(normalized);
    _speechLanguageService.setLanguage(normalized.voiceListMode);
    _voiceSessionManager.resetSession();
    _applyAudioSettings();
    _restartGoalReminderTimer();
    _lsSave();
    unawaited(_reconcileForeground(force: true));
  }

  Future<void> _openFullscreenFocus({
    FullscreenFocusMode? specificMode,
    bool forceHorizontal = false,
    bool startImmersive = false,
  }) async {
    final initialMode =
        specificMode ??
        (currentTabIndex == 2
            ? FullscreenFocusMode.moduleC
            : (timerInterval != null || currentTabIndex == 1
                  ? FullscreenFocusMode.timer
                  : FullscreenFocusMode.clock));
    if (_fullscreenFocusOpen) return;
    _fullscreenFocusOpen = true;
    await Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => FullscreenFocusView(
              initialMode: initialMode,
              initialDarkTheme: fullscreenDarkTheme,
              initialDimBrightness: fullscreenDimBrightness,
              initialDimBrightnessLevel: fullscreenDimBrightnessLevel,
              initialForceLandscape: forceHorizontal
                  ? true
                  : fullscreenStartLandscape,
              initialShowClock: fullscreenShowClock,
              initialClockScale: fullscreenClockScale,
              onShowClockChanged: (show) {
                if (!mounted) return;
                setState(() {
                  fullscreenShowClock = show;
                  _lsSave();
                });
              },
              onClockScaleChanged: (scale) {
                if (!mounted) return;
                setState(() {
                  fullscreenClockScale = scale;
                  _lsSave();
                });
              },
              startImmersive: startImmersive,
              onThemeChanged: (isDark) {
                if (!mounted) return;
                setState(() {
                  fullscreenDarkTheme = isDark;
                  _lsSave();
                });
              },
              onDimBrightnessChanged: (isDimmed) {
                if (!mounted) return;
                setState(() {
                  fullscreenDimBrightness = isDimmed;
                  _lsSave();
                });
              },
              onForceLandscapeChanged: (isLandscape) {
                if (!mounted) return;
                setState(() {
                  fullscreenStartLandscape = isLandscape;
                  _lsSave();
                });
              },
              clockTextBuilder: () => currentTimeDisplay,
              timerTextBuilder: () => timerDisplayValue,
              isTimerRunningBuilder: () => timerInterval != null,
              stopwatchTextBuilder: () => stopwatchElapsedValue,
              isStopwatchRunningBuilder: () => stopwatchInterval != null,
              onTimerStart: startTimer,
              onTimerStop: stopTimer,
              onTimerReset: resetTimer,
              onStopwatchStart: startStopwatch,
              onStopwatchStop: stopStopwatch,
              onStopwatchReset: resetStopwatch,
            ),
          ),
        )
        .whenComplete(() {
          _fullscreenFocusOpen = false;
        });
    await SystemChrome.setPreferredOrientations([]);
  }

  Future<void> _exitAppFully() async {
    try {
      stopClock();
      timerInterval?.cancel();
      timerInterval = null;
      stopwatchInterval?.cancel();
      stopwatchInterval = null;
      _cancelPendingSpeech();
      await _timerRuntimeStore.save(TimerRuntime.idle());
      await _timerRuntimeStore.saveStopwatch(StopwatchRuntime.idle());
      await _stopTts();
      await _audioService.stopBackground();
      await _audioService.stopNotification();
      await _stopForegroundService();
    } catch (error, stackTrace) {
      debugPrint('Exit cleanup failed: $error\n$stackTrace');
    }

    if (!mounted) return;
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemNavigator.pop();
      return;
    }
    exit(0);
  }

  void _onReceiveTaskData(Object data) {
    _dispatchExternal(() => _handleTaskData(data));
  }

  void _dispatchExternal(Future<void> Function() action) {
    if (!_bootstrapReady) {
      _pendingExternalActions.add(action);
      return;
    }
    unawaited(action());
  }

  Future<void> _handleTaskData(Object data) async {
    if (!mounted) return;
    if (data is Map) {
      final type = data['type']?.toString();
      if (type == 'speechMaster' && data['value'] is bool) {
        await _setSpeechMaster(data['value'] as bool);
        return;
      }
      if (type == 'exit') {
        await _exitAppFully();
        return;
      }
      if (type == 'runtime' && data['snapshot'] is Map) {
        final snapshot = Map<String, dynamic>.from(data['snapshot'] as Map);
        await _applyTimerRuntime(TimerRuntime.fromJson(snapshot));
        if (data['stopwatch'] is Map) {
          await _applyStopwatchRuntime(
            StopwatchRuntime.fromJson(
              Map<String, dynamic>.from(data['stopwatch'] as Map),
            ),
          );
        }
        return;
      }
    }

    if (data is! String) return;
    switch (data) {
      case 'btn_speech_master':
        await _setSpeechMaster(!speechMasterOn);
        return;
      case 'btn_timer_toggle':
        timerInterval == null ? startTimer() : stopTimer();
        return;
      case 'btn_clock_speech':
        toggleClock();
        return;
      case 'btn_stopwatch_toggle':
        stopwatchInterval == null ? startStopwatch() : stopStopwatch();
        return;
      case 'btn_timer_repeat':
        if (_lastFinishedTimerDurationSeconds > 0) {
          _startTimerFromMinutes(
            (_lastFinishedTimerDurationSeconds ~/ 60).clamp(1, 720),
          );
        }
        return;
      case 'btn_timer_dismiss':
        await _dismissFinishedTimer();
        return;
      case 'btn_exit':
        await _exitAppFully();
        return;
      default:
        return;
    }
  }

  Future<void> _setSpeechMaster(bool enabled) async {
    if (!mounted) return;
    if (speechMasterOn == enabled) {
      await _settingsService.save(_settings);
      return;
    }
    setState(() => speechMasterOn = enabled);
    if (!enabled) {
      _cancelPendingSpeech();
      await _stopTts();
      await _audioService.stopBackground();
      FlutterRingtonePlayer().stop();
    } else {
      _applyAudioSettings();
    }
    await _settingsService.save(_currentSettingsSnapshot());
    await _writeWidgetState();
    await _reconcileForeground(force: true);
  }

  Future<void> _dismissFinishedTimer() async {
    if (!mounted) return;
    FlutterRingtonePlayer().stop();
    _timerRuntime = TimerRuntime.idle().copyWith(
      revision: _timerRuntime.revision + 1,
    );
    await _timerRuntimeStore.save(_timerRuntime);
    if (!mounted) return;
    setState(() => _isTimerFinished = false);
    await _reconcileForeground(force: true);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(SystemChrome.setPreferredOrientations([]));
    _initForegroundTask();
    _initWidgetChannel();
    _initQuickActions();
    FlutterForegroundTask.addTaskDataCallback(_onReceiveTaskData);
    unawaited(_bootstrap());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybePromptForKokoroDownload());
    });

    displayTick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;

      final display = _formatCurrentTime(DateTime.now());
      final timerDisplay = _formatTimerDisplayValue(seconds);
      final stopwatchDisplay = _formatStopwatchElapsed(
        stopwatchElapsedSeconds,
        showMilliseconds: stopwatchShowMilliseconds,
      );
      if (display != currentTimeDisplay) {
        setState(() {
          currentTimeDisplay = display;
          timerDisplayValue = timerDisplay;
          stopwatchElapsedValue = stopwatchDisplay;
        });
      } else if (timerDisplay != timerDisplayValue ||
          stopwatchDisplay != stopwatchElapsedValue) {
        setState(() {
          timerDisplayValue = timerDisplay;
          stopwatchElapsedValue = stopwatchDisplay;
        });
      }
    });
  }

  Future<void> _bootstrap() async {
    final settings = _settings;
    _speechLanguageService.setLanguage(settings.voiceListMode);
    currentTimeDisplay = _formatCurrentTime(DateTime.now());
    timerDisplayValue = _formatTimerDisplayValue(seconds);
    stopwatchElapsedValue = _formatStopwatchElapsed(
      stopwatchElapsedSeconds,
      showMilliseconds: stopwatchShowMilliseconds,
    );

    await _audioService.init();
    if (!mounted) return;
    unawaited(_initTts());
    _applyAudioSettings();
    _restartGoalReminderTimer();
    unawaited(_refreshTodaySummary());
    await _restoreTimerRuntime();
    await _restoreStopwatchRuntime();
    if (!mounted) return;
    if (clockOn) startClock();
    await _initializeForegroundNotification();
    if (!mounted) return;
    _bootstrapReady = true;
    final pending = List<Future<void> Function()>.from(_pendingExternalActions);
    _pendingExternalActions.clear();
    for (final action in pending) {
      await action();
      if (!mounted) return;
    }
    await _drainWidgetActions();
    await _writeWidgetState();
  }

  Future<void> _maybePromptForKokoroDownload() async {
    if (!Platform.isLinux ||
        _speechService.kokoroDownloadStatus.value.phase ==
            SpeechModelDownloadPhase.ready) {
      return;
    }

    final preferences = await SharedPreferences.getInstance();
    if ((preferences.getBool(PrefKeys.linuxKokoroConsentPromptSeen) ?? false) ||
        (preferences.getBool(PrefKeys.linuxKokoroConsentAccepted) ?? false)) {
      return;
    }
    if (!mounted) return;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => KokoroDownloadConsentDialog(
        onAccept: () => Navigator.of(dialogContext).pop(true),
        onDecline: () => Navigator.of(dialogContext).pop(false),
      ),
    );
    await preferences.setBool(PrefKeys.linuxKokoroConsentPromptSeen, true);
    await preferences.setBool(
      PrefKeys.linuxKokoroConsentAccepted,
      accepted == true,
    );
    if (accepted != true || !mounted) return;
    unawaited(_speechService.downloadKokoroVoice());
  }

  void _downloadKokoroVoiceFromSettings() {
    unawaited(_recordKokoroDownloadConsentAndStart());
  }

  Future<void> _recordKokoroDownloadConsentAndStart() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(PrefKeys.linuxKokoroConsentPromptSeen, true);
    await preferences.setBool(PrefKeys.linuxKokoroConsentAccepted, true);
    if (!mounted) return;
    await _speechService.downloadKokoroVoice();
  }

  AppSettings _currentSettingsSnapshot() => _settings;

  void _lsSave() {
    unawaited(_settingsService.save(_currentSettingsSnapshot()));
    unawaited(_writeWidgetState());
  }

  /// Log the current timer session to persistent storage (tagging only).
  void _logCurrentSession(int elapsedSeconds) {
    if (_sessionStartTime == null) return;
    final session = SessionLog(
      startTime: _sessionStartTime!,
      endTime: DateTime.now(),
      durationSeconds: elapsedSeconds,
      tag: sessionTag,
    );
    _sessionStartTime = null;
    unawaited(_sessionLogService.logSession(session));
    _refreshTodaySummary();
  }

  /// Refresh the today summary string shown in the timer panel.
  Future<void> _refreshTodaySummary() async {
    if (!taggingOn) {
      if (_todaySummary.isNotEmpty) setState(() => _todaySummary = '');
      return;
    }
    final summary = await _sessionLogService.getDailySummary(DateTime.now());
    if (!mounted) return;
    final parts = <String>[];
    if (summary.studySeconds > 0) {
      parts.add('Study ${summary.studyFormatted}');
    }
    if (summary.nonStudySeconds > 0) {
      parts.add('Non-study ${summary.nonStudyFormatted}');
    }
    setState(() => _todaySummary = parts.join(' · '));
  }


  /// Start a preset timer from widget (extracted for reuse with tag dialog).
  Future<void> _startPresetFromWidget(int mins) async {
    final safeMins = mins.clamp(1, 720);
    final totalSeconds = safeMins * 60;
    _armedPresetTimer?.cancel();
    _armedPresetValue = null;

    timerInterval?.cancel();
    timerInterval = null;

    setState(() {
      currentTabIndex = 1;
      chainModeOn = false;
      chainIndex = 0;
      sliderValue = safeMins;
      seconds = totalSeconds;
      _activeTimerDurationSeconds = totalSeconds;
      timerValue = _formatTimerDisplayValue(totalSeconds);
      timerDisplayValue = timerValue;
      _isTimerFinished = false;
      fullscreenShowClock = true;
    });

    _timerRuntime = TimerRuntime.running(
      durationSeconds: totalSeconds,
      remainingSeconds: totalSeconds,
      now: DateTime.now(),
      chainModeOn: false,
      chainPresetKey: chainPresetKey,
      chainIndex: 0,
      revision: _timerRuntime.revision + 1,
    );

    setState(() {
      timerInterval = Timer.periodic(const Duration(milliseconds: 250), tick);
    });

    if (taggingOn) _sessionStartTime = DateTime.now();

    await _timerRuntimeStore.save(_timerRuntime);
    await _saveLastTimerSeconds(totalSeconds);
    _applyAudioSettings();
    await _reconcileForeground(force: true);

    if (!_fullscreenFocusOpen) {
      unawaited(_openFullscreenFocus(
        specificMode: FullscreenFocusMode.timer,
        forceHorizontal: true,
        startImmersive: true,
      ));
    }
  }

  Future<void> _writeWidgetState() async {
    if (!Platform.isAndroid) return;
    try {
      await _widgetChannel.invokeMethod<bool>('updateWidgetState', {
        'clockOn': clockOn,
        'timerSpeakOn': timerSpeakOn,
        'stopwatchSpeakOn': stopwatchSpeakOn,
        'goalReminderOn': goalReminderOn,
        'speechMasterOn': speechMasterOn,
        'timerDisplay': timerDisplayValue,
        'armedAction': _widgetArmedAction ?? '',
      });
    } on PlatformException catch (error) {
      debugPrint('Widget state update failed: $error');
    } on MissingPluginException catch (error) {
      debugPrint('Widget channel unavailable: $error');
    }
  }

  Future<void> _writeWidgetArmedState(String action) async {
    _widgetArmedAction = action.isEmpty ? null : action;
    await _writeWidgetState();
  }

  void _initWidgetChannel() {
    _widgetChannel.setMethodCallHandler((call) async {
      if (call.method == 'widgetActionsAvailable') {
        _dispatchExternal(_drainWidgetActions);
      }
    });
  }

  Future<void> _drainWidgetActions() {
    _widgetDrainTail = _widgetDrainTail
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Previous widget drain failed: $error');
        })
        .then((_) => _drainWidgetActionsNow());
    return _widgetDrainTail;
  }

  Future<void> _drainWidgetActionsNow() async {
    if (!Platform.isAndroid || !mounted) return;
    try {
      final queued = await _widgetChannel.invokeListMethod<dynamic>(
        'drainWidgetActions',
      );
      for (final raw in queued ?? const <dynamic>[]) {
        if (raw is! Map) continue;
        final id = raw['id']?.toString();
        final action = raw['action']?.toString();
        if (id == null || action == null) continue;
        await _handleWidgetAction(action);
        await _widgetChannel.invokeMethod<bool>('ackWidgetAction', {'id': id});
        if (!mounted) return;
      }
    } on PlatformException catch (error) {
      debugPrint('Widget action drain failed: $error');
    } on MissingPluginException catch (error) {
      debugPrint('Widget channel unavailable: $error');
    }
  }

  /// Handles actions arriving from home screen widget button taps.
  ///
  /// Two-tap confirmation is applied to ["toggle_speech_master"] and
  /// ["open_fullscreen_clock"]. Other actions execute immediately.
  Future<void> _handleWidgetAction(String type) async {
    if (!mounted) return;

    // ── Two-tap confirmation path: speech master & fullscreen clock ─────
    if (type == 'toggle_speech_master' || type == 'open_fullscreen_clock') {
      if (_widgetArmedAction == type) {
        // Second tap: confirm and execute
        _widgetArmedTimer?.cancel();
        _widgetArmedAction = null;
        unawaited(_writeWidgetArmedState(''));

        if (type == 'toggle_speech_master') {
          await _setSpeechMaster(!speechMasterOn);
        } else {
          // open_fullscreen_clock
          setState(() => currentTabIndex = 0);
          _openFullscreenFocus(
            specificMode: FullscreenFocusMode.clock,
            forceHorizontal: true,
            startImmersive: true,
          );
        }
        return;
      }

      // First tap: arm the action, show visual on widget
      _widgetArmedTimer?.cancel();
      _widgetArmedAction = type;
      unawaited(_writeWidgetArmedState(type));
      _widgetArmedTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        _widgetArmedAction = null;
        unawaited(_writeWidgetArmedState(''));
      });
      return;
    }

    // ── Immediate actions (no confirmation needed) ──────────────────────
    const presetMap = {
      'start_1m': 1,
      'start_2m': 2,
      'start_3m': 3,
      'start_5m': 5,
      'start_7m': 7,
      'start_10m': 10,
      'start_12m': 12,
      'start_15m': 15,
      'start_20m': 20,
      'start_25m': 25,
      'start_30m': 30,
      'start_35m': 35,
      'start_45m': 45,
      'start_60m': 60,
      'start_90m': 90,
    };

    if (presetMap.containsKey(type)) {
      final mins = presetMap[type]!;
      if (taggingOn && sessionTag.isEmpty) {
        sessionTag = 'Study';
        _lsSave();
      }
      await _startPresetFromWidget(mins);
      return;
    }

    switch (type) {
      case 'resume_last':
        await _handleQuickAction('resume_last');
        break;
      case 'start_timer_fullscreen':
        setState(() {
          currentTabIndex = 1;
        });
        startTimer();
        _openFullscreenFocus(
          specificMode: FullscreenFocusMode.timer,
          forceHorizontal: true,
          startImmersive: true,
        );
        break;
      case 'start_stopwatch_fullscreen':
        setState(() {
          currentTabIndex = 2;
        });
        startStopwatch();
        _openFullscreenFocus(
          specificMode: FullscreenFocusMode.moduleC,
          forceHorizontal: true,
          startImmersive: true,
        );
        break;
      case 'toggle_clock_speech':
        setState(() {
          clockOn = !clockOn;
          _lsSave();
          if (clockOn) {
            startClock();
          } else {
            stopClock();
          }
        });
        _applyAudioSettings();
        unawaited(_syncForegroundNotification(force: true));
        break;
      case 'toggle_timer_speech':
        setState(() {
          timerSpeakOn = !timerSpeakOn;
          _lsSave();
        });
        break;
      case 'toggle_stopwatch_speech':
        setState(() {
          stopwatchSpeakOn = !stopwatchSpeakOn;
          _lsSave();
        });
        break;
      case 'toggle_goals_speech':
        setState(() {
          goalReminderOn = !goalReminderOn;
          _lsSave();
          _restartGoalReminderTimer();
        });
        break;
    }
  }

  void _applyAudioSettings() {
    // Master Audio OFF — prevent all ambient audio
    if (_isAudioMuted()) {
      unawaited(_audioService.stopBackground());
      if (mounted) setState(() => audioPlaying = false);
      return;
    }
    final bool shouldTimerPlay = timerInterval != null && timerNoiseOn;
    final bool shouldClockPlay = clockOn && clockNoiseOn;
    final bool shouldPlay = shouldTimerPlay || shouldClockPlay;

    if (audioPlaying != shouldPlay) {
      if (mounted) {
        setState(() {
          audioPlaying = shouldPlay;
        });
      } else {
        audioPlaying = shouldPlay;
      }
    }

    if (shouldPlay) {
      unawaited(
        _audioService.applyBackground(
          shouldPlay: true,
          assetPath: soundChosen,
          volume: noiseVolume,
        ),
      );
    } else {
      unawaited(_audioService.stopBackground());
    }
  }

  void _restartGoalReminderTimer() {
    goalReminderTimer?.cancel();
    goalReminderTimer = null;
    _nextGoalReminderAt = null;
    if (!goalReminderOn || goalReminderItems.isEmpty) return;
    _nextGoalReminderAt = DateTime.now().add(
      Duration(minutes: goalReminderIntervalMins),
    );
    _scheduleNextGoalReminder();
  }

  void _scheduleNextGoalReminder() {
    final due = _nextGoalReminderAt;
    if (due == null || !goalReminderOn || goalReminderItems.isEmpty) return;
    final now = DateTime.now();
    final delay = due.isAfter(now) ? due.difference(now) : Duration.zero;
    goalReminderTimer = Timer(delay, () {
      if (!mounted || !goalReminderOn || goalReminderItems.isEmpty) return;
      _announceNextGoalReminder();
      final interval = Duration(minutes: goalReminderIntervalMins);
      var next = due.add(interval);
      final current = DateTime.now();
      while (!next.isAfter(current)) {
        next = next.add(interval);
      }
      _nextGoalReminderAt = next;
      _scheduleNextGoalReminder();
    });
  }

  void _speakGoalReminderMessage(String text) {
    if (_isAudioMuted()) {
      speechQueue.clear();
      return;
    }
    _speakAfterGap(
      text: text,
      getLatestOtherSpoke: () =>
          max(max(lastClockSpoke, lastTimerSpoke), lastStopwatchSpoke),
      markSpoke: () =>
          lastGoalReminderSpoke = DateTime.now().millisecondsSinceEpoch,
      isStillValid: () => goalReminderOn && goalReminderItems.isNotEmpty,
      onFire: () => speak(text),
    );
  }

  void _announceNextGoalReminder({bool force = false}) {
    if ((!goalReminderOn && !force) || goalReminderItems.isEmpty) return;

    final index = goalReminderNextIndex % goalReminderItems.length;
    final goal = goalReminderItems[index];

    setState(() {
      goalReminderNextIndex = (index + 1) % goalReminderItems.length;
      _lsSave();
    });

    _speakGoalReminderMessage('Goal reminder: $goal');
  }

  void _testSpeech() {
    final preferredVoice = getPreferredVoice();
    if (_isMalayalamActive(preferredVoice)) {
      speak('ഇത് ശബ്ദ പരിശോധനയാണ്. നിങ്ങളുടെ ടൈമർ ആരംഭിക്കാൻ തയ്യാറാണ്.');
    } else {
      speak('This is a voice test. Your focus timer is ready.');
    }
  }

  Future<void> _stopTts() async {
    if (Platform.isLinux || Platform.isWindows) {
      await _speechService.stopDesktopSpeech();
    }
    if (Platform.isLinux) return;
    await flutterTts.stop();
  }

  Future<bool> _initTts({bool forceRebind = false}) async {
    if (Platform.isLinux) {
      _ttsReady = true;
      return true;
    }

    final existing = _ttsInitInFlight;
    if (existing != null) {
      await existing;
      if (!forceRebind) return _ttsReady;
    }
    if (!forceRebind &&
        !_ttsReady &&
        DateTime.now().isBefore(_nextTtsInitAllowedAt)) {
      return false;
    }

    if (forceRebind) {
      final previous = flutterTts;
      await previous.stop();
      flutterTts = FlutterTts();
      _voiceSessionManager.resetSession();
      _ttsReady = false;
      _nextTtsInitAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);
    }

    final tts = flutterTts;
    final completer = Completer<void>();
    _ttsInitInFlight = completer.future;
    try {
      tts.setErrorHandler((message) {
        if (identical(tts, flutterTts)) _ttsReady = false;
        debugPrint('TTS error: $message');
      });
      try {
        await tts.awaitSpeakCompletion(true);
        final engine = _speechService.normalizeSpeechEngineMode(
          speechEngineMode,
        );
        if (Platform.isAndroid &&
            engine != 'auto' &&
            engine != 'system_only' &&
            engine != 'sherpa_only') {
          await _speechService.setSpeechEngine(flutterTts: tts, engine: engine);
        }
      } on MissingPluginException {
        _nextTtsInitAllowedAt = DateTime.now().add(const Duration(seconds: 20));
        return false;
      } on PlatformException catch (error) {
        _nextTtsInitAllowedAt = DateTime.now().add(const Duration(seconds: 20));
        debugPrint('TTS init failed: $error');
        return false;
      }

      _ttsReady = true;
      for (var attempt = 1; attempt <= 4; attempt++) {
        try {
          final loadedVoices = _speechService.parseSupportedVoices(
            await tts.getVoices,
          );
          if (loadedVoices.isNotEmpty) {
            if (mounted && identical(tts, flutterTts)) {
              setState(() {
                voices = loadedVoices;
                _speechLanguageService.allVoices = loadedVoices;
              });
            }
            break;
          }
        } catch (error) {
          debugPrint('TTS getVoices attempt $attempt failed: $error');
        }
        await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
      }
    } finally {
      completer.complete();
      if (identical(_ttsInitInFlight, completer.future)) {
        _ttsInitInFlight = null;
      }
    }
    return _ttsReady;
  }

  Future<bool> _ensureTtsReady({bool forceRebind = false}) async {
    if (_ttsReady && !forceRebind) return true;
    return _initTts(forceRebind: forceRebind);
  }

  List<Map<dynamic, dynamic>> _availableVoicesForSettings() {
    _speechLanguageService.allVoices = voices;
    return _speechLanguageService.voicesForLanguage();
  }

  Map<dynamic, dynamic>? getPreferredVoice() {
    return _voiceSessionManager.getPreferredVoice(
      voiceResolver: () => _speechService.preferredVoice(
        voices: voices,
        voiceListMode: _speechLanguageService.language,
        favoriteVoiceName: favoriteVoiceName,
        favoriteVoiceLocale: favoriteVoiceLocale,
      ),
      voiceListMode: _speechLanguageService.language,
      favoriteVoiceName: favoriteVoiceName,
      favoriteVoiceLocale: favoriteVoiceLocale,
    );
  }

  bool _isMalayalamActive(Map<dynamic, dynamic>? preferredVoice) {
    return _voiceSessionManager.isMalayalamActive(
      isMalayalamResolver: (voice) => _malayalamTtsService.isMalayalamMode(
        voiceListMode: _speechLanguageService.language,
        preferredVoice: voice,
      ),
      preferredVoice: preferredVoice,
    );
  }

  Future<void> drainQueue() async {
    if (!mounted || _isAudioMuted()) {
      speechQueue.clear();
      if (isSpeechActive && mounted) {
        setState(() => isSpeechActive = false);
      }
      return;
    }
    if (isSpeechActive || speechQueue.isEmpty) return;

    final generation = _speechGeneration;
    setState(() => isSpeechActive = true);
    final item = speechQueue.removeFirst();
    if (item.delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: item.delayMs));
    }
    if (!mounted || generation != _speechGeneration || _isAudioMuted()) {
      if (mounted) setState(() => isSpeechActive = false);
      return;
    }

    final normalizedEngineMode = _speechService.normalizeSpeechEngineMode(
      speechEngineMode,
    );
    final desktopPlatform = Platform.isLinux || Platform.isWindows;
    final desktopSherpaOnly =
        desktopPlatform && normalizedEngineMode == 'sherpa_only';
    if (!desktopSherpaOnly && !desktopPlatform) {
      final ready = await _ensureTtsReady();
      if (!ready || !mounted || generation != _speechGeneration) {
        if (mounted) setState(() => isSpeechActive = false);
        speechQueue.clear();
        return;
      }
    }

    final preferredVoice = getPreferredVoice();
    try {
      await _speechService.speakItem(
        flutterTts: flutterTts,
        item: item,
        speakVolume: speakVolume,
        maximumSpeechVolume: maximumSpeechVolume,
        preferredVoice: preferredVoice,
        useMalayalamNuance: _isMalayalamActive(preferredVoice),
        speechEngineMode: speechEngineMode,
      );
    } catch (error) {
      debugPrint('TTS speak failed, retrying after rebind: $error');
      if (generation == _speechGeneration) {
        try {
          final rebound = await _ensureTtsReady(forceRebind: true);
          if (rebound && generation == _speechGeneration) {
            final retryVoice = getPreferredVoice();
            await _speechService.speakItem(
              flutterTts: flutterTts,
              item: item,
              speakVolume: speakVolume,
              maximumSpeechVolume: maximumSpeechVolume,
              preferredVoice: retryVoice,
              useMalayalamNuance: _isMalayalamActive(retryVoice),
              speechEngineMode: speechEngineMode,
            );
          }
        } catch (retryError) {
          debugPrint('TTS retry failed: $retryError');
        }
      }
    }
    if (!mounted) return;
    setState(() => isSpeechActive = false);
    if (generation == _speechGeneration) unawaited(drainQueue());
  }

  void _cancelPendingSpeech() {
    _speechGeneration++;
    speechQueue.clear();
    if (isSpeechActive && mounted) {
      setState(() => isSpeechActive = false);
    }
    unawaited(_stopTts());
  }

  void speak(String text) {
    if (_isAudioMuted()) {
      speechQueue.clear();
      return;
    }
    final pv = getPreferredVoice();
    final useMalayalam = _isMalayalamActive(pv);
    final language = useMalayalam ? 'ml' : 'en';
    speechQueue.add(SpeechItem(text, language: language));
    drainQueue();
  }

  bool _isNightTime() {
    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;

    if (sleepStartMinutes == sleepEndMinutes) {
      return false;
    }

    if (sleepStartMinutes < sleepEndMinutes) {
      return nowMinutes >= sleepStartMinutes && nowMinutes < sleepEndMinutes;
    }

    return nowMinutes >= sleepStartMinutes || nowMinutes < sleepEndMinutes;
  }

  void _cancelNightIdleTimer() {
    nightIdleTimer?.cancel();
    nightIdleTimer = null;
  }

  void _startNightIdleTimerIfNeeded() {
    _cancelNightIdleTimer();
    if (!muteSpeechAfterMidnight ||
        nightMuteMode != 'automatic' ||
        !_isNightTime()) {
      return;
    }

    nightIdleTimer = Timer(const Duration(minutes: 5), () {
      autoNightMuteActive = true;
      _cancelPendingSpeech();
      unawaited(_audioService.stopBackground());
      unawaited(_audioService.stopNotification());
      FlutterRingtonePlayer().stop();
    });
  }

  void _scheduleNightResumeAnnouncement() {
    nightResumeSpeechTimer?.cancel();
    if (!muteSpeechAfterMidnight ||
        nightMuteMode != 'automatic' ||
        !_isNightTime()) {
      return;
    }

    nightResumeSpeechTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      if (!muteSpeechAfterMidnight ||
          nightMuteMode != 'automatic' ||
          !_isNightTime()) {
        return;
      }
      final announcement = timeToWords();
      speakTimerMessage(announcement);
    });
  }

  void _handleNightUsageStateChange(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      autoNightMuteActive = false;
      _cancelNightIdleTimer();
      _scheduleNightResumeAnnouncement();
      return;
    }

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      _startNightIdleTimerIfNeeded();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _handleNightUsageStateChange(state);
    if (state == AppLifecycleState.resumed) {
      _dispatchExternal(() async {
        if (timerInterval == null ||
            _timerRuntime.status != TimerRuntimeStatus.running) {
          await _restoreTimerRuntime();
        }
        await _drainWidgetActions();
        await _reconcileForeground(force: true);
      });
    }
  }

  bool _isAudioMuted() {
    // Master Audio — when OFF, suppress ALL audio (speech, sounds, ringtones)
    if (!speechMasterOn) return true;

    if (!muteSpeechAfterMidnight) return false;
    if (!_isNightTime()) {
      autoNightMuteActive = false;
      return false;
    }
    if (nightMuteMode == 'manual') {
      return true;
    }
    return autoNightMuteActive;
  }

  void _speakAfterGap({
    required String text,
    required int Function() getLatestOtherSpoke,
    required void Function() markSpoke,
    required VoidCallback onFire,
    bool Function()? isStillValid,
  }) {
    final generation = _speechGeneration;
    _announcementTail = _announcementTail
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('Announcement predecessor failed: $error');
        })
        .then((_) async {
          final elapsed = _announcementClock.elapsedMilliseconds;
          final waitMs = max(0, 10000 - (elapsed - _lastAnnouncementElapsedMs));
          if (waitMs > 0) {
            await Future<void>.delayed(Duration(milliseconds: waitMs));
          }
          if (!mounted ||
              generation != _speechGeneration ||
              _isAudioMuted() ||
              (isStillValid != null && !isStillValid())) {
            return;
          }
          _lastAnnouncementElapsedMs = _announcementClock.elapsedMilliseconds;
          markSpoke();
          onFire();
        });
  }

  String timeToWords() {
    final preferredVoice = getPreferredVoice();
    if (_isMalayalamActive(preferredVoice)) {
      return _malayalamTtsService.clockAnnouncement(DateTime.now());
    }
    return _timerService.timeToWords(DateTime.now());
  }

  void startClock() {
    stopClock();
    if (!clockOn) return;
    if (clockSpeakTime) speakClock(timeToWords());
    _nextClockAt = DateTime.now().add(Duration(minutes: clockIntervalMins));
    _scheduleNextClockAnnouncement();
    unawaited(_reconcileForeground(force: true));
  }

  void _scheduleNextClockAnnouncement() {
    final due = _nextClockAt;
    if (due == null || !clockOn) return;
    final now = DateTime.now();
    final delay = due.isAfter(now) ? due.difference(now) : Duration.zero;
    clockTimer = Timer(delay, () {
      if (!mounted || !clockOn) return;
      if (clockSpeakTime) speakClock(timeToWords());
      final interval = Duration(minutes: clockIntervalMins);
      var next = due.add(interval);
      final current = DateTime.now();
      while (!next.isAfter(current)) {
        next = next.add(interval);
      }
      _nextClockAt = next;
      _scheduleNextClockAnnouncement();
    });
  }

  void stopClock() {
    clockTimer?.cancel();
    clockTimer = null;
    _nextClockAt = null;
    unawaited(_reconcileForeground(force: true));
  }

  void toggleClock() {
    setState(() {
      clockOn = !clockOn;
      _lsSave();
      if (clockOn) {
        startClock();
      } else {
        stopClock();
      }
    });
    _applyAudioSettings();
  }

  void speakClock(String text) {
    if (_isAudioMuted()) {
      speechQueue.clear();
      return;
    }
    _speakAfterGap(
      text: text,
      getLatestOtherSpoke: () =>
          max(max(lastTimerSpoke, lastStopwatchSpoke), lastGoalReminderSpoke),
      markSpoke: () => lastClockSpoke = DateTime.now().millisecondsSinceEpoch,
      isStillValid: () => clockOn && clockSpeakTime,
      onFire: () {
        final repeatCount = clockSpeakRepeatCount.clamp(1, 3);
        for (var i = 0; i < repeatCount; i++) {
          speechQueue.add(SpeechItem(text, delayMs: i == 0 ? 0 : 350));
        }
        if (motivationOn) {
          final quoteText = _nextQuoteForCategory(motivationCategory);
          speechQueue.add(
            SpeechItem(
              quoteText,
              isQuote: true,
              delayMs: motivationDelaySeconds * 1000,
            ),
          );
        }
        drainQueue();
      },
    );
  }

  String _nextQuoteForCategory(String category) {
    final preferredVoice = getPreferredVoice();
    final useMalayalam = _isMalayalamActive(preferredVoice);

    if (useMalayalam) {
      final categoryQuotes = _malayalamTtsService.quotesForCategory(category);
      return _quoteRotationService.nextQuoteForList(
        key: category,
        quotes: categoryQuotes,
        fallbackQuote: _malayalamTtsService.defaultQuote(),
      );
    }

    return _quoteRotationService.nextQuoteFromMap(
      category: category,
      quotesByCategory: quotesByCategory,
      fallbackCategory: 'General',
      fallbackQuote: 'Stay steady and use this moment well.',
    );
  }

  void speakTimerMessage(String text) {
    if (_isAudioMuted()) {
      speechQueue.clear();
      return;
    }
    _speakAfterGap(
      text: text,
      getLatestOtherSpoke: () =>
          max(max(lastClockSpoke, lastStopwatchSpoke), lastGoalReminderSpoke),
      markSpoke: () => lastTimerSpoke = DateTime.now().millisecondsSinceEpoch,
      onFire: () => speak(text),
    );
  }

  String _formatTimerDisplayValue(int totalSeconds) {
    final mins = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  String _formatStopwatchElapsed(
    int totalSeconds, {
    bool showMilliseconds = false,
  }) {
    final elapsedMs = _stopwatchRuntime.elapsedMsAt(DateTime.now());
    final effectiveMs = elapsedMs > 0 ? elapsedMs : totalSeconds * 1000;
    final totalForView = effectiveMs ~/ 1000;
    final hours = totalForView ~/ 3600;
    final minutes = (totalForView % 3600) ~/ 60;
    final seconds = totalForView % 60;
    final base = hours > 0
        ? '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}'
        : '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    if (!showMilliseconds) return base;
    final centiseconds = ((effectiveMs % 1000) ~/ 10).toString().padLeft(
      2,
      '0',
    );
    return '$base.$centiseconds';
  }

  String _stopwatchElapsedSpeechText() {
    final hours = stopwatchElapsedSeconds ~/ 3600;
    final minutes = (stopwatchElapsedSeconds % 3600) ~/ 60;
    final secs = stopwatchElapsedSeconds % 60;

    final parts = <String>[];
    if (hours > 0) {
      parts.add('$hours hour${hours == 1 ? '' : 's'}');
    }
    if (minutes > 0) {
      parts.add('$minutes minute${minutes == 1 ? '' : 's'}');
    }
    if (secs > 0 || parts.isEmpty) {
      parts.add('$secs second${secs == 1 ? '' : 's'}');
    }

    return 'Elapsed ${parts.join(', ')}';
  }

  void _speakStopwatchMessage(String text) {
    if (_isAudioMuted()) {
      speechQueue.clear();
      return;
    }
    _speakAfterGap(
      text: text,
      getLatestOtherSpoke: () =>
          max(max(lastClockSpoke, lastTimerSpoke), lastGoalReminderSpoke),
      markSpoke: () =>
          lastStopwatchSpoke = DateTime.now().millisecondsSinceEpoch,
      isStillValid: () => stopwatchInterval != null && stopwatchSpeakOn,
      onFire: () => speak(text),
    );
  }

  void _tickStopwatch(Timer timer) {
    final nextSeconds = _stopwatchRuntime.elapsedMsAt(DateTime.now()) ~/ 1000;
    setState(() {
      stopwatchElapsedSeconds = nextSeconds;
      stopwatchElapsedValue = _formatStopwatchElapsed(
        nextSeconds,
        showMilliseconds: stopwatchShowMilliseconds,
      );
    });
    if (nextSeconds != _lastStopwatchNotificationSecond &&
        (nextSeconds % 30 == 0 || nextSeconds <= 3)) {
      _lastStopwatchNotificationSecond = nextSeconds;
      unawaited(_reconcileForeground(force: true));
    }
    if (stopwatchSpeakOn &&
        nextSeconds > 0 &&
        nextSeconds % stopwatchSpeakDelaySeconds == 0 &&
        nextSeconds != _lastStopwatchAutoAnnouncedSecond) {
      _lastStopwatchAutoAnnouncedSecond = nextSeconds;
      _speakStopwatchMessage(_stopwatchElapsedSpeechText());
    }
  }

  Future<void> _restoreStopwatchRuntime() async {
    await _applyStopwatchRuntime(await _timerRuntimeStore.loadStopwatch());
  }

  Future<void> _applyStopwatchRuntime(StopwatchRuntime runtime) async {
    if (!mounted || runtime.revision < _stopwatchRuntime.revision) return;
    stopwatchInterval?.cancel();
    _stopwatchRuntime = runtime;
    final elapsedSeconds = runtime.elapsedMsAt(DateTime.now()) ~/ 1000;
    setState(() {
      stopwatchElapsedSeconds = elapsedSeconds;
      stopwatchElapsedValue = _formatStopwatchElapsed(
        elapsedSeconds,
        showMilliseconds: stopwatchShowMilliseconds,
      );
      stopwatchInterval = runtime.isRunning
          ? Timer.periodic(
              Duration(milliseconds: stopwatchShowMilliseconds ? 50 : 250),
              _tickStopwatch,
            )
          : null;
    });
    await _reconcileForeground(force: true);
  }

  void startStopwatch() {
    if (stopwatchInterval != null) return;
    _stopwatchRuntime = _stopwatchRuntime.copyWith(
      isRunning: true,
      startedAtEpochMs: () => DateTime.now().millisecondsSinceEpoch,
      revision: _stopwatchRuntime.revision + 1,
    );
    setState(() {
      stopwatchInterval = Timer.periodic(
        Duration(milliseconds: stopwatchShowMilliseconds ? 50 : 250),
        _tickStopwatch,
      );
    });
    unawaited(_timerRuntimeStore.saveStopwatch(_stopwatchRuntime));
    unawaited(_reconcileForeground(force: true));
  }

  void stopStopwatch() {
    if (!_stopwatchRuntime.isRunning) return;
    final elapsed = _stopwatchRuntime.elapsedMsAt(DateTime.now());
    _stopwatchRuntime = _stopwatchRuntime.copyWith(
      isRunning: false,
      accumulatedMs: elapsed,
      startedAtEpochMs: () => null,
      revision: _stopwatchRuntime.revision + 1,
    );
    stopwatchInterval?.cancel();
    setState(() => stopwatchInterval = null);
    unawaited(_timerRuntimeStore.saveStopwatch(_stopwatchRuntime));
    unawaited(_reconcileForeground(force: true));
  }

  void resetStopwatch() {
    stopwatchInterval?.cancel();
    _stopwatchRuntime = StopwatchRuntime.idle().copyWith(
      revision: _stopwatchRuntime.revision + 1,
    );
    setState(() {
      stopwatchInterval = null;
      stopwatchElapsedSeconds = 0;
      _lastStopwatchAutoAnnouncedSecond = -1;
      stopwatchElapsedValue = _formatStopwatchElapsed(
        0,
        showMilliseconds: stopwatchShowMilliseconds,
      );
    });
    unawaited(_timerRuntimeStore.saveStopwatch(_stopwatchRuntime));
    unawaited(_reconcileForeground(force: true));
  }

  void speakStopwatchElapsedNow() {
    _speakStopwatchMessage(_stopwatchElapsedSpeechText());
  }

  Future<void> _restoreTimerRuntime() async {
    if (timerInterval != null &&
        _timerRuntime.status == TimerRuntimeStatus.running) {
      return;
    }
    final runtime = await _timerRuntimeStore.load();
    if (!mounted) return;
    await _applyTimerRuntime(runtime, restored: true);
  }

  Future<void> _applyTimerRuntime(
    TimerRuntime runtime, {
    bool restored = false,
  }) async {
    if (!mounted) return;
    final isLocallyRunning = timerInterval != null &&
        _timerRuntime.status == TimerRuntimeStatus.running;
    if (isLocallyRunning) {
      if (runtime.status == TimerRuntimeStatus.idle) {
        return;
      }
      if (runtime.runId.isNotEmpty && runtime.runId != _timerRuntime.runId) {
        return;
      }
      if (runtime.revision < _timerRuntime.revision) {
        return;
      }
    } else {
      if (runtime.runId == _timerRuntime.runId &&
          runtime.revision < _timerRuntime.revision) {
        return;
      }
    }
    var next = runtime;
    if (next.status == TimerRuntimeStatus.running &&
        next.remainingAt(DateTime.now()) == 0) {
      next = next.copyWith(
        status: TimerRuntimeStatus.finished,
        remainingSeconds: 0,
        endAtEpochMs: () => null,
        revision: next.revision + 1,
      );
      await _timerRuntimeStore.save(next);
    }
    if (!mounted) return;

    timerInterval?.cancel();
    timerInterval = null;
    final remaining = next.remainingAt(DateTime.now());
    setState(() {
      _timerRuntime = next;
      seconds = remaining;
      _activeTimerDurationSeconds = next.durationSeconds;
      chainModeOn = next.chainModeOn;
      chainPresetKey = next.chainPresetKey;
      chainIndex = next.chainIndex;
      _isTimerFinished = next.status == TimerRuntimeStatus.finished;
      timerValue = _formatTimerDisplayValue(remaining);
      timerDisplayValue = timerValue;
      if (next.status == TimerRuntimeStatus.running) {
        timerInterval = Timer.periodic(const Duration(milliseconds: 250), tick);
      }
    });
    _applyAudioSettings();
    await _reconcileForeground(force: true);
    if (restored && next.status == TimerRuntimeStatus.finished && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_showTimerFinishedDialog());
      });
    }
  }

  void tick(Timer timer) {
    if (_timerRuntime.status != TimerRuntimeStatus.running) return;
    final previous = seconds;
    final remaining = _timerRuntime.remainingAt(DateTime.now());
    if (remaining == previous) return;
    if (remaining <= 0) {
      unawaited(_completeTimerRun());
      return;
    }

    final crossed = _timerService.crossedAnnouncementMinutes(
      previousSeconds: previous,
      currentSeconds: remaining,
      announceEveryMinutes: timerAnnounceEvery,
    );
    setState(() {
      seconds = remaining;
      timerValue = _formatTimerDisplayValue(remaining);
      timerDisplayValue = timerValue;
      _timerRuntime = _timerRuntime.copyWith(remainingSeconds: remaining);
    });
    if (timerSpeakOn && crossed.isNotEmpty) {
      final minutes = crossed.last;
      final preferredVoice = getPreferredVoice();
      final useMalayalam = _isMalayalamActive(preferredVoice);
      speakTimerMessage(
        useMalayalam
            ? _malayalamTtsService.timerRemaining(minutes)
            : '$minutes minute${minutes == 1 ? '' : 's'} remaining',
      );
    }
    if (remaining % 60 == 0 || remaining <= 10 || crossed.isNotEmpty) {
      unawaited(_reconcileForeground(force: true));
    }
  }

  Future<void> _completeTimerRun() async {
    if (_timerCompletionInFlight ||
        _timerRuntime.status != TimerRuntimeStatus.running) {
      return;
    }
    _timerCompletionInFlight = true;
    try {
      if (chainModeOn) {
        final sequence = chainPresets[chainPresetKey] ?? const [25];
        if (chainIndex < sequence.length - 1) {
          chainIndex++;
          final nextSeconds = sequence[chainIndex] * 60;
          _activeTimerDurationSeconds = nextSeconds;
          _timerRuntime = TimerRuntime.running(
            durationSeconds: nextSeconds,
            remainingSeconds: nextSeconds,
            now: DateTime.now(),
            chainModeOn: true,
            chainPresetKey: chainPresetKey,
            chainIndex: chainIndex,
            runId: _timerRuntime.runId,
            revision: _timerRuntime.revision + 1,
          );
          await _timerRuntimeStore.save(_timerRuntime);
          if (!mounted) return;
          setState(() {
            seconds = nextSeconds;
            timerValue = _formatTimerDisplayValue(nextSeconds);
            timerDisplayValue = timerValue;
          });
          if (timerSpeakOn) {
            final preferredVoice = getPreferredVoice();
            final useMalayalam = _isMalayalamActive(preferredVoice);
            speakTimerMessage(
              useMalayalam
                  ? _malayalamTtsService.nextTimerStarting(nextSeconds ~/ 60)
                  : 'Starting next timer: ${nextSeconds ~/ 60} minutes',
            );
          }
          await _reconcileForeground(force: true);
          return;
        }
        chainIndex = 0;
      }

      timerInterval?.cancel();
      _lastFinishedTimerDurationSeconds = _activeTimerDurationSeconds > 0
          ? _activeTimerDurationSeconds
          : sliderValue * 60;
      _timerRuntime = _timerRuntime.copyWith(
        status: TimerRuntimeStatus.finished,
        remainingSeconds: 0,
        endAtEpochMs: () => null,
        revision: _timerRuntime.revision + 1,
      );
      await _timerRuntimeStore.save(_timerRuntime);
      if (!mounted) return;
      setState(() {
        timerInterval = null;
        seconds = 0;
        timerValue = '00:00';
        timerDisplayValue = '00:00';
        _isTimerFinished = true;
      });
      _applyAudioSettings();
      await _reconcileForeground(force: true);

      if (taggingOn && _sessionStartTime != null) {
        _logCurrentSession(_lastFinishedTimerDurationSeconds);
      }
      if (timerSpeakOn) {
        final preferredVoice = getPreferredVoice();
        final useMalayalam = _isMalayalamActive(preferredVoice);
        speakTimerMessage(
          useMalayalam
              ? _malayalamTtsService.timerFinished()
              : 'Timer finished',
        );
      }
      final alarmGeneration = ++_alarmGeneration;
      if (Platform.isAndroid && !_isAudioMuted()) {
        FlutterRingtonePlayer().playAlarm(looping: true);
        Future<void>.delayed(const Duration(seconds: 30), () {
          if (_alarmGeneration == alarmGeneration) {
            FlutterRingtonePlayer().stop();
          }
        });
      } else if (!_isAudioMuted()) {
        unawaited(
          _audioService.playNotification(
            assetPath: notifySound,
            stopAfter: const Duration(seconds: 10),
          ),
        );
      }
      unawaited(_showTimerFinishedDialog());
    } finally {
      _timerCompletionInFlight = false;
    }
  }

  void _startTimerFromMinutes(int minutes) {
    final safeMinutes = minutes.clamp(1, 720).toInt();
    FlutterRingtonePlayer().stop();
    stopTimer();
    setState(() {
      _isTimerFinished = false;
      chainModeOn = false;
      chainIndex = 0;
      sliderValue = safeMinutes;
      seconds = safeMinutes * 60;
      timerValue = '${safeMinutes.toString().padLeft(2, '0')}:00';
      timerDisplayValue = _formatTimerDisplayValue(seconds);
      _activeTimerDurationSeconds = seconds;
    });
    startTimer();
  }

  Future<void> _showTimerFinishedDialog() async {
    if (!mounted || _timerFinishedDialogOpen) return;
    final rootNavigator = Navigator.of(context, rootNavigator: true);

    _timerFinishedDialogOpen = true;
    final selectedMinutes = _fullscreenFocusOpen
        ? await _showFullscreenTimerFinishedDialog()
        : await _showNormalTimerFinishedDialog();
    FlutterRingtonePlayer().stop();
    _timerFinishedDialogOpen = false;

    if (!mounted) return;
    if (selectedMinutes == null) {
      await _dismissFinishedTimer();
      if (_fullscreenFocusOpen) {
        await rootNavigator.maybePop();
      }
      return;
    }
    _startTimerFromMinutes(selectedMinutes);
  }

  Future<int?> _showNormalTimerFinishedDialog() async {
    final customController = TextEditingController();
    String? inputError;

    final selectedMinutes = await showDialog<int>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      builder: (dialogContext) {
        return ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 700),
          child: AlertDialog(
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 24,
              vertical: 24,
            ),
            title: const Text('Timer finished'),
            contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            content: StatefulBuilder(
              builder: (context, setDialogState) {
                return SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          final repeatMinutes =
                              (_lastFinishedTimerDurationSeconds ~/ 60)
                                  .clamp(1, 720)
                                  .toInt();
                          Navigator.of(dialogContext).pop(repeatMinutes);
                        },
                        icon: const Icon(Icons.replay_rounded),
                        label: const Text('Repeat Same Timer'),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Start New Preset Timer',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          const double minChipWidth = 72;
                          const double spacing = 8;
                          int columns =
                              ((constraints.maxWidth + spacing) /
                                      (minChipWidth + spacing))
                                  .floor();
                          if (columns < 2) columns = 2;
                          final rows =
                              (_timerFinishedPresetMinutes.length / columns)
                                  .ceil();
                          return Column(
                            children: List.generate(rows, (rowIndex) {
                              final start = rowIndex * columns;
                              final end = (start + columns).clamp(
                                0,
                                _timerFinishedPresetMinutes.length,
                              );
                              return Padding(
                                padding: EdgeInsets.only(
                                  bottom: rowIndex < rows - 1 ? spacing : 0,
                                ),
                                child: Row(
                                  children: [
                                    for (int i = start; i < end; i++)
                                      Expanded(
                                        child: Padding(
                                          padding: EdgeInsets.only(
                                            right: i < end - 1 ? spacing : 0,
                                          ),
                                          child: ActionChip(
                                            label: Center(
                                              child: Text(
                                                '${_timerFinishedPresetMinutes[i]} min',
                                              ),
                                            ),
                                            onPressed: () =>
                                                Navigator.of(dialogContext).pop(
                                                  _timerFinishedPresetMinutes[i],
                                                ),
                                          ),
                                        ),
                                      ),
                                    // Pad incomplete rows
                                    for (int i = end; i < start + columns; i++)
                                      const Expanded(child: SizedBox()),
                                  ],
                                ),
                              );
                            }),
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                      TextField(
                        controller: customController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Custom duration (minutes)',
                          errorText: inputError,
                        ),
                        onSubmitted: (_) {
                          final minutes = int.tryParse(
                            customController.text.trim(),
                          );
                          if (minutes == null || minutes < 1 || minutes > 720) {
                            setDialogState(() {
                              inputError = 'Enter a value between 1 and 720';
                            });
                            return;
                          }
                          Navigator.of(dialogContext).pop(minutes);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Exit / Close Timer'),
              ),
              FilledButton(
                onPressed: () {
                  final minutes = int.tryParse(customController.text.trim());
                  if (minutes == null || minutes < 1 || minutes > 720) {
                    return;
                  }
                  Navigator.of(dialogContext).pop(minutes);
                },
                child: const Text('Start custom'),
              ),
            ],
          ), // AlertDialog
        ); // ConstrainedBox
      },
    );

    customController.dispose();
    return selectedMinutes;
  }

  Future<int?> _showFullscreenTimerFinishedDialog() {
    return showDialog<int>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (dialogContext) {
        final cs = Theme.of(dialogContext).colorScheme;
        final fg = cs.onSurface;
        final bg = cs.surface;
        final surface = cs.surfaceContainerLow;
        final variant = cs.onSurfaceVariant;
        final outline = cs.outlineVariant;
        final primary = cs.primary;
        final selectedBg = cs.primaryContainer;

        Widget presetButton(int mins) {
          return Material(
            color: surface,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => Navigator.of(dialogContext).pop(mins),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: outline),
                ),
                child: Center(
                  child: Text(
                    '$mins min',
                    style: TextStyle(
                      color: fg,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return Dialog.fullscreen(
          backgroundColor: bg,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        style: IconButton.styleFrom(
                          backgroundColor: selectedBg,
                          foregroundColor: fg,
                        ),
                        icon: const Icon(Icons.close_rounded),
                      ),
                      const Spacer(),
                      Text(
                        'Timer finished',
                        style: TextStyle(
                          color: fg,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const Spacer(),
                      const SizedBox(width: 48),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 58,
                    child: FilledButton.icon(
                      onPressed: () {
                        final repeatMinutes =
                            (_lastFinishedTimerDurationSeconds ~/ 60)
                                .clamp(1, 720)
                                .toInt();
                        Navigator.of(dialogContext).pop(repeatMinutes);
                      },
                      icon: const Icon(Icons.replay_rounded),
                      label: const Text('Repeat Same Timer'),
                      style: FilledButton.styleFrom(
                        backgroundColor: primary,
                        foregroundColor: cs.onPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Start New Preset Timer',
                      style: TextStyle(
                        color: variant,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: GridView.builder(
                      itemCount: _timerFinishedPresetMinutes.length,
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 180,
                            mainAxisExtent: 52,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                          ),
                      itemBuilder: (context, index) =>
                          presetButton(_timerFinishedPresetMinutes[index]),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close_rounded),
                      label: const Text('Exit / Close Timer'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: fg,
                        side: BorderSide(color: outline),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        textStyle: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void startTimer() {
    if (timerInterval != null) return;
    _armedPresetTimer?.cancel();
    _armedPresetValue = null;
    if (seconds <= 0) {
      if (chainModeOn) {
        final sequence = chainPresets[chainPresetKey] ?? const [25];
        if (chainIndex >= sequence.length) chainIndex = 0;
        seconds = sequence[chainIndex] * 60;
      } else {
        seconds = sliderValue * 60;
      }
    }
    seconds = seconds.clamp(1, 720 * 60);
    if (_timerRuntime.status != TimerRuntimeStatus.paused ||
        _activeTimerDurationSeconds <= 0 ||
        seconds > _activeTimerDurationSeconds) {
      _activeTimerDurationSeconds = seconds;
    }
    _timerRuntime = TimerRuntime.running(
      durationSeconds: _activeTimerDurationSeconds,
      remainingSeconds: seconds,
      now: DateTime.now(),
      chainModeOn: chainModeOn,
      chainPresetKey: chainPresetKey,
      chainIndex: chainIndex,
      revision: _timerRuntime.revision + 1,
    );
    setState(() {
      _isTimerFinished = false;
      timerValue = _formatTimerDisplayValue(seconds);
      timerDisplayValue = timerValue;
      timerInterval = Timer.periodic(const Duration(milliseconds: 250), tick);
    });
    if (taggingOn) _sessionStartTime ??= DateTime.now();
    unawaited(_timerRuntimeStore.save(_timerRuntime));
    unawaited(_saveLastTimerSeconds(seconds));
    _applyAudioSettings();
    unawaited(_reconcileForeground(force: true));
  }

  void stopTimer() {
    if (timerInterval == null) return;
    seconds = _timerRuntime.remainingAt(DateTime.now());
    if (taggingOn && _sessionStartTime != null) {
      final elapsed = _activeTimerDurationSeconds - seconds;
      if (elapsed > 0) _logCurrentSession(elapsed);
    }
    timerInterval?.cancel();
    _timerRuntime = _timerRuntime.copyWith(
      status: TimerRuntimeStatus.paused,
      remainingSeconds: seconds,
      endAtEpochMs: () => null,
      revision: _timerRuntime.revision + 1,
    );
    unawaited(_timerRuntimeStore.save(_timerRuntime));
    if (seconds > 0) unawaited(_saveLastTimerSeconds(seconds));
    if (mounted) {
      setState(() => timerInterval = null);
    } else {
      timerInterval = null;
    }
    _applyAudioSettings();
    unawaited(_reconcileForeground(force: true));
  }

  void resetTimer() {
    if (timerInterval != null) stopTimer();
    timerInterval?.cancel();
    _timerRuntime = TimerRuntime.idle().copyWith(
      revision: _timerRuntime.revision + 1,
    );
    unawaited(_timerRuntimeStore.save(_timerRuntime));
    setState(() {
      timerInterval = null;
      seconds = 0;
      timerValue = '00:00';
      timerDisplayValue = '00:00';
      chainIndex = 0;
      _isTimerFinished = false;
      _activeTimerDurationSeconds = 0;
    });
    unawaited(_reconcileForeground(force: true));
  }

  void choosePreset(int value) {
    resetTimer();
    setState(() {
      sliderValue = value.clamp(1, 720);
      seconds = sliderValue * 60;
      _activeTimerDurationSeconds = seconds;
    });
    startTimer();
  }

  void addTimeToRunningTimer(int additionalSeconds) {
    if (timerInterval == null) return;
    final remaining =
        (_timerRuntime.remainingAt(DateTime.now()) + additionalSeconds).clamp(
          1,
          720 * 60,
        );
    final duration = (_activeTimerDurationSeconds + additionalSeconds).clamp(
      1,
      720 * 60,
    );
    _activeTimerDurationSeconds = duration;
    _timerRuntime = TimerRuntime.running(
      durationSeconds: duration,
      remainingSeconds: remaining,
      now: DateTime.now(),
      chainModeOn: chainModeOn,
      chainPresetKey: chainPresetKey,
      chainIndex: chainIndex,
      runId: _timerRuntime.runId,
      revision: _timerRuntime.revision + 1,
    );
    setState(() {
      seconds = remaining;
      sliderValue = (remaining / 60).ceil().clamp(1, 720);
      timerValue = _formatTimerDisplayValue(remaining);
      timerDisplayValue = timerValue;
    });
    unawaited(_timerRuntimeStore.save(_timerRuntime));
    unawaited(_reconcileForeground(force: true));
  }

  /// Starts timer preset immediately on tap.
  void _onPresetTap(int val) {
    _armedPresetTimer?.cancel();
    _armedPresetValue = null;
    choosePreset(val);
  }

  Widget _buildSpeakClockTab() {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ColoredBox(
        color: cs.surface,
        child: ClockPanel(
          onExitApp: () => unawaited(_exitAppFully()),
          onFullscreenPressed: () => _openFullscreenFocus(
            specificMode: FullscreenFocusMode.clock,
            forceHorizontal: true,
          ),
          onFullscreenImmersivePressed: () => _openFullscreenFocus(
            specificMode: FullscreenFocusMode.clock,
            forceHorizontal: true,
            startImmersive: true,
          ),
          currentTimeDisplay: currentTimeDisplay,
          clockIntervalMins: clockIntervalMins,
          clockShowMilliseconds: clockShowMilliseconds,
          clockSpeakTime: clockSpeakTime,
          clockSpeakRepeatCount: clockSpeakRepeatCount,
          clockNoiseOn: clockNoiseOn,
          motivationOn: motivationOn,
          motivationCategory: motivationCategory,
          motivationDelaySeconds: motivationDelaySeconds,
          clockIntervalOptions: clockIntervalOptions,
          clockSpeakRepeatOptions: clockSpeakRepeatOptions,
          motivationCategories: motivationCategories,
          motivationDelayOptions: motivationDelayOptions,
          clockShowSeconds: clockShowSeconds,
          onClockIntervalChanged: (val) {
            if (val == null) return;
            setState(() {
              clockIntervalMins = val;
              _lsSave();
            });
            if (clockOn) startClock();
          },
          onClockShowMillisecondsChanged: (val) {
            setState(() {
              clockShowMilliseconds = val ?? true;
              currentTimeDisplay = _formatCurrentTime(DateTime.now());
              _lsSave();
            });
          },
          onClockShowSecondsChanged: (val) {
            setState(() {
              clockShowSeconds = val ?? true;
              currentTimeDisplay = _formatCurrentTime(DateTime.now());
              _lsSave();
            });
          },
          onClockSpeakTimeChanged: (val) {
            final nowOn = val ?? true;
            final needsStart = nowOn && !clockOn;
            setState(() {
              clockSpeakTime = nowOn;
              if (needsStart) clockOn = true;
              _lsSave();
            });
            if (needsStart) startClock();
            if (nowOn) speakClock(timeToWords());
          },
          onClockSpeakRepeatCountChanged: (val) {
            if (val == null) return;
            setState(() {
              clockSpeakRepeatCount = val.clamp(1, 3);
              _lsSave();
            });
          },
          onClockNoiseOnChanged: (val) {
            final nowOn = val ?? false;
            final needsStart = nowOn && !clockOn;
            setState(() {
              clockNoiseOn = nowOn;
              if (needsStart) clockOn = true;
              _lsSave();
            });
            if (needsStart) startClock();
            _applyAudioSettings();
          },
          onMotivationChanged: (val) {
            final nowOn = val ?? true;
            final needsStart = nowOn && !clockOn;
            setState(() {
              motivationOn = nowOn;
              if (needsStart) clockOn = true;
              _lsSave();
            });
            if (needsStart) startClock();
          },
          onMotivationCategoryChanged: (val) {
            if (val == null) return;
            setState(() {
              motivationCategory = val;
              _lsSave();
            });
          },
          onMotivationDelayChanged: (val) {
            if (val == null) return;
            setState(() {
              motivationDelaySeconds = val;
              _lsSave();
            });
          },
          backgroundPersistenceOn: backgroundPersistenceOn,
          onBackgroundPersistenceChanged: (val) {
            setState(() {
              backgroundPersistenceOn = val ?? false;
              _lsSave();
            });
            unawaited(_reconcileForeground(force: true));
          },
        ),
      ),
    );
  }

  Widget _buildTimerSetupTab() {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ColoredBox(
        color: cs.surface,
        child: TimerPanel(
          onExitApp: () => unawaited(_exitAppFully()),
          onFullscreenPressed: () => _openFullscreenFocus(
            specificMode: FullscreenFocusMode.timer,
            forceHorizontal: true,
          ),
          onFullscreenImmersivePressed: () => _openFullscreenFocus(
            specificMode: FullscreenFocusMode.timer,
            forceHorizontal: true,
            startImmersive: true,
          ),
          timerValue: timerDisplayValue,
          sliderValue: sliderValue,
          remainingSeconds: seconds,
          voicesCount: voices.length,
          isRunning: timerInterval != null,
          presetValues: presetValues,
          startTimer: startTimer,
          stopTimer: stopTimer,
          resetTimer: resetTimer,
          choosePreset: choosePreset,
          addTimeToRunningTimer: addTimeToRunningTimer,
          armedPresetValue: _armedPresetValue,
          onPresetTap: _onPresetTap,
          onSliderChanged: (val) {
            setState(() {
              sliderValue = val.toInt();
            });
          },
          timerNoiseOn: timerNoiseOn,
          timerSpeakOn: timerSpeakOn,
          timerShowMilliseconds: timerShowMilliseconds,
          timerAnnounceEvery: timerAnnounceEvery,
          chainModeOn: chainModeOn,
          chainPresetKey: chainPresetKey,
          chainPresets: chainPresets,
          chainIndex: chainIndex,
          timerAnnounceOptions: timerAnnounceOptions,
          fullscreenShowClock: fullscreenShowClock,
          onFullscreenShowClockChanged: (val) {
            setState(() {
              fullscreenShowClock = val ?? false;
              _lsSave();
            });
          },
          onTimerNoiseOnChanged: (val) {
            setState(() {
              timerNoiseOn = val ?? true;
              _lsSave();
            });
            _applyAudioSettings();
          },
          onTimerSpeakOnChanged: (val) {
            setState(() {
              timerSpeakOn = val ?? true;
              _lsSave();
            });
          },
          onTimerShowMillisecondsChanged: (val) {
            setState(() {
              timerShowMilliseconds = val ?? false;
              timerDisplayValue = _formatTimerDisplayValue(seconds);
              _lsSave();
            });
          },
          onTimerAnnounceEveryChanged: (val) {
            if (val == null) return;
            setState(() {
              timerAnnounceEvery = val;
              _lsSave();
            });
          },
          onChainModeChanged: (val) {
            setState(() {
              chainModeOn = val ?? false;
              chainIndex = 0;
              _lsSave();
            });
          },
          onChainPresetChanged: (val) {
            if (val == null) return;
            setState(() {
              chainPresetKey = val;
              chainIndex = 0;
              _lsSave();
            });
          },
          taggingOn: taggingOn,
          sessionTag: sessionTag,
          todaySummary: _todaySummary,
          onTaggingOnChanged: (val) {
            setState(() {
              taggingOn = val;
              _lsSave();
            });
            if (val) _refreshTodaySummary();
          },
          onSessionTagChanged: (val) {
            setState(() {
              sessionTag = val;
              _lsSave();
            });
          },
          onDashboardPressed: () {
            Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const DashboardScreen()));
          },
        ),
      ),
    );
  }

  int _lapCount = 0;
  List<String> _lapTimes = [];

  void _recordLap() {
    setState(() {
      _lapCount++;
      _lapTimes.insert(0, 'Lap $_lapCount  $stopwatchElapsedValue');
    });
  }

  Widget _buildStopwatchTab() {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ColoredBox(
        color: cs.surface,
        child: StopwatchPanel(
          onExitApp: () => unawaited(_exitAppFully()),
          onFullscreenPressed: () => _openFullscreenFocus(
            specificMode: FullscreenFocusMode.moduleC,
            forceHorizontal: true,
          ),
          onFullscreenImmersivePressed: () => _openFullscreenFocus(
            specificMode: FullscreenFocusMode.moduleC,
            forceHorizontal: true,
            startImmersive: true,
          ),
          elapsedValue: stopwatchElapsedValue,
          isRunning: stopwatchInterval != null,
          startStopwatch: startStopwatch,
          stopStopwatch: stopStopwatch,
          resetStopwatch: () {
            resetStopwatch();
            setState(() {
              _lapCount = 0;
              _lapTimes = [];
            });
          },
          onLap: _recordLap,
          lapCount: _lapCount,
          lapTimes: _lapTimes,
          stopwatchSpeakOn: stopwatchSpeakOn,
          stopwatchShowMilliseconds: stopwatchShowMilliseconds,
          stopwatchSpeakDelaySeconds: stopwatchSpeakDelaySeconds,
          stopwatchSpeakDelayOptions: stopwatchSpeakDelayOptions,
          onStopwatchSpeakOnChanged: (val) {
            setState(() {
              stopwatchSpeakOn = val ?? true;
              _lsSave();
            });
          },
          onStopwatchShowMillisecondsChanged: (val) {
            setState(() {
              stopwatchShowMilliseconds = val ?? false;
              stopwatchElapsedValue = _formatStopwatchElapsed(
                stopwatchElapsedSeconds,
                showMilliseconds: stopwatchShowMilliseconds,
              );
              _lsSave();
            });
          },
          onStopwatchSpeakDelayChanged: (val) {
            if (val == null) return;
            setState(() {
              stopwatchSpeakDelaySeconds = val;
              _lastStopwatchAutoAnnouncedSecond = -1;
              _lsSave();
            });
          },
        ),
      ),
    );
  }

  Widget _buildHelpTab() {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: cs.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: cs.primary),
        title: Text(
          AppLocalizations.of(context)?.helpTitle ?? 'Help / Working',
          style: TextStyle(
            color: cs.primary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: ListView(
            children: [
              HelpPanel(
                muteSpeechAfterMidnight: muteSpeechAfterMidnight,
                nightMuteMode: nightMuteMode,
                sleepStartLabel: _formatMinutesAs12Hour(sleepStartMinutes),
                sleepEndLabel: _formatMinutesAs12Hour(sleepEndMinutes),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    foregroundHealthTimer?.cancel();
    nightIdleTimer?.cancel();
    nightResumeSpeechTimer?.cancel();
    goalReminderTimer?.cancel();
    _armedPresetTimer?.cancel();
    _widgetArmedTimer?.cancel();
    clockTimer?.cancel();
    clockTimer = null;
    timerInterval?.cancel();
    timerInterval = null;
    stopwatchInterval?.cancel();
    stopwatchInterval = null;
    displayTick?.cancel();
    if (Platform.isLinux || Platform.isWindows) {
      unawaited(_speechService.disposeDesktopSpeech());
      if (Platform.isWindows) unawaited(flutterTts.stop());
    } else {
      unawaited(_stopTts());
    }
    unawaited(_settingsService.flush());
    unawaited(_audioService.dispose());
    // Remove callback to avoid memory leaks
    FlutterForegroundTask.removeTaskDataCallback(_onReceiveTaskData);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(settingsProvider);
    final appTitle = currentTabIndex == 0
        ? 'Clock'
        : currentTabIndex == 1
        ? 'Timer'
        : 'Stopwatch';

    return OrientationBuilder(
      builder: (context, orientation) {
        return Scaffold(
          appBar: AppBar(
            centerTitle: false,
            title: Text(appTitle),
            leading: IconButton(
              icon: const Icon(Icons.menu_rounded),
              tooltip: 'Settings',
              onPressed: _openSettings,
            ),
            actions: [
              IconButton(
                onPressed: () => unawaited(_setSpeechMaster(!speechMasterOn)),
                tooltip: speechMasterOn ? 'Turn audio off' : 'Turn audio on',
                icon: Icon(
                  speechMasterOn
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                ),
              ),
              IconButton(
                onPressed: _openFullscreenFocus,
                tooltip: 'Focus mode',
                icon: const Icon(Icons.fullscreen_rounded),
              ),
              IconButton(
                onPressed: () => unawaited(_exitAppFully()),
                tooltip: 'Exit',
                icon: const Icon(Icons.power_settings_new_rounded),
              ),
              const SizedBox(width: 4),
            ],
          ),
          body: AnimatedSwitcher(
            duration: const Duration(milliseconds: 280),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutCubic,
                ),
                child: child,
              );
            },
            child: KeyedSubtree(
              key: ValueKey<int>(currentTabIndex),
              child: currentTabIndex == 0
                  ? _buildSpeakClockTab()
                  : (currentTabIndex == 1
                        ? _buildTimerSetupTab()
                        : _buildStopwatchTab()),
            ),
          ),
          bottomNavigationBar: orientation == Orientation.portrait
              ? BottomNavBar(
                  selectedIndex: currentTabIndex,
                  onDestinationSelected: (index) {
                    setState(() {
                      currentTabIndex = index;
                    });
                    // Clear two-tap armed state when leaving timer tab
                    if (index != 1) {
                      _armedPresetTimer?.cancel();
                      _armedPresetValue = null;
                    }
                  },
                  destinations: const [
                    NavDestination(
                      icon: Icons.watch_later_outlined,
                      activeIcon: Icons.watch_later_outlined,
                      label: 'Clock',
                    ),
                    NavDestination(
                      icon: Icons.hourglass_empty_rounded,
                      activeIcon: Icons.hourglass_empty_rounded,
                      label: 'Timer',
                    ),
                    NavDestination(
                      icon: Icons.timer_outlined,
                      activeIcon: Icons.timer_outlined,
                      label: 'Stopwatch',
                    ),
                  ],
                )
              : null,
        );
      },
    );
  }
}
