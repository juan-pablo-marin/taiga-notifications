#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Export active Taiga tasks to HTML — NO notifications sent
# Filtra por estados activos: New, Ready, In progress, Code Review,
# Ready for test, QA Testing, QA rejected
# =============================================================================

: "${TAIGA_BASE_URL:?Definir TAIGA_BASE_URL}"
: "${TAIGA_PROJECT_ID:?Definir TAIGA_PROJECT_ID}"

TAIGA_BASE_URL="${TAIGA_BASE_URL%/}"
TAIGA_USERNAME="${TAIGA_USERNAME:-}"
TAIGA_PASSWORD="${TAIGA_PASSWORD:-}"
TAIGA_AUTH_TOKEN="${TAIGA_AUTH_TOKEN:-}"
TAIGA_SSL_VERIFY="${TAIGA_SSL_VERIFY:-1}"
TAIGA_PROJECT_SLUG="${TAIGA_PROJECT_SLUG:-}"
TAIGA_WEB_UI_BASE_URL="${TAIGA_WEB_UI_BASE_URL:-$TAIGA_BASE_URL}"

CURL_EXTRA=()
case "${TAIGA_SSL_VERIFY,,}" in 0|false|no|off) CURL_EXTRA=(-k) ;; esac

OUTPUT_FILE="${1:-/output/tareas_activas.html}"
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Estados activos
ACTIVE_STATUSES='["New","Ready","In progress","Code Review","Ready for test","QA Testing","QA rejected"]'

log() { echo "[export-html] $*" >&2; }

get_token() {
  if [[ -n "$TAIGA_AUTH_TOKEN" ]]; then echo "$TAIGA_AUTH_TOKEN"; return; fi
  local resp tok
  resp="$(curl "${CURL_EXTRA[@]}" -sS -X POST "${TAIGA_BASE_URL}/api/v1/auth" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg u "$TAIGA_USERNAME" --arg p "$TAIGA_PASSWORD" '{type:"normal",username:$u,password:$p}')")"
  tok="$(echo "$resp" | jq -r '.auth_token // empty')"
  [[ -z "$tok" ]] && { log "Fallo login Taiga"; exit 1; }
  echo "$tok"
}

# Fetch all pages writing to a file to avoid argument-too-long errors
fetch_all_pages_to_file() {
  local token="$1" url="$2" outfile="$3"
  local page=1 headers_file tmpfile
  headers_file="$(mktemp)"
  echo '[]' > "$outfile"

  while [[ -n "$url" ]]; do
    tmpfile="$(mktemp)"
    log "  Pagina $page: $url"
    curl "${CURL_EXTRA[@]}" -sS -D "$headers_file" -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" "$url" > "$tmpfile" 2>&1 || { log "  curl fallo"; break; }

    # Merge into accumulator
    if jq -e 'type=="array"' "$tmpfile" >/dev/null 2>&1; then
      jq -s '.[0] + .[1]' "$outfile" "$tmpfile" > "${outfile}.tmp" && mv "${outfile}.tmp" "$outfile"
    elif jq -e 'has("results")' "$tmpfile" >/dev/null 2>&1; then
      jq '.results' "$tmpfile" > "${tmpfile}.r"
      jq -s '.[0] + .[1]' "$outfile" "${tmpfile}.r" > "${outfile}.tmp" && mv "${outfile}.tmp" "$outfile"
      rm -f "${tmpfile}.r"
    else
      rm -f "$tmpfile"
      break
    fi
    rm -f "$tmpfile"

    # Check for next page
    local next_url
    next_url="$(grep -i '^X-Pagination-Next:' "$headers_file" | sed 's/^[^:]*: *//;s/[[:space:]]*$//' | tr -d '\r')"
    if [[ -z "$next_url" ]]; then
      break
    fi
    url="$next_url"
    page=$((page+1)); [[ $page -gt 500 ]] && break
  done
  rm -f "$headers_file"
}

