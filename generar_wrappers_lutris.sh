#!/usr/bin/env bash

# Generador de wrappers para Lutris -> Steam mediante Proton

set -Eeuo pipefail
shopt -s nullglob

# Directorio de salida de los wrappers (vacío = ~/Games/wrappers).
# Se puede forzar con: WRAPPERS_DIR=/ruta/a/wrappers ./generar_wrappers_lutris.sh
WRAPPERS_DIR="${WRAPPERS_DIR:-${HOME}/Games/wrappers}"

# Directorio de configuraciones de Lutris (vacío = autodetectar).
# Se puede forzar con: LUTRIS_GAMES_DIR=/ruta/a/games ./generar_wrappers_lutris.sh
LUTRIS_GAMES_DIR="${LUTRIS_GAMES_DIR:-}"

# Política para el compatdata de Steam que queda huérfano al reutilizar el
# prefix de Lutris. Valores: delete (borrar) | backup (mover a *.orphan-backup)
# | keep (no tocar). El wrapper permite sobrescribirlo en tiempo de ejecución.
ORPHAN_ACTION="${ORPHAN_ACTION:-delete}"

# Base de datos de Lutris (vacío = autodetectar junto a las configs).
# Se puede forzar con: LUTRIS_PGA_DB=/ruta/a/pga.db
LUTRIS_PGA_DB="${LUTRIS_PGA_DB:-}"

# Omitir los juegos lanzados por el runner de Steam (no necesitan wrapper).
# Poner a 0 para volver a incluirlos.
SKIP_STEAM="${SKIP_STEAM:-1}"

# Añadir/actualizar los accesos directos no-Steam en Steam (shortcuts.vdf).
# Activo por defecto; desactívalo con --no-add-to-steam o ADD_TO_STEAM=0.
ADD_TO_STEAM="${ADD_TO_STEAM:-1}"

# Si Steam está abierto, cerrarlo y reabrirlo para escribir los accesos.
# STEAM_RESTART=0 (o --no-steam-restart) avisa y no toca Steam.
STEAM_RESTART="${STEAM_RESTART:-1}"

# Segundos máximos a esperar a que Steam termine de cerrarse.
STEAM_SHUTDOWN_TIMEOUT="${STEAM_SHUTDOWN_TIMEOUT:-30}"

# Segundos máximos a esperar a que Steam vuelva a arrancar.
STEAM_START_TIMEOUT="${STEAM_START_TIMEOUT:-30}"

# Si el cierre ordenado falla: 0 = abortar (por defecto), 1 = forzar (pkill).
FORCE_CLOSE_STEAM=0

# Borrar wrappers huérfanos (cuya config de Lutris ya no existe) y sus
# accesos directos en Steam. Opt-in.
PRUNE=0

# Modo de prueba: solo mostrar los nombres resueltos, sin generar wrappers.
DRY_RUN=0

while (($#)); do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=1
            ;;
        --add-to-steam)
            ADD_TO_STEAM=1
            ;;
        --no-add-to-steam)
            ADD_TO_STEAM=0
            ;;
        --no-steam-restart)
            STEAM_RESTART=0
            ;;
        --force-close-steam)
            FORCE_CLOSE_STEAM=1
            ;;
        --prune)
            PRUNE=1
            ;;
        -h|--help)
            cat <<'USAGE'
Uso: generar_wrappers_lutris.sh [opciones]

Genera un wrapper por cada juego de Lutris para lanzarlo desde Steam/Proton.

Por defecto también crea/actualiza el acceso directo no-Steam en Steam; si Steam
está abierto, lo cierra y lo vuelve a abrir para escribir los cambios.

Opciones:
  -n, --dry-run        Muestra config -> slug -> nombre sin generar nada.
      --add-to-steam   Fuerza añadir/actualizar los accesos directos (por defecto).
      --no-add-to-steam  No tocar Steam.
      --no-steam-restart  Si Steam está abierto, avisar y saltar (no reiniciar).
      --force-close-steam Si el cierre ordenado falla, forzar con pkill.
      --prune          Borra wrappers huérfanos (su config de Lutris ya no
                       existe) y sus accesos directos en Steam.
  -h, --help           Muestra esta ayuda.

Variables de entorno:
  WRAPPERS_DIR      Directorio de salida (por defecto ~/Games/wrappers).
  LUTRIS_GAMES_DIR  Directorio de configs de Lutris (games/).
  LUTRIS_PGA_DB     Ruta de pga.db (contiene el nombre real del juego).
  ORPHAN_ACTION     delete | backup | keep (compatdata huérfano de Steam).
  SKIP_STEAM        Omitir juegos del runner de Steam (1=omitir, 0=incluir).
  ADD_TO_STEAM      1 (por defecto) | 0.
  STEAM_RESTART     1 (por defecto) | 0.
  STEAM_SHUTDOWN_TIMEOUT  Segundos de espera al cerrar Steam (por defecto 30).
  STEAM_START_TIMEOUT     Segundos de espera al reabrir Steam (por defecto 30).
  STEAM_DIR         Raíz de Steam (por defecto: autodetectada).
  STEAM_USERDATA    Directorio userdata/<id> de Steam (por defecto: autodetectado).
USAGE
            exit 0
            ;;
        *)
            echo "Opción desconocida: $1" >&2
            exit 1
            ;;
    esac
    shift
done

mkdir -p -- "$WRAPPERS_DIR"

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

