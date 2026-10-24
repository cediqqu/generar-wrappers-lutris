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

# Modo de prueba: solo mostrar los nombres resueltos, sin generar wrappers.
DRY_RUN=0

while (($#)); do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=1
            ;;
        -h|--help)
            cat <<'USAGE'
Uso: generar_wrappers_lutris.sh [opciones]

Genera un wrapper por cada juego de Lutris para lanzarlo desde Steam/Proton.

Opciones:
  -n, --dry-run   Muestra config -> slug -> nombre sin generar nada.
  -h, --help      Muestra esta ayuda.

Variables de entorno:
  WRAPPERS_DIR      Directorio de salida (por defecto ~/Games/wrappers).
  LUTRIS_GAMES_DIR  Directorio de configs de Lutris (games/).
  LUTRIS_PGA_DB     Ruta de pga.db (contiene el nombre real del juego).
  ORPHAN_ACTION     delete | backup | keep (compatdata huérfano de Steam).
  SKIP_STEAM        Omitir juegos del runner de Steam (1=omitir, 0=incluir).
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

# Elimina el wrapper temporal si el script se interrumpe.
temp_wrapper=""
cleanup() {
    if [[ -n "$temp_wrapper" && -e "$temp_wrapper" ]]; then
        rm -f -- "$temp_wrapper"
    fi
}
trap cleanup EXIT

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

for config in "$LUTRIS_CONF_DIR"/*.yml; do
    [[ -f "$config" ]] || continue

    config_base="$(basename -- "$config")"
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

echo "------------------------------------------------------------"
echo "Proceso finalizado."
echo "Wrappers disponibles en: $WRAPPERS_DIR"
