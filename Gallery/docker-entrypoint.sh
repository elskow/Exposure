#!/bin/sh
set -e

# Fix ownership of mounted volumes (runs as root, then drops to appuser)
chown -R appuser:appgroup /app/data 2>/dev/null || true
chown -R appuser:appgroup /app/wwwroot/images/places 2>/dev/null || true

# Switch to appuser and run the app
exec su-exec appuser dotnet Gallery.dll "$@"
