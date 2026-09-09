# fastapi-project-generator

Genera un proyecto base **FastAPI + PostgreSQL** con un solo comando, en Linux, macOS
y Windows.

> **Repositorio privado de uso interno. Todos los derechos reservados.**
> Sin licencia de distribución: no se autoriza su uso fuera de la organización.

No es una plantilla genérica sacada de un tutorial: reproduce el patrón real de los
nueve microservicios FastAPI de Allegro, con sus mismas versiones pineadas, su misma
estructura y su misma capa de autenticación. Lo que cambia respecto a esos nueve es
que aquí ruff, pre-commit y CI vienen de serie.

## Uso

```bash
# Linux / macOS / Git Bash / WSL
./bootstrap.sh mi-nuevo-proyecto --with-db --with-docker
```

```powershell
# Windows (PowerShell nativo)
.\bootstrap.ps1 mi-nuevo-proyecto -WithDb -WithDocker
```

Sin argumentos, ambos preguntan de forma interactiva:

```bash
./bootstrap.sh
```

### De un solo comando, sin clonar

Los scripts detectan que llegaron sueltos y se descargan sus propias plantillas a un
directorio temporal.

```bash
# Linux / macOS
curl -sSL https://raw.githubusercontent.com/yecsAssisprex/fastapi-project-generator/main/bootstrap.sh \
  | bash -s -- mi-nuevo-proyecto --with-db --with-docker -y
```

```powershell
# Windows
$s = iwr -useb https://raw.githubusercontent.com/yecsAssisprex/fastapi-project-generator/main/bootstrap.ps1
$f = "$env:TEMP\bootstrap.ps1"; $s.Content | Out-File $f -Encoding utf8
& $f mi-nuevo-proyecto -WithDb -WithDocker -Yes
```

> **Con el repositorio en privado, `curl` y `iwr` necesitan credenciales.** Lo
> práctico es clonarlo una vez y ejecutar el script desde ahí; el modo remoto queda
> listo para el día que se abra, o para usarlo con un token.
>
> Para apuntar a un fork o a otra rama sin editar nada: `FPG_REPO=<url>` y `FPG_REF=<rama>`.

## Opciones

| Bash | PowerShell | Por defecto | Qué hace |
|---|---|---|---|
| `<nombre>` | `<nombre>` | interactivo | Nombre del proyecto |
| `-d, --dest <ruta>` | `-Dest <ruta>` | `.` | Directorio padre donde crearlo |
| `--with-db` | `-WithDb` | off | SQLAlchemy 2 + Alembic + psycopg, con CRUD de ejemplo |
| `--with-docker` | `-WithDocker` | off | `Dockerfile` y `docker-compose.yml` |
| `--all` | `-All` | — | Atajo de los dos anteriores |
| `--no-quality` | `-NoQuality` | calidad **on** | Omite ruff, pre-commit y CI |
| `--port <n>` | `-Port <n>` | `8000` | Puerto del servicio |
| `--python <ver>` | `-Python <ver>` | `3.12` | Versión de Python (imagen, CI, target de ruff) |
| `--no-git` | `-NoGit` | git **on** | No inicializa repositorio |
| `-y, --yes` | `-Yes` | off | No pregunta nada |
| `-f, --force` | `-Force` | off | Escribe en un directorio existente y no vacío |
| `--dry-run` | `-DryRun` | off | Lista lo que crearía, sin tocar el disco |
| `-h, --help` | `-ShowHelp` | — | Ayuda |
| `--version` | `-ShowVersion` | — | Versión del generador |

`--with-docker` sin `--with-db` genera un compose **solo con la app**: no tiene
sentido levantar un Postgres que nadie usa.

## Qué genera

Con `--with-db --with-docker` y la calidad por defecto:

```
mi-nuevo-proyecto/
├── app/
│   ├── main.py                 # FastAPI(), routers, /health, handler de 400
│   ├── core/
│   │   ├── config.py           # Settings (pydantic-settings)
│   │   ├── security.py         # Identity, get_current_identity()
│   │   └── database.py         #   --with-db
│   ├── models/example.py       #   --with-db  SQLAlchemy 2, Mapped[]
│   ├── schemas/example.py      # Pydantic v2
│   └── routers/example.py      # APIRouter protegido
├── alembic/                    #   --with-db
├── tests/                      # conftest, test_health, test_auth, test_example
├── .github/workflows/ci.yml    #   calidad
├── .pre-commit-config.yaml     #   calidad
├── pyproject.toml              # solo [tool.ruff] y [tool.pytest.ini_options]
├── requirements.txt            # versiones pineadas
├── Dockerfile                  #   --with-docker
├── docker-compose.yml          #   --with-docker  (+ Postgres si hay --with-db)
├── .env.example · .gitignore · .dockerignore
└── README.md
```

El proyecto nace **funcionando**: `pip install -r requirements.txt && pytest` pasa en
verde recién generado, y `ruff check` no tiene nada que decir.

