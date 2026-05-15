# Notification System Fix — Diseño de Bugfix

## Overview

El script `scripts/remind.sh` presenta dos bugs interrelacionados: (1) la exclusión incorrecta de líderes de la lista de responsables cuando ambos modos de notificación están activos, y (2) la ausencia de mecanismos de detección y reporte de fallos silenciosos. El fix elimina la lógica de exclusión de líderes y añade contadores de errores, un resumen de ejecución final, y un log de error crítico cuando hay tareas pendientes pero 0 envíos exitosos. Se mantiene la arquitectura bash existente sin cambio de lenguaje.

## Glosario

- **Bug_Condition (C)**: Condición que activa el bug — cuando `send_leads=1` y `send_assignees=1`, el script excluye a líderes de la lista de responsables; o cuando el script falla silenciosamente sin alertar
- **Property (P)**: Comportamiento deseado — líderes reciben AMBOS mensajes; fallos se reportan con contadores y logs críticos
- **Preservation**: Comportamiento existente que NO debe cambiar — deduplicación diaria, modos ONLY_LEAD/EXCLUDE_LEAD, formato de mensajes, flujo de autenticación
- **`collect_assignee_uids`**: Función en `scripts/remind.sh` que recopila los Discord UIDs únicos de responsables con tareas pendientes, actualmente filtra líderes cuando `exclude_lead_uids=1`
- **`exclude_lead_from_assignee_list`**: Variable booleana que se activa automáticamente cuando ambos modos de envío están habilitados, causando la exclusión de líderes
- **Estado de deduplicación**: Archivo JSON (`notified_state.json`) que registra qué notificaciones se enviaron exitosamente en el día actual para evitar duplicados

## Bug Details

### Bug Condition

El bug se manifiesta en dos escenarios independientes:

**Bug 1 — Exclusión de líderes**: Cuando ambos modos de notificación están activos (`send_leads=1` AND `send_assignees=1`), el script establece `exclude_lead_from_assignee_list=1`, lo que causa que `collect_assignee_uids` filtre a los líderes de la lista de responsables. Los líderes solo reciben el reporte de liderazgo pero NO su notificación personal.

**Bug 2 — Fallos silenciosos**: Cuando el script completa su ejecución con 0 notificaciones enviadas exitosamente (por mapeo incorrecto, fallos de API, etc.), solo se registra un log informativo sin distinguir entre "no hay nada que notificar" y "hubo un fallo total".

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type ScriptExecution
  OUTPUT: boolean
  
  // Bug 1: Exclusión de líderes
  leaderExcluded := input.send_leads == 1
                    AND input.send_assignees == 1
                    AND input.user_is_leader == true
                    AND input.user_has_pending_tasks == true
                    AND NOT user_receives_assignee_notification(input.user_id)
  
  // Bug 2: Fallos silenciosos
  silentFailure := input.tasks_to_notify > 0
                   AND input.successful_sends == 0
                   AND NOT critical_error_logged()
  
  RETURN leaderExcluded OR silentFailure