log "Autenticando con Taiga..."
TOKEN="$(get_token)"

log "Obteniendo TODAS las tareas del proyecto (paginado)..."
TASKS_FILE="$TMPDIR_WORK/tasks.json"
fetch_all_pages_to_file "$TOKEN" "${TAIGA_BASE_URL}/api/v1/tasks?project=${TAIGA_PROJECT_ID}" "$TASKS_FILE"
log "  Tasks obtenidas: $(jq 'length' "$TASKS_FILE")"

log "Obteniendo TODAS las user stories del proyecto (paginado)..."
US_FILE="$TMPDIR_WORK/userstories.json"
fetch_all_pages_to_file "$TOKEN" "${TAIGA_BASE_URL}/api/v1/userstories?project=${TAIGA_PROJECT_ID}" "$US_FILE"
log "  User stories obtenidas: $(jq 'length' "$US_FILE")"

export TZ="${TZ:-America/Bogota}"
TODAY="$(date +%Y-%m-%d)"
TOMORROW="$(date -d "$TODAY + 1 day" +%Y-%m-%d 2>/dev/null || jq -nr --arg t "$TODAY" '$t | strptime("%Y-%m-%d") | mktime + 86400 | strftime("%Y-%m-%d")')"

log "Hoy: $TODAY | Mañana: $TOMORROW"

# Combine, add entity_type, filter by active statuses, normalize dates
ALL_FILE="$TMPDIR_WORK/all_active.json"
echo "$ACTIVE_STATUSES" > "$TMPDIR_WORK/statuses.json"

