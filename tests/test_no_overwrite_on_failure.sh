#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/previous.html" <<'HTML'
<!DOCTYPE html><html><body><h1>PREVIOUS DATA</h1></body></html>
HTML

# Falso curl para simular que la API falla, y PATH sin jq para que el script falle antes de escribir el resultado final.
cat > "$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
case "$*" in
  *"/api/v1/auth"*) echo '{"auth_token":"faketoken"}' ;;
  *) echo '[]' ;;
 esac
CURL
chmod +x "$WORK/bin/curl"

OUT="$WORK/out.html"
cp "$WORK/previous.html" "$OUT"

PATH="$WORK/bin:/bin:/usr/bin" \
TAIGA_BASE_URL="https://taiga.example.com" \
TAIGA_PROJECT_ID="42" \
TAIGA_AUTH_TOKEN="faketoken" \
TZ="America/Bogota" \
  bash "$REPO/scripts/export_tasks_html.sh" "$OUT" >/tmp/test_no_overwrite.log 2>&1 || true

if grep -q "PREVIOUS DATA" "$OUT"; then
  echo "OK: el archivo anterior se conserva cuando la actualización falla"
  exit 0
fi

echo "FAIL: el archivo se sobrescribió aunque la actualización falló" >&2
cat "$OUT" >&2
exit 1
