FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY scripts/*.py scripts/
COPY web/ web/

ENV PYTHONUNBUFFERED=1
