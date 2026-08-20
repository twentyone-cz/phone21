# Phone21 — kontakty a kalendář (server pro synchronizaci).
FROM python:3.12-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN pip install --no-cache-dir radicale==3.7.8 bcrypt==5.0.0
COPY config /etc/radicale/config
COPY rights /etc/radicale/rights
COPY entrypoint.py /opt/phone21-dav/entrypoint.py
EXPOSE 5232
CMD ["python3", "/opt/phone21-dav/entrypoint.py"]
