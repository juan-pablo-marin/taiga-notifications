#!/usr/bin/env bash
set -euo pipefail

log() { echo "[taiga-remind] $*" >&2; }

: "${TAIGA_BASE_URL:?Definir TAIGA_BASE_URL}"
: "${TAIGA_PROJECT_ID:?Definir TAIGA_PROJECT_ID}"
: "${DISCORD_BOT_TOKEN:?Definir DISCORD_BOT_TOKEN}"
: "${DISCORD_USER_MAP_JSON:?Definir DISCORD_USER_MAP_JSON}"

TAIGA_BASE_URL="${TAIGA_BASE_URL//$'\r'/}"
TAIGA_PROJECT_ID="${TAIGA_PROJECT_ID//$'\r'/}"
TAIGA_USERNAME="${TAIGA_USERNAME:-}"; TAIGA_USERNAME="${TAIGA_USERNAME//$'\r'/}"
TAIGA_PASSWORD="${TAIGA_PASSWORD:-}"; TAIGA_PASSWORD="${TAIGA_PASSWORD//$'\r'/}"
TAIGA_AUTH_TOKEN="${TAIGA_AUTH_TOKEN:-}"; TAIGA_AUTH_TOKEN="${TAIGA_AUTH_TOKEN//$'\r'/}"
TAIGA_WEB_UI_BASE_URL="${TAIGA_WEB_UI_BASE_URL:-$TAIGA_BASE_URL}"; TAIGA_WEB_UI_BASE_URL="${TAIGA_WEB_UI_BASE_URL//$'\r'/}"
TAIGA_PROJECT_SLUG="${TAIGA_PROJECT_SLUG:-}"; TAIGA_PROJECT_SLUG="${TAIGA_PROJECT_SLUG//$'\r'/}"
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN//$'\r'/}"
DISCORD_USER_MAP_JSON="${DISCORD_USER_MAP_JSON//$'\r'/}"
DISCORD_LEAD_EMAIL="${DISCORD_LEAD_EMAIL:-dmvelezp@sena.edu.co}"; DISCORD_LEAD_EMAIL="${DISCORD_LEAD_EMAIL//$'\r'/}"
DISCORD_LEAD_EMAILS="${DISCORD_LEAD_EMAILS:-$DISCORD_LEAD_EMAIL}"; DISCORD_LEAD_EMAILS="${DISCORD_LEAD_EMAILS//$'\r'/}"
TAIGA_NOTIFY_STATE_FILE="${TAIGA_NOTIFY_STATE_FILE:-/data/notified_state.json}"; TAIGA_NOTIFY_STATE_FILE="${TAIGA_NOTIFY_STATE_FILE//$'\r'/}"
TAIGA_NOTIFY_ASSIGNEE="${TAIGA_NOTIFY_ASSIGNEE:-}"; TAIGA_NOTIFY_ASSIGNEE="${TAIGA_NOTIFY_ASSIGNEE//$'\r'/}"
TAIGA_NOTIFY_ONLY_LEAD="${TAIGA_NOTIFY_ONLY_LEAD:-false}"; TAIGA_NOTIFY_ONLY_LEAD="${TAIGA_NOTIFY_ONLY_LEAD//$'\r'/}"
TAIGA_NOTIFY_EXCLUDE_LEAD="${TAIGA_NOTIFY_EXCLUDE_LEAD:-false}"; TAIGA_NOTIFY_EXCLUDE_LEAD="${TAIGA_NOTIFY_EXCLUDE_LEAD//$'\r'/}"
TAIGA_SSL_VERIFY="${TAIGA_SSL_VERIFY:-1}"; TAIGA_SSL_VERIFY="${TAIGA_SSL_VERIFY//$'\r'/}"

CURL_EXTRA=()
case "${TAIGA_SSL_VERIFY,,}" in 0|false|no|off) CURL_EXTRA=(-k) ;; esac

TAIGA_BASE_URL="${TAIGA_BASE_URL%/}"
TAIGA_WEB_UI_BASE_URL="${TAIGA_WEB_UI_BASE_URL%/}"

