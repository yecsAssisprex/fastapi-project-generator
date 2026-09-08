
### Base de datos

```sql
CREATE DATABASE {{PROJECT_SNAKE}};
```

```bash
alembic revision --autogenerate -m "initial schema"   # la primera vez
alembic upgrade head
```

El arranque **no** crea tablas: el esquema lo gestionan las migraciones. La URL sale
de `DATABASE_URL`, no del `alembic.ini`.

### El servicio