END FUNCTION
```

### Ejemplos

- **Ejemplo 1**: Líder "dmvelezp" tiene 3 tareas vencidas. Con `send_leads=1` y `send_assignees=1`, recibe el reporte de liderazgo (todas las tareas del proyecto) pero NO recibe su DM personal con sus 3 tareas. **Esperado**: recibe ambos mensajes.
- **Ejemplo 2**: Responsable "Fredy" tiene tarea #391 venciendo hoy, pero su email no coincide con ninguna clave en `DISCORD_USER_MAP_JSON`. El script termina con `sent=0` y solo registra "Sin mapeo responsable" en stderr. **Esperado**: log de error crítico indicando fallo total + resumen con contadores.
- **Ejemplo 3**: Discord API retorna HTTP 429 (rate limit) para todos los envíos. El script termina con `sent=0` sin alerta. **Esperado**: log de error crítico + contadores de fallos.
- **Ejemplo 4**: Líder "dmvelezp" NO tiene tareas asignadas. Solo recibe reporte de liderazgo. **Esperado (sin cambio)**: comportamiento correcto, no debe recibir DM personal vacío.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- El formato y contenido de los mensajes DM (reporte de liderazgo y reporte personal) deben permanecer idénticos
- La deduplicación diaria debe seguir funcionando: máximo un DM personal por persona por día
- `TAIGA_NOTIFY_ONLY_LEAD=true` debe seguir enviando solo reporte de liderazgo
- `TAIGA_NOTIFY_EXCLUDE_LEAD=true` debe seguir enviando solo notificaciones a responsables
- El flujo de autenticación con Taiga API no cambia
- La lógica de filtrado por fecha (mañana, hoy, vencidas) no cambia
- El archivo de estado de deduplicación solo se marca como enviado cuando `send_dm` retorna éxito (patrón `if send_dm ... then mark_sent_today` ya existente)
- Cuando no hay tareas pendientes, el script termina silenciosamente sin error

**Scope:**
Todos los inputs que NO involucren la combinación `send_leads=1 + send_assignees=1` con líderes que tienen tareas asignadas, ni ejecuciones con 0 envíos exitosos cuando hay tareas pendientes, deben ser completamente no afectados por este fix. Esto incluye:
- Ejecuciones con `TAIGA_NOTIFY_ONLY_LEAD=true`
- Ejecuciones con `TAIGA_NOTIFY_EXCLUDE_LEAD=true`
- Ejecuciones donde no hay tareas pendientes
- Ejecuciones donde todos los envíos son exitosos
- Responsables que no son líderes (su flujo no cambia)

## Hypothesized Root Cause

Basado en el análisis del código fuente:

1. **Lógica explícita de exclusión (Bug 1)**: En la línea `[[ "$send_leads" -eq 1 && "$send_assignees" -eq 1 ]] && exclude_lead_from_assignee_list=1`, el script intencionalmente excluye a líderes de la lista de responsables. Esto se propaga a `collect_assignee_uids` que tiene el bloque:
   ```bash
   if [[ "$exclude_lead_uids" -eq 1 ]] && is_lead_uid "$aid" "$lead_json"; then
     continue
   fi
   ```
   La intención original era probablemente evitar "spam" a líderes, pero el requisito actual es que reciban ambos mensajes.

2. **Ausencia de contadores de fallo (Bug 2)**: El script tiene contadores `sent`, `skip`, `miss` pero NO tiene un contador `failed` para envíos que fallaron. Cuando `send_dm` retorna error, simplemente no incrementa `sent` ni marca dedup, pero no registra el fallo explícitamente.

3. **Sin validación de resultado final (Bug 2)**: El log final `log "DM enviados=$sent ..."` es puramente informativo. No hay lógica condicional que detecte `sent=0` cuando `combined` tiene items, lo que permitiría alertar sobre un fallo total.

4. **Deduplicación correcta pero sin visibilidad**: El patrón `if send_dm ... then mark_sent_today` ya es correcto (no marca si falla), pero sin un contador de fallos, no hay forma de saber cuántos intentos fallaron.

## Correctness Properties

Property 1: Bug Condition - Líderes reciben notificación personal de responsable

_For any_ ejecución donde `send_leads=1` AND `send_assignees=1` AND un líder tiene tareas asignadas que vencen mañana, hoy o están vencidas, la función `collect_assignee_uids` fijada SHALL incluir el UID del líder en la lista de responsables, permitiendo que reciba su DM personal además del reporte de liderazgo.

**Validates: Requirements 2.1, 2.2**

Property 2: Bug Condition - Detección de fallo total con log crítico

_For any_ ejecución donde existen tareas pendientes de notificar (`combined` no vacío) AND el total de notificaciones enviadas exitosamente es 0, el script fijado SHALL registrar un log de error crítico claramente distinguible (prefijo `[CRITICAL]` o similar) indicando fallo total en el envío.

**Validates: Requirements 2.6**

Property 3: Preservation - Comportamiento de responsables no-líderes

_For any_ ejecución donde un responsable NO es líder y tiene tareas pendientes, el script fijado SHALL producir exactamente el mismo comportamiento que el script original: enviar DM personal, respetar deduplicación, y registrar en log.

**Validates: Requirements 3.1, 3.2, 3.3**

Property 4: Preservation - Modos exclusivos ONLY_LEAD y EXCLUDE_LEAD

_For any_ ejecución con `TAIGA_NOTIFY_ONLY_LEAD=true` o `TAIGA_NOTIFY_EXCLUDE_LEAD=true`, el script fijado SHALL producir exactamente el mismo comportamiento que el script original, sin enviar notificaciones adicionales ni alterar el flujo.

**Validates: Requirements 3.4, 3.5**

## Fix Implementation

### Changes Required

Asumiendo que nuestro análisis de causa raíz es correcto:

**File**: `scripts/remind.sh`

**Función**: `main()` y `collect_assignee_uids()`

**Cambios Específicos**:

1. **Eliminar lógica de exclusión de líderes**: Remover la línea `[[ "$send_leads" -eq 1 && "$send_assignees" -eq 1 ]] && exclude_lead_from_assignee_list=1` y la variable `exclude_lead_from_assignee_list`. Pasar siempre `0` como tercer argumento a `collect_assignee_uids`, o eliminar el parámetro completamente.

2. **Simplificar `collect_assignee_uids`**: Eliminar el bloque condicional que filtra líderes:
   ```bash
   # ELIMINAR:
   if [[ "$exclude_lead_uids" -eq 1 ]] && is_lead_uid "$aid" "$lead_json"; then
     continue
   fi
   ```
   La función ya no necesita el parámetro `exclude_lead_uids` ni la referencia a `lead_json` para filtrado (puede mantener `lead_json` si se usa para otros propósitos).

3. **Añadir contador de fallos**: Declarar variable `failed=0` junto a los otros contadores. Incrementar `failed` en el bloque `else` implícito cuando `send_dm` falla (tanto en el loop de líderes como en el de responsables):
   ```bash
   if send_dm "$uid" "$msg"; then
     mark_sent_today "$dedup"; sent=$((sent+1)); sent_leads=$((sent_leads+1))
   else
     failed=$((failed+1))
   fi
   ```

4. **Añadir resumen final mejorado**: Modificar el log final para incluir el contador de fallos:
   ```bash
   log "DM enviados=$sent | fallidos=$failed | dm_lideres=$sent_leads | dm_responsables=$sent_assignees | ya_enviados_hoy=$skip | lideres_mapeados=$leaders_count | sin_mapeo_responsable=$miss"
   ```

5. **Añadir detección de fallo total**: Después del log de resumen, añadir lógica condicional:
   ```bash
   local total_to_notify
   total_to_notify="$(echo "$combined" | jq 'length')"
   if [[ "$total_to_notify" -gt 0 && "$sent" -eq 0 && "$skip" -eq 0 ]]; then
     log "[CRITICAL] Hay $total_to_notify tareas pendientes pero 0 notificaciones enviadas. Fallos=$failed, Sin_mapeo=$miss"
     exit 2
   fi
   ```
   Se usa `exit 2` para distinguir de `exit 1` (error de configuración) y `exit 0` (éxito).

## Testing Strategy

### Validation Approach

La estrategia de testing sigue un enfoque de dos fases: primero, generar contraejemplos que demuestren los bugs en el código sin corregir, luego verificar que el fix funciona correctamente y preserva el comportamiento existente.

### Exploratory Bug Condition Checking

**Goal**: Generar contraejemplos que demuestren los bugs ANTES de implementar el fix. Confirmar o refutar el análisis de causa raíz. Si refutamos, necesitaremos re-hipotetizar.

**Test Plan**: Crear un entorno de test con mocks de Discord API y Taiga API. Ejecutar el script sin corregir con configuraciones que activen las condiciones de bug. Observar que los líderes NO reciben DM personal y que fallos totales no generan alertas.

**Test Cases**:
1. **Leader Exclusion Test**: Configurar `send_leads=1`, `send_assignees=1`, líder con tareas asignadas. Verificar que `collect_assignee_uids` NO incluye al líder (fallará en código sin corregir — confirma bug)
2. **Silent Failure - Unmapped User**: Configurar un responsable cuyo email no está en `DISCORD_USER_MAP_JSON`. Verificar que el script termina con `sent=0` sin log crítico (fallará en código sin corregir — confirma bug)
3. **Silent Failure - API Error**: Mockear Discord API para retornar HTTP 500. Verificar que el script no genera alerta de fallo total (fallará en código sin corregir — confirma bug)
4. **Leader Without Tasks**: Configurar líder sin tareas asignadas. Verificar que NO recibe DM personal (debe pasar en ambas versiones — edge case)

**Expected Counterexamples**:
- El UID del líder no aparece en la salida de `collect_assignee_uids` cuando `exclude_lead_uids=1`
- El script termina con exit code 0 y log informativo cuando `sent=0` y hay tareas pendientes
- Posibles causas confirmadas: lógica explícita de exclusión en línea 101, ausencia de contador `failed`

### Fix Checking

**Goal**: Verificar que para todos los inputs donde la condición de bug se cumple, la función corregida produce el comportamiento esperado.

**Pseudocode:**
```
FOR ALL input WHERE isBugCondition(input) DO
  result := remind_sh_fixed(input)
  IF input.type == "leader_exclusion" THEN
    ASSERT leader_uid IN collect_assignee_uids_fixed(combined, lead_ids, 0)
    ASSERT leader_received_both_messages(result)
  END IF
  IF input.type == "silent_failure" THEN
    ASSERT result.logs CONTAINS "[CRITICAL]"
    ASSERT result.exit_code == 2
    ASSERT result.summary CONTAINS "fallidos"
  END IF
