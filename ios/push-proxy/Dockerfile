FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY gecko_push_proxy.py .

# the APNs .p8 key is expected to be mounted, e.g. at /secrets/apns.p8
USER nobody
ENTRYPOINT ["python", "-u", "gecko_push_proxy.py"]
