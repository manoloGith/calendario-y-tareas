# Calendario y Tareas

Aplicación de escritorio (Windows, macOS y Linux) de calendario y gestor de tareas con estilo macOS, modo claro y oscuro, widgets anclados al escritorio y datos **locales y cifrados**. La interfaz está hecha en Flutter y toda la lógica en un núcleo Rust.

Esta versión trabaja **local primero**: todo se guarda en una base de datos cifrada del equipo y funciona sin red. Los conectores disponibles son archivos **.ics** y **CalDAV**. La sincronización entre dispositivos con cifrado de extremo a extremo llegará con el **servidor zero-knowledge** (ver «Próximos pasos»); el núcleo ya está preparado para él.

## Contenido

```
core/                 Núcleo Rust (biblioteca nativa calendario_core)
  src/db.rs           Base de datos SQLCipher, registro de cambios
  src/vault.rs        Reglas de negocio: rangos, listas inteligentes, recurrencias, .ics, CalDAV, avisos
  src/recur.rs        Expansión de RRULE con zonas horarias y cambios de horario
  src/ics.rs          Lectura y escritura de iCalendar (VEVENT, VTODO, VALARM, RELATED-TO, CATEGORIES)
  src/caldav.rs       Conector CalDAV (descubrimiento, subida con ETag, descarga, conflictos)
  src/nlp.rs          Captura rápida en lenguaje natural (español)
  src/backup.rs       Copias .calbak (XChaCha20-Poly1305 + Argon2id)
  src/desktop.rs      Anclaje de widgets, diálogos de archivos, notificaciones
  src/api.rs, ffi.rs  API JSON y la interfaz C que usa Flutter
  tests/              Pruebas de integración (bóveda, API, CalDAV real)
app/                  Interfaz Flutter
  lib/core/           Puente FFI, modelos, estado, ajustes
  lib/ui/             Ventana principal, calendario, tareas, ajustes
  lib/desktop_widgets Widgets de escritorio
  tool/patch_runners.dart  Ajusta los proyectos nativos que genera flutter create (icono incluido)
  tool/make_icon.py   Genera el icono (assets/icon/) en PNG e ICO
tool/build.sh, build.ps1   Compilación con un solo comando
.github/workflows/    Compilación y pruebas en Windows, macOS y Linux reales
```

## Compilar

