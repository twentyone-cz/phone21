# GSM2SIP web UI — čistá stdlib, žádné pip závislosti
FROM python:3.12-slim
# qrencode: QR s configem WireGuardu pro telefon (záložka Telefon).
# Systémový balíček, ne pip — pravidlo „žádné pip závislosti" platí dál.
RUN apt-get update \
 && apt-get install -y --no-install-recommends qrencode \
 && rm -rf /var/lib/apt/lists/*
COPY app.py /app/app.py
USER nobody
CMD ["python3", "/app/app.py"]
