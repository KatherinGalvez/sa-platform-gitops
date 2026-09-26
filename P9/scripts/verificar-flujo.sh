#!/usr/bin/env bash
# Demuestra que el flujo "de la Practica 8" sigue operando (tambien despues
# de la reconstruccion): GitOps, entrega progresiva y politicas de admision.
#   ./verificar-flujo.sh
source "$(dirname "$0")/lib.sh"
LOG="$EVIDENCIAS/flujo-$(date +%Y%m%d-%H%M%S).log"
credenciales_cluster

seccion "1. GitOps: aplicaciones de ArgoCD"
correr kubectl -n argocd get applications

seccion "2. Entrega progresiva: Rollout canary"
kubectl argo rollouts get rollout servicio-datos -n datos 2>&1 | tee -a "$LOG" \
  || correr kubectl -n datos get rollout servicio-datos

seccion "3. Politicas de admision (Kyverno, modo Enforce)"
correr kubectl get clusterpolicy
log "Prueba: un pod con imagen ':latest' en el namespace datos debe ser RECHAZADO"
if kubectl -n datos run prueba-politica --image=nginx:latest --labels=app=prueba \
     --overrides='{"spec":{"containers":[{"name":"prueba-politica","image":"nginx:latest","resources":{"requests":{"memory":"16Mi"},"limits":{"memory":"32Mi"}}}]}}' \
     --dry-run=server -o name 2>&1 | tee -a "$LOG"; then
  log "RESULTADO: ATENCION, el pod fue aceptado (la politica no esta activa)"
else
  log "RESULTADO: rechazado por la politica, como se esperaba"
fi
log "Prueba: un pod correcto (version fija, limites y etiqueta app) debe ser ACEPTADO"
kubectl -n datos run prueba-ok --image=nginx:1.27 --labels=app=prueba \
  --overrides='{"spec":{"containers":[{"name":"prueba-ok","image":"nginx:1.27","resources":{"requests":{"memory":"16Mi"},"limits":{"memory":"32Mi"}}}]}}' \
  --dry-run=server -o name 2>&1 | tee -a "$LOG"