**Requisitos:** [Rust](https://rustup.rs) estable y [Flutter](https://docs.flutter.dev/get-started/install) estable (3.32 o posterior) con el soporte de escritorio de tu sistema:

- **Windows:** Visual Studio 2022 con «Desarrollo para el escritorio con C++».
- **macOS:** Xcode.
- **Linux:** `sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libstdc++-12-dev libayatana-appindicator3-dev`.

**Con un solo comando**, desde la carpeta raíz:

```bash
./tool/build.sh            # Linux y macOS (release)
./tool/build.sh run        # modo desarrollo
```

```powershell
powershell -ExecutionPolicy Bypass -File tool\build.ps1        # Windows (release)
powershell -ExecutionPolicy Bypass -File tool\build.ps1 run    # modo desarrollo
```

El script compila el núcleo Rust, genera el proyecto nativo con `flutter create` la primera vez, lo ajusta con `tool/patch_runners.dart` (empaqueta la biblioteca nativa, ventanas ocultas al arrancar, transparencia en Linux, red sin App Sandbox en macOS) y compila la app.

Resultado:

| Sistema | Ejecutable |
|---|---|
| Windows | `app\build\windows\x64\runner\Release\calendario.exe` |
| macOS | `app/build/macos/Build/Products/Release/calendario.app` |
| Linux | `app/build/linux/x64/release/bundle/calendario` |

**GitHub Actions:** si subes el proyecto a GitHub, el flujo `.github/workflows/build.yml` ejecuta las pruebas del núcleo (con un servidor CalDAV real) y compila la app en los tres sistemas; los ejecutables quedan como artefactos descargables.

## Uso

**App portable.** Al abrirse, la app usa los datos de la carpeta `datos` que haya junto al ejecutable (en macOS, junto a `calendario.app`): así puedes llevar la carpeta completa en un USB o copiarla a otro equipo. Contiene la base de datos cifrada (`datos.calendario`) y los ajustes (`ajustes.json`); las rutas dentro de la carpeta de la app se guardan de forma relativa, así que da igual la letra de unidad del USB. Si no hay datos, la pantalla de inicio permite **crearlos** (junto a la app o en otra carpeta), **abrir datos existentes de una carpeta** o **importar una copia de seguridad (.calbak)**. Para guardar los datos en otro sitio más adelante: Ajustes › General › **Carpeta de datos › Cambiar carpeta…** (se mueven allí). Si la carpeta de la app no admite escritura (por ejemplo, dentro de «Archivos de programa»), se usa la carpeta del usuario.

**Bandeja del sistema e instancia única.** La app deja su icono en la bandeja del sistema. Cerrar la ventana la oculta ahí (los widgets siguen funcionando); clic en el icono la vuelve a mostrar y su menú ofrece «Nuevo evento», «Nueva tarea», «Bloquear» y **«Salir»**, que cierra la app y todos sus widgets (también con Ctrl+Q). Solo puede haber una ventana principal y un widget de cada tipo a la vez: si se abre el programa otra vez, se muestra la ventana que ya estaba abierta.

**Primera vez.** La app pide una contraseña para crear la bóveda cifrada. Con «Recordar en este equipo» se guarda en el llavero del sistema (Credential Manager, Keychain o Secret Service) y la app y los widgets se abren sin pedirla. Si olvidas la contraseña, los datos no se pueden recuperar: haz copias de seguridad.

**Calendario.** Vistas Día, Semana, Mes y Año. En la semana: doble clic en un hueco para crear, clic en un evento para editarlo, arrástralo para moverlo (también a otro día) y arrastra su borde inferior para cambiar la duración. En los eventos recurrentes la app pregunta si el cambio es para «solo esta», «esta y las siguientes» o «todas». Las tareas con fecha aparecen en el calendario y se pueden completar desde ahí.

**Tareas.** Cada tarea tiene **fecha de inicio y fecha de fin** (las dos opcionales, con hora si se quiere); «Hoy» muestra las que vencen hoy o antes y las que ya han empezado. Listas inteligentes (Hoy, Programadas, Todas, Marcadas, Completadas), listas propias con secciones, subtareas, etiquetas, prioridades, avisos y tareas recurrentes (cada día, días laborables, semana, 2 semanas, mes, **trimestre**, **semestre**, año): al completar una recurrente pasa a su siguiente fecha y reabre sus subtareas, como en Recordatorios.

**Captura rápida** en lenguaje natural, sin enviar nada a la red. Ejemplos:

- «Cena con Ana el viernes a las 21h #amigos»
- «Pagar recibo IBI mañana !!»
- «Daily cada día laborable a las 9:30»
- «Dentista el 12 de noviembre a las 5 de la tarde»
- «Revisar PR 142 en 2 días durante 30 min»
- «Pagar IVA trimestralmente #impuestos», «Revisión del coche cada semestre»

**Atajos** (Cmd en macOS, Ctrl en Windows y Linux):

| Atajo | Acción |
|---|---|
| N | Nuevo evento o tarea |
| F | Buscar |
| T | Ir a hoy |
| 1 / 2 | Calendario / Tareas |
| R | Sincronizar CalDAV |
| , | Ajustes |
| L | Bloquear |
| Q | Salir (cierra también los widgets) |
| Alt + ← / → | Periodo anterior / siguiente |

**Archivos .ics.** «Enlazar» mantiene el calendario unido al archivo: los cambios se escriben en él y, si otro programa lo modifica, la app lo vuelve a leer (cada 10 segundos). «Importar» hace una copia. Cada calendario se puede exportar a .ics desde su menú «…».

**CalDAV** (Nextcloud, iCloud con contraseña de aplicación, Fastmail, Radicale, Baïkal…). Ajustes › Cuentas › Añadir cuenta. Cada cuenta admite una **dirección principal y una o varias alternativas** del mismo servidor, por ejemplo la IP local de casa y la dirección por VPN (Tailscale): al sincronizar se prueba primero la última que funcionó y, si no responde en unos segundos, las demás. «Probar conexión» comprueba cada dirección y muestra si responde y en cuánto tiempo. En Ajustes › Cuentas se ve por cuál está conectada y se puede editar. Sin red, los cambios se quedan en local y se suben al reconectar; si el mismo elemento cambió en los dos lados, gana la edición más reciente. Se pueden crear calendarios nuevos en el servidor desde «Nuevo calendario o lista».

**Copias de seguridad.** Ajustes › Copias. El archivo `.calbak` contiene todo (también las cuentas) cifrado con la contraseña que elijas; se verifica al crearlo. Al restaurar puedes fusionar o reemplazar.

**Adjuntos.** Eventos y tareas admiten documentos, enlaces y carpetas (botón del clip en «Adjuntos»). Los documentos se copian dentro de la base de datos, cifrados (máximo 50 MB cada uno), así que viajan con tus datos y en las copias de seguridad aunque borres el original; al abrirlos se descifra una copia temporal (los cambios que hagas en ella no se guardan en el adjunto: usa «Guardar una copia…»). Los enlaces se abren en el navegador y las carpetas en el explorador (son referencias: si la carpeta se mueve, deja de encontrarse). Los adjuntos no se sincronizan por CalDAV.

**Widgets.** Tres widgets: «Solo calendario», «Calendario y eventos» y «Tareas». En Ajustes › Widgets, para cada uno: activarlo, el **periodo que muestra su lista** (hoy, próximos 3, 7 o 15 días, o el próximo mes) y el **tamaño del texto** (70–160 %); la fuente es común a todos. El **«+»** junto al título abre en la app el formulario de nuevo evento (en el día seleccionado) o una tarea nueva; **doble clic en un día** también abre el formulario de evento. Si un evento o tarea tiene adjuntos, aparece un **clip** para abrirlos. **Tamaño de la ventana:** al aparecer en un monitor nuevo se adapta a su escala (DPI) y resolución; después se cambia desde cualquier borde o con el asa de la esquina inferior derecha. En las listas, el texto crece o encoge con el ancho y la altura solo cambia cuántos elementos se ven (con scroll). La posición y el tamaño se guardan **para cada monitor y resolución**.

## Arquitectura

```
Flutter (UI, widgets)  ──dart:ffi──▶  calendario_core (Rust)
   JSON {"method", "params"}            ├─ SQLCipher (fuente de verdad, cifrada)
                                        ├─ registro de cambios (futuro servidor ZK)
                                        ├─ conector .ics (archivos enlazados)
                                        └─ conector CalDAV (HTTPS, en segundo plano)
```

La comunicación es una única función C (`cal_call`) que recibe y devuelve JSON, sin generadores de código. Las operaciones de red, copias y diálogos se ejecutan en otro isolate de Dart para no bloquear la interfaz; la sincronización CalDAV abre su propia conexión a la base de datos. Cada widget es un proceso de la misma app (`calendario --widget=tasks`) que abre la misma base de datos y se refresca cuando cambia su número de versión.

## Seguridad: qué está cifrado y qué no

- **En el equipo, todo:** la base de datos completa (eventos, tareas, cuentas y contraseñas CalDAV) va cifrada con SQLCipher. El archivo de ajustes (`ajustes.json`) solo guarda preferencias (tema, posición de widgets, ruta de la bóveda).
- **Copias `.calbak`:** cifradas con XChaCha20-Poly1305 y una clave derivada con Argon2id.
- **CalDAV y .ics no son de extremo a extremo.** El servidor CalDAV y los archivos .ics enlazados o exportados contienen los datos en claro, porque así lo exigen esos formatos para que otras apps los lean. El cifrado de extremo a extremo entre dispositivos llegará con el servidor zero-knowledge.

## Pruebas

```bash
cd core
cargo test                                   # unitarias e integración
# CalDAV contra un servidor real (Radicale):
pip install radicale
python -m radicale --server-hosts 127.0.0.1:5232 --auth-type none --storage-filesystem-folder /tmp/col &
CALDAV_TEST_URL=http://127.0.0.1:5232/ cargo test --test caldav
```

Son 26 pruebas. Cubren:

- cifrado y cambio de contraseña;
- recurrencias con cambio de horario y edición «solo esta» y «esta y las siguientes»;
- subtareas y listas inteligentes;
- archivo .ics enlazado y modificado por otro programa;
- copias cifradas;
- la API JSON completa;
- dos dispositivos sincronizando por CalDAV con cambios sin conexión y un conflicto.

## Estado y limitaciones conocidas

- **Verificado:** el núcleo Rust y sus pruebas, en Linux. El puente Dart ↔ Rust, ejecutado contra la biblioteca real. Todo el código Dart pasa `dart analyze` sin incidencias contra Flutter estable y window_manager 0.5. `tool/patch_runners.dart`, probado con las plantillas actuales de `flutter create`.
- **Pendiente de verificar en un equipo real:**
  - la compilación final de la app con `flutter build` (el flujo de GitHub Actions lo hace en los tres sistemas);
  - el anclaje de widgets en Windows 11 24H2 y macOS.
- **Linux con Wayland en GNOME:** los widgets no se pueden anclar al fondo (limitación del compositor); funcionan como ventanas normales.
- **Ventana principal:** la de Windows y Linux dibuja su propio semáforo; en macOS se usa el nativo.
- **Aún no implementado:** invitaciones a asistentes, varias zonas horarias en la vista.
- **CalDAV:** las ocurrencias modificadas de una serie (RECURRENCE-ID) que vienen del servidor se muestran, pero sus cambios locales no se suben por separado.

## Próximos pasos

1. **Servidor zero-knowledge.** Usará el mismo módulo de conectividad que CalDAV (`core/src/endpoints.rs`): varias direcciones por servidor (local, VPN…), prueba con tiempo de espera corto y rutas independientes del origen. El cliente ya guarda un registro ordenado de cambios (`changes`) y dispone del sobre cifrado de `backup.rs`, que servirán para subir solo blobs cifrados y sincronizar entre dispositivos.
2. **App móvil.** Flutter iOS/Android reutilizando el mismo núcleo Rust y gran parte de la interfaz.
