
## Docker

```bash
cp .env.example .env
docker compose up -d --build
docker compose logs -f app
```

El `.env` **no** se copia a la imagen: las variables se inyectan al correr.
