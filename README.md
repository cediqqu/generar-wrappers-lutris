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
| `-h`, `--help` | Muestra la ayuda. |

### Variables de entorno

| Variable | Por defecto | Descripción |
| --- | --- | --- |
| `WRAPPERS_DIR` | `~/Games/wrappers` | Directorio de salida de los wrappers. |
| `LUTRIS_GAMES_DIR` | autodetectado | Directorio de configs de Lutris (`games/`). |
| `LUTRIS_PGA_DB` | autodetectado | Ruta a `pga.db` (nombre real del juego). |
| `ORPHAN_ACTION` | `delete` | Qué hacer con el `compatdata` huérfano de Steam: `delete`, `backup` o `keep`. Se puede sobrescribir en cada wrapper al vuelo. |
| `SKIP_STEAM` | `1` | Omite los juegos del runner de Steam (no necesitan wrapper). Ponlo a `0` para incluirlos. |

Ejemplo:

```bash
WRAPPERS_DIR=~/steam-wrappers SKIP_STEAM=0 bash generar_wrappers_lutris.sh
```

## Añadir los wrappers a Steam

1. En Steam: **Añadir un juego → Añadir un producto no-Steam** y elige el
   wrapper generado (`~/Games/wrappers/<Juego>.sh`).
2. En las **Propiedades** de ese acceso directo, pestaña **Compatibilidad**,
   activa *Forzar el uso de una herramienta de compatibilidad concreta* y elige
   una versión de **Proton**.

> Importante: si un wrapper «no arranca», casi siempre es porque **no se le
> asignó una versión de Proton** al acceso directo. No es un fallo del script.

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
