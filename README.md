# generar-wrappers-lutris

Script en Bash que genera un *wrapper* `.sh` por cada juego de **Lutris** para
poder lanzarlo desde **Steam** con **Proton**, reutilizando el mismo prefix de
Wine que ya usa Lutris.

Así puedes añadir tus juegos de Lutris como accesos directos (no-Steam) en Steam,
aprovechando sus funciones (overlay, mando, streaming, etc.) sin duplicar el
prefix ni reinstalar el juego.

## Cómo funciona

1. **Escanea las configs de Lutris** (`.../lutris/games/*.yml`). Autodetecta
   instalaciones Flatpak y nativas.
2. **Obtiene el nombre real del juego** desde la base de datos de Lutris
   (`pga.db`, tabla `games`). Los YAML de Lutris *no* contienen el nombre de
   pantalla, solo un `config_id`; por eso se empareja por **slug**
   (nombre de fichero sin el `-<config_id>` final).
3. **Escribe un wrapper por juego** en el directorio de salida. Cada wrapper:
   - apunta `STEAM_COMPAT_DATA_PATH` al prefix de Lutris,
   - crea el enlace `pfx -> .` dentro del prefix (Proton espera `pfx/drive_c`,
     mientras que los prefixes de Lutris tienen `drive_c` en la raíz),
   - resuelve el `exe` y el `working_dir` (incluidas rutas tipo `C:\...`),
   - lanza el juego con `proton run`.
4. **Gestiona el `compatdata` huérfano** que Steam crea para el acceso directo:
   el wrapper reutiliza el prefix de Lutris y puede borrar, respaldar o
   conservar ese `.../steamapps/compatdata/<appid>` que queda inservible.
5. **Sincroniza con Steam** (por defecto): crea el acceso directo no-Steam de
   cada wrapper en `shortcuts.vdf`; si Steam está abierto, lo cierra y lo
   reabre. Con `--prune` limpia los wrappers y accesos directos de juegos que ya
   no están en Lutris. Desactívalo con `--no-add-to-steam`.

Los wrappers están pensados para **ejecutarse desde Steam**: necesitan
`STEAM_COMPAT_TOOL_PATHS`, así que si los lanzas a mano desde una terminal
fallarán a propósito.

## Requisitos

- **Bash 5** (usa arrays asociativos, `%q` y `${var,,}`).
- **`sqlite3`** para leer el nombre del juego desde `pga.db` (si falta, el script
  hace *fallback* al `name:` del YAML o al nombre de fichero).
- **Lutris** instalado (Flatpak o nativo) con los juegos ya configurados.
- **Steam + Proton** para lanzar los wrappers generados.

## Uso

```bash
bash generar_wrappers_lutris.sh            # genera los wrappers
bash generar_wrappers_lutris.sh --dry-run  # previsualiza sin escribir nada
bash generar_wrappers_lutris.sh --help     # ayuda
```

> Nota: si el repo está en un montaje `noexec`, invócalo con `bash` (como
> arriba) en lugar de `./generar_wrappers_lutris.sh`. Los wrappers generados sí
> son ejecutables.

### Opciones

| Opción | Descripción |
| --- | --- |
| `-n`, `--dry-run` | Muestra `config -> slug -> nombre` sin generar nada. |
| `--add-to-steam` | Fuerza añadir/actualizar los accesos directos (ya es el comportamiento por defecto). |
| `--no-add-to-steam` | No tocar Steam; solo generar wrappers. |
| `--no-steam-restart` | Si Steam está abierto, avisar y saltar en vez de cerrarlo y reabrirlo. |
| `--force-close-steam` | Si el cierre ordenado de Steam falla, forzarlo con `pkill`. |
| `--prune` | Borra los wrappers huérfanos (su config de Lutris ya no existe) y sus accesos directos en Steam. |
| `-h`, `--help` | Muestra la ayuda. |

### Variables de entorno

