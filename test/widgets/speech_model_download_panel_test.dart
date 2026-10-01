import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solasflow/models/speech_model_download_status.dart';
import 'package:solasflow/widgets/settings_panel.dart';

void main() {
  testWidgets('English voice download exposes progress, cancel, and retry', (
    tester,
  ) async {
    final status = ValueNotifier(
      const SpeechModelDownloadStatus(
        phase: SpeechModelDownloadPhase.notDownloaded,
      ),
    );
    final customModelStatus = ValueNotifier('Using bundled voices');
    var downloadRequests = 0;
    var cancelRequests = 0;

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: SettingsPanel(
              soundList: const [],
              volumeLists: const [0.1, 0.2, 0.6, 0.8, 1.0],
              isSpeechActive: false,
              speechQueueLength: 0,
              voices: const [],
              speechEngineRuntime: 'sherpa',
              speechEngineRuntimeDetail: 'Piper fallback ready',
              showEnglishVoiceDownload: true,
              speechModelDownloadStatus: status,
              customModelStatus: customModelStatus,
              onImportDesktopModel: (_, _) async {},
              onClearDesktopModel: (_) async {},
              sleepStartLabel: '10:00 PM',
              sleepEndLabel: '7:00 AM',
              onSoundChanged: (_) {},
              onNoiseVolumeChanged: (_) {},
              onSpeakVolumeChanged: (_) {},
              onMaximumSpeechVolumeChanged: (_) {},
              onSpeechMasterOnChanged: (_) {},
              onAppDarkThemeChanged: (_) {},
              onAppFontSizeMultiplierChanged: (_) {},
              onFullscreenDarkThemeChanged: (_) {},
              onFullscreenDimBrightnessChanged: (_) {},
              onFullscreenDimBrightnessLevelChanged: (_) {},
              onFullscreenStartLandscapeChanged: (_) {},
              onMuteSpeechAfterMidnightChanged: (_) {},
              onNightMuteModeChanged: (_) {},
              onPickSleepStart: () {},
              onPickSleepEnd: () {},
              onVoiceListModeChanged: (_) {},
              onSpeechEngineModeChanged: (_) {},
              onFavoriteVoiceChanged: (_) {},
              onOpenHelp: () {},
              onTestSpeech: () {},
              onDownloadEnglishVoice: () => downloadRequests++,
              onCancelEnglishVoiceDownload: () => cancelRequests++,
            ),
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.text('Kokoro English voice'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not downloaded'), findsOneWidget);
    await tester.tap(find.text('Download'));
    expect(downloadRequests, 1);

    status.value = const SpeechModelDownloadStatus(
      phase: SpeechModelDownloadPhase.downloading,
      receivedBytes: 85,
      totalBytes: 200,
    );
    await tester.pump();
    expect(find.textContaining('43%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    expect(cancelRequests, 1);

    status.value = const SpeechModelDownloadStatus(
      phase: SpeechModelDownloadPhase.failed,
      error: 'Connection timed out',
    );
    await tester.pump();
    expect(find.textContaining('Connection timed out'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(downloadRequests, 2);

    await tester.pumpWidget(const SizedBox());
    status.dispose();
    customModelStatus.dispose();
  });
}
