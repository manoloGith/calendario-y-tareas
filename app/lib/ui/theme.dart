// Sistema de diseño (tokens del mockup) para modo claro y oscuro.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@immutable
class Tokens extends ThemeExtension<Tokens> {
  const Tokens({
    required this.window,
    required this.sidebar,
    required this.sideBorder,
    required this.border,
    required this.text,
    required this.sec,
    required this.faint,
    required this.pill,
    required this.pillSel,
    required this.glass,
    required this.card,
    required this.allDay,
    required this.tag,
    required this.sel,
    required this.accent,
    required this.danger,
    required this.warn,
    required this.warnBg,
    required this.ok,
    required this.okBg,
    required this.tintAlpha,
    required this.dark,
  });

  final Color window, sidebar, sideBorder, border, text, sec, faint, pill, pillSel, glass, card, allDay, tag, sel;
  final Color accent, danger, warn, warnBg, ok, okBg;
  final double tintAlpha;
  final bool dark;

  static const light = Tokens(
    window: Color(0xFFFFFFFF),
    sidebar: Color(0xFFF1F1F3),
    sideBorder: Color(0x0F000000),
    border: Color(0xFFE6E6EA),
    text: Color(0xFF1D1D1F),
    sec: Color(0xFF626267),
    faint: Color(0xFF707075),
    pill: Color(0xFFECECEF),
    pillSel: Color(0xFFFFFFFF),
    glass: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    allDay: Color(0xFFFAFAFB),
    tag: Color(0xFFEEEEF1),
    sel: Color(0x17007AFF),
    accent: Color(0xFF007AFF),
    danger: Color(0xFFC4281C),
    warn: Color(0xFF8A4300),
    warnBg: Color(0x21FF9500),
    ok: Color(0xFF1E7B34),
    okBg: Color(0x2134C759),
    tintAlpha: 0.17,
    dark: false,
  );

  static const darkTokens = Tokens(
    window: Color(0xFF1E1E20),
    sidebar: Color(0xFF2A2A2D),
    sideBorder: Color(0x14FFFFFF),
    border: Color(0xFF38383C),
    text: Color(0xFFF2F2F7),
    sec: Color(0xFFA8A8AE),
    faint: Color(0xFF8E8E93),
    pill: Color(0xFF3A3A3E),
    pillSel: Color(0xFF5C5C61),
    glass: Color(0xFF2C2C2F),
    card: Color(0xFF333337),
    allDay: Color(0xFF232326),
    tag: Color(0x1AFFFFFF),
    sel: Color(0x2E0A84FF),
    accent: Color(0xFF0A84FF),
    danger: Color(0xFFFF6961),
    warn: Color(0xFFFFB340),
    warnBg: Color(0x24FF9500),
    ok: Color(0xFF5EDB7A),
    okBg: Color(0x2434C759),
    tintAlpha: 0.24,
    dark: true,
  );

  /// Texto legible sobre el tinte de un calendario.
  Color tintText(Color c) {
    final hsl = HSLColor.fromColor(c);
    return dark
        ? hsl.withLightness((hsl.lightness + 0.25).clamp(0.0, 0.85)).toColor()
        : hsl.withLightness((hsl.lightness * 0.55).clamp(0.15, 0.4)).toColor();
  }

  Color tint(Color c) => c.withValues(alpha: tintAlpha);

  @override
  Tokens copyWith() => this;

  @override
  Tokens lerp(Tokens? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension TokensX on BuildContext {
  Tokens get tk => Theme.of(this).extension<Tokens>()!;
}

String? _systemFont() {
  if (kIsWeb) return null;
  switch (defaultTargetPlatform) {
    case TargetPlatform.windows:
      return 'Segoe UI Variable Text';
    case TargetPlatform.linux:
      return 'Inter';
    default:
      return null; // macOS: San Francisco por defecto
  }
}

ThemeData buildTheme(Tokens t) {
  final base = t.dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
  final font = _systemFont();
  return base.copyWith(
    extensions: [t],
    scaffoldBackgroundColor: t.window,
    canvasColor: t.window,
    dividerColor: t.border,
    colorScheme: base.colorScheme.copyWith(primary: t.accent, surface: t.window, onSurface: t.text, secondary: t.accent),
    textTheme: base.textTheme.apply(fontFamily: font, bodyColor: t.text, displayColor: t.text).copyWith(
          bodyMedium: TextStyle(fontSize: 13, color: t.text, fontFamily: font),
          bodySmall: TextStyle(fontSize: 11.5, color: t.sec, fontFamily: font),
        ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.window,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: TextStyle(fontSize: 13, color: t.text),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 600),
      decoration: BoxDecoration(color: t.dark ? const Color(0xFF48484A) : const Color(0xFF3A3A3C), borderRadius: BorderRadius.circular(6)),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: t.pill,
      hintStyle: TextStyle(color: t.faint, fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: t.accent, width: 1.5)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? const Color(0xFF34C759) : t.pill),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4))),
    scrollbarTheme: ScrollbarThemeData(thickness: const WidgetStatePropertyAll(6), radius: const Radius.circular(3), thumbColor: WidgetStatePropertyAll(t.faint.withValues(alpha: .4))),
    visualDensity: VisualDensity.compact,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: t.sel,
  );
}

/// Textos de Material en español (sin depender de flutter_localizations).
class SpanishMaterialLocalizations extends DefaultMaterialLocalizations {
  const SpanishMaterialLocalizations();
  @override
  String get okButtonLabel => 'Aceptar';
  @override
  String get cancelButtonLabel => 'Cancelar';
  @override
  String get closeButtonLabel => 'Cerrar';
  @override
  String get copyButtonLabel => 'Copiar';
  @override
  String get cutButtonLabel => 'Cortar';
  @override
  String get pasteButtonLabel => 'Pegar';
  @override
  String get selectAllButtonLabel => 'Seleccionar todo';
  @override
  String get searchFieldLabel => 'Buscar';
  @override
  String get closeButtonTooltip => 'Cerrar';
  @override
  String get backButtonTooltip => 'Atrás';
  @override
  String get deleteButtonTooltip => 'Eliminar';
  @override
  String get moreButtonTooltip => 'Más';
  @override
  String get showMenuTooltip => 'Mostrar menú';
  @override
  String get modalBarrierDismissLabel => 'Cerrar';
}

class SpanishMaterialDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const SpanishMaterialDelegate();
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<MaterialLocalizations> load(Locale locale) => SynchronousFuture(const SpanishMaterialLocalizations());
  @override
  bool shouldReload(SpanishMaterialDelegate old) => false;
}
