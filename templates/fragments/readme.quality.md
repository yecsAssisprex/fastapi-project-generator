
## Calidad

```bash
ruff check .          # lint
ruff format .         # formato
pre-commit install    # una vez: engancha ruff al commit
```

`.github/workflows/ci.yml` corre lint, formato y tests en cada push y pull request.
