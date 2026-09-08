#!/usr/bin/env bash
#
# fastapi-project-generator — genera un proyecto base FastAPI + PostgreSQL.
#
#   ./bootstrap.sh mi-proyecto --with-db --with-docker
#
# Compatible con bash 3.2 (el que trae macOS), Linux, y Windows via Git Bash o WSL.
# El equivalente para PowerShell nativo es `bootstrap.ps1`, con el mismo comportamiento.

set -euo pipefail

VERSION="1.0.0"
# De donde clonarse cuando se ejecuta via `curl | bash` y no hay templates/ en disco.
# Sobrescribible con la variable de entorno FPG_REPO.
DEFAULT_REPO="https://github.com/CAMBIAME/fastapi-project-generator.git"
REPO_URL="${FPG_REPO:-$DEFAULT_REPO}"
REPO_REF="${FPG_REF:-main}"

# --- Salida ------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

info()  { printf '%s\n' "$*"; }
step()  { printf '%s>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# --- Limpieza ----------------------------------------------------------------------

WORK_DIR=""
CLONE_DIR=""
cleanup() {
  [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR"
  [ -n "$CLONE_DIR" ] && [ -d "$CLONE_DIR" ] && rm -rf "$CLONE_DIR"
  return 0
}
trap cleanup EXIT INT TERM

# --- Opciones ----------------------------------------------------------------------

PROJECT_NAME=""
DEST="."
WITH_DB=0
WITH_DOCKER=0
QUALITY=1
PORT=8000
PYTHON_VERSION="3.12"
DO_GIT=1
ASSUME_YES=0
FORCE=0
DRY_RUN=0

usage() {
  cat <<USAGE
${C_BOLD}fastapi-project-generator${C_RESET} v$VERSION
Genera un proyecto base FastAPI + PostgreSQL con autenticacion JWT, tests y CI.

${C_BOLD}USO${C_RESET}
  ./bootstrap.sh <nombre> [opciones]
  ./bootstrap.sh                          # modo interactivo

${C_BOLD}OPCIONES${C_RESET}
  -d, --dest <ruta>     Directorio padre donde crear el proyecto (por defecto: .)
      --with-db         SQLAlchemy 2 + Alembic + psycopg y un CRUD de ejemplo
      --with-docker     Dockerfile y docker-compose.yml (con Postgres si hay --with-db)
      --all             Atajo de --with-db --with-docker
      --no-quality      Omite ruff, pre-commit y el workflow de CI
      --port <n>        Puerto del servicio (por defecto: $PORT)
      --python <ver>    Version de Python: imagen, CI y target de ruff (por defecto: $PYTHON_VERSION)
      --no-git          No hace git init ni el commit inicial
  -y, --yes             No preguntar nada; usa los valores por defecto
  -f, --force           Permite escribir en un directorio existente y no vacio
      --dry-run         Lista lo que crearia, sin tocar el disco
  -h, --help            Esta ayuda
      --version         Version del generador

${C_BOLD}EJEMPLOS${C_RESET}
  ./bootstrap.sh mi-servicio --all
  ./bootstrap.sh mi-servicio --with-db --port 8021 --dest ~/proyectos
  ./bootstrap.sh mi-servicio --no-quality --no-git --dry-run
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --version)     echo "$VERSION"; exit 0 ;;
    -d|--dest)     [ $# -ge 2 ] || die "--dest necesita una ruta"; DEST="$2"; shift 2 ;;
    --dest=*)      DEST="${1#*=}"; shift ;;
    --with-db)     WITH_DB=1; shift ;;
    --with-docker) WITH_DOCKER=1; shift ;;
    --all)         WITH_DB=1; WITH_DOCKER=1; shift ;;
    --no-quality)  QUALITY=0; shift ;;
    --port)        [ $# -ge 2 ] || die "--port necesita un numero"; PORT="$2"; shift 2 ;;
    --port=*)      PORT="${1#*=}"; shift ;;
    --python)      [ $# -ge 2 ] || die "--python necesita una version"; PYTHON_VERSION="$2"; shift 2 ;;
    --python=*)    PYTHON_VERSION="${1#*=}"; shift ;;
    --no-git)      DO_GIT=0; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -f|--force)    FORCE=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -*)            die "Opcion desconocida: $1"$'\n'"Prueba con --help." ;;
    *)
      [ -z "$PROJECT_NAME" ] || die "Solo se admite un nombre de proyecto (recibido tambien: $1)"
      PROJECT_NAME="$1"; shift ;;
  esac
