"""
Tablero de solo lectura: involucrados (asignados) × cantidad de tareas abiertas por estado.
Usa las mismas variables TAIGA_* que el notificador a Discord.
"""

from __future__ import annotations

import os
from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Any
from zoneinfo import ZoneInfo

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

templates = Jinja2Templates(directory="templates")
app = FastAPI(title="Taiga — resumen por involucrado", docs_url=None, redoc_url=None)


def _env_clean(name: str) -> str:
    """Quita \\r y espacios (típico de .env en Windows); evita login inválido con credenciales correctas."""
    return os.environ.get(name, "").replace("\r", "").strip()


def _base_url() -> str:
    u = _env_clean("TAIGA_BASE_URL")
    if not u:
        raise RuntimeError("Definir TAIGA_BASE_URL")
    return u.rstrip("/")


def _project_id() -> str:
    p = _env_clean("TAIGA_PROJECT_ID")
    if not p:
        raise RuntimeError("Definir TAIGA_PROJECT_ID")
    return p


def _http_verify() -> bool:
    return _env_clean("TAIGA_SSL_VERIFY").lower() not in ("0", "false", "no", "off")


def get_auth_token(client: httpx.Client) -> str:
    token = _env_clean("TAIGA_AUTH_TOKEN")
    if token:
        return token
    user = _env_clean("TAIGA_USERNAME")
    pwd = _env_clean("TAIGA_PASSWORD")
    if not user or not pwd:
        raise RuntimeError(
            "Definir TAIGA_AUTH_TOKEN o TAIGA_USERNAME + TAIGA_PASSWORD en el entorno"
        )
    url = f"{_base_url()}/api/v1/auth"
    try:
        r = client.post(
            url,
            json={"type": "normal", "username": user, "password": pwd},
            timeout=60.0,
        )
        r.raise_for_status()
    except httpx.HTTPStatusError as e:
        body = (e.response.text or "")[:800].replace("\n", " ")
        raise RuntimeError(
            f"Login Taiga rechazado (HTTP {e.response.status_code}). "
            f"Usa el mismo **username** de Taiga (no siempre el email), revisa TAIGA_BASE_URL y .env sin comillas raras. "
            f"Detalle API: {body or '(sin cuerpo)'}"
        ) from e
    data = r.json()
    tok = data.get("auth_token")
    if not tok:
        raise RuntimeError(f"Login Taiga inválido (sin auth_token): {data}")
    return tok


def _auth_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }


def _fetch_open_items(
    client: httpx.Client, token: str, endpoint: str
) -> list[dict[str, Any]]:
    base = (
        f"{_base_url()}/api/v1/{endpoint}"
        f"?project={_project_id()}&status__is_closed=false"
    )
    out: list[dict[str, Any]] = []
    url: str | None = base

    for _ in range(500):
        if not url:
            break
        r = client.get(url, headers=_auth_headers(token), timeout=120.0)
        r.raise_for_status()
        raw = r.json()
        if isinstance(raw, list):
            out.extend(raw)
            break
        if isinstance(raw, dict) and "results" in raw:
            out.extend(raw["results"])
            nxt = raw.get("next")
            url = nxt if nxt else None
        else:
            raise RuntimeError(f"Respuesta inesperada de /{endpoint}: {type(raw)}")

    return out


def fetch_open_tasks(client: httpx.Client, token: str) -> list[dict[str, Any]]:
    return _fetch_open_items(client, token, "tasks")


def fetch_open_userstories(client: httpx.Client, token: str) -> list[dict[str, Any]]:
    return _fetch_open_items(client, token, "userstories")


def fetch_project_name(client: httpx.Client, token: str) -> str | None:
    try:
        r = client.get(
            f"{_base_url()}/api/v1/projects/{_project_id()}",
            headers=_auth_headers(token),
            timeout=60.0,
        )
        r.raise_for_status()
        return r.json().get("name")
    except Exception:
        return None


def status_label(item: dict[str, Any]) -> str:
    info = item.get("status_extra_info") or {}
    name = info.get("name")
    if name:
        return str(name)
    sid = item.get("status")
    return f"Estado #{sid}" if sid is not None else "Sin estado"


def _today_in_config_tz() -> date:
    tz_name = os.environ.get("TZ", "UTC").strip() or "UTC"
    try:
        z = ZoneInfo(tz_name)
    except Exception:
        z = ZoneInfo("UTC")
    return datetime.now(z).date()


def parse_due_date(item: dict[str, Any]) -> date | None:
    raw = item.get("due_date")
    if not raw or not isinstance(raw, str):
        return None
    part = raw.split("T", 1)[0].strip()
    try:
        y, m, d = (int(x) for x in part.split("-", 2))
        return date(y, m, d)
    except (ValueError, AttributeError):
        return None


def assignee_key_and_label(item: dict[str, Any]) -> tuple[str, str]:
    uid = item.get("assigned_to")
    info = item.get("assigned_to_extra_info")
    if uid is None and not info:
        return ("__unassigned__", "Sin asignar")
    if info:
        label = info.get("full_name_display") or info.get("username") or f"Usuario #{uid}"
    else:
        label = f"Usuario #{uid}"
    return (str(uid), label)


