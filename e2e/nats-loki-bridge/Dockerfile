FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir nats-py

COPY bridge.py .

RUN useradd -r -s /usr/sbin/nologin bridge
USER bridge

CMD ["python", "bridge.py"]
