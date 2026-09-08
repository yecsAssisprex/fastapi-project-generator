#!/usr/bin/env bash
#
# Pruebas de extremo a extremo del generador.
#
# Genera proyectos con cada combinacion de flags y comprueba que el resultado
# funciona de verdad: se instala, pasa sus tests, pasa su linter y su compose es
# valido. Un generador que produce un proyecto roto no sirve de nada, y eso solo se
# ve ejecutando lo que produce.
#
#   ./tests/e2e.sh            # todo
#   ./tests/e2e.sh --rapido   # solo generacion y validaciones, sin pip install
#
# Variables:
#   FPG_KEEP=1   no borra el directorio de trabajo al terminar (para inspeccionarlo)

set -uo pipefail

RAPIDO=0
[ "${1:-}" = "--rapido" ] && RAPIDO=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="$ROOT/bootstrap.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fpg-e2e.XXXXXX")"
PIP_CACHE="${TMPDIR:-/tmp}/fpg-pip-cache"
mkdir -p "$PIP_CACHE"

if [ -t 1 ]; then
  G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else
  G=""; R=""; Y=""; B=""; N=""
fi

PASS=0; FAIL=0; SKIP=0
FALLOS=""

finish() {
  [ -n "${FPG_KEEP:-}" ] || rm -rf "$WORK"
  echo
  echo "${B}Resultado:${N} ${G}$PASS ok${N}, ${R}$FAIL fallidos${N}, ${Y}$SKIP omitidos${N}"
  [ -n "$FALLOS" ] && printf '%s' "$FALLOS"
  [ "$FAIL" -eq 0 ] || exit 1
}
trap finish EXIT

