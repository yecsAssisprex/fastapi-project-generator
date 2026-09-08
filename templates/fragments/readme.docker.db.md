
Con la base ya arriba, aplicar las migraciones dentro del contenedor:

```bash
docker compose exec app alembic upgrade head
```

Los datos de Postgres viven en el volumen `pgdata` y sobreviven a `docker compose
down`. Para empezar de cero: `docker compose down -v`.