done

# --- Modo interactivo ---------------------------------------------------------------

preguntar() { # preguntar <mensaje> <default:s|n>  -> 0 si si
  local mensaje="$1" defecto="$2" respuesta pista
  if [ "$ASSUME_YES" -eq 1 ]; then
    [ "$defecto" = "s" ] && return 0 || return 1
  fi
  [ "$defecto" = "s" ] && pista="S/n" || pista="s/N"
  printf '%s [%s] ' "$mensaje" "$pista" > /dev/tty
  read -r respuesta < /dev/tty || respuesta=""
  respuesta=$(printf '%s' "$respuesta" | tr '[:upper:]' '[:lower:]')
  case "$respuesta" in
    s|si|y|yes) return 0 ;;
    n|no)       return 1 ;;
    "")         [ "$defecto" = "s" ] && return 0 || return 1 ;;
    *)          [ "$defecto" = "s" ] && return 0 || return 1 ;;
  esac
}

if [ -z "$PROJECT_NAME" ] && [ "$ASSUME_YES" -eq 0 ]; then
  [ -t 0 ] || [ -e /dev/tty ] || die "Falta el nombre del proyecto y no hay terminal para preguntarlo."$'\n'"Pasalo como argumento:  bootstrap.sh mi-proyecto"
  printf '%sGenerador de proyectos FastAPI%s\n\n' "$C_BOLD" "$C_RESET"
  while [ -z "$PROJECT_NAME" ]; do
    printf 'Nombre del proyecto: ' > /dev/tty
    read -r PROJECT_NAME < /dev/tty || die "Cancelado."
  done
  printf 'Directorio destino [%s]: ' "$DEST" > /dev/tty
  read -r _dest < /dev/tty || _dest=""
  [ -n "$_dest" ] && DEST="$_dest"
  preguntar "Incluir base de datos (SQLAlchemy + Alembic)?" n && WITH_DB=1
  preguntar "Incluir Dockerfile y docker-compose?"           n && WITH_DOCKER=1
  preguntar "Incluir ruff, pre-commit y CI?"                 s && QUALITY=1 || QUALITY=0
  printf '\n'
fi
[ -n "$PROJECT_NAME" ] || die "Falta el nombre del proyecto. Prueba con --help."

# --- Validaciones (todas antes de escribir nada) -------------------------------------

step "Validando"

echo "$PROJECT_NAME" | grep -Eq '^[a-z][a-z0-9-]{0,47}[a-z0-9]$' \
  || die "Nombre invalido: '$PROJECT_NAME'"$'\n'"  Minusculas, numeros y guiones; entre 2 y 49 caracteres; empieza por letra y no termina en guion."$'\n'"  Ejemplo: mi-servicio"

case "$PROJECT_NAME" in
  test|tests|app|main|os|sys|json|typing|types|code|email|logging|random|time|uuid|abc|io|re)
    die "'$PROJECT_NAME' colisiona con un modulo de Python o con una carpeta del propio proyecto. Elige otro nombre." ;;
esac

echo "$PORT" | grep -Eq '^[0-9]+$' || die "--port debe ser un numero (recibido: $PORT)"
[ "$PORT" -ge 1024 ] && [ "$PORT" -le 65535 ] \
  || die "--port fuera de rango: $PORT (usa 1024-65535; por debajo de 1024 hace falta root)"

