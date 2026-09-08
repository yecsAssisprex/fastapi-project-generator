<#
.SYNOPSIS
    Genera un proyecto base FastAPI + PostgreSQL.

.DESCRIPTION
    Equivalente de bootstrap.sh para PowerShell nativo en Windows. Mismo
    comportamiento, mismas plantillas, mismos valores por defecto.

.EXAMPLE
    .\bootstrap.ps1 mi-servicio -WithDb -WithDocker

.EXAMPLE
    .\bootstrap.ps1 mi-servicio -Dest C:\proyectos -Port 8021 -Yes
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Name,
    [string]$Dest = ".",
    [switch]$WithDb,
    [switch]$WithDocker,
    [switch]$All,
    [switch]$NoQuality,
    [int]$Port = 8000,
    [string]$Python = "3.12",
    [switch]$NoGit,
    [switch]$Yes,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$ShowHelp,
    [switch]$ShowVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptVersion = '1.0.0'
# De donde clonarse cuando se ejecuta via `iwr ... | iex` y no hay templates/ en disco.
$DefaultRepo = 'https://github.com/CAMBIAME/fastapi-project-generator.git'
$RepoUrl = if ($env:FPG_REPO) { $env:FPG_REPO } else { $DefaultRepo }
$RepoRef = if ($env:FPG_REF) { $env:FPG_REF } else { 'main' }

# --- Salida -------------------------------------------------------------------------

