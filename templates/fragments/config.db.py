
    # --- Base de datos (PostgreSQL) ---
    # El prefijo `+psycopg` es el driver de SQLAlchemy: psycopg 3, sincrono.
    database_url: str = "postgresql+psycopg://postgres:postgres@localhost:5432/{{PROJECT_SNAKE}}"
