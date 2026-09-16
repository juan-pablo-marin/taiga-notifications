#!/usr/bin/env bash
# Prueba offline de scripts/export_tasks_html.sh usando un mock de curl.
# Simula la API de Taiga (auth, tasks, userstories, issues, memberships)
# y verifica que el HTML generado incluya datos de las tres entidades.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Localiza jq (PATH o binario local); se necesita para el script y la validacion.
JQ="$(command -v jq || true)"
[[ -z "$JQ" && -x "$HOME/.localbin/jq" ]] && JQ="$HOME/.localbin/jq"
if [[ -z "$JQ" ]]; then echo "ERROR: jq no encontrado en PATH ni en ~/.localbin"; exit 1; fi
JQ_DIR="$(dirname "$JQ")"

# --- Fake data -------------------------------------------------------------
TODAY="$(date +%Y-%m-%d)"
YESTERDAY="$(date -d "$TODAY - 2 day" +%Y-%m-%d)"
TOMORROW="$(date -d "$TODAY + 1 day" +%Y-%m-%d)"

cat > "$WORK/tasks.json" <<JSON
[
  {"ref":101,"subject":"Tarea vencida de prueba","due_date":"$YESTERDAY",
   "status_extra_info":{"name":"In progress","is_closed":false},
   "assigned_to_extra_info":{"full_name_display":"Ana Perez","username":"aperez"},
   "assigned_users":[1]},
  {"ref":102,"subject":"Tarea cerrada (debe excluirse)","due_date":"$TODAY",
   "status_extra_info":{"name":"Closed","is_closed":true},
   "assigned_to_extra_info":{"full_name_display":"Ana Perez","username":"aperez"}}
]
JSON

cat > "$WORK/userstories.json" <<JSON
[
  {"ref":201,"subject":"US vence hoy","due_date":"$TODAY",
   "status_extra_info":{"name":"New","is_closed":false},
   "assigned_to_extra_info":{"full_name_display":"Beto Gomez","username":"bgomez"},
   "assigned_users":[2,3]}
]
JSON

# Los issues del listado de Taiga traen priority/severity/type como IDs numericos
# (sin *_extra_info); los nombres se resuelven con los catalogos de abajo.
cat > "$WORK/issues.json" <<JSON
[
  {"ref":301,"subject":"Issue abierto critico","due_date":"$TOMORROW",
   "status_extra_info":{"name":"In progress","is_closed":false},
   "assigned_to_extra_info":{"full_name_display":"Carla Ruiz","username":"cruiz"},
   "priority":5,"severity":9,"type":7},
  {"ref":302,"subject":"Issue cerrado (debe excluirse)","due_date":null,
   "status_extra_info":{"name":"Closed","is_closed":true},
   "assigned_to_extra_info":{"full_name_display":"Carla Ruiz","username":"cruiz"},
   "priority":1,"severity":2,"type":6},
  {"ref":303,"subject":"Issue sin fecha","due_date":null,
   "status_extra_info":{"name":"New","is_closed":false},
   "assigned_to_extra_info":null,
   "priority":3,"severity":4,"type":8}
]
JSON

cat > "$WORK/priorities.json" <<'JSON'
[{"id":5,"name":"High"},{"id":3,"name":"Normal"},{"id":1,"name":"Low"}]
JSON
cat > "$WORK/severities.json" <<'JSON'
[{"id":9,"name":"Critical"},{"id":4,"name":"Normal"},{"id":2,"name":"Minor"}]
JSON
cat > "$WORK/issue_types.json" <<'JSON'
[{"id":7,"name":"Bug"},{"id":8,"name":"Enhancement"},{"id":6,"name":"Question"}]
JSON

cat > "$WORK/members.json" <<'JSON'
[
  {"user":1,"full_name":"Ana Perez","username":"aperez"},
  {"user":2,"full_name":"Beto Gomez","username":"bgomez"},
  {"user":3,"full_name":"Diana Lopez","username":"dlopez"}
]
JSON

# --- Fake curl -------------------------------------------------------------
# Emula respuestas de la API segun la URL solicitada (ultimo argumento).
cat > "$WORK/curl" <<CURLEOF
#!/usr/bin/env bash
# Ignora flags -sS -D file -H ... ; localiza la URL (ultimo token http...)
url=""
prev=""
for a in "\$@"; do
  case "\$a" in
    http*) url="\$a" ;;
  esac
  prev="\$a"
