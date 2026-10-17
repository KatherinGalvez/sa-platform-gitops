#!/usr/bin/env bash
# Abre las consolas en Cloud Shell (Vista previa web -> Cambiar puerto):
#   8080 Grafana | 8081 ArgoCD | 8082 Prometheus | 8083 Argo Rollouts | 8084 Alertmanager
# Deje esta terminal abierta; Ctrl+C cierra todo.
source "$(dirname "$0")/lib.sh"
credenciales
echo "Grafana     -> puerto 8080  usuario: admin  clave: $(kubectl -n observabilidad get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
echo "ArgoCD      -> puerto 8081  usuario: admin  clave: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
echo "Prometheus  -> puerto 8082  (Alerts, Rules, Graph)"
echo "Rollouts    -> puerto 8083  (namespace produccion)"
echo "Alertmanager-> puerto 8084"
kubectl -n observabilidad port-forward svc/kps-grafana 8080:80 >/dev/null 2>&1 &
kubectl -n argocd port-forward svc/argocd-server 8081:80 >/dev/null 2>&1 &
kubectl -n observabilidad port-forward svc/prometheus-operated 8082:9090 >/dev/null 2>&1 &
kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 8083:3100 >/dev/null 2>&1 &
kubectl -n observabilidad port-forward svc/alertmanager-operated 8084:9093 >/dev/null 2>&1 &
echo "Reenvios activos. Ctrl+C para cerrar."
trap 'kill $(jobs -p) 2>/dev/null' EXIT INT
wait
