#!/usr/bin/env bash
# Compila Calendario y Tareas en Linux o macOS.
#   ./tool/build.sh          → compilación release
#   ./tool/build.sh run      → ejecuta en modo desarrollo (flutter run)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -s)" in
  Linux)  PLAT=linux ;;
  Darwin) PLAT=macos ;;
  *) echo "Sistema no soportado por este script (en Windows usa tool\\build.ps1)"; exit 1 ;;
esac
command -v cargo >/dev/null   || { echo "Falta Rust: https://rustup.rs"; exit 1; }
command -v flutter >/dev/null || { echo "Falta Flutter: https://docs.flutter.dev/get-started/install"; exit 1; }

echo "▸ 1/4 Núcleo Rust (release)"
(cd "$ROOT/core" && cargo build --release)

cd "$ROOT/app"
if [ ! -d "$PLAT" ]; then
  echo "▸ 2/4 Generando el proyecto nativo de $PLAT"
  flutter create --platforms="$PLAT" --project-name calendario --org es.calendario .
  # flutter create añade un test de ejemplo que no corresponde a esta app.
  rm -f test/widget_test.dart
else
  echo "▸ 2/4 Proyecto nativo de $PLAT ya existe"
fi

echo "▸ 3/4 Ajustando el proyecto nativo"
dart run tool/patch_runners.dart || echo "  (revisa los avisos anteriores)"
flutter pub get

if [ "${1:-}" = "run" ]; then
  exec flutter run -d "$PLAT"
fi

echo "▸ 4/4 Compilando la app"
flutter build "$PLAT" --release

if [ "$PLAT" = macos ]; then
  APP="build/macos/Build/Products/Release/calendario.app"
  mkdir -p "$APP/Contents/Frameworks"
  cp "$ROOT/core/target/release/libcalendario_core.dylib" "$APP/Contents/Frameworks/"
  codesign --force --deep --sign - "$APP"
  echo "✓ Listo: app/$APP"
else
  echo "✓ Listo: app/build/linux/x64/release/bundle/calendario"
fi
