FROM python:3.12-slim

RUN pip install --no-cache-dir uv

WORKDIR /app

COPY pyproject.toml ./
COPY src/ ./src/
COPY migrations/ ./migrations/

RUN uv sync --no-dev

CMD ["uv", "run", "--no-sync", "python", "-m", "gamblobot.main"]
