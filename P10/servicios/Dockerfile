# Una sola imagen para los tres servicios y el generador; el Deployment/Rollout
# elige el programa con `command`. Version fija (politica de admision de P8).
FROM python:3.12.8-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY telemetria.py pedidos.py pagos.py inventario.py generador.py ./
USER 10001
EXPOSE 8080
CMD ["python", "pedidos.py"]
