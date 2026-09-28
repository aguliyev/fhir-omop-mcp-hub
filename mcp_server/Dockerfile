FROM python:3.12-slim@sha256:44ff437bba879d4941b710a369a8f19266aea34b29002807f0c487fabc9eec9b

# Build context is ./mcp_server, which IS the package dir: stage it as
# /app/mcp_server next to pyproject.toml so setuptools packages.find resolves.
WORKDIR /app
COPY pyproject.toml ./
COPY . ./mcp_server/
RUN pip install --no-cache-dir .
EXPOSE 8000
CMD ["python", "-m", "mcp_server.server"]
