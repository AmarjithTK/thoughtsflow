# Sherpa-ONNX desktop assets

Linux x64 uses a bundled native Sherpa C API in a persistent Dart worker. Windows retains the executable backend. Keep model folders and language data with the release bundle.

## Expected layout

- `assets/tts/sherpa-linux-x64-runtime.tar.bz2` — verified v1.12.34 shared libraries, extracted into app-owned runtime storage
- `assets/tts/Sherpa-runtime-NOTICE.txt` and `assets/tts/espeak-ng-LICENSE.txt` — licenses and corresponding-source links
- `assets/tts/bin/linux-x64/sherpa-onnx-offline-tts-play`
- `assets/tts/bin/windows-x64/sherpa-onnx-offline-tts-play.exe`
- `assets/tts/models/en/primary/model.onnx`
- `assets/tts/models/en/primary/tokens.txt`
- `assets/tts/models/en/backup/model.onnx`
- `assets/tts/models/en/backup/tokens.txt`
- `assets/tts/models/ml/primary/model.onnx`
- `assets/tts/models/ml/primary/tokens.txt`
- `assets/tts/models/ml/backup/model.onnx`
- `assets/tts/models/ml/backup/tokens.txt`

Linux uses `libsherpa-onnx-c-api.so` and `libonnxruntime.so` from the pinned archive; it does not launch the CLI for each phrase or download a native runtime automatically. Existing executable assets remain for the Windows backend and standalone tooling.

Local imports must be trusted self-contained Sherpa-converted Piper/VITS or English Kokoro folders, not arbitrary Hugging Face weights. See the main README's Linux speech section for required files, import controls, language restrictions, and license obligations.
