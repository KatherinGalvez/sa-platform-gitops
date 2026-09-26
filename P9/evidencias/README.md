# Evidencias

Los scripts escriben aquí sus registros con marcas de tiempo (`[AAAA-MM-DD HH:MM:SS CST]` y `MARCA <evento> epoch=`):

| Archivo | Lo genera |
|---|---|
| `00-preparacion.log`, `01-llave-sealed-secrets.log`, `02-configurar-gitops.log` | Preparación única |
| `bootstrap-<fecha>.log` | `scripts/bootstrap.sh` |
| `dr-<fecha>.log`, `resumen-dr-<fecha>.md`, `huella-antes/despues-<fecha>.txt` | `scripts/prueba-dr.sh` |
| `restauracion-datos-<fecha>.log`, `resumen-restauracion-<fecha>.md` | `scripts/prueba-restauracion-datos.sh` |
| `perdida-nodo-<fecha>.log`, `sonda-<fecha>.log` | `scripts/prueba-perdida-nodo.sh` |

Guarde las capturas en `capturas/` con el nombre indicado en [`docs/GUIA-NUBE.md`](../docs/GUIA-NUBE.md) (C01 … C24).
