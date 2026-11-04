// Plataforma: escritorio (Windows, macOS, Linux) o móvil (Android).
import 'dart:io';

bool get isMobile => Platform.isAndroid || Platform.isIOS;
bool get isDesktop => !isMobile;