if ! echo "$DISCORD_USER_MAP_JSON" | jq -e 'type=="object"' >/dev/null 2>&1; then
  log "DISCORD_USER_MAP_JSON invalido"
  exit 1
fi

normalize_email() { echo "${1,,}" | sed 's/^ *//;s/ *$//'; }

lookup_discord_id_by_email() {
  local email_lc
  email_lc="$(normalize_email "$1")"
  echo "$DISCORD_USER_MAP_JSON" | jq -r --arg e "$email_lc" 'to_entries[] | select((.key|ascii_downcase)==$e) | .value' | head -n 1
}

lookup_discord_id_for_assignee() {
  local email="$1"
  local username="$2"
  local id=""
  if [[ -n "$email" ]]; then
    id="$(lookup_discord_id_by_email "$email")"
    [[ -n "$id" ]] && { echo "$id"; return; }
  fi
  if [[ -n "$username" ]]; then
    id="$(lookup_discord_id_by_email "$username")"
    [[ -n "$id" ]] && { echo "$id"; return; }
    id="$(lookup_discord_id_by_email "${username}@sena.edu.co")"
    [[ -n "$id" ]] && { echo "$id"; return; }
  fi
  echo ""
}

list_lead_ids() {
  local ids="[]" email uid
  IFS=',' read -r -a emails <<< "$DISCORD_LEAD_EMAILS"
  for email in "${emails[@]}"; do
    email="$(normalize_email "$email")"
    [[ -z "$email" ]] && continue
    uid="$(lookup_discord_id_by_email "$email")"
    if [[ -z "$uid" ]]; then
      log "No existe correo de lider en mapa: $email"
      continue
    fi
    ids="$(jq -n --argjson arr "$ids" --arg v "$uid" '$arr + [$v] | unique')"
  done
  echo "$ids"
}

is_lead_uid() {
  local uid="$1" lead_json="$2"
  echo "$lead_json" | jq -e --arg u "$uid" 'map(tostring) | index($u) != null' >/dev/null 2>&1
}

filter_rows_for_discord_uid() {
  local target_uid="$1"
  local arr="$2"
  local out='[]' row email username aid
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    email="$(echo "$row" | jq -r '(.assigned_to_extra_info.email // "") | ascii_downcase')"
    username="$(echo "$row" | jq -r '(.assigned_to_extra_info.username // "") | ascii_downcase')"
    aid="$(lookup_discord_id_for_assignee "$email" "$username")"
    [[ "$aid" == "$target_uid" ]] && out="$(jq -n --argjson o "$out" --argjson r "$row" '$o + [$r]')"
  done < <(echo "$arr" | jq -c '.[]')
  echo "$out"
}