ok()   { PASS=$((PASS + 1)); printf '  %sok%s   %s\n' "$G" "$N" "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  %sFALLA%s %s\n' "$R" "$N" "$1"; FALLOS="$FALLOS  - $1"$'\n'; }
skip() { SKIP=$((SKIP + 1)); printf '  %s--%s   %s\n' "$Y" "$N" "$1"; }
caso() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

check()     { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (esperado '$3', obtenido '$2')"; fi; }
check_file() { if [ -f "$1/$2" ]; then ok "existe $2"; else bad "falta $2"; fi; }
check_nofile() { if [ ! -e "$1/$2" ]; then ok "no existe $2"; else bad "$2 no deberia existir"; fi; }

# --- 1. Matriz de generacion: db x docker x calidad -----------------------------------

# nombre|flags|db|docker|calidad
MATRIZ="
c1-base||0|0|1
c2-db|--with-db|1|0|1
c3-docker|--with-docker|0|1|1
c4-noq|--no-quality|0|0|0
c5-db-docker|--with-db --with-docker|1|1|1
c6-db-noq|--with-db --no-quality|1|0|0
c7-docker-noq|--with-docker --no-quality|0|1|0
c8-all-noq|--all --no-quality|1|1|0
"

DOCKER_OK=0
command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && DOCKER_OK=1

while IFS='|' read -r nombre flags db docker calidad; do
  [ -n "$nombre" ] || continue
  caso "[$nombre] flags: ${flags:-(ninguno)}"

  if ! "$BOOTSTRAP" "$nombre" $flags -d "$WORK" -y >"$WORK/$nombre.log" 2>&1; then
    bad "$nombre: la generacion fallo"; sed 's/^/      /' "$WORK/$nombre.log"; continue
  fi
  P="$WORK/$nombre"
  ok "generado"

  # Archivos que siempre tienen que estar.
  for f in app/main.py app/core/config.py app/core/security.py app/routers/example.py \
           app/schemas/example.py tests/conftest.py tests/test_auth.py tests/test_health.py \
           tests/test_example.py requirements.txt pyproject.toml .env.example .gitignore README.md; do
    check_file "$P" "$f"
  done

  # Base de datos.
  if [ "$db" = "1" ]; then
    for f in app/core/database.py app/models/__init__.py app/models/example.py \
             alembic/env.py alembic.ini alembic/script.py.mako; do check_file "$P" "$f"; done
    grep -q '^sqlalchemy==' "$P/requirements.txt" && ok "requirements trae sqlalchemy" || bad "falta sqlalchemy"
    grep -q 'DATABASE_URL' "$P/.env.example" && ok ".env.example trae DATABASE_URL" || bad "falta DATABASE_URL"
    # El punto delicado: env.py toma la URL de Settings, no del .ini.
    grep -q 'settings.database_url' "$P/alembic/env.py" \
      && ok "alembic/env.py lee la URL de Settings" || bad "alembic/env.py no usa settings.database_url"
    grep -q '^sqlalchemy.url' "$P/alembic.ini" && bad "alembic.ini no debe fijar sqlalchemy.url" \
      || ok "alembic.ini no versiona la URL"
  else
    for f in app/core/database.py app/models alembic alembic.ini; do check_nofile "$P" "$f"; done
    # Lo que el generador NO puede dejar: una importacion colgando de un modulo que
    # no se genero. Es el fallo clasico de un generador condicional.
    if grep -rn 'app\.core\.database\|app\.models\|alembic' "$P" >/dev/null 2>&1; then
      bad "quedan referencias a modulos inexistentes:"; grep -rn 'app\.core\.database\|app\.models\|alembic' "$P" | sed 's/^/      /'
    else ok "sin referencias a database/models/alembic"; fi
    grep -q 'sqlalchemy' "$P/requirements.txt" && bad "requirements no deberia traer sqlalchemy" \
      || ok "requirements sin sqlalchemy"
  fi

  # Docker.
  if [ "$docker" = "1" ]; then
    check_file "$P" Dockerfile; check_file "$P" docker-compose.yml
    if [ "$db" = "1" ]; then
      grep -q 'COPY alembic' "$P/Dockerfile" && ok "Dockerfile copia alembic" || bad "Dockerfile sin alembic"
      grep -q 'libpq-dev' "$P/Dockerfile" && ok "Dockerfile instala libpq-dev" || bad "sin libpq-dev"
      grep -q '^  db:' "$P/docker-compose.yml" && ok "compose trae Postgres" || bad "compose sin Postgres"
    else
      grep -q '^  db:' "$P/docker-compose.yml" && bad "compose no deberia traer Postgres" \
        || ok "compose solo con la app"
      grep -q 'libpq-dev' "$P/Dockerfile" && bad "libpq-dev sin base de datos" || ok "Dockerfile sin libpq-dev"
    fi
    if [ "$DOCKER_OK" = "1" ]; then
      ( cd "$P" && cp .env.example .env && docker compose config -q ) >/dev/null 2>&1 \
        && ok "docker compose config valido" || bad "docker compose config invalido"
      rm -f "$P/.env"
    else skip "docker compose config (docker no disponible)"; fi
  else
    check_nofile "$P" Dockerfile; check_nofile "$P" docker-compose.yml
  fi

  # Calidad.
  if [ "$calidad" = "1" ]; then
    check_file "$P" .pre-commit-config.yaml
    check_file "$P" .github/workflows/ci.yml
    grep -q 'tool.ruff' "$P/pyproject.toml" && ok "pyproject configura ruff" || bad "pyproject sin ruff"
    grep -q '^ruff==' "$P/requirements.txt" && ok "requirements trae ruff" || bad "requirements sin ruff"
  else
    check_nofile "$P" .pre-commit-config.yaml
    check_nofile "$P" .github
    grep -q 'tool.ruff' "$P/pyproject.toml" && bad "pyproject no deberia configurar ruff" \
      || ok "pyproject sin ruff"
  fi

  # Nada de marcadores sin resolver, en ningun caso.
  if grep -rn '{{[A-Z_]*}}' "$P" >/dev/null 2>&1; then
    bad "quedaron marcadores sin resolver"; grep -rn '{{[A-Z_]*}}' "$P" | sed 's/^/      /'
  else ok "sin marcadores sin resolver"; fi

  # git
  [ -d "$P/.git" ] && ok "repositorio git inicializado" || bad "sin repositorio git"
  [ "$(git -C "$P" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "main" ] \
    && ok "rama main" || bad "la rama no es main"
  [ "$(git -C "$P" rev-list --count HEAD 2>/dev/null)" = "1" ] \
    && ok "un commit inicial" || bad "no hay commit inicial"
  [ -z "$(git -C "$P" status --porcelain 2>/dev/null)" ] \
    && ok "arbol de trabajo limpio" || bad "quedaron archivos sin commitear"

  # Lo que de verdad importa: que el proyecto funcione.
  if [ "$RAPIDO" = "1" ]; then
    skip "instalar y ejecutar (--rapido)"
  else
    ( cd "$P"
      python3 -m venv .venv >/dev/null 2>&1 \
        && ./.venv/bin/pip install -q --cache-dir "$PIP_CACHE" -r requirements.txt >/dev/null 2>&1
    ) && ok "pip install" || { bad "pip install fallo"; continue; }

    ( cd "$P" && ./.venv/bin/python -m pytest -q ) >"$P/.pytest.log" 2>&1 \
      && ok "pytest ($(grep -oE '[0-9]+ passed' "$P/.pytest.log" | tail -1))" \
      || { bad "pytest fallo"; tail -20 "$P/.pytest.log" | sed 's/^/      /'; }

    if [ "$calidad" = "1" ]; then
      ( cd "$P" && ./.venv/bin/ruff check . ) >"$P/.ruff.log" 2>&1 \
        && ok "ruff check" || { bad "ruff check fallo"; tail -15 "$P/.ruff.log" | sed 's/^/      /'; }
      ( cd "$P" && ./.venv/bin/ruff format --check . ) >/dev/null 2>&1 \
        && ok "ruff format --check" || bad "el codigo generado no esta formateado"
    fi
  fi
# Here-string y no un pipe: con un pipe el bucle correria en una subshell y los
# contadores de PASS/FAIL no volverian, asi que el script saldria con exito aunque
# fallaran casos de la matriz.
done <<< "$MATRIZ"

# --- 2. Validaciones y flags de comportamiento ------------------------------------------

caso "[validaciones] nombres rechazados"
for malo in "Mi-Proyecto" "mi_proyecto" "1proyecto" "mi-proyecto-" "a" "test" "app"; do
  if "$BOOTSTRAP" "$malo" -d "$WORK" -y >/dev/null 2>&1; then
    bad "acepto el nombre invalido '$malo'"
  else ok "rechaza '$malo'"; fi
done

caso "[validaciones] puerto y version de Python"
"$BOOTSTRAP" v-port -d "$WORK" -y --port 80    >/dev/null 2>&1 && bad "acepto --port 80"    || ok "rechaza --port 80"
"$BOOTSTRAP" v-port -d "$WORK" -y --port 99999 >/dev/null 2>&1 && bad "acepto --port 99999" || ok "rechaza --port 99999"
"$BOOTSTRAP" v-py   -d "$WORK" -y --python 2.7 >/dev/null 2>&1 && bad "acepto --python 2.7" || ok "rechaza --python 2.7"

caso "[validaciones] destino"
"$BOOTSTRAP" v-dest -d "$WORK/no-existe" -y >/dev/null 2>&1 && bad "acepto un destino inexistente" \
  || ok "rechaza un destino inexistente"

mkdir -p "$WORK/ocupado/v-ocupado" && echo hola > "$WORK/ocupado/v-ocupado/algo.txt"
"$BOOTSTRAP" v-ocupado -d "$WORK/ocupado" -y >/dev/null 2>&1 \
  && bad "escribio en un directorio no vacio sin --force" || ok "rechaza un directorio no vacio"
"$BOOTSTRAP" v-ocupado -d "$WORK/ocupado" -y --force >/dev/null 2>&1 \
  && ok "--force escribe en un directorio no vacio" || bad "--force no funciono"
[ -f "$WORK/ocupado/v-ocupado/algo.txt" ] && ok "--force conserva lo que ya habia" \
  || bad "--force borro contenido previo"

caso "[flags] --dry-run"
SALIDA="$("$BOOTSTRAP" v-dry --all -d "$WORK" -y --dry-run 2>&1)"
[ ! -e "$WORK/v-dry" ] && ok "--dry-run no escribe nada" || bad "--dry-run creo el directorio"
echo "$SALIDA" | grep -q 'app/main.py' && ok "--dry-run lista los archivos" || bad "--dry-run no lista nada"

caso "[flags] --no-git"
"$BOOTSTRAP" v-nogit -d "$WORK" -y --no-git >/dev/null 2>&1
[ ! -d "$WORK/v-nogit/.git" ] && ok "--no-git no inicializa repositorio" || bad "--no-git creo un repositorio"

caso "[flags] --port y --python se propagan"
"$BOOTSTRAP" v-cfg --all -d "$WORK" -y --port 9100 --python 3.11 --no-git >/dev/null 2>&1
grep -q 'EXPOSE 9100' "$WORK/v-cfg/Dockerfile"                  && ok "Dockerfile: EXPOSE 9100"  || bad "Dockerfile sin 9100"
grep -q '"9100:9100"' "$WORK/v-cfg/docker-compose.yml"          && ok "compose: puerto 9100"     || bad "compose sin 9100"
grep -q 'localhost:9100' "$WORK/v-cfg/README.md"                && ok "README: puerto 9100"      || bad "README sin 9100"
grep -q 'FROM python:3.11-slim' "$WORK/v-cfg/Dockerfile"        && ok "Dockerfile: Python 3.11"  || bad "Dockerfile sin 3.11"
grep -q 'py311' "$WORK/v-cfg/pyproject.toml"                    && ok "ruff: target py311"       || bad "ruff sin py311"
grep -q '"3.11"' "$WORK/v-cfg/.github/workflows/ci.yml"         && ok "CI: Python 3.11"          || bad "CI sin 3.11"

caso "[idempotencia] regenerar da el mismo resultado"
"$BOOTSTRAP" v-idem --all -d "$WORK" -y --no-git >/dev/null 2>&1
cp -R "$WORK/v-idem" "$WORK/v-idem-copia"
"$BOOTSTRAP" v-idem --all -d "$WORK" -y --no-git --force >/dev/null 2>&1
diff -r "$WORK/v-idem" "$WORK/v-idem-copia" >/dev/null 2>&1 \
  && ok "dos ejecuciones producen lo mismo" || bad "la segunda ejecucion difiere"

caso "[paridad] bash vs PowerShell"
PWSH=""
command -v pwsh >/dev/null 2>&1 && PWSH="pwsh"
command -v powershell >/dev/null 2>&1 && [ -z "$PWSH" ] && PWSH="powershell"
if [ -z "$PWSH" ]; then
  skip "PowerShell no disponible"
else
  mkdir -p "$WORK/par-sh" "$WORK/par-ps"
  "$BOOTSTRAP" par --all -d "$WORK/par-sh" -y --no-git >/dev/null 2>&1
  "$PWSH" -NoProfile -File "$ROOT/bootstrap.ps1" par -All -Dest "$WORK/par-ps" -Yes -NoGit >/dev/null 2>&1
  diff -r "$WORK/par-sh/par" "$WORK/par-ps/par" >/dev/null 2>&1 \
    && ok "bash y PowerShell generan lo mismo" || bad "bash y PowerShell difieren"
fi
