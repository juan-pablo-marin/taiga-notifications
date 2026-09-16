#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# Export active Taiga items to a professional, self-contained HTML report.
# NO notifications are sent.
#
# Incluye:
#   - Tareas y User Stories (estados activos)
#   - Issues / Incidencias (no cerradas)
#
# La vista separa "Tareas & User Stories" de "Issues", con KPIs, badges de
# vencimiento, enlaces a Taiga y filtros interactivos (responsable, estado,
# vencimiento, grupo/tipo, prioridad, severidad), orden por columnas y
# exportación a CSV. Todo el filtrado ocurre en el navegador (JS embebido),
# sin depender de un servidor.
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
TAIGA_WEB_UI_BASE_URL="${TAIGA_WEB_UI_BASE_URL%/}"

CURL_EXTRA=()
case "${TAIGA_SSL_VERIFY,,}" in 0|false|no|off) CURL_EXTRA=(-k) ;; esac

OUTPUT_FILE="${1:-/output/tareas_activas.html}"
TMPDIR_WORK="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# Estados activos para tasks y user stories
ACTIVE_STATUSES='["New","Ready","In progress","Code Review","Ready for test","QA Testing","QA Rejected","Waiting Deploy"]'

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

log "Obteniendo TODOS los issues del proyecto (paginado)..."
ISSUES_FILE="$TMPDIR_WORK/issues.json"
fetch_all_pages_to_file "$TOKEN" "${TAIGA_BASE_URL}/api/v1/issues?project=${TAIGA_PROJECT_ID}" "$ISSUES_FILE"
log "  Issues obtenidos: $(jq 'length' "$ISSUES_FILE")"

log "Obteniendo miembros del proyecto..."
MEMBERS_FILE="$TMPDIR_WORK/members.json"
fetch_all_pages_to_file "$TOKEN" "${TAIGA_BASE_URL}/api/v1/memberships?project=${TAIGA_PROJECT_ID}" "$MEMBERS_FILE"
log "  Miembros obtenidos: $(jq 'length' "$MEMBERS_FILE")"

# Catálogos de issues (el listado solo trae IDs numéricos para priority/severity/type)
log "Obteniendo catálogos de issues (prioridades, severidades, tipos)..."
PRIORITIES_FILE="$TMPDIR_WORK/priorities.json"
SEVERITIES_FILE="$TMPDIR_WORK/severities.json"
ISSUE_TYPES_FILE="$TMPDIR_WORK/issue_types.json"
fetch_all_pages_to_file "$TOKEN" "${TAIGA_BASE_URL}/api/v1/priorities?project=${TAIGA_PROJECT_ID}" "$PRIORITIES_FILE"
fetch_all_pages_to_file "$TOKEN" "${TAIGA_BASE_URL}/api/v1/severities?project=${TAIGA_PROJECT_ID}" "$SEVERITIES_FILE"
fetch_all_pages_to_file "$TOKEN" "${TAIGA_BASE_URL}/api/v1/issue-types?project=${TAIGA_PROJECT_ID}" "$ISSUE_TYPES_FILE"
log "  Prioridades: $(jq 'length' "$PRIORITIES_FILE") | Severidades: $(jq 'length' "$SEVERITIES_FILE") | Tipos: $(jq 'length' "$ISSUE_TYPES_FILE")"

export TZ="${TZ:-America/Bogota}"
TODAY="$(date +%Y-%m-%d)"
TOMORROW="$(date -d "$TODAY + 1 day" +%Y-%m-%d 2>/dev/null || jq -nr --arg t "$TODAY" '$t | strptime("%Y-%m-%d") | mktime + 86400 | strftime("%Y-%m-%d")')"
GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S %Z')"

log "Hoy: $TODAY | Mañana: $TOMORROW"

# ---------------------------------------------------------------------------
# Normalizamos todo a un único arreglo JSON. El navegador se encarga del
# filtrado/orden, así que aquí solo dejamos los datos limpios.
# ---------------------------------------------------------------------------
DATA_FILE="$TMPDIR_WORK/data.json"