jq -s --slurpfile statuses "$TMPDIR_WORK/statuses.json" '
  ((.[0] // []) | map(. + {entity_type:"task"})) +
  ((.[1] // []) | map(. + {entity_type:"userstory"}))
  | map(select(.status_extra_info.name as $s | $statuses[0] | index($s) != null))
  | map(.due_date_clean = (if .due_date then (.due_date | tostring | split("T")[0]) else null end))
  | sort_by(.due_date_clean // "9999-99-99")
' "$TASKS_FILE" "$US_FILE" > "$ALL_FILE"

TOTAL="$(jq 'length' "$ALL_FILE")"
log "Total activas (filtradas por estado): $TOTAL"

# Split by date category
OVERDUE_FILE="$TMPDIR_WORK/overdue.json"
TODAY_FILE="$TMPDIR_WORK/today.json"
TOMORROW_FILE="$TMPDIR_WORK/tomorrow.json"
FUTURE_FILE="$TMPDIR_WORK/future.json"
NODATE_FILE="$TMPDIR_WORK/nodate.json"

jq --arg t "$TODAY" '[.[] | select(.due_date_clean != null and .due_date_clean < $t)]' "$ALL_FILE" > "$OVERDUE_FILE"
jq --arg t "$TODAY" '[.[] | select(.due_date_clean == $t)]' "$ALL_FILE" > "$TODAY_FILE"
jq --arg t "$TOMORROW" '[.[] | select(.due_date_clean != null and .due_date_clean == $t)]' "$ALL_FILE" > "$TOMORROW_FILE"
jq --arg t "$TOMORROW" '[.[] | select(.due_date_clean != null and .due_date_clean > $t)]' "$ALL_FILE" > "$FUTURE_FILE"
jq '[.[] | select(.due_date_clean == null)]' "$ALL_FILE" > "$NODATE_FILE"

log "Vencidas: $(jq 'length' "$OVERDUE_FILE") | Hoy: $(jq 'length' "$TODAY_FILE") | Mañana: $(jq 'length' "$TOMORROW_FILE") | Futuro: $(jq 'length' "$FUTURE_FILE") | Sin fecha: $(jq 'length' "$NODATE_FILE")"

# Generate HTML table rows from a file
generate_table_rows_from_file() {
  local file="$1"
  jq -r '.[] |
    "<tr>" +
    "<td>" + (.entity_type // "task") + "</td>" +
    "<td>#" + (.ref|tostring) + "</td>" +
    "<td>" + (.subject // "Sin título") + "</td>" +
    "<td>" + ((.assigned_to_extra_info.full_name_display) // "Sin asignar") + "</td>" +
    "<td>" + ((.assigned_to_extra_info.username) // "-") + "</td>" +
    "<td>" + (.due_date_clean // "Sin fecha") + "</td>" +
    "<td>" + ((.status_extra_info.name) // "-") + "</td>" +
    "</tr>"' "$file"
}

mkdir -p "$(dirname "$OUTPUT_FILE")"

cat > "$OUTPUT_FILE" <<'HEADER'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Tareas Activas - Taiga APE</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #f5f7fa; color: #333; padding: 20px; }
  h1 { text-align: center; margin-bottom: 10px; color: #2c3e50; }
  .meta { text-align: center; color: #666; margin-bottom: 30px; font-size: 0.9em; }
  .filters-wrap { text-align: center; margin-bottom: 20px; }
  .filters { display: inline-block; color: #555; font-size: 0.85em; background: #eef2f7; padding: 8px 15px; border-radius: 6px; }
  .section { margin-bottom: 30px; }
  .section h2 { padding: 10px 15px; border-radius: 6px 6px 0 0; margin: 0; font-size: 1.1em; }
  .overdue h2 { background: #e74c3c; color: white; }
  .today h2 { background: #f39c12; color: white; }
  .tomorrow h2 { background: #3498db; color: white; }
  .future h2 { background: #27ae60; color: white; }
  .nodate h2 { background: #95a5a6; color: white; }
  table { width: 100%; border-collapse: collapse; background: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); border-radius: 0 0 6px 6px; overflow: hidden; }
  th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid #eee; font-size: 0.9em; }
  th { background: #f8f9fa; font-weight: 600; color: #555; }
  tr:hover { background: #f0f7ff; }
  .count { font-size: 0.85em; opacity: 0.9; margin-left: 8px; }
  .empty { padding: 20px; text-align: center; color: #999; background: white; border-radius: 0 0 6px 6px; }
</style>
</head>
<body>
HEADER

{
  echo "<h1>📋 Tareas Activas — Taiga APE</h1>"
  echo "<div class='meta'>Generado: $(date '+%Y-%m-%d %H:%M:%S %Z') | Proyecto: ${TAIGA_PROJECT_SLUG:-$TAIGA_PROJECT_ID} | Total: $TOTAL items</div>"
  echo "<div class='filters-wrap'><div class='filters'>📌 Estados incluidos: New, Ready, In progress, Code Review, Ready for test, QA Testing, QA rejected</div></div>"

  render_section() {
    local class="$1" title="$2" file="$3"
    local count; count="$(jq 'length' "$file")"
    echo "<div class='section $class'>"
    echo "<h2>$title<span class='count'>($count)</span></h2>"
    if [[ "$count" -eq 0 ]]; then
      echo "<div class='empty'>No hay items en esta categoría</div>"
    else
      echo "<table><thead><tr><th>Tipo</th><th>Ref</th><th>Asunto</th><th>Responsable</th><th>Usuario</th><th>Fecha</th><th>Estado</th></tr></thead><tbody>"
      generate_table_rows_from_file "$file"
      echo "</tbody></table>"
    fi
    echo "</div>"
  }

  render_section "overdue" "🔴 VENCIDAS" "$OVERDUE_FILE"
  render_section "today" "🟠 VENCEN HOY ($TODAY)" "$TODAY_FILE"
  render_section "tomorrow" "🔵 VENCEN MAÑANA ($TOMORROW)" "$TOMORROW_FILE"
  render_section "future" "🟢 FUTURAS" "$FUTURE_FILE"
  render_section "nodate" "⚪ SIN FECHA DE VENCIMIENTO" "$NODATE_FILE"

  echo "</body></html>"
} >> "$OUTPUT_FILE"

log "HTML generado: $OUTPUT_FILE"
