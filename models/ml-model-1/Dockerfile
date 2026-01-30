ARG PYTHON_VERSION="3.10"

FROM python:${PYTHON_VERSION}-slim AS builder
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

# Disable Python downloads, because we want to use the system interpreter
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0 UV_NATIVE_TLS=1

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Use Zscaler certificate when BUILD_ENV is 'local'. This must be set when building locally.
ARG BUILD_ENV=git-actions
ENV BUILD_ENV=$BUILD_ENV

COPY certificates/ /usr/local/share/ca-certificates/

RUN if [ "$BUILD_ENV" = "git-actions" ] ; then echo "non-local env"; else echo "local env: BUILD_ENV"; update-ca-certificates ; fi

RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev --group service

COPY pyproject.toml uv.lock README.md /app/
COPY src /app/

# Add VERSION argument after dependencies are installed to preserve cache
ARG VERSION
ENV VERSION=${VERSION}

# Set the version in the project if VERSION is provided
RUN if [ -n "$VERSION" ]; then \
    uv version "$VERSION"; \
    fi

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev --group service

FROM python:${PYTHON_VERSION}-slim

RUN apt-get update && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*
    
RUN groupadd --system --gid 999 nonroot \
    && useradd --system --gid 999 --uid 999 --create-home nonroot

COPY --from=builder --chown=nonroot:nonroot /app /app

ENV PATH="/app/.venv/bin:$PATH"

USER nonroot

WORKDIR /app

CMD ["python", "app.py"]