# taiga-discord-reminders

- **Recordatorios** a Discord (webhook) por tareas que vencen mañana, hoy o están vencidas y abiertas.
- **Tablero web** (`taiga-dashboard`): tabla de **involucrados** (personas asignadas) con **cantidades por estado** de tareas abiertas (solo lectura).

## Requisitos

Docker y Docker Compose; archivo `.env` (ver `.env.example`).

## Arranque

```bash
cd taiga-discord-reminders
cp .env.example .env
# Edita .env

docker compose up -d --build
```

- Recordatorios Discord: contenedor `taiga-discord-reminders` (cron interno, p. ej. 08:00 `TZ`).
- Tablero: **http://localhost:8080/** (o el puerto de `TAIGA_DASHBOARD_PORT`).

### Solo tablero (sin Discord / sin cron)

```bash
docker compose up -d --build taiga-dashboard
```

Sigue necesitando credenciales Taiga en `.env`. Puedes dejar `DISCORD_WEBHOOK_URL` vacío si no usas el otro servicio.

### Solo recordatorios Discord

```bash
docker compose up -d --build taiga-discord-reminders
```

## Prueba manual del script Discord

```bash
docker compose run --rm --no-deps taiga-discord-reminders /scripts/remind.sh
```

## Seguridad del tablero

La página **no tiene login**: cualquiera con acceso al puerto ve los conteos. En servidor, suele bastar:

```yaml
ports:
  - "127.0.0.1:8080:8080"
```

(edita `docker-compose.yml` o usa un proxy reverso con autenticación).

## Variables

Resumen en `.env.example`. El tablero usa las mismas `TAIGA_*` que el notificador; no escribe en Taiga ni usa bot de Discord.
# taiga-notifications