jq -n -c \
  --slurpfile tasks "$TASKS_FILE" \
  --slurpfile us "$US_FILE" \
  --slurpfile issues "$ISSUES_FILE" \
  --slurpfile members "$MEMBERS_FILE" \
  --slurpfile priorities "$PRIORITIES_FILE" \
  --slurpfile severities "$SEVERITIES_FILE" \
  --slurpfile issuetypes "$ISSUE_TYPES_FILE" \
  --arg today "$TODAY" \
  --arg tomorrow "$TOMORROW" \
  --arg webbase "$TAIGA_WEB_UI_BASE_URL" \
  --arg slug "$TAIGA_PROJECT_SLUG" \
  --argjson statuses "$ACTIVE_STATUSES" '
  ($members[0] // []) as $members_list |
  (($priorities[0] // []) | map({key:(.id|tostring), value:.name}) | from_entries) as $prio_map |
  (($severities[0] // []) | map({key:(.id|tostring), value:.name}) | from_entries) as $sev_map |
  (($issuetypes[0] // []) | map({key:(.id|tostring), value:.name}) | from_entries) as $type_map |
  def assignee_label($item):
    if (($item.assigned_users // []) | length) > 1 then
      [ $item.assigned_users[] as $uid
        | (($members_list[] | select(.user == $uid) | .full_name) // "Usuario #\($uid)") ]
      | join(", ")
    else
      (($item.assigned_to_extra_info.full_name_display) // "Sin asignar")
    end;
  def kind_path($t):
    if $t == "userstory" then "us"
    elif $t == "issue" then "issue"
    else "task" end;
  def group_of($t):
    if $t == "issue" then "issue" else "work" end;
  def norm($item; $t):
    (if $item.due_date then ($item.due_date | tostring | split("T")[0]) else null end) as $due
    | {
        type: $t,
        group: group_of($t),
        ref: $item.ref,
        subject: ($item.subject // "Sin título"),
        assignee: assignee_label($item),
        username: (($item.assigned_to_extra_info.username) // "-"),
        due: $due,
        category: (
          if $due == null then "nodate"
          elif $due < $today then "overdue"
          elif $due == $today then "today"
          elif $due == $tomorrow then "tomorrow"
          else "future" end
        ),
        status: (($item.status_extra_info.name) // "-"),
        priority: (($item.priority_extra_info.name) // ($item.priority | if . == null then null else $prio_map[(.|tostring)] end)),
        severity: (($item.severity_extra_info.name) // ($item.severity | if . == null then null else $sev_map[(.|tostring)] end)),
        issue_type: (($item.type_extra_info.name) // ($item.type | if . == null then null else $type_map[(.|tostring)] end)),
        url: (
          if ($webbase | length) > 0 and ($slug | length) > 0
          then "\($webbase)/project/\($slug)/\(kind_path($t))/\($item.ref)"
          else "" end
        )
      };
  (
    ( ($tasks[0]  // []) | map(select(.status_extra_info.name as $s | $statuses | index($s) != null)) | map(norm(.; "task")) )
    + ( ($us[0]     // []) | map(select(.status_extra_info.name as $s | $statuses | index($s) != null)) | map(norm(.; "userstory")) )
    + ( ($issues[0] // []) | map(select((.status_extra_info.is_closed) // false | not)) | map(norm(.; "issue")) )
  )
  | sort_by(.due // "9999-99-99", .ref)
' > "$DATA_FILE"

WORK_TOTAL="$(jq '[.[] | select(.group=="work")] | length' "$DATA_FILE")"
ISSUE_TOTAL="$(jq '[.[] | select(.group=="issue")] | length' "$DATA_FILE")"
TOTAL="$(jq 'length' "$DATA_FILE")"
log "Total: $TOTAL (Tareas/US: $WORK_TOTAL | Issues: $ISSUE_TOTAL)"

mkdir -p "$(dirname "$OUTPUT_FILE")"

# ---------------------------------------------------------------------------
# HTML: cabecera + estilos (heredoc sin expansión de variables)
# ---------------------------------------------------------------------------
cat > "$OUTPUT_FILE" <<'HEADER'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Reporte de Validación — Taiga APE</title>
<style>
  :root {
    --bg: #f4f6fb; --panel: #fff; --text: #2c3e50; --muted: #7a869a;
    --border: #e6e9f0; --accent: #2563eb; --accent-weak: #eef4ff;
    --overdue: #e74c3c; --today: #f39c12; --tomorrow: #2980b9;
    --future: #27ae60; --nodate: #95a5a6;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: var(--bg); color: var(--text); padding: 24px; }
  header.top { margin-bottom: 18px; }
  h1 { font-size: 1.5em; color: var(--text); display: flex; align-items: center; gap: 10px; }
  .meta { color: var(--muted); margin-top: 6px; font-size: 0.88em; }
  .meta code { background: #eef2f7; padding: 1px 6px; border-radius: 4px; }

  /* KPI cards */
  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 12px; margin: 18px 0; }
  .kpi { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; box-shadow: 0 1px 3px rgba(16,24,40,0.04); cursor: pointer; transition: transform .08s ease, box-shadow .12s ease, border-color .12s ease; position: relative; }
  .kpi:hover { border-color: var(--accent); box-shadow: 0 3px 10px rgba(16,24,40,0.10); transform: translateY(-1px); }
  .kpi.active { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-weak); }
  .kpi.active::after { content: "●"; position: absolute; top: 8px; right: 10px; font-size: 0.6em; color: var(--accent); }
  .kpi .label { font-size: 0.75em; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
  .kpi .value { font-size: 1.7em; font-weight: 700; margin-top: 4px; }
  .kpi.overdue .value { color: var(--overdue); }
  .kpi.today .value { color: var(--today); }
  .kpi.tomorrow .value { color: var(--tomorrow); }
  .kpi.future .value { color: var(--future); }
  .kpi.nodate .value { color: var(--nodate); }

  /* Filters */
  .toolbar { background: var(--panel); border: 1px solid var(--border); border-radius: 10px; padding: 14px 16px; margin-bottom: 18px; box-shadow: 0 1px 3px rgba(16,24,40,0.04); }
  .toolbar .row { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; }
  .field { display: flex; flex-direction: column; gap: 4px; }
  .field label { font-size: 0.72em; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
  .field input, .field select { padding: 8px 10px; border: 1px solid var(--border); border-radius: 8px; font-size: 0.9em; background: #fff; min-width: 150px; color: var(--text); }
  .field input:focus, .field select:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-weak); }
  .field.grow { flex: 1 1 240px; }
  .field.grow input { width: 100%; }
  .toolbar .actions { display: flex; gap: 8px; margin-left: auto; }
  button.btn { padding: 8px 14px; border: 1px solid var(--border); background: #fff; border-radius: 8px; font-size: 0.88em; cursor: pointer; color: var(--text); font-weight: 600; }
  button.btn:hover { background: var(--accent-weak); border-color: var(--accent); }
  button.btn.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
  button.btn.primary:hover { filter: brightness(1.05); }

  /* Sections */
  .section { margin-bottom: 28px; }
  .section > h2 { font-size: 1.1em; padding: 12px 16px; background: var(--text); color: #fff; border-radius: 10px 10px 0 0; display: flex; align-items: center; gap: 10px; }
  .section.issues > h2 { background: #7b341e; }
  .section > h2 .count { margin-left: auto; font-size: 0.85em; font-weight: 500; opacity: .92; }
  .table-wrap { background: var(--panel); border: 1px solid var(--border); border-top: none; border-radius: 0 0 10px 10px; overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; }
  th, td { padding: 10px 12px; text-align: left; border-bottom: 1px solid var(--border); font-size: 0.88em; vertical-align: top; }
  th { background: #f8f9fc; font-weight: 600; color: #55617a; white-space: nowrap; cursor: pointer; user-select: none; position: sticky; top: 0; }
  th .arrow { color: var(--accent); font-size: 0.8em; }
  tbody tr:hover { background: #f7faff; }
  td.subject { min-width: 280px; }
  a.ref { color: var(--accent); text-decoration: none; font-weight: 600; white-space: nowrap; }
  a.ref:hover { text-decoration: underline; }

  .badge { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 0.76em; font-weight: 600; color: #fff; white-space: nowrap; }
  .badge.overdue { background: var(--overdue); }
  .badge.today { background: var(--today); }
  .badge.tomorrow { background: var(--tomorrow); }
  .badge.future { background: var(--future); }
  .badge.nodate { background: var(--nodate); }
  .pill { display: inline-block; padding: 2px 8px; border-radius: 6px; font-size: 0.78em; background: #eef2f7; color: #55617a; white-space: nowrap; }
  .pill.type-issue { background: #fbe9e7; color: #b03a2e; }
  .pill.type-userstory { background: #e8f0fe; color: #1a5276; }
  .pill.type-task { background: #eafaf1; color: #1e8449; }

  .empty { padding: 22px; text-align: center; color: var(--muted); }
  .note { margin-top: 20px; text-align: center; color: var(--muted); font-size: 0.82em; }
</style>
</head>
<body>
<header class="top">
  <h1>🧾 Reporte de Validación — Taiga APE</h1>
  <div class="meta" id="meta"></div>
</header>

<div class="kpis" id="kpis"></div>

<div class="toolbar">
  <div class="row">
    <div class="field grow">
      <label for="f-search">Buscar (asunto / #ref / responsable)</label>
      <input type="text" id="f-search" placeholder="Escribe para filtrar...">
    </div>
    <div class="field">
      <label for="f-group">Grupo</label>
      <select id="f-group">
        <option value="">Todos</option>
        <option value="work">Tareas &amp; User Stories</option>
        <option value="issue">Issues</option>
      </select>
    </div>
    <div class="field">
      <label for="f-type">Tipo</label>
      <select id="f-type"><option value="">Todos</option></select>
    </div>
    <div class="field">
      <label for="f-assignee">Responsable</label>
      <select id="f-assignee"><option value="">Todos</option></select>
    </div>
    <div class="field">
      <label for="f-status">Estado</label>
      <select id="f-status"><option value="">Todos</option></select>
    </div>
    <div class="field">
      <label for="f-due">Vencimiento</label>
      <select id="f-due">
        <option value="">Todos</option>
        <option value="overdue">🔴 Vencidas</option>
        <option value="today">🟠 Vencen hoy</option>
        <option value="tomorrow">🔵 Vencen mañana</option>
        <option value="future">🟢 Futuras</option>
        <option value="nodate">⚪ Sin fecha</option>
      </select>
    </div>
    <div class="field">
      <label for="f-priority">Prioridad (issues)</label>
      <select id="f-priority"><option value="">Todas</option></select>
    </div>
    <div class="field">
      <label for="f-severity">Severidad (issues)</label>
      <select id="f-severity"><option value="">Todas</option></select>
    </div>
    <div class="actions">
      <button class="btn" id="btn-clear" type="button">Limpiar</button>
      <button class="btn primary" id="btn-csv" type="button">⬇ Exportar CSV</button>
    </div>
  </div>
</div>

<div class="section work">
  <h2>📋 Tareas &amp; User Stories <span class="count" id="count-work"></span></h2>
  <div class="table-wrap">
    <table id="table-work">
      <thead>
        <tr>
          <th data-key="category">Vence</th>
          <th data-key="type">Tipo</th>
          <th data-key="ref">Ref</th>
          <th data-key="subject">Asunto</th>
          <th data-key="assignee">Responsable</th>
          <th data-key="username">Usuario</th>
          <th data-key="due">Fecha</th>
          <th data-key="status">Estado</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
    <div class="empty" data-empty hidden>No hay items que coincidan con los filtros.</div>
  </div>
</div>

<div class="section issues">
  <h2>🐞 Issues / Incidencias <span class="count" id="count-issue"></span></h2>
  <div class="table-wrap">
    <table id="table-issue">
      <thead>
        <tr>
          <th data-key="category">Vence</th>
          <th data-key="ref">Ref</th>
          <th data-key="subject">Asunto</th>
          <th data-key="assignee">Responsable</th>
          <th data-key="username">Usuario</th>
          <th data-key="due">Fecha</th>
          <th data-key="status">Estado</th>
          <th data-key="priority">Prioridad</th>
          <th data-key="severity">Severidad</th>
          <th data-key="issue_type">Tipo incidencia</th>
        </tr>
      </thead>
      <tbody></tbody>
    </table>
    <div class="empty" data-empty hidden>No hay issues que coincidan con los filtros.</div>
  </div>
</div>

<p class="note">
  Solo lectura. Tareas y user stories en estados activos; issues no cerrados en Taiga.
  Los filtros se aplican en el navegador. Zona horaria: <code id="tz"></code>.
</p>

HEADER

# ---------------------------------------------------------------------------
# Datos + metadatos embebidos como JSON
# ---------------------------------------------------------------------------
{
  printf '<script id="report-data" type="application/json">'
  cat "$DATA_FILE"
  printf '</script>\n'

  printf '<script id="report-meta" type="application/json">'
  jq -n -c \
    --arg generated_at "$GENERATED_AT" \
    --arg project "${TAIGA_PROJECT_SLUG:-$TAIGA_PROJECT_ID}" \
    --arg tz "$TZ" \
    --arg today "$TODAY" \
    --arg tomorrow "$TOMORROW" \
    --argjson total "$TOTAL" \
    --argjson work_total "$WORK_TOTAL" \
    --argjson issue_total "$ISSUE_TOTAL" \
    --argjson statuses "$ACTIVE_STATUSES" \
    '{generated_at:$generated_at, project:$project, tz:$tz, today:$today, tomorrow:$tomorrow, total:$total, work_total:$work_total, issue_total:$issue_total, active_statuses:$statuses}'
  printf '</script>\n'
} >> "$OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Lógica de render/filtrado (heredoc sin expansión)
# ---------------------------------------------------------------------------
cat >> "$OUTPUT_FILE" <<'SCRIPT'
<script>
(function () {
  "use strict";
  const DATA = JSON.parse(document.getElementById("report-data").textContent || "[]");
  const META = JSON.parse(document.getElementById("report-meta").textContent || "{}");

  const CAT_LABEL = { overdue: "Vencida", today: "Hoy", tomorrow: "Mañana", future: "Futura", nodate: "Sin fecha" };
  const CAT_ORDER = { overdue: 0, today: 1, tomorrow: 2, future: 3, nodate: 4 };
  const TYPE_LABEL = { task: "Tarea", userstory: "User Story", issue: "Issue" };

  // ---- Meta / cabecera --------------------------------------------------
  document.getElementById("meta").innerHTML =
    "Generado: <code>" + esc(META.generated_at || "") + "</code> · " +
    "Proyecto: <code>" + esc(META.project || "") + "</code> · " +
    "Total: <strong>" + (META.total || 0) + "</strong> items " +
    "(Tareas/US: " + (META.work_total || 0) + " · Issues: " + (META.issue_total || 0) + ")";
  document.getElementById("tz").textContent = META.tz || "";

  // ---- Poblado de selects ----------------------------------------------
  fillSelect("f-type", uniq(DATA.map(d => d.type)).sort(), v => TYPE_LABEL[v] || v);
  fillSelect("f-assignee", uniq(DATA.map(d => d.assignee)).sort(cmpText));
  fillSelect("f-status", uniq(DATA.map(d => d.status)).sort(cmpText));
  fillSelect("f-priority", uniq(DATA.filter(d => d.priority).map(d => d.priority)).sort(cmpText));
  fillSelect("f-severity", uniq(DATA.filter(d => d.severity).map(d => d.severity)).sort(cmpText));

  // ---- Estado de orden por tabla ---------------------------------------
  const sortState = {
    work: { key: "due", dir: 1 },
    issue: { key: "due", dir: 1 }
  };

  const controls = ["f-search", "f-group", "f-type", "f-assignee", "f-status", "f-due", "f-priority", "f-severity"];
  controls.forEach(id => {
    const el = document.getElementById(id);
    el.addEventListener("input", render);
    el.addEventListener("change", render);
  });
  document.getElementById("btn-clear").addEventListener("click", () => {
    controls.forEach(id => { document.getElementById(id).value = ""; });
    render();
  });
  document.getElementById("btn-csv").addEventListener("click", exportCsv);

  // Tarjetas KPI clicables: limpian los filtros actuales y aplican el nuevo.
  function activateCard(card) {
    if (!card) return;
    const cat = card.dataset.cat;
    controls.forEach(id => { document.getElementById(id).value = ""; });
    if (cat && cat !== "total") {
      document.getElementById("f-due").value = cat;
    }
    render();
  }
  const kpisWrap = document.getElementById("kpis");
  kpisWrap.addEventListener("click", (e) => activateCard(e.target.closest(".kpi")));
  kpisWrap.addEventListener("keydown", (e) => {
    if (e.key === "Enter" || e.key === " " || e.key === "Spacebar") {
      const card = e.target.closest(".kpi");
      if (card) { e.preventDefault(); activateCard(card); }
    }
  });

  // Sortable headers
  document.querySelectorAll("#table-work thead th, #table-issue thead th").forEach(th => {
    th.addEventListener("click", () => {
      const tableId = th.closest("table").id;
      const grp = tableId === "table-issue" ? "issue" : "work";
      const key = th.dataset.key;
      const st = sortState[grp];
      if (st.key === key) { st.dir *= -1; } else { st.key = key; st.dir = 1; }
      render();
    });
  });

  // Estado inicial determinista: el navegador (Chromium) restaura los valores
  // previos de los <select> al recargar/volver, incluso despues de este script.
  // pageshow se dispara tras esa restauracion, asi que reseteamos ahi tambien.
  function resetFilters() {
    controls.forEach(id => {
      const el = document.getElementById(id);
      el.setAttribute("autocomplete", "off");
      el.value = "";
    });
    render();
  }
  window.addEventListener("pageshow", resetFilters);

  resetFilters();

  // ---- Funciones --------------------------------------------------------
  function getFilters() {
    return {
      q: document.getElementById("f-search").value.trim().toLowerCase(),
      group: document.getElementById("f-group").value,
      type: document.getElementById("f-type").value,
      assignee: document.getElementById("f-assignee").value,
      status: document.getElementById("f-status").value,
      due: document.getElementById("f-due").value,
      priority: document.getElementById("f-priority").value,
      severity: document.getElementById("f-severity").value
    };
  }

  function applyFilters(rows, f) {
    return rows.filter(d => {
      if (f.group && d.group !== f.group) return false;
      if (f.type && d.type !== f.type) return false;
      if (f.assignee && d.assignee !== f.assignee) return false;
      if (f.status && d.status !== f.status) return false;
      if (f.due && d.category !== f.due) return false;
      if (f.priority && d.priority !== f.priority) return false;
      if (f.severity && d.severity !== f.severity) return false;
      if (f.q) {
        const hay = (d.subject + " #" + d.ref + " " + d.assignee + " " + d.username).toLowerCase();
        if (hay.indexOf(f.q) === -1) return false;
      }
      return true;
    });
  }

  function sortRows(rows, grp) {
    const st = sortState[grp];
    const key = st.key, dir = st.dir;
    return rows.slice().sort((a, b) => {
      let va, vb;
      if (key === "category") { va = CAT_ORDER[a.category]; vb = CAT_ORDER[b.category]; }
      else if (key === "ref") { va = a.ref || 0; vb = b.ref || 0; }
      else if (key === "due") { va = a.due || "9999-99-99"; vb = b.due || "9999-99-99"; }
      else { va = (a[key] || "").toString().toLowerCase(); vb = (b[key] || "").toString().toLowerCase(); }
      if (va < vb) return -1 * dir;
      if (va > vb) return 1 * dir;
      return (a.ref || 0) - (b.ref || 0);
    });
  }

  function render() {
    const f = getFilters();
    const filtered = applyFilters(DATA, f);

    renderKpis(filtered);
    updateHeaderArrows();

    const work = sortRows(filtered.filter(d => d.group === "work"), "work");
    const issues = sortRows(filtered.filter(d => d.group === "issue"), "issue");

    renderTable("table-work", work, false);
    renderTable("table-issue", issues, true);

    document.getElementById("count-work").textContent = work.length + " items";
    document.getElementById("count-issue").textContent = issues.length + " items";
  }

  function renderKpis(rows) {
    const c = { total: rows.length, overdue: 0, today: 0, tomorrow: 0, future: 0, nodate: 0 };
    rows.forEach(d => { c[d.category] = (c[d.category] || 0) + 1; });
    const kpis = [
      { key: "total", label: "Total (filtrado)", cls: "" },
      { key: "overdue", label: "🔴 Vencidas", cls: "overdue" },
      { key: "today", label: "🟠 Vencen hoy", cls: "today" },
      { key: "tomorrow", label: "🔵 Vencen mañana", cls: "tomorrow" },
      { key: "future", label: "🟢 Futuras", cls: "future" },
      { key: "nodate", label: "⚪ Sin fecha", cls: "nodate" }
    ];
    const wrap = document.getElementById("kpis");
    const activeCat = document.getElementById("f-due").value || "total";
    wrap.innerHTML = "";
    kpis.forEach(k => {
      const div = document.createElement("div");
      div.className = "kpi " + k.cls + (k.key === activeCat ? " active" : "");
      div.dataset.cat = k.key;
      div.setAttribute("role", "button");
      div.tabIndex = 0;
      div.setAttribute("aria-pressed", k.key === activeCat ? "true" : "false");
      div.title = k.key === "total"
        ? "Ver todo y limpiar filtros"
        : "Filtrar por: " + k.label;
      const l = document.createElement("div"); l.className = "label"; l.textContent = k.label;
      const v = document.createElement("div"); v.className = "value"; v.textContent = c[k.key] || 0;
      div.appendChild(l); div.appendChild(v);
      wrap.appendChild(div);
    });
  }

  function renderTable(tableId, rows, isIssue) {
    const table = document.getElementById(tableId);
    const tbody = table.querySelector("tbody");
    const emptyEl = table.parentElement.querySelector("[data-empty]");
    tbody.innerHTML = "";

    if (rows.length === 0) {
      table.hidden = true;
      emptyEl.hidden = false;
      return;
    }
    table.hidden = false;
    emptyEl.hidden = true;

    const frag = document.createDocumentFragment();
    rows.forEach(d => {
      const tr = document.createElement("tr");
      tr.appendChild(catCell(d));
      if (!isIssue) tr.appendChild(typeCell(d));
      tr.appendChild(refCell(d));
      tr.appendChild(td(d.subject, "subject"));
      tr.appendChild(td(d.assignee));
      tr.appendChild(td(d.username));
      tr.appendChild(td(d.due || "Sin fecha"));
      tr.appendChild(td(d.status));
      if (isIssue) {
        tr.appendChild(td(d.priority || "-"));
        tr.appendChild(td(d.severity || "-"));
        tr.appendChild(td(d.issue_type || "-"));
      }
      frag.appendChild(tr);
    });
    tbody.appendChild(frag);
  }

  function catCell(d) {
    const cell = document.createElement("td");
    const span = document.createElement("span");
    span.className = "badge " + d.category;
    span.textContent = CAT_LABEL[d.category] || d.category;
    cell.appendChild(span);
    return cell;
  }

  function typeCell(d) {
    const cell = document.createElement("td");
    const span = document.createElement("span");
    span.className = "pill type-" + d.type;
    span.textContent = TYPE_LABEL[d.type] || d.type;
    cell.appendChild(span);
    return cell;
  }

  function refCell(d) {
    const cell = document.createElement("td");
    if (d.url) {
      const a = document.createElement("a");
      a.className = "ref"; a.href = d.url; a.target = "_blank"; a.rel = "noopener";
      a.textContent = "#" + d.ref;
      cell.appendChild(a);
    } else {
      cell.textContent = "#" + d.ref;
    }
    return cell;
  }

  function td(text, cls) {
    const cell = document.createElement("td");
    if (cls) cell.className = cls;
    cell.textContent = text == null ? "" : String(text);
    return cell;
  }

  function updateHeaderArrows() {
    ["work", "issue"].forEach(grp => {
      const tableId = grp === "issue" ? "table-issue" : "table-work";
      const st = sortState[grp];
      document.querySelectorAll("#" + tableId + " thead th").forEach(th => {
        const base = th.dataset.label || (th.dataset.label = th.textContent.replace(/[▲▼]\s*$/, "").trim());
        th.innerHTML = "";
        th.appendChild(document.createTextNode(base + " "));
        if (th.dataset.key === st.key) {
          const arrow = document.createElement("span");
          arrow.className = "arrow";
          arrow.textContent = st.dir === 1 ? "▲" : "▼";
          th.appendChild(arrow);
        }
      });
    });
  }

  function exportCsv() {
    const f = getFilters();
    const rows = sortRows(applyFilters(DATA, f), "work")
      .concat(sortRows(applyFilters(DATA, f).filter(d => d.group === "issue"), "issue"));
    // Build unified export from the full filtered set (work + issue)
    const all = applyFilters(DATA, f);
    const cols = ["group", "type", "ref", "subject", "assignee", "username", "due", "category", "status", "priority", "severity", "issue_type", "url"];
    const header = ["Grupo", "Tipo", "Ref", "Asunto", "Responsable", "Usuario", "Fecha", "Vence", "Estado", "Prioridad", "Severidad", "Tipo incidencia", "URL"];
    const lines = [header.map(csvCell).join(",")];
    all.forEach(d => {
      lines.push(cols.map(c => csvCell(d[c] == null ? "" : d[c])).join(","));
    });
    const blob = new Blob(["\ufeff" + lines.join("\r\n")], { type: "text/csv;charset=utf-8;" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "taiga_validacion_" + (META.today || "reporte") + ".csv";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(a.href);
  }

  function csvCell(v) {
    const s = String(v);
    if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
    return s;
  }

  // ---- Utilidades -------------------------------------------------------
  function fillSelect(id, values, labelFn) {
    const sel = document.getElementById(id);
    values.forEach(v => {
      if (v === "" || v == null) return;
      const opt = document.createElement("option");
      opt.value = v;
      opt.textContent = labelFn ? labelFn(v) : v;
      sel.appendChild(opt);
    });
  }
  function uniq(arr) { return Array.from(new Set(arr.filter(x => x != null && x !== ""))); }
  function cmpText(a, b) { return String(a).toLowerCase().localeCompare(String(b).toLowerCase(), "es"); }
  function esc(s) { const d = document.createElement("div"); d.textContent = s == null ? "" : String(s); return d.innerHTML; }
})();
</script>
</body>
</html>
SCRIPT

log "HTML generado: $OUTPUT_FILE"
