# SOURCE: https://docs.litestar.dev/2/topics/deployment/docker.html
# Set the base image using Python 3.12
FROM python:3.12-slim
ENV PYTHON_ENV=development

# Create a non-root user
RUN addgroup --system app && adduser --system --group app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv

# Copy application into the container
WORKDIR /app
COPY . /app

# Install dependencies
RUN uv sync --frozen --no-cache

# Set application ownership to non-root user
RUN chown -R app:app /app
USER app

# Run the app
CMD . ./.venv/bin/activate && exec uvicorn --port $PORT --host 0.0.0.0 src.main:app --log-level error
