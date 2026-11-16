# KI-Modelle (laufen ausschließlich lokal über Core ML)

## Real-ESRGAN x4v3 – Hochskalierung (im Repository und in der App enthalten)
* Modell: xinntao/Real-ESRGAN (realesr-general-x4v3), BSD-3-Clause
* Core-ML-Konvertierung: https://huggingface.co/VincentGOURBIN/RealESRGAN-CoreML (BSD-3-Clause)

## Whisper large-v3 turbo – Spracherkennung (wird beim ersten Gebrauch geladen, ca. 630 MB)
* Modell: OpenAI Whisper (MIT); Core-ML-Konvertierung im WhisperKit-Format: https://huggingface.co/argmaxinc/whisperkit-coreml (MIT)
* Laufzeitbibliothek: WhisperKit (argmaxinc, MIT), als Swift-Paket eingebunden

## Personenverfolgung
* Apple Vision (Gesichts- und Körpererkennung), Teil von macOS