END FOR
```

### Preservation Checking

**Goal**: Verificar que para todos los inputs donde la condición de bug NO se cumple, la función corregida produce el mismo resultado que la función original.

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT remind_sh_original(input) = remind_sh_fixed(input)
END FOR
```

**Testing Approach**: Property-based testing es recomendado para preservation checking porque:
- Genera muchos casos de prueba automáticamente a través del dominio de inputs
- Detecta edge cases que tests manuales podrían omitir
- Provee garantías fuertes de que el comportamiento no cambia para inputs no-buggy

**Test Plan**: Observar comportamiento en código sin corregir primero para responsables no-líderes, modos exclusivos, y ejecuciones sin tareas. Luego escribir property-based tests capturando ese comportamiento.

**Test Cases**:
1. **Non-Leader Assignee Preservation**: Observar que responsables no-líderes reciben DM personal correctamente en código sin corregir, luego verificar que continúa después del fix
2. **ONLY_LEAD Mode Preservation**: Observar que con `TAIGA_NOTIFY_ONLY_LEAD=true` solo se envía reporte de liderazgo, verificar que continúa después del fix
3. **EXCLUDE_LEAD Mode Preservation**: Observar que con `TAIGA_NOTIFY_EXCLUDE_LEAD=true` solo se envían DMs personales, verificar que continúa después del fix
4. **No Tasks Preservation**: Observar que sin tareas pendientes el script termina con exit 0 sin envíos, verificar que continúa después del fix
5. **Dedup Preservation**: Observar que la deduplicación diaria funciona correctamente, verificar que continúa después del fix

