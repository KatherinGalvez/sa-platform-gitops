"""Servicio pedidos: punto de entrada de la compra.

POST /pedidos  -> reserva en inventario -> cobra en pagos -> 201 creado.
Una sola traza recorre los tres servicios (cabecera traceparent).

Fallo inducible por configuracion (para el canary y las pruebas):
  FALLA_PORCENTAJE   porcentaje de pedidos que responden 500
  LATENCIA_EXTRA_MS  milisegundos agregados a cada pedido
"""
import os
import random
import uuid

import requests
from flask import request
from prometheus_client import Counter

from telemetria import cabeceras_propagadas, crear_app, latencia_extra, porcentaje_env

app, log, tracer = crear_app("pedidos")

INVENTARIO = os.environ.get("INVENTARIO_URL", "http://inventario:8080")
PAGOS = os.environ.get("PAGOS_URL", "http://pagos:8080")

# Metricas de negocio
PEDIDOS_CREADOS = Counter("pedidos_creados", "Pedidos creados con exito", ["producto"])
PEDIDOS_RECHAZADOS = Counter("pedidos_rechazados", "Pedidos no completados", ["motivo"])
INGRESOS = Counter("ingresos_quetzales", "Monto cobrado por pedidos creados (Q)")

PRECIOS = {"teclado": 250.0, "monitor": 1800.0, "mouse": 120.0, "laptop": 7500.0, "audifonos": 400.0}


@app.post("/pedidos")
def crear_pedido():
    datos = request.get_json(silent=True) or {}
    producto = datos.get("producto") or random.choice(list(PRECIOS))
    cantidad = int(datos.get("cantidad") or 1)
    pedido_id = str(uuid.uuid4())[:8]
    monto = PRECIOS.get(producto, 100.0) * cantidad

    latencia_extra()
    if random.uniform(0, 100) < porcentaje_env("FALLA_PORCENTAJE"):
        PEDIDOS_RECHAZADOS.labels("error_interno").inc()
        log.error("fallo al registrar el pedido", extra={
            "pedido_id": pedido_id, "producto": producto, "error": "FALLA_PORCENTAJE (fallo inducido)"})
        return {"error": "error interno al registrar el pedido", "pedido_id": pedido_id}, 500

    with tracer.start_as_current_span("reservar_inventario"):
        try:
            r = requests.post(f"{INVENTARIO}/reservar", json={"producto": producto, "cantidad": cantidad},
                              headers=cabeceras_propagadas(), timeout=2)
        except requests.RequestException as e:
            PEDIDOS_RECHAZADOS.labels("inventario_no_disponible").inc()
            log.error("inventario no responde", extra={"pedido_id": pedido_id, "destino": "inventario", "error": str(e)})
            return {"error": "inventario no disponible"}, 502
    if r.status_code == 409:
        PEDIDOS_RECHAZADOS.labels("sin_stock").inc()
        log.info("pedido rechazado por falta de stock", extra={"pedido_id": pedido_id, "producto": producto})
        return {"pedido_id": pedido_id, "estado": "sin_stock"}, 409
    if r.status_code >= 500:
        PEDIDOS_RECHAZADOS.labels("inventario_error").inc()
        log.error("inventario devolvio error", extra={"pedido_id": pedido_id, "destino": "inventario", "status": r.status_code})
        return {"error": "error en inventario"}, 502

    with tracer.start_as_current_span("cobrar_pago"):
        try:
            p = requests.post(f"{PAGOS}/cobrar", json={"pedido_id": pedido_id, "monto": monto},
                              headers=cabeceras_propagadas(), timeout=2)
        except requests.RequestException as e:
            PEDIDOS_RECHAZADOS.labels("pagos_no_disponible").inc()
            log.error("pagos no responde", extra={"pedido_id": pedido_id, "destino": "pagos", "error": str(e)})
            return {"error": "pagos no disponible"}, 502
    if p.status_code == 402:
        PEDIDOS_RECHAZADOS.labels("pago_rechazado").inc()
        log.info("pedido rechazado: pago no autorizado", extra={"pedido_id": pedido_id, "monto": monto})
        return {"pedido_id": pedido_id, "estado": "pago_rechazado"}, 402
    if p.status_code >= 500:
        PEDIDOS_RECHAZADOS.labels("pagos_error").inc()
        log.error("pagos devolvio error", extra={"pedido_id": pedido_id, "destino": "pagos", "status": p.status_code})
        return {"error": "error en pagos"}, 502

    PEDIDOS_CREADOS.labels(producto).inc()
    INGRESOS.inc(monto)
    log.info("pedido creado", extra={"pedido_id": pedido_id, "producto": producto, "cantidad": cantidad, "monto": monto})
    return {"pedido_id": pedido_id, "estado": "creado", "monto": monto}, 201


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PUERTO", "8080")), threaded=True)
