"""Telemetria comun de los servicios de la Practica 10.

Los tres pilares, correlacionados por el identificador de traza:
  * Trazas  -> OpenTelemetry SDK -> OTLP/gRPC -> OTel Collector -> Tempo.
               La propagacion entre servicios usa el estandar W3C TraceContext
               (cabecera `traceparent`), inyectada en cada llamada saliente.
  * Metricas -> prometheus_client en /metrics, recolectadas por Prometheus
               (PodMonitor). Tecnicas (latencia, errores, trafico, saturacion)
               y de negocio (pedidos creados, pagos rechazados, sin stock).
  * Registros -> JSON en stdout con trace_id y span_id; el Collector los lee
               del nodo y los envia a Loki.
"""
import json
import logging
import os
import sys
import time
from datetime import datetime, timezone

import flask.cli
from flask import Flask, Response, g, request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from opentelemetry.propagate import inject
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest

flask.cli.show_server_banner = lambda *a, **k: None  # sin texto plano en stdout

SERVICIO = os.environ.get("OTEL_SERVICE_NAME", "desconocido")
VERSION = os.environ.get("VERSION", "v1")
OTLP_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "http://otel-collector.observabilidad:4317")

# ---------------------------------------------------------------------------
# Metricas tecnicas (cuatro senales de oro)
# ---------------------------------------------------------------------------
LATENCIA = Histogram(
    "http_server_requests_seconds",
    "Duracion de las peticiones HTTP atendidas",
    ["service", "route", "method", "status"],
    buckets=(0.025, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.75, 1.0, 2.5, 5.0),
)
EN_CURSO = Gauge(
    "http_server_requests_in_flight",
    "Peticiones HTTP en curso (saturacion)",
    ["service"],
)


def _formato_ts(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class FormatoJSON(logging.Formatter):
    """Una linea JSON por evento, con el contexto de la traza activa."""

    CAMPOS_EXTRA = (
        "route", "method", "status", "duration_ms", "pedido_id", "producto",
        "cantidad", "monto", "motivo", "error", "destino",
    )

    def format(self, record):
        evento = {
            "timestamp": _formato_ts(record.created),
            "level": record.levelname,
            "service": SERVICIO,
            "version": VERSION,
            "message": record.getMessage(),
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            evento["trace_id"] = format(ctx.trace_id, "032x")
            evento["span_id"] = format(ctx.span_id, "016x")
        for campo in self.CAMPOS_EXTRA:
            if hasattr(record, campo):
                evento[campo] = getattr(record, campo)
        return json.dumps(evento, ensure_ascii=False)


def configurar_registros():
    manejador = logging.StreamHandler(sys.stdout)
    manejador.setFormatter(FormatoJSON())
    raiz = logging.getLogger()
    raiz.handlers = [manejador]
    raiz.setLevel(logging.INFO)
    # El servidor de desarrollo de Flask escribe texto plano: se silencia.
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    return logging.getLogger(SERVICIO)


def configurar_trazas():
    recurso = Resource.create({
        "service.name": SERVICIO,
        "service.version": VERSION,
        "deployment.environment": "produccion",
    })
    proveedor = TracerProvider(resource=recurso)
    proveedor.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True)))
    trace.set_tracer_provider(proveedor)
    # Propaga `traceparent` en todas las llamadas salientes con requests.
    RequestsInstrumentor().instrument()
    return trace.get_tracer(SERVICIO)


def cabeceras_propagadas():
    """Cabeceras W3C TraceContext (traceparent) de la traza activa.

    RequestsInstrumentor ya las inyecta; se hace explicito para que la
    propagacion de contexto sea visible en el codigo.
    """
    cabeceras = {}
    inject(cabeceras)
    return cabeceras


def crear_app(nombre):
    """Crea la app Flask con trazas, metricas y registro de acceso en JSON."""
    log = configurar_registros()
    tracer = configurar_trazas()
    app = Flask(nombre)
    FlaskInstrumentor().instrument_app(app, excluded_urls="metrics,salud")

    @app.before_request
    def _inicio():
        g.inicio = time.perf_counter()
        if request.path not in ("/metrics", "/salud"):
            EN_CURSO.labels(SERVICIO).inc()

    @app.after_request
    def _fin(respuesta):
        if request.path in ("/metrics", "/salud"):
            return respuesta
        EN_CURSO.labels(SERVICIO).dec()
        duracion = time.perf_counter() - g.get("inicio", time.perf_counter())
        ruta = request.url_rule.rule if request.url_rule else "desconocida"
        LATENCIA.labels(SERVICIO, ruta, request.method, str(respuesta.status_code)).observe(duracion)
        nivel = logging.ERROR if respuesta.status_code >= 500 else logging.INFO
        log.log(nivel, "peticion atendida", extra={
            "route": ruta, "method": request.method, "status": respuesta.status_code,
            "duration_ms": round(duracion * 1000, 1),
        })
        return respuesta

    @app.get("/metrics")
    def _metricas():
        return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

    @app.get("/salud")
    def _salud():
        return {"estado": "ok", "servicio": SERVICIO, "version": VERSION}

    return app, log, tracer


def porcentaje_env(nombre):
    try:
        return float(os.environ.get(nombre, "0"))
    except ValueError:
        return 0.0


def latencia_extra():
    ms = porcentaje_env("LATENCIA_EXTRA_MS")
    if ms > 0:
        time.sleep(ms / 1000.0)