collect_assignee_uids() {
  local combined="$1"
  local lead_json="$2"
  local row email username aid
  local -a uids=()
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    email="$(echo "$row" | jq -r '(.assigned_to_extra_info.email // "") | ascii_downcase')"
    username="$(echo "$row" | jq -r '(.assigned_to_extra_info.username // "") | ascii_downcase')"
    [[ -z "$email" && -z "$username" ]] && continue
    aid="$(lookup_discord_id_for_assignee "$email" "$username")"
    [[ -z "$aid" ]] && continue
    uids+=("$aid")
  done < <(echo "$combined" | jq -c '.[]')
  if [[ ${#uids[@]} -eq 0 ]]; then
    return
  fi
  printf '%s\n' "${uids[@]}" | sort -u
}

count_unmapped_assignees() {
  local combined="$1"
  local row email username aid kind ref miss=0
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    email="$(echo "$row" | jq -r '(.assigned_to_extra_info.email // "") | ascii_downcase')"
    username="$(echo "$row" | jq -r '(.assigned_to_extra_info.username // "") | ascii_downcase')"
    [[ -z "$email" && -z "$username" ]] && continue
    aid="$(lookup_discord_id_for_assignee "$email" "$username")"
    if [[ -z "$aid" ]]; then
      kind="$(echo "$row" | jq -r '.entity_type')"
      ref="$(echo "$row" | jq -r '.ref')"
      log "Sin mapeo responsable en .env: ${kind}=${ref} | Email='$email' | User='$username'"
      miss=$((miss + 1))
    fi
  done < <(echo "$combined" | jq -c '.[]')
  echo "$miss"
}

task_link() {
  local ref="$1"
  if [[ -n "$TAIGA_PROJECT_SLUG" ]]; then
    echo "${TAIGA_WEB_UI_BASE_URL}/project/${TAIGA_PROJECT_SLUG}/task/${ref}"
  else
    echo "${TAIGA_WEB_UI_BASE_URL}/project/${TAIGA_PROJECT_ID}/task/${ref}"
  fi
}

userstory_link() {
  local ref="$1"
  if [[ -n "$TAIGA_PROJECT_SLUG" ]]; then
    echo "${TAIGA_WEB_UI_BASE_URL}/project/${TAIGA_PROJECT_SLUG}/us/${ref}"
  else
    echo "${TAIGA_WEB_UI_BASE_URL}/project/${TAIGA_PROJECT_ID}/us/${ref}"
  fi
}

get_token() {
  if [[ -n "${TAIGA_AUTH_TOKEN:-}" ]]; then
    echo "$TAIGA_AUTH_TOKEN"
    return
  fi
  if [[ -z "${TAIGA_USERNAME:-}" || -z "${TAIGA_PASSWORD:-}" ]]; then
    log "Falta TAIGA_AUTH_TOKEN o TAIGA_USERNAME + TAIGA_PASSWORD"
    exit 1
  fi
  local resp tok
  resp="$(curl "${CURL_EXTRA[@]}" -sS -X POST "${TAIGA_BASE_URL}/api/v1/auth" -H "Content-Type: application/json" -d "$(jq -n --arg u "$TAIGA_USERNAME" --arg p "$TAIGA_PASSWORD" '{type:"normal",username:$u,password:$p}')")"
  tok="$(echo "$resp" | jq -r '.auth_token // empty')"
  if [[ -z "$tok" ]]; then
    log "Fallo login Taiga"
    echo "$resp" | jq . >&2 2>/dev/null || echo "$resp" >&2
    exit 1
  fi
  echo "$tok"
}

# Estados activos para filtrado (excluye Done, Closed, Archived, etc.)
ACTIVE_STATUSES='["New","Ready","In progress","Code Review","Ready for test","QA Testing","QA Rejected","Waiting Deploy"]'

# Estados que NO se notifican a los RESPONSABLES (asignados).
# Los LIDERES sí los siguen viendo en su reporte diario.
# Editable via env ASSIGNEE_EXCLUDE_STATUSES_JSON (array JSON). Por defecto: Ready for test.
ASSIGNEE_EXCLUDE_STATUSES="${ASSIGNEE_EXCLUDE_STATUSES_JSON:-[\"Ready for test\"]}"
if ! echo "$ASSIGNEE_EXCLUDE_STATUSES" | jq -e 'type=="array"' >/dev/null 2>&1; then
  log "ASSIGNEE_EXCLUDE_STATUSES_JSON invalido; usando [\"Ready for test\"]"
  ASSIGNEE_EXCLUDE_STATUSES='["Ready for test"]'
fi

# Función genérica de paginación usando archivos temporales y header X-Pagination-Next
fetch_all_pages_to_file() {
  local token="$1" url="$2" outfile="$3"
  local page=1 headers_file tmpfile
  headers_file="$(mktemp)"
  echo '[]' > "$outfile"

  while [[ -n "$url" ]]; do
    tmpfile="$(mktemp)"
    curl "${CURL_EXTRA[@]}" -sS -D "$headers_file" \
      -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" "$url" > "$tmpfile"

    if jq -e 'type=="array"' "$tmpfile" >/dev/null 2>&1; then
      jq -s '.[0] + .[1]' "$outfile" "$tmpfile" > "${outfile}.tmp" && mv "${outfile}.tmp" "$outfile"
    elif jq -e 'has("results")' "$tmpfile" >/dev/null 2>&1; then
      jq '.results' "$tmpfile" > "${tmpfile}.r"
      jq -s '.[0] + .[1]' "$outfile" "${tmpfile}.r" > "${outfile}.tmp" && mv "${outfile}.tmp" "$outfile"
      rm -f "${tmpfile}.r"
    else
      log "Respuesta inesperada en pagina $page"
      cat "$tmpfile" >&2
      rm -f "$tmpfile"
      break
    fi
    rm -f "$tmpfile"

    # Siguiente página via header
    local next_url
    next_url="$(grep -i '^X-Pagination-Next:' "$headers_file" 2>/dev/null | sed 's/^[^:]*: *//;s/[[:space:]]*$//' | tr -d '\r' || true)"
    if [[ -z "$next_url" ]]; then
      break
    fi
    url="$next_url"
    page=$((page+1)); [[ $page -gt 500 ]] && { log "Demasiadas paginas"; break; }
  done
  rm -f "$headers_file"
}



ensure_state_file() {
  local today="$1"
  mkdir -p "$(dirname "$TAIGA_NOTIFY_STATE_FILE")"
  if [[ ! -f "$TAIGA_NOTIFY_STATE_FILE" ]] || ! jq -e 'has("day") and has("sent") and (.sent|type=="object")' "$TAIGA_NOTIFY_STATE_FILE" >/dev/null 2>&1; then
    jq -n --arg d "$today" '{day:$d, sent:{}}' > "$TAIGA_NOTIFY_STATE_FILE"
    return
  fi
  if [[ "$(jq -r '.day' "$TAIGA_NOTIFY_STATE_FILE")" != "$today" ]]; then
    jq -n --arg d "$today" '{day:$d, sent:{}}' > "$TAIGA_NOTIFY_STATE_FILE"
  fi
}

already_sent_today() { jq -e --arg k "$1" '.sent[$k]==true' "$TAIGA_NOTIFY_STATE_FILE" >/dev/null 2>&1; }
mark_sent_today() { local tmp; tmp="$(mktemp)"; jq --arg k "$1" '.sent[$k]=true' "$TAIGA_NOTIFY_STATE_FILE" > "$tmp"; mv "$tmp" "$TAIGA_NOTIFY_STATE_FILE"; }

discord_api() {
  local method="$1" url="$2" payload="${3:-}" out code
  out="$(mktemp)"
  if [[ -n "$payload" ]]; then
    code="$(curl -sS -o "$out" -w "%{http_code}" -X "$method" "$url" -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" -H "Content-Type: application/json" -d "$payload")"
  else
    code="$(curl -sS -o "$out" -w "%{http_code}" -X "$method" "$url" -H "Authorization: Bot ${DISCORD_BOT_TOKEN}")"
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    log "Discord API HTTP $code en $url"; cat "$out" >&2 || true; rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

ensure_dm_channel() {
  local uid="$1" resp
  resp="$(discord_api POST "https://discord.com/api/v10/users/@me/channels" "$(jq -n --arg uid "$uid" '{recipient_id:$uid}')")"
  echo "$resp" | jq -r '.id // empty'
}

send_dm() {
  local uid="$1" content="$2" ch
  ch="$(ensure_dm_channel "$uid")"
  [[ -z "$ch" ]] && { log "No se pudo abrir DM para $uid"; return 1; }
  # Discord limita mensajes a 2000 caracteres. Dividir si es necesario.
  local max_len=1900
  if [[ ${#content} -le $max_len ]]; then
    discord_api POST "https://discord.com/api/v10/channels/${ch}/messages" "$(jq -n --arg c "$content" '{content:$c}')" >/dev/null
  else
    # Dividir por líneas respetando el límite
    local chunk="" line
    while IFS= read -r line; do
      if [[ $(( ${#chunk} + ${#line} + 1 )) -gt $max_len ]]; then
        # Enviar chunk actual
        if [[ -n "$chunk" ]]; then
          discord_api POST "https://discord.com/api/v10/channels/${ch}/messages" "$(jq -n --arg c "$chunk" '{content:$c}')" >/dev/null || return 1
          sleep 1  # Rate limit protection
        fi
        chunk="$line"
      else
        if [[ -n "$chunk" ]]; then
          chunk+=$'\n'"$line"
        else
          chunk="$line"
        fi
      fi
    done <<< "$content"
    # Enviar último chunk
    if [[ -n "$chunk" ]]; then
      discord_api POST "https://discord.com/api/v10/channels/${ch}/messages" "$(jq -n --arg c "$chunk" '{content:$c}')" >/dev/null || return 1
    fi
  fi
}

row_link() {
  local row="$1" kind ref
  kind="$(echo "$row" | jq -r '.entity_type')"
  ref="$(echo "$row" | jq -r '.ref')"
  if [[ "$kind" == "userstory" ]]; then
    userstory_link "$ref"
  else
    task_link "$ref"
  fi
}

build_line() {
  local row="$1" ref subj due assignee kind link prefix
  kind="$(echo "$row" | jq -r '.entity_type')"
  ref="$(echo "$row" | jq -r '.ref')"
  subj="$(echo "$row" | jq -r '.subject // "Sin titulo"')"
  due="$(echo "$row" | jq -r '.due_date // ""' | cut -dT -f1)"
  # Show multiple assignees if assigned_users has more than 1 entry
  local au_count
  au_count="$(echo "$row" | jq '[.assigned_users // [] | .[] ] | length')"
  if [[ "$au_count" -gt 1 && -n "${MEMBERS_JSON:-}" ]]; then
    assignee="$(echo "$row" | jq -r --argjson members "$MEMBERS_JSON" '
      [.assigned_users[] as $uid | ($members[] | select(.user == $uid) | .full_name) // "Usuario #\($uid)"] | join(", ")
    ')"
  else
    assignee="$(echo "$row" | jq -r '.assigned_to_extra_info.full_name_display // "Sin asignar"')"
  fi
  link="$(row_link "$row")"
  if [[ "$kind" == "userstory" ]]; then
    prefix="US"
  else
    prefix="Task"
  fi
  printf -- '• **%s #%s**\n  %s\n  Vence: %s\n  Asignado: %s\n  <%s>\n\n' "$prefix" "$ref" "$subj" "$due" "$assignee" "$link"
}

append_section_lines() {
  local title="$1" rows="$2" msg="$3"
  local count
  count="$(echo "$rows" | jq 'length')"
  [[ "$count" -eq 0 ]] && { echo "$msg"; return; }
  msg+=$'\n'
  msg+="$title ($count)"
  msg+=$'\n'
  # Ordenar por nombre de asignado para agrupar visualmente por usuario
  while IFS= read -r row; do
    [[ -z "$row" ]] && continue
    msg+="$(build_line "$row")"
  done < <(echo "$rows" | jq -c 'sort_by(.assigned_to_extra_info.full_name_display // "zzz") | .[]')
  echo "$msg"
}

build_daily_report() {
  local tomorrow="$1" today="$2" due_tomorrow="$3" due_today="$4" overdue="$5" msg
  msg=":warning: Notificaciones APE"
  msg+=$'\n'
  msg+="Reporte diario Taiga (Tasks + User Stories) — liderazgo"
  msg+=$'\n'
  msg+="- Vence manana: $tomorrow"
  msg+=$'\n'
  msg+="- Fecha de hoy: $today"
  msg+=$'\n'
  msg+="- Ambito: proyecto completo"
  msg+=$'\n'
  msg="$(append_section_lines "VENCEN MANANA" "$due_tomorrow" "$msg")"
  msg="$(append_section_lines "VENCEN HOY" "$due_today" "$msg")"
  msg="$(append_section_lines "VENCIDAS ABIERTAS" "$overdue" "$msg")"
  echo "$msg"
}

build_assignee_report() {
  local tomorrow="$1" today="$2" due_tomorrow="$3" due_today="$4" overdue="$5" msg
  msg=":warning: Notificaciones APE"
  msg+=$'\n'
  msg+="Tus pendientes en Taiga (Tasks + User Stories)"
  msg+=$'\n'
  msg+="- Vence manana: $tomorrow"
  msg+=$'\n'
  msg+="- Fecha de hoy: $today"
  msg+=$'\n'
  msg+="- Solo items asignados a ti"
  msg+=$'\n'
  msg="$(append_section_lines "TE VENCEN MANANA" "$due_tomorrow" "$msg")"
  msg="$(append_section_lines "TE VENCEN HOY" "$due_today" "$msg")"
  msg="$(append_section_lines "TUYAS VENCIDAS ABIERTAS" "$overdue" "$msg")"
  echo "$msg"
}

main() {
  export TZ="${TZ:-UTC}"
  local today tomorrow token all_items with_due due_tomorrow due_today overdue combined
  local lead_ids leaders_count sent=0 failed=0 skip=0 miss=0 sent_leads=0 sent_assignees=0
  local send_leads=1 send_assignees=1 uid dedup msg
  local a_tom a_today a_over total_to_notify
  today="$(date +%Y-%m-%d)"
  tomorrow="$(date -d "$today + 1 day" +%Y-%m-%d 2>/dev/null || jq -nr --arg t "$today" '$t | strptime("%Y-%m-%d") | mktime + 86400 | strftime("%Y-%m-%d")')"
  ensure_state_file "$today"

  case "${TAIGA_NOTIFY_ONLY_LEAD,,}" in true|1|yes|on) send_assignees=0 ;; esac
  case "${TAIGA_NOTIFY_EXCLUDE_LEAD,,}" in true|1|yes|on) send_leads=0 ;; esac

  token="$(get_token)"

  local tasks_file us_file all_file
  tasks_file="$(mktemp)"
  us_file="$(mktemp)"
  all_file="$(mktemp)"

  fetch_all_pages_to_file "$token" "${TAIGA_BASE_URL}/api/v1/tasks?project=${TAIGA_PROJECT_ID}" "$tasks_file"
  fetch_all_pages_to_file "$token" "${TAIGA_BASE_URL}/api/v1/userstories?project=${TAIGA_PROJECT_ID}" "$us_file"

  # Obtener miembros del proyecto para resolver múltiples asignados
  local members_file
  members_file="$(mktemp)"
  fetch_all_pages_to_file "$token" "${TAIGA_BASE_URL}/api/v1/memberships?project=${TAIGA_PROJECT_ID}" "$members_file"
  MEMBERS_JSON="$(cat "$members_file")"
  rm -f "$members_file"
  export MEMBERS_JSON

  # Combinar, agregar entity_type, filtrar por estados activos
  jq -s --argjson statuses "$ACTIVE_STATUSES" '
    ((.[0] // []) | map(. + {entity_type:"task"})) +
    ((.[1] // []) | map(. + {entity_type:"userstory"}))
    | map(select(.status_extra_info.name as $s | $statuses | index($s) != null))
  ' "$tasks_file" "$us_file" > "$all_file"
  rm -f "$tasks_file" "$us_file"

  all_items="$(cat "$all_file")"
  rm -f "$all_file"
  with_due="$(echo "$all_items" | jq '[.[] | select(.due_date != null and .due_date != "") | .due_date |= (tostring | split("T")[0])]')"

  if [[ -n "$TAIGA_NOTIFY_ASSIGNEE" ]]; then
    with_due="$(echo "$with_due" | jq --arg n "$TAIGA_NOTIFY_ASSIGNEE" '[.[] | select(((.assigned_to_extra_info.full_name_display // "") | ascii_downcase | sub("^ *";"") | sub(" *$";"")) == ($n | ascii_downcase | sub("^ *";"") | sub(" *$";"")))]')"
  fi

  due_tomorrow="$(echo "$with_due" | jq --arg t "$tomorrow" '[.[] | select(.due_date == $t)]')"
  due_today="$(echo "$with_due" | jq --arg t "$today" '[.[] | select(.due_date == $t)]')"
  overdue="$(echo "$with_due" | jq --arg t "$today" '[.[] | select(.due_date < $t)]')"

  if [[ "$(echo "$due_tomorrow" | jq 'length')" -eq 0 && "$(echo "$due_today" | jq 'length')" -eq 0 && "$(echo "$overdue" | jq 'length')" -eq 0 ]]; then
    log "Sin tareas ni user stories para manana/hoy/vencidas."
    exit 0
  fi

  combined="$(jq -n --argjson a "$due_tomorrow" --argjson b "$due_today" --argjson c "$overdue" '$a + $b + $c')"
  miss="$(count_unmapped_assignees "$combined")"

  # Conjuntos para RESPONSABLES: excluir estados configurados (p. ej. "Ready for test").
  # Los LIDERES siguen recibiendo due_tomorrow/due_today/overdue completos.
  local a_due_tomorrow a_due_today a_overdue combined_assignee
  a_due_tomorrow="$(echo "$due_tomorrow" | jq --argjson ex "$ASSIGNEE_EXCLUDE_STATUSES" '[.[] | select(((.status_extra_info.name) // "") as $s | ($ex | index($s)) == null)]')"
  a_due_today="$(echo "$due_today" | jq --argjson ex "$ASSIGNEE_EXCLUDE_STATUSES" '[.[] | select(((.status_extra_info.name) // "") as $s | ($ex | index($s)) == null)]')"
  a_overdue="$(echo "$overdue" | jq --argjson ex "$ASSIGNEE_EXCLUDE_STATUSES" '[.[] | select(((.status_extra_info.name) // "") as $s | ($ex | index($s)) == null)]')"
  combined_assignee="$(jq -n --argjson a "$a_due_tomorrow" --argjson b "$a_due_today" --argjson c "$a_overdue" '$a + $b + $c')"

  lead_ids="$(list_lead_ids)"
  leaders_count="$(echo "$lead_ids" | jq 'length')"
  [[ "$send_leads" -eq 1 && "$leaders_count" -eq 0 ]] && { log "No hay lideres mapeados en DISCORD_USER_MAP_JSON"; exit 1; }
  [[ "$send_leads" -eq 0 && "$send_assignees" -eq 0 ]] && { log "Nada que enviar (ONLY_LEAD y EXCLUDE_LEAD activos)."; exit 0; }

  if [[ "$send_leads" -eq 1 ]]; then
    while IFS= read -r uid; do
      [[ -z "$uid" ]] && continue
      dedup="${today}|leaders-daily-report|${uid}"
      already_sent_today "$dedup" && { skip=$((skip+1)); continue; }
      msg="$(build_daily_report "$tomorrow" "$today" "$due_tomorrow" "$due_today" "$overdue")"
      if send_dm "$uid" "$msg"; then mark_sent_today "$dedup"; sent=$((sent+1)); sent_leads=$((sent_leads+1)); else failed=$((failed+1)); fi
    done < <(echo "$lead_ids" | jq -r '.[]')
  fi

  if [[ "$send_assignees" -eq 1 ]]; then
    while IFS= read -r uid; do
      [[ -z "$uid" ]] && continue
      a_tom="$(filter_rows_for_discord_uid "$uid" "$a_due_tomorrow")"
      a_today="$(filter_rows_for_discord_uid "$uid" "$a_due_today")"
      a_over="$(filter_rows_for_discord_uid "$uid" "$a_overdue")"
      if [[ "$(echo "$a_tom" | jq 'length')" -eq 0 && "$(echo "$a_today" | jq 'length')" -eq 0 && "$(echo "$a_over" | jq 'length')" -eq 0 ]]; then
        continue
      fi
      dedup="${today}|assignee-daily-report|${uid}"
      already_sent_today "$dedup" && { skip=$((skip+1)); continue; }
      msg="$(build_assignee_report "$tomorrow" "$today" "$a_tom" "$a_today" "$a_over")"
      if send_dm "$uid" "$msg"; then mark_sent_today "$dedup"; sent=$((sent+1)); sent_assignees=$((sent_assignees+1)); else failed=$((failed+1)); fi
    done < <(collect_assignee_uids "$combined_assignee" "$lead_ids")
  fi

  log "DM enviados=$sent | fallidos=$failed | dm_lideres=$sent_leads | dm_responsables=$sent_assignees | ya_enviados_hoy=$skip | lideres_mapeados=$leaders_count | sin_mapeo_responsable=$miss"

  total_to_notify="$(echo "$combined" | jq 'length')"
  if [[ "$total_to_notify" -gt 0 && "$sent" -eq 0 && "$skip" -eq 0 ]]; then
    log "[CRITICAL] Hay $total_to_notify tareas pendientes pero 0 notificaciones enviadas. Fallos=$failed, Sin_mapeo=$miss"
    exit 2
  fi
}

main "$@"