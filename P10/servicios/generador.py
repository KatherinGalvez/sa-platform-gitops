"""Generador de trafico de usuarios: crea pedidos de forma continua.

Sin trafico no hay metricas que medir: el canary y los SLO se calculan sobre
estas peticiones. TASA = pedidos por segundo.
"""
import json
import os
import random
import time

import requests

DESTINO = os.environ.get("PEDIDOS_URL", "http://pedidos:8080") + "/pedidos"
TASA = float(os.environ.get("TASA", "5"))
PRODUCTOS = ["teclado", "monitor", "mouse", "laptop", "audifonos"]

conteo = {}
ultimo = time.time()
while True:
    try:
        r = requests.post(DESTINO, json={"producto": random.choice(PRODUCTOS), "cantidad": random.randint(1, 3)},
                          timeout=3)
        clave = str(r.status_code)
    except requests.RequestException:
        clave = "sin_respuesta"
    conteo[clave] = conteo.get(clave, 0) + 1
    if time.time() - ultimo >= 30:
        print(json.dumps({"service": "generador", "level": "INFO", "message": "resumen 30s", "respuestas": conteo}),
              flush=True)
        conteo, ultimo = {}, time.time()
    time.sleep(1.0 / TASA)
