# Phone21 web UI — čistá stdlib, žádné pip závislosti
FROM python:3.12-slim
COPY app.py /app/app.py
COPY static/ /app/static/
USER nobody
CMD ["python3", "/app/app.py"]
