#!/usr/bin/env bash
# Demuestra la continuidad de los secretos: la llave activa en el cluster es la
# MISMA que esta en Secret Manager y los SealedSecrets del repositorio se descifran.
source "$(dirname "$0")/lib.sh"
credenciales_cluster

fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }

echo "== Huella SHA-256 del certificado de Sealed Secrets =="
SM=$(gcloud secrets versions access latest --secret p9-sealed-secrets-crt --project "$PROYECTO" | fp)
echo "Secret Manager (fuera del cluster):  $SM"

N=$(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o name | wc -l)
K8S=$(kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key \
      -o jsonpath='{.items[0].data.tls\.crt}' | base64 -d | fp)
echo "Llave en el cluster:                 $K8S   (llaves en el cluster: $N)"

CTRL=$(kubeseal --fetch-cert --controller-name sealed-secrets-controller --controller-namespace kube-system 2>/dev/null | fp || echo "no disponible")
echo "Certificado que sirve el controlador: $CTRL"

if [[ "$SM" == "$K8S" && "$N" == "1" ]]; then
  echo "RESULTADO: la llave restaurada es la original (no se genero una nueva)."
else
  echo "RESULTADO: ATENCION, las huellas no coinciden o hay mas de una llave."
fi

echo
echo "== SealedSecrets y su estado =="
kubectl get sealedsecrets -A -o custom-columns='NAMESPACE:.metadata.namespace,NOMBRE:.metadata.name,SINCRONIZADO:.status.conditions[0].status,MENSAJE:.status.conditions[0].message'
echo
echo "== Secret descifrado por el controlador (solo claves, sin valores) =="
kubectl -n datos get secret db-credenciales -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'
echo
echo "== Uso real del secreto: la API se conecta a la BD con la contrasena descifrada =="
kubectl -n datos get pods -l app=servicio-datos -o custom-columns='POD:.metadata.name,LISTO:.status.containerStatuses[0].ready'