| Variable | Por defecto | Descripción |
| --- | --- | --- |
| `WRAPPERS_DIR` | `~/Games/wrappers` | Directorio de salida de los wrappers. |
| `LUTRIS_GAMES_DIR` | autodetectado | Directorio de configs de Lutris (`games/`). |
| `LUTRIS_PGA_DB` | autodetectado | Ruta a `pga.db` (nombre real del juego). |
| `ORPHAN_ACTION` | `delete` | Qué hacer con el `compatdata` huérfano de Steam: `delete`, `backup` o `keep`. Se puede sobrescribir en cada wrapper al vuelo. |
| `SKIP_STEAM` | `1` | Omite los juegos del runner de Steam (no necesitan wrapper). Ponlo a `0` para incluirlos. |
| `ADD_TO_STEAM` | `1` | Sincronizar los accesos directos en Steam. `0` para desactivarlo. |
| `STEAM_RESTART` | `1` | Cerrar y reabrir Steam si está abierto. `0` para avisar y saltar. |
| `STEAM_SHUTDOWN_TIMEOUT` | `30` | Segundos de espera máxima al cerrar Steam. |
| `STEAM_START_TIMEOUT` | `30` | Segundos de espera máxima al reabrir Steam. |
| `STEAM_DIR` | autodetectado | Raíz de Steam (por defecto: se busca en `~/.local/share/Steam`, Flatpak, etc.). |
| `STEAM_USERDATA` | autodetectado | Directorio `userdata/<id>` de Steam a usar (si tienes varias cuentas). |

Ejemplo:

```bash
WRAPPERS_DIR=~/steam-wrappers SKIP_STEAM=0 bash generar_wrappers_lutris.sh
```

## Accesos directos en Steam (automático)

Por defecto, al ejecutar el script se crean/actualizan los accesos directos
no-Steam apuntando a `~/Games/wrappers/<Juego>.sh`, con el nombre real del
juego. **No duplica**: si un juego ya tiene un acceso (aunque sea de Steam ROM
Manager, que usa `/bin/bash` + el wrapper como opción de lanzamiento) o ya existe
otro con el mismo nombre, no añade nada. Antes de escribir guarda
`shortcuts.vdf.bak`.

```bash
bash generar_wrappers_lutris.sh          # genera wrappers + sincroniza Steam
```

Si Steam está abierto, el script lo **cierra**, escribe y lo **vuelve a abrir**
con `steam -silent` —solo si hay cambios que aplicar; si no hay nada que hacer,
no toca Steam—. Verifica que arranca y, si no, te avisa y deja la salida de Steam
en `~/.cache/generar_wrappers/steam-restart.log`.

- `--no-add-to-steam`: no tocar Steam (solo generar wrappers).
- `--no-steam-restart`: si Steam está abierto, avisar y saltar (no reiniciar).
- `--force-close-steam`: forzar el cierre con `pkill` si el ordenado falla.
- `STEAM_SHUTDOWN_TIMEOUT` / `STEAM_START_TIMEOUT`: segundos de espera (30 por defecto).

Si detecta un **juego en ejecución**, no cierra Steam y avisa. Si Steam no está
instalado, este paso se omite en silencio.

**Manual** (alternativa):

1. En Steam: **Añadir un juego → Añadir un producto no-Steam** y elige el
   wrapper generado (`~/Games/wrappers/<Juego>.sh`).

En ambos casos, elige en las **Propiedades** del acceso directo, pestaña
**Compatibilidad**, *Forzar el uso de una herramienta de compatibilidad
concreta* y una versión de **Proton**. El script **no** asigna Proton por ti.

> Importante: si un wrapper «no arranca», casi siempre es porque **no se le
> asignó una versión de Proton** al acceso directo. No es un fallo del script.

## Eliminar wrappers y accesos directos huérfanos

Si borras un juego en Lutris, su wrapper queda huérfano. Con Steam **cerrado**:

```bash
bash generar_wrappers_lutris.sh --prune
```

Borra los wrappers cuya config de Lutris ya no existe (los identifica por la
marca `# Lutris config:`) y sus accesos directos en Steam. Los `.sh` sin esa
marca no se tocan. Si no se localiza el directorio de configs de Lutris, no se
poda nada.

## Regenerar wrappers

Cada wrapper incluye una marca con su config de origen:

```
# Lutris config: <fichero>.yml
```

Si esa config ya tiene wrapper, el script **no lo regenera**. Para forzar la
regeneración, borra el wrapper y vuelve a ejecutar el script.

## Compatibilidad

- Pensado para **SteamOS / Steam Deck / Rog Xbox Ally X** y en general para
  cualquier Linux con Steam + Proton.
- Detecta Lutris en Flatpak (`~/.var/app/net.lutris.Lutris/...`) y en
  instalación nativa (`~/.local/share/lutris`, `~/.config/lutris`).

## Licencia

[MIT](LICENSE) © 2026 César Díaz Cueva
