# Third-party notices

The app links only the WhisperKit and ArgmaxCore products from
[Argmax Open-Source SDK v1.1.0](https://github.com/argmaxinc/argmax-oss-swift/tree/v1.1.0).
The SDK's MIT license and bundled third-party notices are included here and in
the built app's `Contents/Resources/ThirdPartyLicenses` directory.

The app downloads the fixed multilingual `large-v3-v20240930_626MB` Core ML
conversion of OpenAI Whisper from
[Argmax's model repository](https://huggingface.co/argmaxinc/whisperkit-coreml).
Model weights are cached on the user's Mac, outside the app and source repository.
The [OpenAI Whisper MIT license](https://github.com/openai/whisper/blob/main/LICENSE)
is included as `Whisper-MIT.txt`.

The SDK's command-line tooling, speech synthesis and speaker diarization products
are not linked into LectureScribe.