function Write-Step { param([string]$Message) Write-Host "> $Message" -ForegroundColor Blue }
function Write-Ok   { param([string]$Message) Write-Host "OK $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "!  $Message" -ForegroundColor Yellow }
function Stop-WithError {
    param([string]$Message)
    Write-Host "X  $Message" -ForegroundColor Red
    exit 1
}

function Show-Usage {
    @"
fastapi-project-generator v$ScriptVersion
Genera un proyecto base FastAPI + PostgreSQL con autenticacion JWT, tests y CI.

USO
  .\bootstrap.ps1 <nombre> [opciones]
  .\bootstrap.ps1                          # modo interactivo

OPCIONES
  -Dest <ruta>      Directorio padre donde crear el proyecto (por defecto: .)
  -WithDb           SQLAlchemy 2 + Alembic + psycopg y un CRUD de ejemplo
  -WithDocker       Dockerfile y docker-compose.yml (con Postgres si hay -WithDb)
  -All              Atajo de -WithDb -WithDocker
  -NoQuality        Omite ruff, pre-commit y el workflow de CI
  -Port <n>         Puerto del servicio (por defecto: 8000)
  -Python <ver>     Version de Python: imagen, CI y target de ruff (por defecto: 3.12)
  -NoGit            No hace git init ni el commit inicial
  -Yes              No preguntar nada; usa los valores por defecto
  -Force            Permite escribir en un directorio existente y no vacio
  -DryRun           Lista lo que crearia, sin tocar el disco
  -ShowHelp         Esta ayuda
  -ShowVersion      Version del generador

EJEMPLOS
  .\bootstrap.ps1 mi-servicio -All
  .\bootstrap.ps1 mi-servicio -WithDb -Port 8021 -Dest ~\proyectos
"@ | Write-Host
}

if ($ShowHelp)    { Show-Usage; exit 0 }
if ($ShowVersion) { Write-Host $ScriptVersion; exit 0 }
if ($All) { $WithDb = $true; $WithDocker = $true }
$Quality = -not $NoQuality

# --- Modo interactivo -----------------------------------------------------------------

function Read-YesNo {
    param([string]$Message, [string]$Default)
    if ($Yes) { return ($Default -eq 's') }
    $hint = if ($Default -eq 's') { 'S/n' } else { 's/N' }
    $answer = (Read-Host "$Message [$hint]").Trim().ToLower()
    switch ($answer) {
        { $_ -in @('s', 'si', 'y', 'yes') } { return $true }
        { $_ -in @('n', 'no') }             { return $false }
        default                             { return ($Default -eq 's') }
    }
}

if (-not $Name -and -not $Yes) {
    Write-Host "Generador de proyectos FastAPI" -ForegroundColor White
    Write-Host ""
    while (-not $Name) { $Name = (Read-Host "Nombre del proyecto").Trim() }
    $answer = (Read-Host "Directorio destino [$Dest]").Trim()
    if ($answer) { $Dest = $answer }
    if (Read-YesNo "Incluir base de datos (SQLAlchemy + Alembic)?" 'n') { $WithDb = $true }
    if (Read-YesNo "Incluir Dockerfile y docker-compose?"           'n') { $WithDocker = $true }
    $Quality = Read-YesNo "Incluir ruff, pre-commit y CI?"          's'
    Write-Host ""
}
if (-not $Name) { Stop-WithError "Falta el nombre del proyecto. Prueba con -ShowHelp." }

# --- Validaciones (todas antes de escribir nada) ----------------------------------------

Write-Step "Validando"

if ($Name -cnotmatch '^[a-z][a-z0-9-]{0,47}[a-z0-9]$') {
    Stop-WithError @"
Nombre invalido: '$Name'
  Minusculas, numeros y guiones; entre 2 y 49 caracteres; empieza por letra y no termina en guion.
  Ejemplo: mi-servicio
"@
}

$reserved = @('test', 'tests', 'app', 'main', 'os', 'sys', 'json', 'typing', 'types',
              'code', 'email', 'logging', 'random', 'time', 'uuid', 'abc', 'io', 're')
if ($reserved -contains $Name) {
    Stop-WithError "'$Name' colisiona con un modulo de Python o con una carpeta del propio proyecto. Elige otro nombre."
}

if ($Port -lt 1024 -or $Port -gt 65535) {
    Stop-WithError "-Port fuera de rango: $Port (usa 1024-65535; por debajo de 1024 hace falta administrador)"
}

if ($Python -notmatch '^3\.(9|1[0-9])$') {
    Stop-WithError "-Python debe ser 3.9 .. 3.19 (recibido: $Python)"
}

$ProjectSnake = $Name.Replace('-', '_')
$ProjectTitle = (($Name -split '-') | ForEach-Object {
    if ($_.Length -gt 0) { $_.Substring(0, 1).ToUpper() + $_.Substring(1) } else { $_ }
}) -join ' '
$PyTag = 'py' + $Python.Replace('.', '')

if ($Dest.StartsWith('~')) { $Dest = Join-Path $HOME $Dest.Substring(1).TrimStart('\', '/') }
if (-not (Test-Path -LiteralPath $Dest -PathType Container)) {
    Stop-WithError "El directorio destino no existe: $Dest"
}
$DestAbs = (Resolve-Path -LiteralPath $Dest).Path
$Target = Join-Path $DestAbs $Name

if (Test-Path -LiteralPath $Target) {
    if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
        Stop-WithError "Ya existe un archivo (no un directorio) en: $Target"
    }
    $contenido = @(Get-ChildItem -LiteralPath $Target -Force)
    if ($contenido.Count -gt 0 -and -not $Force) {
        Stop-WithError @"
El directorio ya existe y no esta vacio: $Target
  Usa -Force para escribir dentro de todos modos, o elige otro nombre.
"@
    }
}

$hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
if (-not $NoGit -and -not $hasGit) {
    Stop-WithError @"
git no esta en el PATH.
  Instalalo, o genera el proyecto sin repositorio con -NoGit.
"@
}
if ($WithDocker -and -not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Warn "docker no esta en el PATH: el proyecto se genera igual, pero no podras levantarlo aqui."
}
if (-not (Get-Command python -ErrorAction SilentlyContinue) -and
    -not (Get-Command python3 -ErrorAction SilentlyContinue)) {
    Write-Warn "No se encontro Python: el proyecto se genera igual, pero no podras instalarlo ni correr los tests aqui."
}

# --- Localizar las plantillas ------------------------------------------------------------

$CloneDir = $null
$Templates = $null
if ($PSScriptRoot) { $Templates = Join-Path $PSScriptRoot 'templates' }

if (-not $Templates -or -not (Test-Path -LiteralPath $Templates -PathType Container)) {
    # Modo remoto: `iwr ... | iex`. El script llega solo, sin sus plantillas.
    if ($RepoUrl -like '*CAMBIAME*') {
        Stop-WithError @"
Ejecucion remota sin repositorio configurado.
  Edita `$DefaultRepo en el script, o define `$env:FPG_REPO = '<url del repo>'.
"@
    }
    if (-not $hasGit) { Stop-WithError "La ejecucion remota necesita git para descargar las plantillas." }
    Write-Step "Descargando las plantillas de $RepoUrl"
    $CloneDir = Join-Path ([System.IO.Path]::GetTempPath()) ("fpg-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    & git clone --quiet --depth 1 --branch $RepoRef $RepoUrl $CloneDir
    if ($LASTEXITCODE -ne 0) { Stop-WithError "No se pudo clonar $RepoUrl (rama $RepoRef)." }
    $Templates = Join-Path $CloneDir 'templates'
}
if (-not (Test-Path -LiteralPath (Join-Path $Templates 'base') -PathType Container)) {
    Stop-WithError "No se encuentran las plantillas en: $Templates"
}

# --- Motor de plantillas -------------------------------------------------------------------

$AptDb = if ($WithDb) { ' libpq-dev' } else { '' }

$Replacements = [ordered]@{
    '{{PROJECT_NAME}}'    = $Name
    '{{PROJECT_SNAKE}}'   = $ProjectSnake
    '{{PROJECT_TITLE}}'   = $ProjectTitle
    '{{PORT}}'            = "$Port"
    '{{PYTHON_VERSION}}'  = $Python
    '{{PY_TAG}}'          = $PyTag
    '{{APT_DB}}'          = $AptDb
}

# UTF-8 sin BOM y saltos de linea LF: un BOM al principio de un .py o un CRLF en un
# script del contenedor rompen en sitios dificiles de diagnosticar.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Convert-Template {
    param([string]$Content)
    foreach ($key in $Replacements.Keys) {
        $Content = $Content.Replace($key, $Replacements[$key])
    }
    return $Content
}

function Write-TextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), $Utf8NoBom)
}

