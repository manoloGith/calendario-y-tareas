# Compila Calendario y Tareas en Windows.
#   powershell -ExecutionPolicy Bypass -File tool\build.ps1        → compilación release
#   powershell -ExecutionPolicy Bypass -File tool\build.ps1 run    → modo desarrollo (flutter run)
param([string]$Mode = "release")
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw "Falta Rust: https://rustup.rs" }
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) { throw "Falta Flutter: https://docs.flutter.dev/get-started/install/windows" }

Write-Host "> 1/4 Nucleo Rust (release)"
Push-Location "$Root\core"; cargo build --release; if ($LASTEXITCODE -ne 0) { throw "cargo build fallo" }; Pop-Location

Push-Location "$Root\app"
if (-not (Test-Path "windows")) {
  Write-Host "> 2/4 Generando el proyecto nativo de Windows"
  flutter create --platforms=windows --project-name calendario --org es.calendario .
  Remove-Item -ErrorAction SilentlyContinue "test\widget_test.dart"
}
Write-Host "> 3/4 Ajustando el proyecto nativo"
dart run tool/patch_runners.dart
flutter pub get

if ($Mode -eq "run") { flutter run -d windows; Pop-Location; exit }

Write-Host "> 4/4 Compilando la app"
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw "flutter build fallo" }
Pop-Location
Write-Host "Listo: app\build\windows\x64\runner\Release\calendario.exe"
