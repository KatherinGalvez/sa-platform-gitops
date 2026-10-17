#!/usr/bin/env bash
# Elimina TODO lo de la Practica 10 (cluster p10-obs e imagenes) para que no
# genere costos. No toca el cluster p9-dr.
#   ./P10/scripts/destruir.sh
source "$(dirname "$0")/lib.sh"
gcloud config set project "$PROYECTO" >/dev/null
read -r -p "Se eliminara el cluster $CLUSTER y el repositorio de imagenes $REPOSITORIO_IMAGENES. Escriba SI: " R
[[ "$R" == "SI" ]] || { echo "Cancelado"; exit 1; }
gcloud container clusters delete "$CLUSTER" --zone "$ZONA" --quiet --async
gcloud artifacts repositories delete "$REPOSITORIO_IMAGENES" --location "$REGION" --quiet || true
echo "Eliminacion del cluster en curso (5-10 min). Revise:"
echo "  gcloud container clusters list"
echo "  gcloud compute disks list   # no deben quedar discos de p10-obs"
