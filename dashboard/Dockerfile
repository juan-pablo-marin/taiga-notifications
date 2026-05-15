FROM python:3.12-alpine

WORKDIR /app
RUN apk add --no-cache curl

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates ./templates

ENV TAIGA_DASHBOARD_BIND=0.0.0.0
ENV TAIGA_DASHBOARD_PORT=8086

EXPOSE 8086

CMD sh -c 'uvicorn app:app --host "${TAIGA_DASHBOARD_BIND}" --port "${TAIGA_DASHBOARD_PORT}"'