def build_matrix(
    items: list[dict[str, Any]],
) -> tuple[list[str], list[dict[str, Any]], dict[str, int], int, int, int, int]:
    # (assignee_key -> label)
    labels: dict[str, str] = {}
    counts: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    all_statuses: set[str] = set()
    overdue_by_key: dict[str, int] = defaultdict(int)
    due_tomorrow_by_key: dict[str, int] = defaultdict(int)
    due_today_by_key: dict[str, int] = defaultdict(int)
    today = _today_in_config_tz()
    tomorrow = today + timedelta(days=1)

    for t in items:
        key, label = assignee_key_and_label(t)
        labels.setdefault(key, label)
        st = status_label(t)
        all_statuses.add(st)
        counts[key][st] += 1
        d = parse_due_date(t)
        if d is not None:
            if d < today:
                overdue_by_key[key] += 1
            elif d == today:
                due_today_by_key[key] += 1
            elif d == tomorrow:
                due_tomorrow_by_key[key] += 1

    status_cols = sorted(all_statuses, key=lambda s: s.lower())
    row_keys = sorted(
        labels.keys(),
        key=lambda k: (k == "__unassigned__", labels[k].lower()),
    )

    rows: list[dict[str, Any]] = []
    col_totals: dict[str, int] = defaultdict(int)
    grand = 0

    for key in row_keys:
        cells: dict[str, int] = {}
        row_total = 0
        for st in status_cols:
            n = counts[key].get(st, 0)
            cells[st] = n
            row_total += n
            col_totals[st] += n
        grand += row_total
        rows.append(
            {
                "label": labels[key],
                "cells": cells,
                "total": row_total,
                "overdue": overdue_by_key.get(key, 0),
                "due_today": due_today_by_key.get(key, 0),
                "due_tomorrow": due_tomorrow_by_key.get(key, 0),
            }
        )

    overdue_total = sum(overdue_by_key.values())
    due_today_total = sum(due_today_by_key.values())
    due_tomorrow_total = sum(due_tomorrow_by_key.values())
    return (
        status_cols,
        rows,
        col_totals,
        grand,
        overdue_total,
        due_today_total,
        due_tomorrow_total,
    )


def _username_from_item(item: dict[str, Any]) -> str:
    info = item.get("assigned_to_extra_info")
    if info:
        return info.get("username") or "-"
    return "-"


def normalize_item(raw: dict[str, Any], item_type: str) -> dict[str, Any]:
    due = parse_due_date(raw)
    assignee_key, assignee_label = assignee_key_and_label(raw)
    return {
        "type": item_type,
        "ref": raw.get("ref"),
        "subject": raw.get("subject") or "Sin título",
        "status": status_label(raw),
        "due_date": due.isoformat() if due else None,
        "due_date_display": due.isoformat() if due else "Sin fecha",
        "assignee_key": assignee_key,
        "assignee_label": assignee_label,
        "username": _username_from_item(raw),
    }


def split_and_group_items(items: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    today = _today_in_config_tz()
    tomorrow = today + timedelta(days=1)

    buckets: dict[str, list[dict[str, Any]]] = {
        "overdue": [],
        "today": [],
        "tomorrow": [],
        "future": [],
        "nodate": [],
    }
    for it in items:
        d = parse_due_date(it)
        entity_type = it.get("entity_type", "task")
        norm = normalize_item(it, entity_type)
        if d is None:
            buckets["nodate"].append(norm)
        elif d < today:
            buckets["overdue"].append(norm)
        elif d == today:
            buckets["today"].append(norm)
        elif d == tomorrow:
            buckets["tomorrow"].append(norm)
        else:
            buckets["future"].append(norm)

    # Sort each bucket by due_date, then type, then ref
    for key in buckets:
        buckets[key].sort(
            key=lambda x: (
                x["due_date"] or "9999-12-31",
                x["type"],
                x["ref"] or 0,
            )
        )

    return buckets


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request) -> Any:
    err: str | None = None
    project_name: str | None = None
    status_cols: list[str] = []
    rows: list[dict[str, Any]] = []
    col_totals: dict[str, int] = {}
    grand_total = 0
    overdue_total = 0
    due_today_total = 0
    due_tomorrow_total = 0
    item_count = 0
    grouped_due: dict[str, list[dict[str, Any]]] = {
        "overdue": [], "today": [], "tomorrow": [], "future": [], "nodate": []
    }
    today_str = _today_in_config_tz().isoformat()
    tomorrow_str = (_today_in_config_tz() + timedelta(days=1)).isoformat()

    try:
        with httpx.Client(verify=_http_verify()) as client:
            token = get_auth_token(client)
            project_name = fetch_project_name(client, token)
            tasks = fetch_open_tasks(client, token)
            userstories = fetch_open_userstories(client, token)
            items = [dict(t, entity_type="task") for t in tasks] + [
                dict(us, entity_type="userstory") for us in userstories
            ]
            item_count = len(items)
            (
                status_cols,
                rows,
                col_totals,
                grand_total,
                overdue_total,
                due_today_total,
                due_tomorrow_total,
            ) = build_matrix(items)
            grouped_due = split_and_group_items(items)
    except Exception as e:
        err = str(e)

    # Collect unique statuses from items for the filter display
    all_statuses_in_data = sorted(set(
        it["status"] for bucket in grouped_due.values() for it in bucket
    ))

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "error": err,
            "project_name": project_name,
            "project_id": _project_id(),
            "status_cols": status_cols,
            "rows": rows,
            "col_totals": col_totals,
            "grand_total": grand_total,
            "overdue_total": overdue_total,
            "due_today_total": due_today_total,
            "due_tomorrow_total": due_tomorrow_total,
            "item_count": item_count,
            "grouped_due": grouped_due,
            "today_str": today_str,
            "tomorrow_str": tomorrow_str,
            "all_statuses": all_statuses_in_data,
            "generated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "tz_label": os.environ.get("TZ", "UTC"),
        },
    )


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
