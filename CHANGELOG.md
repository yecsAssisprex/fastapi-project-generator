# Changelog

## 1.0.0 — 2026-09-08

Primera version. Extraida del patron real de los nueve servicios FastAPI de Allegro
(ver `ARCHITECTURE.md` en ese repositorio).

- `bootstrap.sh` y `bootstrap.ps1`, con comportamiento identico: la misma
  combinacion de flags produce los mismos archivos byte a byte en ambos.
- Esqueleto base: FastAPI, `Settings` con pydantic-settings, autenticacion JWT
  completa, un recurso de ejemplo y su suite de tests.
- `--with-db`: SQLAlchemy 2 + Alembic + psycopg 3, con CRUD y tests.
- `--with-docker`: `Dockerfile` y `docker-compose.yml` (con Postgres si hay `--with-db`).
- Calidad por defecto (`--no-quality` para omitirla): ruff, pre-commit y CI.
- 330 aserciones de extremo a extremo en `tests/e2e.sh`.
