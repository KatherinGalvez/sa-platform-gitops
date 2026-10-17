"""Servicio inventario: reserva existencias para un pedido.

POST /reservar -> 200 reservado | 409 sin stock (negocio) | 500 error (tecnico)
"""
import os
import random
import time

from flask import request
from prometheus_client import Counter

from telemetria import crear_app, latencia_extra, porcentaje_env

app, log, tracer = crear_app("inventario")

RESERVAS = Counter("inventario_reservas", "Reservas de inventario realizadas", ["producto"])
SIN_STOCK = Counter("inventario_sin_stock", "Reservas rechazadas por falta de existencias", ["producto"])

TASA_SIN_STOCK = 2.0  # %


@app.post("/reservar")
def reservar():
    datos = request.get_json(silent=True) or {}
    producto = datos.get("producto", "desconocido")
    cantidad = int(datos.get("cantidad") or 1)

    with tracer.start_as_current_span("consultar_existencias") as span:
        span.set_attribute("inventario.producto", producto)
        time.sleep(random.uniform(0.01, 0.04))
        latencia_extra()
        if random.uniform(0, 100) < porcentaje_env("FALLA_PORCENTAJE"):
            log.error("error leyendo existencias", extra={"producto": producto, "error": "FALLA_PORCENTAJE"})
            return {"error": "error interno"}, 500

    if random.uniform(0, 100) < TASA_SIN_STOCK:
        SIN_STOCK.labels(producto).inc()
        log.info("sin existencias", extra={"producto": producto, "cantidad": cantidad})
        return {"estado": "sin_stock"}, 409

    RESERVAS.labels(producto).inc()
    log.info("existencias reservadas", extra={"producto": producto, "cantidad": cantidad})
    return {"estado": "reservado"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PUERTO", "8080")), threaded=True)
