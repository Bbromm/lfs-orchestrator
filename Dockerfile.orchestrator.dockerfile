FROM python:3.12-slim

LABEL maintainer="LFS Orchestrator"
LABEL description="DAG-based orchestrator for Linux From Scratch"

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY pyproject.toml requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./src/
COPY config/ ./config/
RUN pip install --no-cache-dir -e .

RUN mkdir -p /data /logs

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["uvicorn", "lfs_orchestrator.api:app", "--host", "0.0.0.0", "--port", "8000"]