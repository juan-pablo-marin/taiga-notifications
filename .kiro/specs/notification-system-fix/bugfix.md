# Bugfix Requirements Document

## Introduction

El sistema de notificaciones Taiga-Discord presenta dos problemas interrelacionados que resultan en la pérdida total o parcial de notificaciones:

1. **Bug de exclusión de líderes**: Cuando ambas notificaciones están activas (`send_leads=1` y `send_assignees=1`), el script activa `exclude_lead_from_assignee_list=1`, lo que excluye a los líderes de recibir su notificación personal como responsables. El requisito del usuario establece que los líderes deben recibir AMBOS mensajes: el reporte completo de liderazgo Y su notificación personal.

2. **Bug de fallos silenciosos**: El script puede fallar en enviar CUALQUIER notificación sin generar alertas visibles ni diagnósticos. Ejemplo concreto: la tarea #391 asignada a "Fredy" (un responsable regular, NO líder) con fecha de vencimiento hoy (2026-05-12) no generó ninguna notificación — ni para el responsable ni para los líderes. Esto indica que el script puede fallar completamente sin dejar rastro del problema (mapeo incorrecto de usuario, fallo de autenticación, error de API de Discord, deduplicación falsa, etc.).

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN un líder tiene tareas asignadas que vencen mañana, hoy o están vencidas AND ambas notificaciones (líderes y responsables) están activas THEN el sistema excluye al líder de la lista de responsables (`exclude_lead_from_assignee_list=1`) y NO le envía su notificación personal de tareas asignadas

1.2 WHEN `exclude_lead_from_assignee_list=1` se activa automáticamente (porque `send_leads=1` y `send_assignees=1`) THEN el sistema filtra completamente a los líderes en la función `collect_assignee_uids`, impidiendo que reciban el mensaje personalizado de responsable

1.3 WHEN un responsable no está correctamente mapeado en `DISCORD_USER_MAP_JSON` (email o username no coincide) THEN el sistema lo omite silenciosamente sin generar una alerta clara ni un resumen de notificaciones fallidas

1.4 WHEN el script falla en autenticación con Taiga, conexión con Discord API, o cualquier paso crítico THEN el script termina con `exit 1` pero no genera ninguna notificación de fallo al administrador ni registro persistente del error

1.5 WHEN el archivo de estado de deduplicación contiene entradas de una ejecución parcial previa (donde se marcó como enviado pero el DM realmente falló) THEN el sistema asume que ya se envió la notificación y omite al usuario en ejecuciones posteriores del mismo día

1.6 WHEN el script completa su ejecución sin enviar ninguna notificación (0 DMs enviados, 0 líderes notificados) THEN el sistema solo registra un log informativo sin alertar que hubo un fallo total en el envío

1.7 WHEN un responsable tiene tareas que vencen pero su email/username en Taiga no coincide con ninguna clave en `DISCORD_USER_MAP_JSON` THEN el sistema registra "Sin mapeo responsable" en stderr pero no hay mecanismo para que el administrador se entere del problema de forma proactiva

### Expected Behavior (Correct)

2.1 WHEN un líder tiene tareas asignadas que vencen mañana, hoy o están vencidas AND ambas notificaciones están activas THEN el sistema SHALL enviar al líder TANTO el reporte de liderazgo (todas las tareas del proyecto) COMO su notificación personal de responsable (solo sus tareas)

2.2 WHEN se recopilan los UIDs de responsables para enviar notificaciones personales THEN el sistema SHALL incluir a los líderes en la lista de responsables sin excluirlos, permitiendo que reciban su DM personal además del reporte de liderazgo

2.3 WHEN un responsable no está mapeado en `DISCORD_USER_MAP_JSON` THEN el sistema SHALL registrar una advertencia clara con el nombre completo, email y username del responsable no mapeado, Y SHALL incluir un resumen al final de la ejecución con el total de responsables sin mapeo

2.4 WHEN el script completa su ejecución THEN el sistema SHALL generar un resumen final que incluya: total de notificaciones enviadas exitosamente, total de notificaciones fallidas, total de responsables sin mapeo, y total de notificaciones omitidas por deduplicación

2.5 WHEN el envío de un DM falla (error de Discord API, canal no creado, rate limit) THEN el sistema SHALL NO marcar ese envío como exitoso en el archivo de estado de deduplicación, permitiendo reintentos en ejecuciones posteriores del mismo día

2.6 WHEN el script detecta que hay tareas pendientes de notificar pero NO logró enviar NINGUNA notificación (0 exitosas) THEN el sistema SHALL registrar un error crítico claramente distinguible en los logs indicando fallo total

2.7 WHEN una tarea sigue abierta (no está en estado "done") y su fecha de vencimiento es hoy, mañana o ya pasó THEN el sistema SHALL notificar al responsable cada día hasta que la tarea cambie de estado o se modifique la fecha de vencimiento

### Unchanged Behavior (Regression Prevention)

3.1 WHEN un líder no tiene tareas asignadas que estén próximas a vencer, venzan hoy o estén vencidas THEN el sistema SHALL CONTINUE TO enviarle únicamente el reporte de liderazgo sin notificación personal de responsable

3.2 WHEN un responsable que NO es líder tiene tareas asignadas próximas a vencer THEN el sistema SHALL CONTINUE TO enviarle su notificación personal de responsable normalmente

3.3 WHEN la deduplicación por día está activa y una notificación fue enviada EXITOSAMENTE THEN el sistema SHALL CONTINUE TO enviar máximo una notificación personal de responsable por persona por día (un solo mensaje con TODAS sus tareas), independientemente de cuántas categorías de vencimiento tengan sus tareas

3.4 WHEN `TAIGA_NOTIFY_ONLY_LEAD=true` THEN el sistema SHALL CONTINUE TO enviar solo el reporte de liderazgo sin notificaciones a responsables

3.5 WHEN `TAIGA_NOTIFY_EXCLUDE_LEAD=true` THEN el sistema SHALL CONTINUE TO enviar solo notificaciones a responsables sin reporte de liderazgo

3.6 WHEN no hay tareas que venzan mañana, hoy ni vencidas THEN el sistema SHALL CONTINUE TO terminar sin enviar ningún mensaje

3.7 WHEN un nuevo día comienza THEN el sistema SHALL CONTINUE TO resetear el estado de deduplicación, permitiendo que las tareas que siguen abiertas y vencidas se re-notifiquen diariamente

3.8 WHEN el script se ejecuta correctamente y envía todas las notificaciones sin errores THEN el sistema SHALL CONTINUE TO registrar el resumen de envíos en el log como lo hace actualmente