### Decisiones que hereda de Allegro

- **Las dependencias van en `requirements.txt`**, pineadas con `==`, no en
  `pyproject.toml`. El `pyproject.toml` es solo configuración de herramientas.
  Mantener dos listas de dependencias es peor que no tener ninguna.
- **psycopg 3 síncrono** (`postgresql+psycopg://`), no psycopg2 ni asyncpg.
- **La lógica de negocio vive en los routers.** No hay `services/` ni
  `repositories/`: para un servicio de este tamaño sería indirección sin
  contrapartida. Cuando la misma regla haya que invocarla desde dos routers, ahí
  conviene extraerla.
- **`400` para un body mal formado**, no el `422` que FastAPI usa por defecto: el
  `422` queda reservado para el dominio ("la petición es válida pero no se puede
  aplicar"), y el consumidor tiene que poder distinguir los dos casos.
- **Los tests no dependen de infraestructura**: SQLite en memoria, tokens firmados en
  el propio `conftest.py`. Nada de Postgres ni servicios levantados.
- **La URL de la base sale de `Settings`**, nunca del `alembic.ini`.

### Autenticación, incluida de serie

`app/core/security.py` trae `Identity` y `get_current_identity()`, con validación de
`issuer` y `audience` y rechazo de refresh tokens y de tokens de alcance limitado.
`app/routers/example.py` muestra los dos patrones de uso: guardia del router completo
e inyección de `Identity` cuando el endpoint necesita saber quién llama.

Los siete caminos que terminan en `401` vienen ya cubiertos en `tests/test_auth.py`:
sin token, firma inválida, expirado, `issuer` ajeno, `audience` ajena, refresh token y
scope limitado.

Los valores por defecto de `JWT_ISSUER` y `JWT_AUDIENCE` son los de Allegro
(`allegro-identity-auth` / `allegro-control-plane`). Cámbialos en `.env` si el
proyecto no es de esa plataforma.

## Requisitos

- **bash 3.2+** (el de macOS sirve) o **PowerShell 5.1+**
- **git**, salvo que uses `--no-git`
- **Python 3.9+** y **Docker**, solo si vas a instalar o levantar lo generado

Los scripts avisan de lo que falta antes de escribir nada, y construyen el proyecto en
un directorio temporal que solo se mueve al destino cuando todo salió bien: un fallo a
mitad no deja un proyecto a medias.

## Desarrollo del generador

```bash
./tests/e2e.sh            # suite completa: ~330 aserciones
./tests/e2e.sh --rapido   # sin pip install, solo generación y validaciones
FPG_KEEP=1 ./tests/e2e.sh # conserva el directorio de trabajo para inspeccionarlo
```

La suite genera un proyecto con **cada combinación de flags**, lo instala, corre sus
tests y su linter, y valida su `docker compose`. Un generador que produce proyectos
rotos no sirve de nada, y eso solo se ve ejecutando lo que produce.

Comprueba además dos cosas fáciles de romper al editar plantillas:

- que **no sobreviva ningún marcador** `{{...}}` sin sustituir, y
- que **sin `--with-db` no quede ninguna referencia** a `app.core.database`,
  `app.models` ni `alembic` — el fallo clásico de un generador condicional es dejar un
  import colgando de un módulo que no se generó.

Los mismos scripts corren en CI (`.github/workflows/ci.yml`), junto a shellcheck,
PSScriptAnalyzer y una comprobación de que **bash y PowerShell producen archivos
idénticos byte a byte**.

### Cómo funcionan las plantillas

`templates/` está dividido en capas que se aplican en orden: `base` → `db` → `docker`
→ `quality`. Una capa posterior puede **sobrescribir** un archivo de `base` (así el
`example.py` con CRUD reemplaza al stub cuando hay base de datos).

Los archivos `.tmpl` pasan por sustitución de marcadores (`{{PROJECT_NAME}}`,
`{{PORT}}`, …) y pierden la extensión; el resto se copia tal cual.

`templates/fragments/` son trozos que se **insertan** dentro de archivos ya generados,
reemplazando una línea-marcador como `#{{DB_REQUIREMENTS}}`. Es lo que permite que
`requirements.txt` o `.env.example` sean condicionales sin mantener dos versiones
enteras de cada uno.

No hay motor de plantillas ni dependencias: `sed` y `awk` en bash, `-replace` en
PowerShell.

### Añadir una plantilla

1. Crea el archivo en la capa que corresponda, con extensión `.tmpl` si lleva
   marcadores.
2. Si es condicional dentro de un archivo compartido, añade la línea-marcador en la
   plantilla base y el fragmento en `templates/fragments/`, y engánchalo en **los dos**
   scripts.
3. Ejecuta `./tests/e2e.sh`. Si tocaste código Python, comprueba que sigue pasando
   `ruff format --check`: la CI del proyecto generado lo exige.