# Localiza el directorio de configs de Lutris (Flatpak o instalación nativa).
detect_lutris_games_dir() {
    if [[ -n "$LUTRIS_GAMES_DIR" ]]; then
        printf '%s\n' "$LUTRIS_GAMES_DIR"
        return 0
    fi

    local candidate
    for candidate in \
        "${HOME}/.var/app/net.lutris.Lutris/data/lutris/games" \
        "${HOME}/.var/app/net.lutris.Lutris/config/lutris/games" \
        "${HOME}/.local/share/lutris/games" \
        "${HOME}/.config/lutris/games"; do
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# Localiza pga.db (base de datos de Lutris, contiene el nombre real del juego).
find_lutris_db() {
    if [[ -n "$LUTRIS_PGA_DB" ]]; then
        printf '%s\n' "$LUTRIS_PGA_DB"
        return 0
    fi

    local candidate
    for candidate in \
        "$(dirname -- "$LUTRIS_CONF_DIR")/pga.db" \
        "${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db" \
        "${HOME}/.var/app/net.lutris.Lutris/config/lutris/pga.db" \
        "${HOME}/.local/share/lutris/pga.db" \
        "${HOME}/.config/lutris/pga.db"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# Deriva el slug del filename de una config: <slug>-<config_id>.yml -> <slug>.
config_slug() {
    local base="$1"

    if [[ "$base" =~ ^(.+)-[0-9]+$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "$base"
    fi
}

# Carga los mapas slug -> nombre y slug -> runner desde pga.db (una consulta).
declare -A LUTRIS_NAMES=()
declare -A LUTRIS_RUNNERS=()
lutris_load_names() {
    local db="$1"
    local slug name runner output

    command -v sqlite3 >/dev/null 2>&1 || return 1
    [[ -f "$db" ]] || return 1

    LUTRIS_NAMES=()
    LUTRIS_RUNNERS=()

    # Primero intenta leer también el runner; si la columna no existe, reintenta.
    if output="$(sqlite3 -separator $'\t' "$db" \
        "SELECT slug, name, runner FROM games WHERE slug IS NOT NULL AND name IS NOT NULL;" 2>/dev/null)"; then
        while IFS=$'\t' read -r slug name runner; do
            [[ -n "$slug" ]] || continue
            LUTRIS_NAMES["$slug"]="$name"
            LUTRIS_RUNNERS["$slug"]="$runner"
        done <<< "$output"
    else
        output="$(sqlite3 -separator $'\t' "$db" \
            "SELECT slug, name FROM games WHERE slug IS NOT NULL AND name IS NOT NULL;" 2>/dev/null || true)"
        while IFS=$'\t' read -r slug name; do
            [[ -n "$slug" ]] || continue
            LUTRIS_NAMES["$slug"]="$name"
        done <<< "$output"
    fi

    [[ ${#LUTRIS_NAMES[@]} -gt 0 ]]
}

# Extrae el valor de una clave (posiblemente multilínea) de un bloque YAML.
extract_yaml_value() {
    local key="$1"
    local block="$2"

    awk -v wanted="$key" '
        /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:/ {
            line = $0
            key_name = line
            sub(/^[[:space:]]*/, "", key_name)
            sub(/:.*/, "", key_name)

            value = line
            sub(/^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*/, "", value)

            if (key_name == wanted) {
                reading = 1
                result = value
            } else {
                reading = 0
            }
            next
        }

        reading {
            sub(/^[[:space:]]+/, "", $0)
            result = result " " $0
        }

        END { print result }
    ' <<< "$block" |
        sed \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' \
            -e 's/^"//' \
            -e 's/"$//' \
            -e "s/^'//" \
            -e "s/'$//"
}

# Extrae el valor de una clave de primer nivel (sin indentación) de un fichero.
yaml_top_level_value() {
    local key="$1"
    local file="$2"

    awk -v wanted="$key" '
        $0 ~ "^" wanted ":[[:space:]]*" {
            line = $0
            sub("^" wanted ":[[:space:]]*", "", line)
            sub(/[[:space:]]+$/, "", line)
            sub(/^"/, "", line)
            sub(/"$/, "", line)
            print line
            exit
        }
    ' "$file"
}

# Ajusta un nombre de juego para usarlo como nombre de fichero, conservando el
# texto original (mayúsculas incluidas); solo neutraliza lo ilegal.
sanitize_name() {
    printf '%s\n' "$1" | tr -d '\000-\037' | sed \
        -e 's#/#-#g' \
        -e 's/^[[:space:]]*//' \
        -e 's/[[:space:]]*$//'
}

# Expande "~" y "~/" al HOME del usuario.
expand_home() {
    local value="$1"

    if [[ "$value" == "~" ]]; then
        printf '%s\n' "$HOME"
    elif [[ "$value" == \~/* ]]; then
        printf '%s/%s\n' "$HOME" "${value#\~/}"
    else
        printf '%s\n' "$value"
    fi
}

# Resuelve una ruta del juego a una ruta absoluta de Linux.
# - Rutas con unidad Windows (C:\..., C:/...) se mapean a drive_c (Z: -> /).
# - Rutas absolutas Unix se respetan tal cual.
# - Rutas relativas se resuelven contra el prefix.
resolve_game_path() {
    local value="$1"
    local prefix="$2"

    [[ -n "$value" ]] || return 0

    if [[ "$value" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        local rest="${BASH_REMATCH[2]//\\//}"
        local base

        if [[ "$drive" == "z" ]]; then
            base=""
        else
            base="$prefix/drive_$drive"
        fi

        printf '%s/%s\n' "$base" "$rest"
    elif [[ "$value" == /* ]]; then
        printf '%s\n' "$value"
    else
        printf '%s/%s\n' "$prefix" "$value"
    fi
}

# Elimina los ficheros temporales si el script se interrumpe.
# Si cerramos Steam para escribir, intenta reabrirlo al salir (red de seguridad).
temp_wrapper=""
temp_py=""
STEAM_CLOSED_BY_US=0
STEAM_ROOT=""
STEAM_RESTART_LOG="${XDG_CACHE_HOME:-$HOME/.cache}/generar_wrappers/steam-restart.log"
cleanup() {
    if [[ -n "$temp_wrapper" && -e "$temp_wrapper" ]]; then
        rm -f -- "$temp_wrapper"
    fi
    if [[ -n "$temp_py" && -e "$temp_py" ]]; then
        rm -f -- "$temp_py"
    fi
    if ((STEAM_CLOSED_BY_US)); then
        printf 'Reabriendo Steam...\n' >&2
        steam_start 0 || true
        STEAM_CLOSED_BY_US=0
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

# ---------------------------------------------------------------------------
# Integración con Steam (accesos directos no-Steam / shortcuts.vdf)
# ---------------------------------------------------------------------------

# Localiza la raíz de Steam (nativa o Flatpak).
detect_steam_root() {
    local candidate
    if [[ -n "${STEAM_DIR:-}" ]]; then
        printf '%s\n' "$STEAM_DIR"
        return 0
    fi

    for candidate in \
        "${HOME}/.local/share/Steam" \
        "${HOME}/.steam/steam" \
        "${HOME}/.steam/root" \
        "${HOME}/.var/app/com.valvesoftware.Steam/data/Steam" \
        "${HOME}/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        if [[ -d "$candidate/userdata" || -d "$candidate/config" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# Localiza el directorio userdata/<SteamID3> que contiene shortcuts.vdf.
detect_steam_userdata() {
    local root="$1"
    local dir best="" best_mtime=-1 mtime

    if [[ -n "${STEAM_USERDATA:-}" ]]; then
        printf '%s\n' "${STEAM_USERDATA%/}"
        return 0
    fi

    for dir in "$root"/userdata/*/; do
        [[ -d "$dir/config" ]] || continue
        if [[ -f "$dir/config/shortcuts.vdf" ]]; then
            mtime="$(stat -c %Y -- "$dir/config/shortcuts.vdf" 2>/dev/null || echo 0)"
            if ((mtime > best_mtime)); then
                best="$dir"
                best_mtime="$mtime"
            fi
        fi
    done

    if [[ -n "$best" ]]; then
        printf '%s\n' "${best%/}"
        return 0
    fi

    # Sin shortcuts.vdf todavía: usa la primera cuenta con directorio config/.
    for dir in "$root"/userdata/*/; do
        [[ -d "$dir/config" ]] || continue
        printf '%s\n' "${dir%/}"
        return 0
    done

    return 1
}

# Comprueba si Steam está en ejecución (debe cerrarse antes de escribir VDF).
steam_is_running() {
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x steam >/dev/null 2>&1 && return 0
        pgrep -x steamwebhelper >/dev/null 2>&1 && return 0
    fi
    # Fallback sin pgrep: inspeccionar la lista de procesos.
    # shellcheck disable=SC2009
    ps -e -o comm= 2>/dev/null | grep -qxE 'steam|steamwebhelper' && return 0
    return 1
}

# ¿Steam instalado como Flatpak? (se deduce de la ruta de su raíz).
steam_is_flatpak() {
    case "$1" in
        *com.valvesoftware.Steam*) return 0 ;;
        *) return 1 ;;
    esac
}

# Comprueba, de forma heurística, si hay un juego en ejecución.
game_is_running() {
    local names='reaper|pressure-vessel|proton|wine|wine64|wineserver|gamescope'
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x reaper >/dev/null 2>&1 && return 0
        pgrep -x pressure-vessel >/dev/null 2>&1 && return 0
        pgrep -x wineserver >/dev/null 2>&1 && return 0
        pgrep -x proton >/dev/null 2>&1 && return 0
        pgrep -x gamescope >/dev/null 2>&1 && return 0
    fi
    # shellcheck disable=SC2009
    ps -e -o comm= 2>/dev/null | grep -qxE "$names" && return 0
    return 1
}

# Arranca Steam desacoplado del script (sobrevive a su salida) y, si se pide,
# verifica que arranca. Guarda la salida en un log para diagnosticar fallos.
# Uso: steam_start [esperar]   (esperar=1 por defecto; 0 no verifica).
steam_start() {
    local wait="${1:-1}"
    local root="${STEAM_ROOT:-}"
    local bin="" waited=0

    mkdir -p -- "$(dirname -- "$STEAM_RESTART_LOG")" 2>/dev/null || true

    if [[ -n "$root" ]] && steam_is_flatpak "$root"; then
        setsid flatpak run com.valvesoftware.Steam >>"$STEAM_RESTART_LOG" 2>&1 </dev/null &
        disown 2>/dev/null || true
    else
        if command -v steam >/dev/null 2>&1; then
            bin="steam"
        elif [[ -n "$root" && -x "$root/steam.sh" ]]; then
            bin="$root/steam.sh"
        elif [[ -n "$root" && -x "$root/steam" ]]; then
            bin="$root/steam"
        fi

        if [[ -z "$bin" ]]; then
            printf 'Aviso: no se encontró el ejecutable de Steam para reabrirlo.\n' >&2
            return 1
        fi

        # Igual que Steam ROM Manager: arrancar en modo silencioso.
        setsid "$bin" -silent >>"$STEAM_RESTART_LOG" 2>&1 </dev/null &
        disown 2>/dev/null || true
    fi

    if ((!wait)); then
        return 0
    fi

    # Verificar que realmente arranca.
    while ((waited < STEAM_START_TIMEOUT)); do
        if steam_is_running; then
            return 0
        fi
        sleep 1
        ((waited+=1))
    done
    return 1
}

# Ordena a Steam cerrarse y espera a que termine (máx. STEAM_SHUTDOWN_TIMEOUT).
steam_shutdown_and_wait() {
    local root="${STEAM_ROOT:-}" waited=0

    if [[ -n "$root" ]] && steam_is_flatpak "$root"; then
        setsid flatpak run com.valvesoftware.Steam -shutdown >/dev/null 2>&1 </dev/null || true
    else
        setsid steam -shutdown >/dev/null 2>&1 </dev/null || true
    fi

    while steam_is_running; do
        if ((waited >= STEAM_SHUTDOWN_TIMEOUT)); then
            return 1
        fi
        sleep 1
        ((waited+=1))
    done
    return 0
}

# Cierre forzado (solo con --force-close-steam).
steam_force_close() {
    local waited=0
    pkill -TERM -x steam >/dev/null 2>&1 || true
    pkill -TERM -x steamwebhelper >/dev/null 2>&1 || true
    while steam_is_running; do
        if ((waited >= 5)); then
            pkill -KILL -x steam >/dev/null 2>&1 || true
            pkill -KILL -x steamwebhelper >/dev/null 2>&1 || true
            sleep 1
            break
        fi
        sleep 1
        ((waited+=1))
    done
    ! steam_is_running
}

# Sincroniza los accesos directos no-Steam con los wrappers existentes.
# Solo actúa si hay cambios: si Steam está abierto, lo cierra, escribe y lo
# reabre. Requiere python3 (parser de VDF binario).
steam_shortcuts_sync() {
    if ((!ADD_TO_STEAM)) && ((!PRUNE)); then
        return 0
    fi

    local root userdata vdf add_flag prune_flag rc check_out added removed skipped closed
    if ! root="$(detect_steam_root)"; then
        return 0   # sin Steam: nada que hacer
    fi
    STEAM_ROOT="$root"

    if ! userdata="$(detect_steam_userdata "$root")"; then
        printf 'Aviso: no se encontró userdata de Steam; se omiten los accesos directos.\n' >&2
        return 0
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'Aviso: falta python3; se omiten los accesos directos de Steam.\n' >&2
        return 0
    fi

    vdf="$userdata/config/shortcuts.vdf"

    add_flag=0
    ((ADD_TO_STEAM)) && add_flag=1

    prune_flag=0
    if ((PRUNE)) && ((${#SCANNED_CONFIGS[@]} > 0)); then
        prune_flag=1
    fi

    temp_py="$(mktemp "${TMPDIR:-/tmp}/steam-shortcuts.XXXXXX.py")"
    cat > "$temp_py" <<'PYEOF'
import os
import shutil
import struct
import sys
import zlib

T_OBJECT = 0x00
T_STRING = 0x01
T_INT32 = 0x02
T_FLOAT32 = 0x03
T_POINTER = 0x04
T_WSTRING = 0x05
T_COLOR = 0x06
T_UINT64 = 0x07
T_END = 0x08
T_INT64 = 0x0A


def read_cstring(buf, i):
    j = buf.index(b"\x00", i)
    return buf[i:j].decode("utf-8", "surrogateescape"), j + 1


def parse_map(buf, i):
    obj = {}
    size = len(buf)
    while i < size:
        t = buf[i]
        i += 1
        if t == T_END:
            break
        key, i = read_cstring(buf, i)
        if t == T_OBJECT:
            val, i = parse_map(buf, i)
        elif t == T_STRING:
            val, i = read_cstring(buf, i)
        elif t == T_INT32:
            val = struct.unpack_from("<i", buf, i)[0]
            i += 4
        elif t == T_UINT64:
            val = struct.unpack_from("<Q", buf, i)[0]
            i += 8
        elif t == T_INT64:
            val = struct.unpack_from("<q", buf, i)[0]
            i += 8
        elif t == T_FLOAT32:
            val = struct.unpack_from("<f", buf, i)[0]
            i += 4
        elif t in (T_COLOR, T_POINTER):
            val = struct.unpack_from("<I", buf, i)[0]
            i += 4
        elif t == T_WSTRING:
            start = i
            while buf[i:i + 2] != b"\x00\x00":
                i += 2
            val = buf[start:i].decode("utf-16-le", "surrogateescape")
            i += 2
        else:
            raise ValueError("tipo VDF desconocido: 0x%02x" % t)
        obj[key] = (t, val)
    return obj, i


def write_map(out, obj):
    for key, (t, val) in obj.items():
        out.append(struct.pack("<B", t))
        out.append(key.encode("utf-8", "surrogateescape") + b"\x00")
        if t == T_OBJECT:
            write_map(out, val)
        elif t == T_STRING:
            out.append(val.encode("utf-8", "surrogateescape") + b"\x00")
        elif t == T_INT32:
            out.append(struct.pack("<i", val))
        elif t == T_UINT64:
            out.append(struct.pack("<Q", val))
        elif t == T_INT64:
            out.append(struct.pack("<q", val))
        elif t == T_FLOAT32:
            out.append(struct.pack("<f", val))
        elif t in (T_COLOR, T_POINTER):
            out.append(struct.pack("<I", val))
        elif t == T_WSTRING:
            out.append(val.encode("utf-16-le", "surrogateescape") + b"\x00\x00")
    out.append(b"\x08")


def shortcut_appid(exe, appname):
    crc = zlib.crc32((exe + appname).encode("utf-8", "surrogateescape")) & 0xFFFFFFFF
    appid = crc | 0x80000000
    return appid - 0x100000000 if appid >= 0x80000000 else appid


def get_exe(entry):
    for key in ("Exe", "exe"):
        if key in entry and entry[key][0] == T_STRING:
            return entry[key][1]
    return None


def get_appname(entry):
    for key in ("AppName", "appname"):
        if key in entry and entry[key][0] == T_STRING:
            return entry[key][1]
    return None


def referenced_paths(entry, wrap_dir):
    """Rutas de wrapper (dentro de WRAPPERS_DIR) citadas por el acceso directo.
    Las busca en 'Exe' y en 'LaunchOptions' (SRM usa /bin/bash + el wrapper
    como opción de lanzamiento)."""
    found = []
    exe = get_exe(entry)
    if exe is not None:
        path = os.path.abspath(exe.strip('"'))
        if path.startswith(wrap_dir + os.sep):
            found.append(path)

    for key in ("LaunchOptions", "launchoptions"):
        if key not in entry or entry[key][0] != T_STRING:
            continue
        s = entry[key][1]
        needle = wrap_dir + os.sep
        start = 0
        while True:
            i = s.find(needle, start)
            if i == -1:
                break
            if i > 0 and s[i - 1] == '"':
                j = s.find('"', i)
                j = len(s) if j == -1 else j
            else:
                j = i
                while j < len(s) and not s[j].isspace() and s[j] != '"':
                    j += 1
            path = os.path.abspath(s[i:j])
            if path.startswith(wrap_dir + os.sep):
                found.append(path)
            start = i + 1
    return found


def wrapper_name(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("# Wrapper autogenerado para:"):
                    return line.split(":", 1)[1].strip()
                if not line.startswith("#") and line.strip():
                    break
    except OSError:
        pass
    return os.path.splitext(os.path.basename(path))[0]


def wrapper_is_managed(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("# Lutris config:"):
                    return True
                if not line.startswith("#") and line.strip():
                    return False
    except OSError:
        return False
    return False


def new_entry(exe, name):
    quoted = '"%s"' % exe
    return {
        "appid": (T_INT32, shortcut_appid(quoted, name)),
        "AppName": (T_STRING, name),
        "Exe": (T_STRING, quoted),
        "StartDir": (T_STRING, '"%s"' % os.path.dirname(exe)),
        "icon": (T_STRING, ""),
        "ShortcutPath": (T_STRING, ""),
        "LaunchOptions": (T_STRING, ""),
        "IsHidden": (T_INT32, 0),
        "AllowDesktopConfig": (T_INT32, 1),
        "AllowOverlay": (T_INT32, 1),
        "OpenVR": (T_INT32, 0),
        "Devkit": (T_INT32, 0),
        "DevkitGameID": (T_STRING, ""),
        "LastPlayTime": (T_INT32, 0),
        "tags": (T_OBJECT, {}),
    }


def main():
    vdf, add_flag, prune_flag, wrappers_dir = sys.argv[1:5]
    write = len(sys.argv) <= 5 or sys.argv[5] != "check"
    add = add_flag == "1"
    prune = prune_flag == "1"
    wrap_dir = os.path.abspath(wrappers_dir)

    root = {}
    if os.path.exists(vdf) and os.path.getsize(vdf) > 0:
        with open(vdf, "rb") as fh:
            buf = fh.read()
        root, _ = parse_map(buf, 0)

    shortcuts = root.get("shortcuts", (T_OBJECT, {}))[1]

    # Wrappers gestionados por el script (con marca de Lutris) presentes en disco.
    desired = {}
    if os.path.isdir(wrap_dir):
        for name in sorted(os.listdir(wrap_dir)):
            if not name.endswith(".sh"):
                continue
            full = os.path.join(wrap_dir, name)
            if os.path.isfile(full) and wrapper_is_managed(full):
                desired[os.path.abspath(full)] = wrapper_name(full)

    # Un acceso está "gestionado" si cita un wrapper (en Exe o LaunchOptions).
    managed = []
    for idx, (t, entry) in list(shortcuts.items()):
        if t != T_OBJECT:
            continue
        paths = referenced_paths(entry, wrap_dir)
        if paths:
            managed.append((idx, paths))

    removed = 0
    if prune:
        for idx, paths in managed:
            # Se borra si ninguno de los wrappers citados existe ya en disco.
            if not any(os.path.exists(p) for p in paths):
                del shortcuts[idx]
                removed += 1

    # Wrappers que ya tienen acceso directo (según Exe/LaunchOptions).
    present = set()
    for _, (t, entry) in list(shortcuts.items()):
        if t != T_OBJECT:
            continue
        present.update(referenced_paths(entry, wrap_dir))

    # Nombres ya usados, para no duplicar accesos por nombre.
    existing_names = set()
    for _, (t, entry) in list(shortcuts.items()):
        if t != T_OBJECT:
            continue
        appname = get_appname(entry)
        if appname:
            existing_names.add(appname.strip().casefold())

    order = sorted(
        shortcuts.items(),
        key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0,
    )
    ordered = [entry for _, entry in order]

    added = 0
    skipped = 0
    if add:
        for exe_path, game_name in desired.items():
            if exe_path in present:
                continue
            key = game_name.strip().casefold()
            if key in existing_names:
                skipped += 1
                continue
            ordered.append((T_OBJECT, new_entry(exe_path, game_name)))
            existing_names.add(key)
            added += 1

    shortcuts = {str(n): entry for n, entry in enumerate(ordered)}
    root["shortcuts"] = (T_OBJECT, shortcuts)

    if not write:
        print("%d %d %d" % (added, removed, skipped))
        return

    if added == 0 and removed == 0:
        if skipped:
            print("Accesos directos: sin cambios (%d ya existían con ese nombre)." % skipped)
        else:
            print("Accesos directos: sin cambios.")
        return

    out = []
    write_map(out, root)
    data = b"".join(out)

    if os.path.exists(vdf):
        shutil.copy2(vdf, vdf + ".bak")

    tmp = vdf + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, vdf)

    msg = "Accesos directos: %d añadidos, %d eliminados." % (added, removed)
    if skipped:
        msg += " %d no añadidos (ya existían con ese nombre)." % skipped
    print(msg)


if __name__ == "__main__":
    main()
PYEOF

    # 1) ¿Hay cambios? Solo lectura, sin tocar Steam.
    check_out=""
    if ! check_out="$(python3 "$temp_py" "$vdf" "$add_flag" "$prune_flag" "$WRAPPERS_DIR" check 2>/dev/null)"; then
        printf 'Aviso: no se pudo analizar shortcuts.vdf; se omiten los accesos directos.\n' >&2
        rm -f -- "$temp_py"
        temp_py=""
        return 0
    fi
    read -r added removed skipped <<< "$check_out"
    added="${added:-0}"
    removed="${removed:-0}"
    skipped="${skipped:-0}"

    if [[ "$added" == "0" && "$removed" == "0" ]]; then
        if [[ "$skipped" != "0" ]]; then
            printf 'Accesos directos en Steam: sin cambios (%s ya existían con ese nombre).\n' "$skipped"
        else
            printf 'Accesos directos en Steam: sin cambios.\n'
        fi
        rm -f -- "$temp_py"
        temp_py=""
        return 0
    fi

    # 2) Si Steam está abierto, gestionar su ciclo de vida.
    closed=0
    if steam_is_running; then
        if ((!STEAM_RESTART)); then
            printf 'Aviso: Steam está abierto y el reinicio está desactivado' >&2
            printf ' (--no-steam-restart); se omiten los accesos directos.\n' >&2
            rm -f -- "$temp_py"
            temp_py=""
            return 0
        fi
        if game_is_running; then
            printf 'Aviso: parece haber un juego en ejecución; no se cierra Steam.' >&2
            printf ' Cierra el juego y vuelve a ejecutar.\n' >&2
            rm -f -- "$temp_py"
            temp_py=""
            return 0
        fi

        printf 'Cerrando Steam para escribir los accesos directos...\n'
        if ! steam_shutdown_and_wait; then
            if ((FORCE_CLOSE_STEAM)); then
                printf 'El cierre ordenado no terminó; forzando (--force-close-steam)...\n' >&2
                if ! steam_force_close; then
                    printf 'Error: no se pudo cerrar Steam; se aborta.\n' >&2
                    rm -f -- "$temp_py"
                    temp_py=""
                    return 1
                fi
            else
                printf 'Error: Steam no se cerró en %ss; se aborta sin tocar nada.\n' \
                    "$STEAM_SHUTDOWN_TIMEOUT" >&2
                printf 'Ciérralo a mano, o usa --force-close-steam.\n' >&2
                rm -f -- "$temp_py"
                temp_py=""
                return 1
            fi
        fi
        closed=1
        STEAM_CLOSED_BY_US=1
    fi

    # 3) Escribir los accesos directos.
    rc=0
    python3 "$temp_py" "$vdf" "$add_flag" "$prune_flag" "$WRAPPERS_DIR" || rc=$?
    rm -f -- "$temp_py"
    temp_py=""

    # 4) Reabrir Steam si lo cerramos nosotros.
    if ((closed)); then
        printf 'Reabriendo Steam...\n'
        if steam_start; then
            printf 'Steam reabierto.\n'
        else
            printf 'Aviso: no se pudo confirmar que Steam arrancase. Revisa el log:\n' >&2
            printf '  %s\n' "$STEAM_RESTART_LOG" >&2
            printf '  o ábrelo a mano.\n' >&2
        fi
        STEAM_CLOSED_BY_US=0
    fi

    return "$rc"
}

# ---------------------------------------------------------------------------
# Programa principal
# ---------------------------------------------------------------------------

if ! LUTRIS_CONF_DIR="$(detect_lutris_games_dir)"; then
    echo "Error: no se encontró el directorio de configs de Lutris." >&2
    echo "Define LUTRIS_GAMES_DIR para indicarlo manualmente." >&2
    exit 1
fi

echo "Escaneando configuraciones en: $LUTRIS_CONF_DIR"

LUTRIS_DB=""
if LUTRIS_DB="$(find_lutris_db)"; then
    if lutris_load_names "$LUTRIS_DB"; then
        echo "Base de datos de Lutris:      $LUTRIS_DB"
    else
        echo "Aviso: no se pudo leer pga.db (¿falta sqlite3?). Se usará 'name:' o el filename." >&2
    fi
else
    echo "Aviso: no se encontró pga.db. Se usará 'name:' o el filename como respaldo." >&2
fi

echo "------------------------------------------------------------"

# Configs vistas en este escaneo.
declare -A SCANNED_CONFIGS=()

for config in "$LUTRIS_CONF_DIR"/*.yml; do
    [[ -f "$config" ]] || continue

    config_base="$(basename -- "$config")"
    SCANNED_CONFIGS["$config_base"]=1
    raw_filename="$(basename -- "$config" .yml)"
    slug="$(config_slug "$raw_filename")"

    game_block="$(awk '
        /^game:[[:space:]]*$/ { in_game = 1; next }
        in_game && /^[^[:space:]]/ { exit }
        in_game { print }
    ' "$config")"

    [[ -n "$game_block" ]] || continue

    # Omitir los juegos lanzados por Steam: no necesitan wrapper.
    runner="${LUTRIS_RUNNERS[$slug]:-}"

    if [[ "$SKIP_STEAM" != "0" ]]; then
        is_steam=0

        if [[ "${runner,,}" == "steam" ]]; then
            is_steam=1
        elif [[ -z "$runner" && -n "$(extract_yaml_value appid "$game_block")" ]]; then
            is_steam=1
        fi

        if ((is_steam)); then
            steam_name="${LUTRIS_NAMES[$slug]:-$raw_filename}"
            if ((DRY_RUN)); then
                printf "%-42s slug=%-26s [steam] Omitido\n" "$config_base" "$slug"
            else
                printf "⏭️  Omitiendo (runner Steam): '%s'\n" "$steam_name"
            fi
            continue
        fi
    fi

    # Nombre: 1) pga.db (slug -> name)  2) 'name:' del YAML  3) filename.
    safe_name=""
    name_source=""

    if [[ -n "${LUTRIS_NAMES[$slug]:-}" ]]; then
        safe_name="$(sanitize_name "${LUTRIS_NAMES[$slug]}")"
        name_source="pga.db"
    fi

    if [[ -z "$safe_name" ]]; then
        yaml_name="$(yaml_top_level_value name "$config")"
        if [[ -n "$yaml_name" ]]; then
            safe_name="$(sanitize_name "$yaml_name")"
            name_source="yaml"
        fi
    fi

    if [[ -z "$safe_name" ]]; then
        clean_filename="$(printf '%s\n' "$raw_filename" | sed -E 's/[_-][0-9]{8,}$//')"
        spaced_name="$(printf '%s\n' "$clean_filename" | sed 's/[_-]/ /g')"

        safe_name="$(printf '%s\n' "$spaced_name" | awk '{
            for (i = 1; i <= NF; i++) {
                $i = toupper(substr($i, 1, 1)) tolower(substr($i, 2))
            }
            print
        }')"

        safe_name="$(sanitize_name "$safe_name")"
        name_source="filename"
    fi

    [[ -n "$safe_name" ]] || safe_name="Lutris_Game"

    if ((DRY_RUN)); then
        printf "%-42s slug=%-26s [%s] %s\n" \
            "$config_base" "$slug" "$name_source" "$safe_name"
        continue
    fi

    if [[ "$name_source" == "filename" ]]; then
        printf "⚠️  '%s': sin nombre en pga.db; usando filename: '%s'\n" \
            "$config_base" "$safe_name" >&2
    fi

    # No regenerar si ya existe un wrapper creado a partir de esta misma config.
    already_wrapper=""
    for existing in "$WRAPPERS_DIR"/*.sh; do
        [[ -e "$existing" ]] || continue
        if grep -qxF -- "# Lutris config: $config_base" "$existing"; then
            already_wrapper="$existing"
            break
        fi
    done

    if [[ -n "$already_wrapper" ]]; then
        printf "⏭️  Omitiendo: '%s' (el wrapper ya existe)\n" \
            "$(basename -- "$already_wrapper")"
        continue
    fi

    # Ruta de salida; si el nombre colisiona con otro juego, añadir sufijo.
    wrapper_path="$WRAPPERS_DIR/${safe_name}.sh"

    if [[ -e "$wrapper_path" ]]; then
        suffix=2
        while [[ -e "$WRAPPERS_DIR/${safe_name}-${suffix}.sh" ]]; do
            ((suffix++))
        done
        wrapper_path="$WRAPPERS_DIR/${safe_name}-${suffix}.sh"
        printf "ℹ️  Nombre en uso: se creará '%s'\n" "$(basename -- "$wrapper_path")"
    fi

    game_exe="$(extract_yaml_value exe "$game_block")"
    game_prefix="$(extract_yaml_value prefix "$game_block")"
    working_dir="$(extract_yaml_value working_dir "$game_block")"

    if [[ -z "$game_exe" || -z "$game_prefix" ]]; then
        printf "⚠️  Omitiendo '%s': falta exe o prefix\n" "$config" >&2
        continue
    fi

    game_prefix="$(expand_home "$game_prefix")"
    game_exe="$(expand_home "$game_exe")"
    working_dir="$(expand_home "$working_dir")"

    game_exe="$(resolve_game_path "$game_exe" "$game_prefix")"
    working_dir="$(resolve_game_path "$working_dir" "$game_prefix")"

    if [[ ! -d "$game_prefix" ]]; then
        printf "⚠️  Omitiendo '%s': el prefix no existe:\n    %s\n" \
            "$safe_name" "$game_prefix" >&2
        continue
    fi

    printf -v quoted_game_prefix '%q' "$game_prefix"
    printf -v quoted_game_exe '%q' "$game_exe"
    printf -v quoted_working_dir '%q' "$working_dir"

    temp_wrapper="$(mktemp "$WRAPPERS_DIR/.wrapper.XXXXXX")"

    cat > "$temp_wrapper" <<EOF
#!/usr/bin/env bash

# Wrapper autogenerado para: $safe_name
# Lutris config: $config_base

set -u

STEAM_ORPHAN_PREFIX="\${STEAM_COMPAT_DATA_PATH:-}"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="\${STEAM_COMPAT_CLIENT_INSTALL_PATH:-\$HOME/.local/share/Steam}"
export STEAM_COMPAT_DATA_PATH=$quoted_game_prefix

GAME_EXE=$quoted_game_exe
WORKING_DIR=$quoted_working_dir

# Política sobre el compatdata huérfano de Steam: delete | backup | keep.
ORPHAN_ACTION="\${ORPHAN_ACTION:-$ORPHAN_ACTION}"

# Rutas reales del prefix del juego y del compatdata que asigna Steam.
TARGET_REAL="\$(realpath -e -- "\$STEAM_COMPAT_DATA_PATH" 2>/dev/null || true)"
ORPHAN_REAL="\$(realpath -e -- "\$STEAM_ORPHAN_PREFIX" 2>/dev/null || true)"

# Actuar solo sobre */steamapps/compatdata/<appid> que no sea el prefix del juego.
if [[ -n "\$ORPHAN_REAL" &&
      -n "\$TARGET_REAL" &&
      "\$ORPHAN_REAL" != "\$TARGET_REAL" &&
      "\$ORPHAN_REAL" =~ /steamapps/compatdata/[0-9]+\$ ]]; then
    case "\$ORPHAN_ACTION" in
        delete)
            echo "Eliminando compatdata huérfano: \$ORPHAN_REAL"
            rm -rf -- "\$ORPHAN_REAL"
            ;;
        backup)
            ORPHAN_BACKUP="\$ORPHAN_REAL.orphan-backup"
            echo "Moviendo compatdata huérfano a: \$ORPHAN_BACKUP"
            rm -rf -- "\$ORPHAN_BACKUP"
            mv -- "\$ORPHAN_REAL" "\$ORPHAN_BACKUP"
            ;;
        keep|ignore)
            echo "Conservando compatdata huérfano: \$ORPHAN_REAL"
            ;;
        *)
            echo "Aviso: ORPHAN_ACTION desconocida ('\$ORPHAN_ACTION'); no se toca el compatdata." >&2
            ;;
    esac
fi

if [[ ! -d "\$STEAM_COMPAT_DATA_PATH" ]]; then
    echo "Error: el prefix no existe: \$STEAM_COMPAT_DATA_PATH" >&2
    exit 1
fi

PFX_PATH="\$STEAM_COMPAT_DATA_PATH/pfx"

if [[ ! -e "\$PFX_PATH" && ! -L "\$PFX_PATH" ]]; then
    ln -s . "\$PFX_PATH"
elif [[ -L "\$PFX_PATH" ]]; then
    PFX_TARGET="\$(readlink -- "\$PFX_PATH" || true)"
    if [[ "\$PFX_TARGET" != "." ]]; then
        echo "Error: pfx apunta a un destino inesperado: \$PFX_TARGET" >&2
        exit 1
    fi
fi

if [[ -z "\${STEAM_COMPAT_TOOL_PATHS:-}" ]]; then
    echo "Error: STEAM_COMPAT_TOOL_PATHS no está definido." >&2
    exit 1
fi

PROTON_DIR="\${STEAM_COMPAT_TOOL_PATHS%%:*}"
PROTON="\$PROTON_DIR/proton"

if [[ ! -x "\$PROTON" ]]; then
    echo "Error: Proton no encontrado o no ejecutable: \$PROTON" >&2
    exit 1
fi

if [[ -n "\$WORKING_DIR" ]]; then
    if [[ ! -d "\$WORKING_DIR" ]]; then
        echo "Error: el directorio de trabajo no existe: \$WORKING_DIR" >&2
        exit 1
    fi
    cd -- "\$WORKING_DIR" || exit 1
else
    GAME_DIR="\$(dirname -- "\$GAME_EXE")"
    if [[ ! -d "\$GAME_DIR" ]]; then
        echo "Error: el directorio del ejecutable no existe: \$GAME_DIR" >&2
        exit 1
    fi
    cd -- "\$GAME_DIR" || exit 1
fi

if [[ ! -f "\$GAME_EXE" ]]; then
    echo "Aviso: el ejecutable no se encuentra en: \$GAME_EXE" >&2
fi

exec "\$PROTON" run "\$GAME_EXE" "\$@"
EOF

    chmod 755 -- "$temp_wrapper"
    mv -- "$temp_wrapper" "$wrapper_path"

    printf "✅ Creado: '%s'\n" "$wrapper_path"
    printf "   Ejecutable: %s\n" "$game_exe"
    printf "   Prefix:     %s\n" "$game_prefix"
done

# ---------------------------------------------------------------------------
# Poda de wrappers huérfanos y sincronización con Steam
# ---------------------------------------------------------------------------

if ((PRUNE)) && ((${#SCANNED_CONFIGS[@]} > 0)); then
    for wrapper in "$WRAPPERS_DIR"/*.sh; do
        [[ -e "$wrapper" ]] || continue

        marker="$(grep -m1 -F -- '# Lutris config: ' "$wrapper" 2>/dev/null || true)"
        marker="${marker#\# Lutris config: }"
        marker="${marker%"${marker##*[![:space:]]}"}"

        if [[ -z "$marker" ]]; then
            printf "ℹ️  No gestionado (sin marca de Lutris), no se poda: '%s'\n" \
                "$(basename -- "$wrapper")" >&2
            continue
        fi

        # Si su config sigue existiendo, no es huérfano.
        if [[ -n "${SCANNED_CONFIGS[$marker]:-}" ]]; then
            continue
        fi

        if ((DRY_RUN)); then
            printf "[dry-run] Se podaría el wrapper huérfano: '%s'\n" \
                "$(basename -- "$wrapper")"
        else
            printf "🗑️  Poda de wrapper huérfano: '%s'\n" \
                "$(basename -- "$wrapper")"
            rm -f -- "$wrapper"
        fi
    done
fi

if { ((ADD_TO_STEAM)) || ((PRUNE)); } && ((!DRY_RUN)); then
    steam_shortcuts_sync || exit 1
fi

echo "------------------------------------------------------------"
echo "Proceso finalizado."
echo "Wrappers disponibles en: $WRAPPERS_DIR"
