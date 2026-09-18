#!/usr/bin/env bash
# build_and_run.sh — buduje i uruchamia Grosznik z config.json
#
# Uzycie:
#   ./build_and_run.sh                    # domyslnie ./config.json
#   ./build_and_run.sh prod.json          # wlasny plik konfiguracji
#   ./build_and_run.sh --build-only       # tylko buduj, nie uruchamiaj
#   ./build_and_run.sh --run-only         # tylko uruchom (zakłada gotowy build)
#   ./build_and_run.sh --help

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[grosznik]${NC} $*"; }
ok()   { echo -e "${GREEN}[  OK  ]${NC} $*"; }
warn() { echo -e "${YELLOW}[ WARN ]${NC} $*"; }
die()  { echo -e "${RED}[ FAIL ]${NC} $*" >&2; exit 1; }

# ── Argumenty ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
BUILD_ONLY=false
RUN_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=true ;;
        --run-only)   RUN_ONLY=true   ;;
        *.json)       CONFIG_FILE="$(realpath "$arg")" ;;
        -h|--help)
            echo "Uzycie: $0 [config.json] [--build-only|--run-only]"
            exit 0 ;;
        *) die "Nieznany argument: $arg" ;;
    esac
done

[[ -f "$CONFIG_FILE" ]] || die "Nie znaleziono pliku konfiguracji: $CONFIG_FILE"
log "Konfiguracja: $CONFIG_FILE"

# ── Parsowanie config.json przez wbudowany Python ─────────────────────────────
parse_config() {
    python3 - "$CONFIG_FILE" "$SCRIPT_DIR" <<'PYEOF'
import sys, json, os

cfg_file   = sys.argv[1]
script_dir = sys.argv[2]

with open(cfg_file) as f:
    c = json.load(f)

def absp(p, base=script_dir):
    if not p: return p
    return os.path.normpath(os.path.join(base, p)) if not os.path.isabs(p) else p

def q(s):
    return "'" + str(s).replace("'", "'\\''") + "'"

mods  = c.get('modules', {})
httpd = c.get('httpd', {})
tg    = c.get('telegram', {})
bld   = c.get('build', {})

lua_so      = absp(mods.get('lua',      './build/modules/lua_module.so'))
grosznik_so = absp(mods.get('grosznik', './build/modules/grosznik.so'))
mods_dir    = os.path.dirname(grosznik_so)

pairs = [
    ('GROSZNIK_DB',            absp(c.get('db_path',  './data/grosznik.db'))),
    ('GROSZNIK_WWW',           absp(c.get('www_root', './www'))),
    ('GROSZNIK_PORT',          c.get('port',           8080)),
    ('JWT_SECRET',             c.get('jwt_secret',     'change_me')),
    ('GROSZNIK_LUA_MODULE',    lua_so),
    ('GROSZNIK_MODULE',        grosznik_so),
    ('GROSZNIK_WORKERS',       httpd.get('workers',            1)),
    ('GROSZNIK_THREADS',       httpd.get('threads_per_worker', 4)),
    ('TELEGRAM_BOT_TOKEN',     tg.get('bot_token',  '')),
    ('TELEGRAM_ALLOWED_USERS', ','.join(str(u) for u in tg.get('allowed_users', []))),
    ('GROSZNIK_TG_OFFSET',     absp(tg.get('offset_file', './data/tg_offset'))),
    ('HTTPD_DIR',              absp(bld.get('httpd_dir',   '../HTTPD'))),
    ('TELEBOT_DIR',            absp(bld.get('telebot_dir', '../Telebot'))),
    ('BUILD_JOBS',             bld.get('jobs', 0)),
    ('LUA_CPATH',              mods_dir + '/?.so'),
]

for k, v in pairs:
    print(f"export {k}={q(v)}")
PYEOF
}

eval "$(parse_config)"

# Auto-detect CPU count when jobs=0
if [[ "$BUILD_JOBS" == "0" ]]; then
    BUILD_JOBS=$(python3 -c "import os; print(os.cpu_count() or 4)")
fi

# ── Budowanie zależności (HTTPD, Telebot) ─────────────────────────────────────
build_dep() {
    local name="$1"
    local dir="$2"
    local artifact="$3"

    [[ -d "$dir" ]] || die "$name: katalog nie znaleziony: $dir"

    if [[ -f "$artifact" ]]; then
        ok "$name — pomijam ($(basename "$artifact") aktualny)"
        return
    fi

    log "Budowanie $name w: $dir  (jobs=$BUILD_JOBS)..."

    cmake -B "$dir/build" -S "$dir" \
        -DCMAKE_BUILD_TYPE=Release -Wno-dev \
        > "/tmp/grosznik_${name}_cmake.log" 2>&1 \
        || { tail -20 "/tmp/grosznik_${name}_cmake.log"; die "$name: cmake nie powiodlo sie"; }

    cmake --build "$dir/build" -j"$BUILD_JOBS" \
        > "/tmp/grosznik_${name}_build.log" 2>&1 \
        || { tail -30 "/tmp/grosznik_${name}_build.log"; die "$name: build nie powiodlo sie"; }

    ok "$name zbudowany"
}

