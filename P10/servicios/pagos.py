"""Servicio pagos: autoriza el cobro de un pedido.

POST /cobrar -> 200 aprobado | 402 rechazado (negocio) | 503 error (tecnico)

Fallo inducible: FALLA_PORCENTAJE (porcentaje de cobros que responden 503,
simula la caida de la pasarela de pago) y LATENCIA_EXTRA_MS.
"""
import os
import random
import time

from flask import request
from prometheus_client import Counter

from telemetria import crear_app, latencia_extra, porcentaje_env

app, log, tracer = crear_app("pagos")

PAGOS_APROBADOS = Counter("pagos_aprobados", "Pagos autorizados")
PAGOS_RECHAZADOS = Counter("pagos_rechazados", "Pagos rechazados", ["motivo"])

TASA_RECHAZO_NEGOCIO = 4.0  # % de tarjetas sin fondos (comportamiento normal)


@app.post("/cobrar")
def cobrar():
    datos = request.get_json(silent=True) or {}
    pedido_id = datos.get("pedido_id", "?")
    monto = float(datos.get("monto", 0))

    with tracer.start_as_current_span("consultar_pasarela") as span:
        span.set_attribute("pago.monto", monto)
        time.sleep(random.uniform(0.02, 0.08))
        latencia_extra()
        if random.uniform(0, 100) < porcentaje_env("FALLA_PORCENTAJE"):
            span.set_attribute("error", True)
            PAGOS_RECHAZADOS.labels("pasarela_caida").inc()
            log.error("la pasarela de pago no respondio", extra={
                "pedido_id": pedido_id, "monto": monto, "error": "timeout pasarela (FALLA_PORCENTAJE)"})
            return {"error": "pasarela de pago no disponible"}, 503

    if random.uniform(0, 100) < TASA_RECHAZO_NEGOCIO:
        PAGOS_RECHAZADOS.labels("fondos_insuficientes").inc()
        log.info("pago rechazado", extra={"pedido_id": pedido_id, "monto": monto, "motivo": "fondos_insuficientes"})
        return {"estado": "rechazado", "motivo": "fondos_insuficientes"}, 402

    PAGOS_APROBADOS.inc()
    log.info("pago aprobado", extra={"pedido_id": pedido_id, "monto": monto})
    return {"estado": "aprobado"}, 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PUERTO", "8080")), threaded=True)
