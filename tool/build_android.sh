#!/usr/bin/env bash
# Compila la app para Android (APK instalable).
# Requisitos: Flutter, Android SDK + NDK (Android Studio), Rust y cargo-ndk:
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   cargo install cargo-ndk
# El NDK se busca en ANDROID_NDK_HOME (p. ej. ~/Android/Sdk/ndk/<versión>).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v flutter >/dev/null || { echo "Falta Flutter"; exit 1; }
command -v cargo-ndk >/dev/null || { echo "Falta cargo-ndk: cargo install cargo-ndk"; exit 1; }
[ -n "${ANDROID_NDK_HOME:-}" ] || { echo "Define ANDROID_NDK_HOME con la ruta del NDK"; exit 1; }

cd "$ROOT/app"
if [ ! -d android ]; then
  echo "▸ 1/4 Generando el proyecto Android"
  flutter create --platforms=android --project-name calendario --org es.calendario .
  rm -f test/widget_test.dart
fi
echo "▸ 2/4 Ajustando el proyecto Android"
dart run tool/patch_runners.dart || echo "  (revisa los avisos anteriores)"

echo "▸ 3/4 Núcleo Rust para Android (arm64, armv7, x86_64)"
(cd "$ROOT/core" && cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 --platform 24 -o "$ROOT/app/android/app/src/main/jniLibs" build --release)

echo "▸ 4/4 Compilando el APK"
flutter pub get
flutter build apk --release
echo "✓ Listo: app/build/app/outputs/flutter-apk/app-release.apk"
