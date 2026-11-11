# generar-wrappers-lutris

Genera un wrapper `.sh` por cada juego de **Lutris** y lo registra como acceso
directo no-Steam en **Steam**, para lanzarlo con **Proton** reutilizando el mismo
prefix de Wine que ya usa Lutris.

Así tus juegos de Lutris aparecen en Steam con overlay, mando y streaming, sin
duplicar el prefix ni reinstalar nada.

**Por qué no basta con un acceso directo normal.** Si añades el `.exe` del juego
como acceso no-Steam, Proton le crea un prefix nuevo y todo lo que Lutris ya
tenía configurado se queda atrás: overrides de DLL, dependencias y los saves que
viven dentro del prefix. Y reutilizar el prefix de Lutris a mano choca con que
Proton espera `pfx/drive_c` donde Lutris tiene `drive_c` en la raíz. Este script
hace las dos cosas, y además toma el `exe` y el `working_dir` del YAML de Lutris
para que no escribas rutas.

Si te basta con lanzar el juego desde Lutris, o quieres que corra con el Wine de
Lutris en vez del Proton de Steam, este script no te sirve. Tampoco sirve para
juegos nativos de Linux: el wrapper siempre lanza con Proton.

Estado: script personal, sin tests automatizados, sin CI y sin releases. No hay
compromiso de soporte ni de compatibilidad con versiones futuras de Lutris o
Steam. La actividad, si te interesa, está en el
[historial de commits](https://github.com/cediqqu/generar-wrappers-lutris/commits/main).

## Requisitos

- **Bash 5**: usa arrays asociativos, `%q` y `${var,,}`.
- **`sqlite3`**: lee el nombre real del juego desde `pga.db`. Si falta, usa el
  `name:` del YAML o el nombre de fichero.
- **`python3`**: solo para la integración con Steam, porque `shortcuts.vdf` es
  un VDF binario y Bash no puede manipular bytes NUL. Sin `python3` el script
  avisa y omite los accesos directos, pero genera los wrappers.
- **Lutris** con los juegos ya configurados.
- **Steam + Proton** para lanzar los wrappers.

## Uso

```bash
git clone https://github.com/cediqqu/generar-wrappers-lutris.git
cd generar-wrappers-lutris
bash generar_wrappers_lutris.sh --dry-run   # previsualiza sin escribir nada
bash generar_wrappers_lutris.sh             # wrappers + accesos directos en Steam
bash generar_wrappers_lutris.sh --help      # ayuda
```

> [!NOTE]
> Si el repo está en un montaje `noexec`, invócalo con `bash` como arriba, no
> con `./generar_wrappers_lutris.sh`. Los wrappers generados sí son ejecutables.

Salida esperada de una primera ejecución:

```
✅ Creado: '/home/deck/Games/wrappers/BioShock Remastered.sh'
   Ejecutable: /home/deck/Games/bioshock-remastered/drive_c/GOG Games/BioShock/BIOSHOCK.EXE
   Prefix:     /home/deck/Games/bioshock-remastered
Accesos directos: 1 añadidos, 0 eliminados.
```

### Opciones

| Opción | Descripción |
| --- | --- |
| `-n`, `--dry-run` | Muestra `config -> slug -> nombre` y qué se podaría, sin generar nada ni tocar Steam. |
| `--add-to-steam` | Fuerza la sincronización de accesos directos (ya es el comportamiento por defecto). |
| `--no-add-to-steam` | No tocar Steam; solo generar wrappers. |
| `--no-steam-restart` | Si Steam está abierto, avisar y saltar en vez de cerrarlo y reabrirlo. |
| `--force-close-steam` | Si el cierre ordenado de Steam falla, forzarlo con `pkill`. |
| `--prune` | Borra los wrappers huérfanos y sus accesos directos en Steam. |
| `-h`, `--help` | Muestra la ayuda. |

### Variables de entorno

| Variable | Por defecto | Descripción |
| --- | --- | --- |
| `WRAPPERS_DIR` | `~/Games/wrappers` | Directorio de salida de los wrappers. |
| `LUTRIS_GAMES_DIR` | autodetectado | Directorio de configs de Lutris (`games/`). |
| `LUTRIS_PGA_DB` | autodetectado | Ruta a `pga.db` (nombre real del juego). |
| `ORPHAN_ACTION` | `delete` | Qué hacer con el `compatdata` huérfano de Steam: `delete`, `backup` o `keep`. Se puede sobrescribir en una ejecución concreta exportando `ORPHAN_ACTION`. |
| `SKIP_STEAM` | `1` | Omite los juegos del runner de Steam (no necesitan wrapper). `0` para incluirlos. |
| `ADD_TO_STEAM` | `1` | Sincronizar los accesos directos en Steam. `0` para desactivarlo. |
| `STEAM_RESTART` | `1` | Cerrar y reabrir Steam si está abierto. `0` para avisar y saltar. |
| `STEAM_SHUTDOWN_TIMEOUT` | `30` | Segundos de espera máxima al cerrar Steam. |
| `STEAM_START_TIMEOUT` | `30` | Segundos de espera máxima al reabrir Steam. |
| `STEAM_DIR` | autodetectado | Raíz de Steam. |
| `STEAM_USERDATA` | autodetectado | Directorio `userdata/<id>` a usar si tienes varias cuentas. Por defecto elige la cuenta con el `shortcuts.vdf` más reciente. |

Ejemplos:

```bash
# Solo generar wrappers, sin tocar Steam
ADD_TO_STEAM=0 bash generar_wrappers_lutris.sh

# Otro directorio de salida e incluir los juegos del runner de Steam
WRAPPERS_DIR=~/steam-wrappers SKIP_STEAM=0 bash generar_wrappers_lutris.sh
```

## Cómo funciona

1. Escanea las configs de Lutris (`.../lutris/games/*.yml`) y autodetecta si es
   Flatpak o instalación nativa.
2. Resuelve el nombre del juego desde `pga.db`. Los YAML de Lutris no guardan el
   nombre de pantalla, así que empareja por **slug**, que es el nombre de fichero
   sin el `-<config_id>` final (ese número **no** es el `id` de la base de datos).
3. Escribe un wrapper por juego que:
   - apunta `STEAM_COMPAT_DATA_PATH` al prefix de Lutris,
   - crea el enlace `pfx -> .` dentro del prefix, porque Proton espera
     `pfx/drive_c` y los prefixes de Lutris tienen `drive_c` en la raíz,
   - resuelve `exe` y `working_dir`, incluidas rutas `C:\...` y `Z:`,
   - lanza el juego con `proton run`.
4. Gestiona el `compatdata` huérfano que Steam crea para el acceso directo,
   según `ORPHAN_ACTION`.
5. Sincroniza los accesos directos en `shortcuts.vdf`.

Los wrappers están pensados para **ejecutarse desde Steam**: necesitan
`STEAM_COMPAT_TOOL_PATHS`, así que si los lanzas a mano desde una terminal
fallan a propósito.

## Accesos directos en Steam

Está activa por defecto. El script escribe en
`<steam>/userdata/<id>/config/shortcuts.vdf` y guarda una copia
`shortcuts.vdf.bak` antes de modificar nada. Para revertir, renombra el `.bak`
sobre el `.vdf`.

- **No duplica.** Considera que un juego ya tiene acceso si algún wrapper
  aparece en su `Exe` **o** en sus opciones de lanzamiento, lo que también cubre
  los accesos creados por Steam ROM Manager (que usa `/bin/bash` + el wrapper).
  Tampoco añade un segundo acceso con el mismo nombre.
- **No pisa lo existente.** En los accesos que ya existen solo añade el token de
  Lutris (ver más abajo); no cambia `AppName` ni `Exe`, así que tu carátula y tu
  versión de Proton se conservan.
- **Solo toca Steam si hay cambios.** Primero hace una pasada de solo lectura; si
  no hay nada que añadir ni quitar, termina sin cerrar Steam.
- **Si Steam está abierto**, lo cierra, escribe y lo vuelve a abrir con
  `steam -silent`, verificando que arranca. La salida de Steam se registra en
  `${XDG_CACHE_HOME:-~/.cache}/generar_wrappers/steam-restart.log`.
- **Si hay un juego en ejecución**, no cierra Steam y te avisa.
- **Si el cierre ordenado no termina** en `STEAM_SHUTDOWN_TIMEOUT` segundos,
  aborta sin escribir nada. Usa `--force-close-steam` para forzarlo con `pkill`.
- **Si no encuentra Steam**, omite este paso en silencio.

> [!IMPORTANT]
> El script no asigna Proton por ti. Cada acceso directo nuevo necesita una
> versión de Proton en **Propiedades → Compatibilidad → Forzar el uso de una
> herramienta de compatibilidad concreta**. Si un wrapper «no arranca», casi
> siempre es eso.

### Plugin Panel de Control (Hooandee)

Cada acceso directo recibe en sus opciones de lanzamiento el token
`lutris:rungameid/<id>`, con el `id` real de `pga.db`. Sin ese token, la sección
**Escaladores** del plugin trata el `.sh` como juego nativo de Linux y no ofrece
opciones; con él, toma la ruta de Lutris.

El token nunca llega al juego: el wrapper lo descarta antes de llamar a Proton.
Además, el wrapper lee `wine -> overrides` del YAML de Lutris y lo exporta como
`WINEDLLOVERRIDES`, porque el plugin escribe ahí el override del escalador y
Proton, sin pasar por Lutris, lo ignoraría.

El token también se añade a los accesos que ya existían, sin tocar sus demás
opciones de lanzamiento.

### Añadir el acceso a mano

Si prefieres no dejar que el script toque Steam:

1. En Steam, **Añadir un juego → Añadir un producto no-Steam** y elige el
   wrapper generado (`~/Games/wrappers/<Juego>.sh`).
2. Asigna una versión de Proton como se indica arriba.

## Eliminar wrappers huérfanos

Si borras un juego en Lutris, su wrapper queda huérfano.

```bash
bash generar_wrappers_lutris.sh --prune
```

Borra los wrappers gestionados cuya config de Lutris ya no existe y sus accesos
directos en Steam. Los `.sh` sin la marca `# Lutris config:` son tuyos y no se
tocan. Si no se pudo escanear el directorio de configs, no se poda nada.

No hace falta cerrar Steam a mano: si está abierto, el script lo cierra y lo
reabre igual que en una ejecución normal. Combínalo con `--dry-run` para ver qué
se borraría.

## Regenerar wrappers

Cada wrapper incluye una marca con su config de origen:

```
# Lutris config: <fichero>.yml
```

Si esa config ya tiene wrapper, el script no lo regenera. Para forzar la
regeneración, borra el wrapper y vuelve a ejecutar el script.

## Compatibilidad

- Pensado para **SteamOS**, **Steam Deck** y **Rog Xbox Ally X**, y en general
  para cualquier Linux con Steam + Proton.
- Detecta Lutris en Flatpak (`~/.var/app/net.lutris.Lutris/...`) y en
  instalación nativa (`~/.local/share/lutris`, `~/.config/lutris`).
- Detecta Steam en `~/.local/share/Steam`, `~/.steam/steam`, `~/.steam/root` y
  en Flatpak (`~/.var/app/com.valvesoftware.Steam/...`).

Licencia: [MIT](LICENSE).