### Unit Tests

- Test de `collect_assignee_uids` con `exclude_lead_uids=0`: verificar que líderes SÍ se incluyen
- Test de `collect_assignee_uids` con líderes que tienen tareas y líderes que no tienen tareas
- Test del contador `failed`: verificar que se incrementa cuando `send_dm` falla
- Test del log `[CRITICAL]`: verificar que se emite cuando `sent=0` y hay tareas pendientes
- Test del resumen final: verificar que incluye todos los contadores (enviados, fallidos, sin mapeo, omitidos)
- Test de edge case: líder es el ÚNICO responsable con tareas pendientes

### Property-Based Tests

- Generar configuraciones aleatorias de usuarios (líderes/no-líderes) con tareas asignadas y verificar que todos los responsables con tareas reciben DM personal independientemente de si son líderes
- Generar escenarios aleatorios de fallos de API (HTTP 4xx/5xx) y verificar que el contador `failed` refleja correctamente el número de fallos
- Generar combinaciones aleatorias de `TAIGA_NOTIFY_ONLY_LEAD` y `TAIGA_NOTIFY_EXCLUDE_LEAD` y verificar que los modos exclusivos se preservan exactamente

### Integration Tests

- Test de flujo completo: autenticación → fetch → filtrado → envío a líderes Y responsables (incluyendo líder como responsable)
- Test de fallo total: mockear Discord API para fallar en todos los envíos, verificar log `[CRITICAL]` y exit code 2
- Test de ejecución parcial: algunos envíos exitosos, algunos fallidos, verificar resumen correcto y dedup solo para exitosos
- Test de re-ejecución: ejecutar dos veces el mismo día, verificar que la segunda ejecución respeta dedup para exitosos pero reintenta fallidos
