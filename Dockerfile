FROM python:3.11-slim
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt pyproject.toml ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
ENV PORT=8080
ENV PYTHONUNBUFFERED=1
ENV ADK_ENABLE_MCP_GRACEFUL_ERROR_HANDLING=1
ENV OTEL_SDK_DISABLED=true
ENV GOOGLE_GENAI_USE_VERTEXAI=1
CMD ["python", "-m", "uvicorn", "app.fast_api_app:app", "--host", "0.0.0.0", "--port", "8080"]