# ── Budowanie Grosznik ────────────────────────────────────────────────────────
build_grosznik() {
    log "Budowanie Grosznik... (jobs=$BUILD_JOBS)"

    cmake -B "$SCRIPT_DIR/build" -S "$SCRIPT_DIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DHTTPD_DIR="$HTTPD_DIR" \
        -DTELEBOT_DIR="$TELEBOT_DIR" \
        -Wno-dev \
        > /tmp/grosznik_cmake.log 2>&1 \
        || { cat /tmp/grosznik_cmake.log; die "Grosznik: cmake nie powiodlo sie"; }

    cmake --build "$SCRIPT_DIR/build" -j"$BUILD_JOBS" \
        > /tmp/grosznik_build.log 2>&1 \
        || { tail -40 /tmp/grosznik_build.log; die "Grosznik: build nie powiodlo sie"; }

    ok "Grosznik zbudowany  →  build/grosznik  +  build/modules/grosznik.so"
}

# ── Sprawdzenie artefaktów ────────────────────────────────────────────────────
check_artifacts() {
    [[ -f "$SCRIPT_DIR/build/grosznik" ]] \
        || die "Brak binarki build/grosznik. Uruchom bez --run-only."

    [[ -f "$SCRIPT_DIR/build/modules/grosznik.so" ]] \
        || die "Brak modulu build/modules/grosznik.so. Uruchom bez --run-only."

    # lua_module.so moze byc w HTTPD build
    if [[ ! -f "$GROSZNIK_LUA_MODULE" ]]; then
        warn "Nie znaleziono: $GROSZNIK_LUA_MODULE"
        warn "Szukam lua_module.so w katalogu HTTPD..."
        local found
        found=$(find "$HTTPD_DIR/build" -name "lua_module.so" 2>/dev/null | head -1 || true)
        if [[ -n "$found" ]]; then
            export GROSZNIK_LUA_MODULE="$found"
            ok "Znaleziono: $found"
        else
            die "Nie znaleziono lua_module.so. Zbuduj HTTPD."
        fi
    fi

    ok "Artefakty OK"
}

# ── Główna logika ─────────────────────────────────────────────────────────────
if [[ "$RUN_ONLY" == false ]]; then
    echo -e "\n${BOLD}=== BUDOWANIE ===${NC}"
    build_dep "HTTPD"   "$HTTPD_DIR"   "$HTTPD_DIR/build/libhttpd_core.a"
    build_dep "Telebot" "$TELEBOT_DIR" "$TELEBOT_DIR/build/libtelebot.a"
    build_grosznik
    echo ""
    ok "Wszystkie komponenty zbudowane pomyslnie"
fi

if [[ "$BUILD_ONLY" == true ]]; then
    echo -e "\n${GREEN}${BOLD}Build zakonczony.${NC}"
    echo -e "Uruchom: ${CYAN}$0 --run-only${NC}"
    exit 0
fi

check_artifacts

# ── Przygotowanie środowiska uruchomieniowego ─────────────────────────────────
echo -e "\n${BOLD}=== URUCHAMIANIE ===${NC}"

mkdir -p "$(dirname "$GROSZNIK_DB")"
mkdir -p "$(dirname "$GROSZNIK_TG_OFFSET")" 2>/dev/null || true

if [[ "$JWT_SECRET" == *"change_me"* ]]; then
    warn "JWT_SECRET to wartosc domyslna — zmien w config.json!"
    warn "Wygeneruj bezpieczny klucz: openssl rand -hex 32"
fi

if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    warn "TELEGRAM_BOT_TOKEN pusty — bot Telegram wylaczony"
fi

echo ""
log "Konfiguracja uruchomieniowa:"
log "  HTTP port      : $GROSZNIK_PORT"
log "  Katalog www    : $GROSZNIK_WWW"
log "  Baza danych    : $GROSZNIK_DB"
log "  lua_module.so  : $GROSZNIK_LUA_MODULE"
log "  grosznik.so    : $GROSZNIK_MODULE"
log "  LUA_CPATH      : $LUA_CPATH"
log "  Workers/Threads: ${GROSZNIK_WORKERS} x ${GROSZNIK_THREADS}"
[[ -n "$TELEGRAM_BOT_TOKEN" ]] && log "  Telegram bot   : aktywny"
echo ""
ok "Startowanie..."
echo -e "${BOLD}─────────────────────────────────────────────────────${NC}"

exec "$SCRIPT_DIR/build/grosznik"