echo "$PYTHON_VERSION" | grep -Eq '^3\.(9|1[0-9])$' \
  || die "--python debe ser 3.9 .. 3.19 (recibido: $PYTHON_VERSION)"

PROJECT_SNAKE=$(echo "$PROJECT_NAME" | tr '-' '_')
PROJECT_TITLE=$(echo "$PROJECT_NAME" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')
PY_TAG="py$(echo "$PYTHON_VERSION" | tr -d '.')"

# shellcheck disable=SC2088  # es un patron de `case`, no un argumento sin expandir
case "$DEST" in
  "~")   DEST="$HOME" ;;
  "~/"*) DEST="$HOME/${DEST#\~/}" ;;
esac
[ -d "$DEST" ] || die "El directorio destino no existe: $DEST"
[ -w "$DEST" ] || die "Sin permiso de escritura en: $DEST"
DEST_ABS="$(cd "$DEST" && pwd)"
TARGET="$DEST_ABS/$PROJECT_NAME"

if [ -e "$TARGET" ]; then
  [ -d "$TARGET" ] || die "Ya existe un archivo (no un directorio) en: $TARGET"
  if [ -n "$(ls -A "$TARGET" 2>/dev/null)" ] && [ "$FORCE" -eq 0 ]; then
    die "El directorio ya existe y no esta vacio: $TARGET"$'\n'"  Usa --force para escribir dentro de todos modos, o elige otro nombre."
  fi
fi

if [ "$DO_GIT" -eq 1 ] && ! command -v git >/dev/null 2>&1; then
  die "git no esta en el PATH."$'\n'"  Instalalo, o genera el proyecto sin repositorio con --no-git."
fi

if [ "$WITH_DOCKER" -eq 1 ] && ! command -v docker >/dev/null 2>&1; then
  warn "docker no esta en el PATH: el proyecto se genera igual, pero no podras levantarlo aqui."
fi

PY_BIN=""
for c in python3 python; do
  command -v "$c" >/dev/null 2>&1 && { PY_BIN="$c"; break; }
done
if [ -z "$PY_BIN" ]; then
  warn "No se encontro Python: el proyecto se genera igual, pero no podras instalarlo ni correr los tests aqui."
fi

# --- Localizar las plantillas --------------------------------------------------------

SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
TEMPLATES="$SCRIPT_DIR/templates"

if [ ! -d "$TEMPLATES" ]; then
  # Modo remoto: `curl ... | bash`. El script llega solo, sin sus plantillas.
  case "$REPO_URL" in
    *CAMBIAME*) die "Ejecucion remota sin repositorio configurado."$'\n'"  Edita DEFAULT_REPO en el script, o exporta FPG_REPO=<url del repo>." ;;
  esac
  command -v git >/dev/null 2>&1 || die "La ejecucion remota necesita git para descargar las plantillas."
  step "Descargando las plantillas de $REPO_URL"
  CLONE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fpg.XXXXXX")"
  git clone --quiet --depth 1 --branch "$REPO_REF" "$REPO_URL" "$CLONE_DIR" \
    || die "No se pudo clonar $REPO_URL (rama $REPO_REF)."
  TEMPLATES="$CLONE_DIR/templates"
fi
[ -d "$TEMPLATES/base" ] || die "No se encuentran las plantillas en: $TEMPLATES"

# --- Motor de plantillas -------------------------------------------------------------

render() { # render <origen> <destino>
  sed -e "s|{{PROJECT_NAME}}|$PROJECT_NAME|g" \
      -e "s|{{PROJECT_SNAKE}}|$PROJECT_SNAKE|g" \
      -e "s|{{PROJECT_TITLE}}|$PROJECT_TITLE|g" \
      -e "s|{{PORT}}|$PORT|g" \
      -e "s|{{PYTHON_VERSION}}|$PYTHON_VERSION|g" \
      -e "s|{{PY_TAG}}|$PY_TAG|g" \
      -e "s|{{APT_DB}}|$APT_DB|g" \
      "$1" > "$2"
}