function Copy-TemplateLayer {
    param([string]$Layer, [string]$Destination)
    $layerPath = Join-Path $Templates $Layer
    if (-not (Test-Path -LiteralPath $layerPath -PathType Container)) { return }
    $prefix = (Resolve-Path -LiteralPath $layerPath).Path
    foreach ($file in Get-ChildItem -LiteralPath $layerPath -Recurse -File -Force) {
        $rel = $file.FullName.Substring($prefix.Length).TrimStart('\', '/')
        $rel = $rel -replace '\\', '/'
        # Una capa posterior puede sobrescribir un archivo de `base`: asi el ejemplo
        # con CRUD reemplaza al stub cuando el proyecto lleva base de datos.
        if ($rel.EndsWith('.tmpl')) {
            $rel = $rel.Substring(0, $rel.Length - 5)
            $content = Convert-Template ([System.IO.File]::ReadAllText($file.FullName))
        } else {
            $content = [System.IO.File]::ReadAllText($file.FullName)
        }
        Write-TextFile (Join-Path $Destination ($rel -replace '/', [IO.Path]::DirectorySeparatorChar)) $content
    }
}

# Sustituye una linea-marcador por el contenido de uno o varios fragmentos (ya
# renderizados), o la borra si no se pasa ninguno. Es lo que hace condicional un
# archivo compartido sin mantener dos versiones enteras de el.
function Expand-Marker {
    param([string]$File, [string]$Marker, [string[]]$Fragments = @())
    if (-not (Test-Path -LiteralPath $File)) { return }

    $replacement = ''
    if ($Fragments.Count -gt 0) {
        $parts = foreach ($frag in $Fragments) {
            $path = Join-Path (Join-Path $Templates 'fragments') $frag
            if (-not (Test-Path -LiteralPath $path)) { Stop-WithError "Fragmento no encontrado: $frag" }
            Convert-Template ([System.IO.File]::ReadAllText($path))
        }
        $replacement = ($parts -join '')
    }

    $lines = ([System.IO.File]::ReadAllText($File) -replace "`r`n", "`n") -split "`n"
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line.Contains($Marker)) {
            if ($replacement -ne '') {
                foreach ($l in ($replacement.TrimEnd("`n") -split "`n")) { $out.Add($l) }
            }
        } else {
            $out.Add($line)
        }
    }
    Write-TextFile $File ($out -join "`n")
}

# --- Generar ---------------------------------------------------------------------------------

$WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) ("fpg-build-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
$Build = Join-Path $WorkDir $Name
New-Item -ItemType Directory -Path $Build -Force | Out-Null

try {
    Write-Step "Generando el esqueleto"
    Copy-TemplateLayer 'base' $Build
    if ($WithDb)     { Write-Step "Anadiendo base de datos (SQLAlchemy + Alembic)"; Copy-TemplateLayer 'db' $Build }
    if ($WithDocker) { Write-Step "Anadiendo Docker";                                Copy-TemplateLayer 'docker' $Build }
    if ($Quality)    { Write-Step "Anadiendo ruff, pre-commit y CI";                 Copy-TemplateLayer 'quality' $Build }

    $requirements = Join-Path $Build 'requirements.txt'
    $config       = Join-Path $Build 'app/core/config.py'
    $pyproject    = Join-Path $Build 'pyproject.toml'
    $envExample   = Join-Path $Build '.env.example'
    $readme       = Join-Path $Build 'README.md'
    $dockerfile   = Join-Path $Build 'Dockerfile'
    $compose      = Join-Path $Build 'docker-compose.yml'

    if ($WithDb) {
        Expand-Marker $requirements '#{{DB_REQUIREMENTS}}' @('requirements.db.txt')
        Expand-Marker $config       '#{{CONFIG_DB}}'       @('config.db.py')
        Expand-Marker $readme       '#{{README_STACK_DB}}' @('readme.stack.db.md')
        Expand-Marker $readme       '#{{README_SETUP_DB}}' @('readme.setup.db.md')
    } else {
        Expand-Marker $requirements '#{{DB_REQUIREMENTS}}'
        Expand-Marker $config       '#{{CONFIG_DB}}'
        Expand-Marker $readme       '#{{README_STACK_DB}}'
        Expand-Marker $readme       '#{{README_SETUP_DB}}'
    }

    if ($Quality) {
        Expand-Marker $requirements '#{{QUALITY_REQUIREMENTS}}' @('requirements.quality.txt')
        Expand-Marker $pyproject    '#{{QUALITY_PYPROJECT}}'    @('pyproject.quality.toml')
        Expand-Marker $readme       '#{{README_QUALITY}}'       @('readme.quality.md')
        # Este marcador solo existe si se acaba de insertar el bloque de ruff.
        if ($WithDb) { Expand-Marker $pyproject '#{{PYPROJECT_ISORT_DB}}' @('pyproject.quality.db.toml') }
        else         { Expand-Marker $pyproject '#{{PYPROJECT_ISORT_DB}}' }
    } else {
        Expand-Marker $requirements '#{{QUALITY_REQUIREMENTS}}'
        Expand-Marker $pyproject    '#{{QUALITY_PYPROJECT}}'
        Expand-Marker $readme       '#{{README_QUALITY}}'
    }

    # .env.example: la seccion de Postgres del compose solo tiene sentido con ambos.
    if     ($WithDb -and $WithDocker) { Expand-Marker $envExample '#{{ENV_DB}}' @('env.db.example', 'env.docker.example') }
    elseif ($WithDb)                  { Expand-Marker $envExample '#{{ENV_DB}}' @('env.db.example') }
    else                              { Expand-Marker $envExample '#{{ENV_DB}}' }

    if ($WithDocker) {
        if ($WithDb) {
            Expand-Marker $dockerfile '#{{DOCKERFILE_DB_COPY}}' @('dockerfile.db.copy')
            Expand-Marker $compose    '#{{COMPOSE_APP_DB}}'     @('compose.app.db.yml')
            Expand-Marker $compose    '#{{COMPOSE_DB_SERVICE}}' @('compose.db.service.yml')
            Expand-Marker $readme     '#{{README_DOCKER}}'      @('readme.docker.md', 'readme.docker.db.md')
        } else {
            # Sin base de datos no se levanta un Postgres "por si acaso": el compose
            # queda solo con la app.
            Expand-Marker $dockerfile '#{{DOCKERFILE_DB_COPY}}'
            Expand-Marker $compose    '#{{COMPOSE_APP_DB}}'
            Expand-Marker $compose    '#{{COMPOSE_DB_SERVICE}}'
            Expand-Marker $readme     '#{{README_DOCKER}}'      @('readme.docker.md')
        }
    } else {
        Expand-Marker $readme '#{{README_DOCKER}}'
    }

    # Red de seguridad: ningun marcador puede sobrevivir a la generacion.
    $sobrantes = Get-ChildItem -LiteralPath $Build -Recurse -File -Force |
        Select-String -Pattern '\{\{[A-Z_]+\}\}' -List
    if ($sobrantes) {
        $sobrantes | ForEach-Object { Write-Host $_.Line -ForegroundColor Red }
        Stop-WithError "Quedaron marcadores sin resolver (arriba). Es un bug del generador, no de tu proyecto."
    }
    # Y sin base de datos no puede quedar nada importando los modulos que no se generaron.
    if (-not $WithDb) {
        $fugas = Get-ChildItem -LiteralPath $Build -Recurse -File -Force |
            Select-String -Pattern 'app\.core\.database|app\.models|alembic' -List
        if ($fugas) {
            $fugas | ForEach-Object { Write-Host "$($_.Path): $($_.Line)" -ForegroundColor Red }
            Stop-WithError "Sin -WithDb quedaron referencias a modulos que no existen (arriba). Bug del generador."
        }
    }

    $total = (Get-ChildItem -LiteralPath $Build -Recurse -File -Force).Count

    if ($DryRun) {
        Write-Host ""
        Write-Host "-DryRun: no se escribio nada. Se habrian creado $total archivos en ${Target}:"
        $prefix = (Resolve-Path -LiteralPath $Build).Path
        Get-ChildItem -LiteralPath $Build -Recurse -File -Force |
            ForEach-Object { "  " + ($_.FullName.Substring($prefix.Length).TrimStart('\', '/') -replace '\\', '/') } |
            Sort-Object | Write-Host
        exit 0
    }

    Write-Step "Escribiendo en $Target"
    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
    Copy-Item -Path (Join-Path $Build '*') -Destination $Target -Recurse -Force
}
finally {
    if (Test-Path -LiteralPath $WorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($CloneDir -and (Test-Path -LiteralPath $CloneDir)) { Remove-Item -LiteralPath $CloneDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Git ---------------------------------------------------------------------------------------

$gitMsg = "sin repositorio (-NoGit)"
if (-not $NoGit) {
    if (Test-Path -LiteralPath (Join-Path $Target '.git')) {
        $gitMsg = "ya habia un repositorio; no se toco"
    } else {
        Write-Step "Inicializando git"
        Push-Location $Target
        try {
            & git init --quiet
            # `git init -b main` necesita git >= 2.28; esto funciona en cualquier version.
            & git symbolic-ref HEAD refs/heads/main
            & git add -A
            & git -c user.name="fastapi-project-generator" `
                  -c user.email="generator@localhost" `
                  commit --quiet -m "chore: scaffold inicial de $Name" 2>&1 | Out-Null
            $gitMsg = "rama main, 1 commit"
        } finally { Pop-Location }
    }
}

# --- Resumen -------------------------------------------------------------------------------------

$modulos = 'base'
if ($WithDb)     { $modulos += ' + db' }
if ($WithDocker) { $modulos += ' + docker' }
if ($Quality)    { $modulos += ' + calidad' }

Write-Host ""
Write-Ok "Proyecto '$Name' creado en $Target"
Write-Host "  Modulos: $modulos"
Write-Host "  $total archivos - Python $Python - puerto $Port - git: $gitMsg"
Write-Host ""
Write-Host "Proximos pasos" -ForegroundColor White
Write-Host "  cd $Name"
Write-Host "  Copy-Item .env.example .env             # completa JWT_SECRET_KEY"
if ($WithDocker) {
    Write-Host "  docker compose up -d --build"
    if ($WithDb) { Write-Host "  docker compose exec app alembic upgrade head" }
    Write-Host ""
    Write-Host "  Sin Docker:"
    Write-Host "  python -m venv venv; .\venv\Scripts\Activate.ps1"
    Write-Host "  pip install -r requirements.txt"
    Write-Host "  uvicorn app.main:app --reload --port $Port"
} else {
    Write-Host "  python -m venv venv; .\venv\Scripts\Activate.ps1"
    Write-Host "  pip install -r requirements.txt"
    if ($WithDb) {
        Write-Host "  # crea la base $ProjectSnake y ajusta DATABASE_URL en .env"
        Write-Host "  alembic revision --autogenerate -m 'initial schema'; alembic upgrade head"
    }
    Write-Host "  uvicorn app.main:app --reload --port $Port"
}
Write-Host "  pytest"
Write-Host ""
Write-Host "  -> http://localhost:$Port/docs"