done
# Header dump file (-D <file>)
dumpfile=""
want_dump=0
for a in "\$@"; do
  if [[ \$want_dump -eq 1 ]]; then dumpfile="\$a"; want_dump=0; fi
  [[ "\$a" == "-D" ]] && want_dump=1
done
[[ -n "\$dumpfile" ]] && : > "\$dumpfile"  # sin X-Pagination-Next => una sola pagina

case "\$url" in
  *"/api/v1/auth"*)        echo '{"auth_token":"faketoken"}' ;;
  *"/api/v1/tasks"*)       cat "$WORK/tasks.json" ;;
  *"/api/v1/userstories"*) cat "$WORK/userstories.json" ;;
  *"/api/v1/issues"*)      cat "$WORK/issues.json" ;;
  *"/api/v1/memberships"*) cat "$WORK/members.json" ;;
  *"/api/v1/priorities"*)  cat "$WORK/priorities.json" ;;
  *"/api/v1/severities"*)  cat "$WORK/severities.json" ;;
  *"/api/v1/issue-types"*) cat "$WORK/issue_types.json" ;;
  *) echo '[]' ;;
esac
CURLEOF
chmod +x "$WORK/curl"

# --- Run -------------------------------------------------------------------
OUT="$WORK/out.html"
PATH="$WORK:$JQ_DIR:$PATH" \
TAIGA_BASE_URL="https://taiga.example.com" \
TAIGA_PROJECT_ID="42" \
TAIGA_PROJECT_SLUG="demo-proj" \
TAIGA_AUTH_TOKEN="faketoken" \
TZ="America/Bogota" \
  bash "$REPO/scripts/export_tasks_html.sh" "$OUT"

echo "===================================================="
fail=0
check() { if grep -q "$1" "$OUT"; then echo "OK  : $2"; else echo "FAIL: $2"; fail=1; fi; }
absent() { if grep -q "$1" "$OUT"; then echo "FAIL: $2 (no debia aparecer)"; fail=1; else echo "OK  : $2"; fi; }

check '"ref":101' "Task activa incluida"
check '"ref":201' "User story incluida"
check '"ref":301' "Issue abierto incluido"
check '"ref":303' "Issue sin fecha incluido"
absent '"ref":102' "Task cerrada excluida"
absent '"ref":302' "Issue cerrado excluido"
check 'Beto Gomez, Diana Lopez' "Multi-asignado resuelto por members"
check '"group":"issue"' "Grupo issue presente"
check '"priority":"High"' "Prioridad mapeada por catalogo (id->High)"
check '"severity":"Critical"' "Severidad mapeada por catalogo (id->Critical)"
check '"issue_type":"Bug"' "Tipo de incidencia mapeado por catalogo (id->Bug)"
check 'Enhancement' "Tipo Enhancement mapeado"
check 'demo-proj/issue/301' "URL de issue construida"
check 'demo-proj/us/201' "URL de user story construida"
check 'demo-proj/task/101' "URL de task construida"
check 'report-data' "Bloque de datos JSON embebido"
check 'Exportar CSV' "Boton exportar CSV presente"

# Validar que el JSON embebido sea parseable.
# El bloque de datos queda como una sola linea: <script ...>{JSON compacto}
# y el </script> va en la linea siguiente, asi que basta con quitar el prefijo.
RAW_JSON="$(grep '^<script id="report-data"' "$OUT" | sed 's/^<script[^>]*>//')"
DATA_JSON="$(printf '%s' "$RAW_JSON" | "$JQ" -c '.' 2>/dev/null)"
if [[ -n "$DATA_JSON" ]]; then
  n="$(echo "$DATA_JSON" | "$JQ" 'length')"
  echo "OK  : JSON embebido valido con $n items (esperado 4)"
  [[ "$n" == "4" ]] || { echo "FAIL: se esperaban 4 items activos"; fail=1; }
else
  echo "FAIL: no se pudo extraer/parsear el JSON embebido"; fail=1
fi

echo "===================================================="
# Copia opcional para inspeccion manual: TEST_KEEP_HTML=/ruta/salida.html
if [[ -n "${TEST_KEEP_HTML:-}" ]]; then
  cp "$OUT" "$TEST_KEEP_HTML" && echo "HTML copiado a $TEST_KEEP_HTML"
fi
[[ $fail -eq 0 ]] && echo "TODOS LOS CHECKS PASARON" || echo "HUBO FALLOS"
exit $fail
