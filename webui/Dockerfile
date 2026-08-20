# Phone21 — ovládání (stdlib + hash hesel)
FROM python:3.12-slim
# jediná ne-stdlib závislost: hash hesel pro účty synchronizace
RUN pip install --no-cache-dir bcrypt==5.0.0
COPY app.py /app/app.py
COPY static/ /app/static/
USER nobody
CMD ["python3", "/app/app.py"]