copy_layer() { # copy_layer <nombre-de-capa> <destino>
  local layer="$TEMPLATES/$1" dest="$2" rel target
  [ -d "$layer" ] || return 0
  while IFS= read -r rel; do
    mkdir -p "$dest/$rel"
  done < <(cd "$layer" && find . -type d -print | sed 's|^\./||' | grep -v '^\.$' || true)
  while IFS= read -r rel; do
    target="$dest/${rel%.tmpl}"
    mkdir -p "$(dirname "$target")"
    # Una capa posterior puede sobrescribir un archivo de `base`: asi el ejemplo con
    # CRUD reemplaza al stub cuando el proyecto lleva base de datos.
    case "$rel" in
      *.tmpl) render "$layer/$rel" "$target" ;;
      *)      cp "$layer/$rel" "$target" ;;
    esac
  done < <(cd "$layer" && find . -type f -print | sed 's|^\./||')
}

# Sustituye una linea-marcador por el contenido de un fragmento (ya renderizado), o la
# borra si no se pasa fragmento. Es lo que hace condicional un archivo compartido sin
# tener que mantener dos versiones enteras de el.
insert_fragment() { # insert_fragment <archivo> <marcador> [fragmento...]
  local file="$1" marker="$2"; shift 2
  local combined="" tmp="$WORK_DIR/.frag.$$" out="$file.tmp.$$"
  [ -f "$file" ] || return 0
  if [ $# -gt 0 ]; then
    : > "$tmp"
    local f
    for f in "$@"; do
      [ -f "$TEMPLATES/fragments/$f" ] || die "Fragmento no encontrado: $f"
      render "$TEMPLATES/fragments/$f" "$tmp.one"
      cat "$tmp.one" >> "$tmp"
      rm -f "$tmp.one"
    done
    combined="$tmp"
  fi
  awk -v m="$marker" -v f="$combined" '
    index($0, m) > 0 {
      if (f != "") { while ((getline line < f) > 0) print line; close(f) }
      next
    }
    { print }
  ' "$file" > "$out"
  mv "$out" "$file"
  rm -f "$tmp"
}

# --- Generar --------------------------------------------------------------------------

APT_DB=""
[ "$WITH_DB" -eq 1 ] && APT_DB=" libpq-dev"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fpg-build.XXXXXX")"
BUILD="$WORK_DIR/$PROJECT_NAME"
mkdir -p "$BUILD"

step "Generando el esqueleto"
copy_layer base "$BUILD"
[ "$WITH_DB" -eq 1 ]     && { step "Anadiendo base de datos (SQLAlchemy + Alembic)"; copy_layer db "$BUILD"; }
[ "$WITH_DOCKER" -eq 1 ] && { step "Anadiendo Docker"; copy_layer docker "$BUILD"; }
[ "$QUALITY" -eq 1 ]     && { step "Anadiendo ruff, pre-commit y CI"; copy_layer quality "$BUILD"; }

# Fragmentos condicionales dentro de archivos compartidos.
if [ "$WITH_DB" -eq 1 ]; then
  insert_fragment "$BUILD/requirements.txt"    '#{{DB_REQUIREMENTS}}'    requirements.db.txt
  insert_fragment "$BUILD/app/core/config.py"  '#{{CONFIG_DB}}'          config.db.py
  insert_fragment "$BUILD/README.md"           '#{{README_STACK_DB}}'    readme.stack.db.md
  insert_fragment "$BUILD/README.md"           '#{{README_SETUP_DB}}'    readme.setup.db.md
else
  insert_fragment "$BUILD/requirements.txt"    '#{{DB_REQUIREMENTS}}'
  insert_fragment "$BUILD/app/core/config.py"  '#{{CONFIG_DB}}'
  insert_fragment "$BUILD/README.md"           '#{{README_STACK_DB}}'
  insert_fragment "$BUILD/README.md"           '#{{README_SETUP_DB}}'
fi

if [ "$QUALITY" -eq 1 ]; then
  insert_fragment "$BUILD/requirements.txt" '#{{QUALITY_REQUIREMENTS}}' requirements.quality.txt
  insert_fragment "$BUILD/pyproject.toml"   '#{{QUALITY_PYPROJECT}}'    pyproject.quality.toml
  insert_fragment "$BUILD/README.md"        '#{{README_QUALITY}}'       readme.quality.md
  # Este marcador solo existe si se acaba de insertar el bloque de ruff.
  if [ "$WITH_DB" -eq 1 ]; then
    insert_fragment "$BUILD/pyproject.toml" '#{{PYPROJECT_ISORT_DB}}'   pyproject.quality.db.toml
  else
    insert_fragment "$BUILD/pyproject.toml" '#{{PYPROJECT_ISORT_DB}}'
  fi
else
  insert_fragment "$BUILD/requirements.txt" '#{{QUALITY_REQUIREMENTS}}'
  insert_fragment "$BUILD/pyproject.toml"   '#{{QUALITY_PYPROJECT}}'
  insert_fragment "$BUILD/README.md"        '#{{README_QUALITY}}'
fi

# .env.example: la seccion de Postgres del compose solo tiene sentido con ambos.
if [ "$WITH_DB" -eq 1 ] && [ "$WITH_DOCKER" -eq 1 ]; then
  insert_fragment "$BUILD/.env.example" '#{{ENV_DB}}' env.db.example env.docker.example
elif [ "$WITH_DB" -eq 1 ]; then
  insert_fragment "$BUILD/.env.example" '#{{ENV_DB}}' env.db.example
else
  insert_fragment "$BUILD/.env.example" '#{{ENV_DB}}'
fi

if [ "$WITH_DOCKER" -eq 1 ]; then
  if [ "$WITH_DB" -eq 1 ]; then
    insert_fragment "$BUILD/Dockerfile"         '#{{DOCKERFILE_DB_COPY}}' dockerfile.db.copy
    insert_fragment "$BUILD/docker-compose.yml" '#{{COMPOSE_APP_DB}}'     compose.app.db.yml
    insert_fragment "$BUILD/docker-compose.yml" '#{{COMPOSE_DB_SERVICE}}' compose.db.service.yml
    insert_fragment "$BUILD/README.md"          '#{{README_DOCKER}}'      readme.docker.md readme.docker.db.md
  else
    # Sin base de datos no se levanta un Postgres "por si acaso": el compose queda
    # solo con la app.
    insert_fragment "$BUILD/Dockerfile"         '#{{DOCKERFILE_DB_COPY}}'
    insert_fragment "$BUILD/docker-compose.yml" '#{{COMPOSE_APP_DB}}'
    insert_fragment "$BUILD/docker-compose.yml" '#{{COMPOSE_DB_SERVICE}}'
    insert_fragment "$BUILD/README.md"          '#{{README_DOCKER}}'      readme.docker.md
  fi
else
  insert_fragment "$BUILD/README.md" '#{{README_DOCKER}}'
fi

# Red de seguridad: ningun marcador puede sobrevivir a la generacion.
if grep -rn '{{[A-Z_]*}}' "$BUILD" >/dev/null 2>&1; then
  grep -rn '{{[A-Z_]*}}' "$BUILD" >&2 || true
  die "Quedaron marcadores sin resolver (arriba). Es un bug del generador, no de tu proyecto."
fi
# Y sin base de datos no puede quedar nada importando los modulos que no se generaron.
if [ "$WITH_DB" -eq 0 ]; then
  if grep -rln 'app\.core\.database\|app\.models\|alembic' "$BUILD" >/dev/null 2>&1; then
    grep -rn 'app\.core\.database\|app\.models\|alembic' "$BUILD" >&2 || true
    die "Sin --with-db quedaron referencias a modulos que no existen (arriba). Bug del generador."
  fi
fi

TOTAL=$(find "$BUILD" -type f | wc -l | tr -d ' ')

if [ "$DRY_RUN" -eq 1 ]; then
  info ""
  info "${C_BOLD}--dry-run: no se escribio nada.${C_RESET} Se habrian creado $TOTAL archivos en $TARGET:"
  (cd "$BUILD" && find . -type f | sed 's|^\./|  |' | sort)
  exit 0
fi

step "Escribiendo en $TARGET"
mkdir -p "$TARGET"
# `cp -R origen/.` en vez de mover el directorio: respeta un destino que ya existe
# (--force) y no depende de que /tmp y el destino esten en el mismo sistema de ficheros.
cp -R "$BUILD/." "$TARGET/"

# --- Git --------------------------------------------------------------------------------

GIT_MSG="sin repositorio (--no-git)"
if [ "$DO_GIT" -eq 1 ]; then
  if [ -d "$TARGET/.git" ]; then
    GIT_MSG="ya habia un repositorio; no se toco"
  else
    step "Inicializando git"
    (
      cd "$TARGET"
      git init --quiet
      # `git init -b main` necesita git >= 2.28; esto funciona en cualquier version.
      git symbolic-ref HEAD refs/heads/main
      git add -A
      if git -c user.name= -c user.email= config user.email >/dev/null 2>&1 \
         || { git config user.email >/dev/null 2>&1 && git config user.name >/dev/null 2>&1; }; then
        git commit --quiet -m "chore: scaffold inicial de $PROJECT_NAME" || true
      else
        git -c user.name="fastapi-project-generator" \
            -c user.email="generator@localhost" \
            commit --quiet -m "chore: scaffold inicial de $PROJECT_NAME" || true
      fi
    )
    GIT_MSG="rama main, 1 commit"
  fi
fi

# --- Resumen ------------------------------------------------------------------------------

MODULOS="base"
[ "$WITH_DB" -eq 1 ]     && MODULOS="$MODULOS + db"
[ "$WITH_DOCKER" -eq 1 ] && MODULOS="$MODULOS + docker"
[ "$QUALITY" -eq 1 ]     && MODULOS="$MODULOS + calidad"

info ""
ok "Proyecto '${C_BOLD}$PROJECT_NAME${C_RESET}' creado en $TARGET"
info "  Modulos: $MODULOS"
info "  $TOTAL archivos · Python $PYTHON_VERSION · puerto $PORT · git: $GIT_MSG"
info ""
info "${C_BOLD}Proximos pasos${C_RESET}"
info "  cd $PROJECT_NAME"
info "  cp .env.example .env                    ${C_DIM}# completa JWT_SECRET_KEY${C_RESET}"
if [ "$WITH_DOCKER" -eq 1 ]; then
  info "  docker compose up -d --build"
  [ "$WITH_DB" -eq 1 ] && info "  docker compose exec app alembic upgrade head"
  info ""
  info "  ${C_DIM}Sin Docker:${C_RESET}"
  info "  python3 -m venv venv && source venv/bin/activate"
  info "  pip install -r requirements.txt"
  info "  uvicorn app.main:app --reload --port $PORT"
else
  info "  python3 -m venv venv && source venv/bin/activate"
  info "  pip install -r requirements.txt"
  if [ "$WITH_DB" -eq 1 ]; then
    info "  createdb $PROJECT_SNAKE                  ${C_DIM}# y ajusta DATABASE_URL en .env${C_RESET}"
    info "  alembic revision --autogenerate -m 'initial schema' && alembic upgrade head"
  fi
  info "  uvicorn app.main:app --reload --port $PORT"
fi
info "  pytest"
info ""
info "  → http://localhost:$PORT/docs"
