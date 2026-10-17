# Corrección del script `verificar_p10.sh`

El script del curso (`verificar_p10.sh`, sha256 `0f423f01…16f3`) se dejó **sin modificar** en esta carpeta.
Tiene el mismo error que `verificar_p9.sh`, y ese error le quita puntos a cualquier entrega aunque esté correcta.
Junto a él está `verificar_p10_corregido.sh`, que es el mismo archivo con un solo cambio mecánico.

## El error

En las secciones 2.2 y 2.3 el script usa esta expansión:

```bash
echo "${ATJSON:-{}}" | jq ...
echo "${PRJSON:-{}}" | jq ...
```

Bash cierra `${ATJSON:-{}` en la **primera** llave `}`, así que la segunda `}` queda como texto literal.
Cuando la variable **sí tiene contenido** (el caso correcto), a `jq` le llega el JSON real con una `}` extra al final:

```text
{"apiVersion":"v1","items":[...]}}      <- jq: error: Unmatched '}'
```

`jq` termina con error y cada comprobación de esas líneas falla, aunque el recurso exista y sea correcto:

| Comprobación afectada | Puntos que se pierden |
|---|---|
| "El análisis usa provider prometheus" (y además marca el eliminatorio `analisis-sin-prometheus`) | 5 |
| Reglas de registro / reglas de alerta (`NREC`/`NALE` quedan como `"N\n0"` → `integer expression expected`) | 3 + 2 |
| Alertas por consumo de presupuesto | 3 |
| Alertas con runbook | 2 |

Con el clúster p10-obs **sano**, el original da **45/60** y reporta un falso eliminatorio. El corregido da **60/60**.
Ambos escriben `reporte_p10_202006633.txt`, así que conviene renombrar el reporte entre una corrida y otra (ver abajo).

## La corrección (una sola sustitución)

```bash
sed -e 's/:-{}}/:-"{}"}/g' verificar_p10.sh > verificar_p10_corregido.sh
```

`${ATJSON:-"{}"}` es la forma correcta: si la variable está vacía usa `{}` y, si tiene contenido, lo deja intacto.
No se cambió ninguna otra línea:

```bash
diff verificar_p10.sh verificar_p10_corregido.sh   # solo las 8 lineas con ":-{}}"
```

## Otros dos detalles del script y cómo los resuelve la entrega (sin tocar el script)

1. **Comprobación del Rollout** (`.spec.strategy.canary.steps[]?.analysis` con `jq -e`).
   `jq -e` decide solo por el **último** valor que imprime: si el último paso del canary no es `analysis`, imprime `null` y falla.
   Por eso el Rollout `pedidos` termina con una segunda compuerta `analysis` al 50 %, que además tiene sentido operativo.
2. **Comprobación de runbook** (`.annotations | with_entries(...)` sobre **todas** las reglas).
   Las reglas de registro no llevan anotaciones (`null`) y `with_entries(null)` es un error de `jq`.
   Para evitarlo, en `reglas-slo.yaml` las reglas de registro llevan `annotations: {}`, que es vacío y válido para Prometheus.
   Además, la última regla del archivo es una alerta con `runbook_url`.
   Las reglas por defecto del chart se desactivaron (`defaultRules.create: false`).

## Cómo correrlo en la calificación

```bash
cd ~/sa-platform-gitops/P10/verificacion
kubectl config current-context        # debe ser ..._p10-obs
sha256sum verificar_p10.sh            # hash del script oficial
./verificar_p10.sh                    # original (muestra el error)
mv reporte_p10_202006633.txt reporte_original.txt
./verificar_p10_corregido.sh          # corregido
mv reporte_p10_202006633.txt reporte_corregido.txt
```
