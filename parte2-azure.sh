#!/usr/bin/env bash
# Parte 2 - Escalabilidad horizontal (Azure for Students, Brazil South)
#
# Uso (en Azure Cloud Shell - Bash):
#   bash parte2-azure.sh          crea toda la infraestructura y corre las pruebas de newman
#   bash parte2-azure.sh borrar   elimina el grupo de recursos para no gastar créditos
#
# Se puede volver a ejecutar sin problema: las VMs que ya existen se omiten.
set -uo pipefail

RG=SCALABILITY_LAB_HORIZONTAL
LOC=brazilsouth
IMAGE=Canonical:ubuntu-24_04-lts:server:latest
ADMIN=scalability_lab
VNET=SCALABILITY_LAB_VIRTUAL_NETWORK
SUBNET=SCALABILITY_LAB_SUBNET
NSG=SCALABILITY_LAB_NSG
LB=SCALABILITY_LAB_LOAD_BALANCER
LBIP=SCALABILITY_LAB_LOAD_BALANCER_IP
FE=LoadBalancerFrontEnd
POOL=SCALABILITY_LAB_BACKEND_POOL
PROBE=SCALABILITY_LAB_HEALTH_PROBE
RULE=SCALABILITY_LAB_LOAD_BALANCING_RULE
REPO=https://github.com/SebasAuM/ARSW_LOAD-BALANCING_AZURE_LAB9_VEGA-AURELA.git
OUT=~/parte2-resultados

# Tamaños preferidos, en orden. Si ninguno está disponible se prueba cualquier
# otro tamaño x64 de 1-2 vCPU que la suscripción pueda usar en las 3 zonas.
PREFERIDOS=(
  Standard_B1s Standard_B1ms Standard_B2ats_v2 Standard_B2als_v2 Standard_B2s
  Standard_D2as_v5 Standard_D2s_v5 Standard_D2as_v6 Standard_D2ads_v6
  Standard_D2s_v3 Standard_F2s_v2 Standard_F2as_v6
)
MAX_PLANES=15

log()  { printf '\n\033[1;36m>> %s\033[0m\n' "$*"; }
ok()   { printf '   \033[32m✔ %s\033[0m\n' "$*"; }
warn() { printf '   \033[33m✘ %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*"; exit 1; }

if [[ "${1:-}" == "borrar" ]]; then
  az group delete -n $RG --yes --no-wait && echo "Borrando $RG en segundo plano."
  exit 0
fi

az account show -o none 2>/dev/null || die "No hay sesión de Azure. Ejecuta: az login"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
log "Consultando tamaños de VM en $LOC (una sola consulta, 30-90 segundos)"

# Columnas: nombre, vCPUs, arquitectura, generaciones, admite Spot, nº de zonas, restricciones
SKUS="$OUT/skus.tsv"
if [[ ! -s "$SKUS" ]]; then
  az vm list-skus -l $LOC --resource-type virtualMachines --all \
    --query "[].[name, capabilities[?name=='vCPUs'].value | [0], capabilities[?name=='CpuArchitectureType'].value | [0], capabilities[?name=='HyperVGenerations'].value | [0], capabilities[?name=='LowPriorityCapable'].value | [0], length(locationInfo[0].zones || \`[]\`), join(',', restrictions[].reasonCode || \`[]\`)]" \
    -o tsv > "$SKUS" || die "No se pudo consultar el catálogo de tamaños"
fi

declare -A VCPUS SPOT MOTIVO
while IFS=$'\t' read -r name vcpu arch gens lowprio zonas restr; do
  if [[ -n "$restr" ]]; then MOTIVO[$name]=$restr; continue; fi
  if [[ "$arch" != x64 || "$gens" != *V2* || ! "$vcpu" =~ ^[0-9]+$ ]] || (( vcpu > 2 || zonas < 3 )); then
    MOTIVO[$name]="no sirve para el lab (arq=$arch, zonas=$zonas, vCPU=$vcpu)"
    continue
  fi
  VCPUS[$name]=$vcpu
  SPOT[$name]=$lowprio
done < "$SKUS"

# Plan = "tamaño prioridad vCPUs": primero los preferidos, luego el resto por vCPUs
DISPONIBLES=()
declare -A AGREGADO
agregar_plan() {
  local s=$1
  [[ -v VCPUS[$s] && ! -v AGREGADO[$s] ]] || return 0
  AGREGADO[$s]=1
  DISPONIBLES+=("$s Regular ${VCPUS[$s]}")
  [[ "${SPOT[$s]}" == True ]] && DISPONIBLES+=("$s Spot ${VCPUS[$s]}")
}
for s in "${PREFERIDOS[@]}"; do
  if [[ -v VCPUS[$s] ]]; then
    ok "$s disponible (${VCPUS[$s]} vCPU, Spot: ${SPOT[$s]})"
  else
    warn "$s: ${MOTIVO[$s]:-no existe en $LOC}"
  fi
  agregar_plan "$s"
done
for s in $(for n in "${!VCPUS[@]}"; do echo "${VCPUS[$n]} $n"; done | sort -n | awk '{print $2}'); do
  agregar_plan "$s"
done
DISPONIBLES=("${DISPONIBLES[@]:0:$MAX_PLANES}")

(( ${#DISPONIBLES[@]} )) || die "Ningún tamaño x64 de 1-2 vCPU está disponible en las 3 zonas de $LOC. Revisa $SKUS"
echo "   Orden en que se intentará crear cada VM:"
printf '     %s\n' "${DISPONIBLES[@]}"

# vCPUs libres de la cuota: cores (normales) o lowPriorityCores (Spot)
cuota_libre() {
  az vm list-usage -l $LOC --query "[?name.value=='$1'] | [0].[limit, currentValue]" -o tsv \
    | awk '{print $1 - $2}'
}

# ---------------------------------------------------------------------------
log "Creando grupo de recursos, red virtual y NSG"

az group show -n $RG -o none 2>/dev/null || az group create -n $RG -l $LOC -o none
az network vnet create -g $RG -n $VNET -l $LOC \
  --address-prefix 10.1.0.0/16 --subnet-name $SUBNET --subnet-prefix 10.1.0.0/24 -o none
az network nsg create -g $RG -n $NSG -l $LOC -o none
az network nsg rule create -g $RG --nsg-name $NSG -n Allow-SSH --priority 1000 \
  --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 22 -o none
az network nsg rule create -g $RG --nsg-name $NSG -n Allow-3000 --priority 1010 \
  --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 3000 -o none
ok "Red lista"

# ---------------------------------------------------------------------------
log "Creando balanceador de carga (frontend 80 -> backend 3000)"

az network public-ip create -g $RG -n $LBIP -l $LOC --sku Standard \
  --allocation-method Static --zone 1 2 3 -o none
az network lb show -g $RG -n $LB -o none 2>/dev/null || \
  az network lb create -g $RG -n $LB -l $LOC --sku Standard \
    --public-ip-address $LBIP --frontend-ip-name $FE --backend-pool-name $POOL -o none
az network lb probe create -g $RG --lb-name $LB -n $PROBE \
  --protocol Tcp --port 3000 --interval 5 --threshold 2 -o none
az network lb rule create -g $RG --lb-name $LB -n $RULE \
  --protocol Tcp --frontend-port 80 --backend-port 3000 \
  --frontend-ip-name $FE --backend-pool-name $POOL --probe-name $PROBE \
  --idle-timeout 4 -o none
LB_PUBLIC_IP=$(az network public-ip show -g $RG -n $LBIP --query ipAddress -o tsv)
ok "Balanceador listo en $LB_PUBLIC_IP"

# ---------------------------------------------------------------------------
# Instalación automática de la app al arrancar cada VM (Node 22 LTS + systemd)
cat > "$OUT/cloud-init.yaml" <<EOF
#cloud-config
package_update: true
packages:
  - git
write_files:
  - path: /etc/systemd/system/fibonacci.service
    content: |
      [Unit]
      Description=FibonacciApp
      After=network-online.target
      [Service]
      WorkingDirectory=/opt/lab/FibonacciApp
      ExecStart=/usr/bin/node FibonacciApp.js
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  - apt-get install -y nodejs
  - git clone $REPO /opt/lab
  - cd /opt/lab/FibonacciApp && npm install
  - systemctl daemon-reload
  - systemctl enable --now fibonacci
EOF

crear_vm() {
  local nombre=$1 zona=$2
  if az vm show -g $RG -n "$nombre" -o none 2>/dev/null; then
    ok "$nombre ya existe, se omite"
    return 0
  fi

  az network public-ip create -g $RG -n "$nombre-ip" -l $LOC --sku Standard \
    --allocation-method Static --zone 1 2 3 -o none
  az network nic create -g $RG -n "$nombre-nic" -l $LOC \
    --vnet-name $VNET --subnet $SUBNET --network-security-group $NSG \
    --public-ip-address "$nombre-ip" --lb-name $LB --lb-address-pools $POOL -o none

  for p in "${DISPONIBLES[@]}"; do
    read -r size prio vcpu <<<"$p"
    local cuota=cores extra=()
    if [[ $prio == Spot ]]; then
      cuota=lowPriorityCores
      extra=(--priority Spot --eviction-policy Deallocate --max-price -1)
    fi
    local libre
    libre=$(cuota_libre $cuota)
    if (( ${libre:-0} < vcpu )); then
      warn "$size ($prio): sin cuota suficiente (libres: ${libre:-0})"
      continue
    fi

    echo "   Creando $nombre con $size ($prio) en zona $zona..."
    if az vm create -g $RG -n "$nombre" -l $LOC --zone "$zona" \
         --size "$size" --image $IMAGE \
         --admin-username $ADMIN --generate-ssh-keys \
         --nics "$nombre-nic" \
         --os-disk-name "$nombre-osdisk" --os-disk-delete-option Delete \
         --custom-data "$OUT/cloud-init.yaml" \
         "${extra[@]}" -o none; then
      ok "$nombre creada ($size, $prio, zona $zona)"
      return 0
    fi
    warn "$size ($prio) falló, probando el siguiente tamaño"
    az vm delete -g $RG -n "$nombre" --yes -o none 2>/dev/null
    az disk delete -g $RG -n "$nombre-osdisk" --yes -o none 2>/dev/null
  done
  die "No se pudo crear $nombre con ningún tamaño. Revisa la cuota con: az vm list-usage -l $LOC -o table"
}

esperar_app() {
  local ip
  ip=$(az vm show -d -g $RG -n "$1" --query publicIps -o tsv)
  for _ in $(seq 60); do
    if curl -s -m 5 "http://$ip:3000/" | grep -q Hello; then
      ok "$1 ($ip) responde en el puerto 3000"
      return 0
    fi
    sleep 10
  done
  warn "$1 ($ip) no respondió en 10 minutos. Revisa con:"
  echo "     az vm run-command invoke -g $RG -n $1 --command-id RunShellScript --scripts 'tail -n 40 /var/log/cloud-init-output.log'"
  return 1
}

# ---------------------------------------------------------------------------
log "Creando VM1, VM2 y VM3 (una por zona de disponibilidad)"
for i in 1 2 3; do crear_vm "VM$i" "$i"; done

log "Esperando a que cloud-init instale la app (3-5 minutos)"
for i in 1 2 3; do esperar_app "VM$i"; done

log "Probando el balanceador"
curl -s -m 10 "http://$LB_PUBLIC_IP/"; echo
curl -s -m 10 "http://$LB_PUBLIC_IP/fibonacci/6"; echo

# ---------------------------------------------------------------------------
log "Preparando newman"
[[ -d ~/lab-repo ]] || git clone -q $REPO ~/lab-repo
COL=~/lab-repo/FibonacciApp/postman/part2/ARSW_LOAD-BALANCING_AZURE.postman_collection.json
ENV="$OUT/environment.json"
cat > "$ENV" <<EOF
{
  "name": "[ARSW_LOAD-BALANCING_AZURE]",
  "values": [
    { "key": "loadbalancer", "value": "$LB_PUBLIC_IP", "enabled": true },
    { "key": "nth", "value": "1000000", "enabled": true }
  ]
}
EOF
[[ -x ~/newman/node_modules/.bin/newman ]] || npm install --silent --prefix ~/newman newman
NEWMAN=~/newman/node_modules/.bin/newman

correr_newman() {
  local paralelos=$1 etiqueta=$2 pids=()
  for k in $(seq "$paralelos"); do
    "$NEWMAN" run "$COL" -e "$ENV" -n 10 --color off > "$OUT/$etiqueta-run$k.txt" 2>&1 &
    pids+=($!)
  done
  wait "${pids[@]}"
  for k in $(seq "$paralelos"); do
    echo "----- $etiqueta / ejecución $k -----"
    tail -n 22 "$OUT/$etiqueta-run$k.txt"
  done
}

INICIO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log "Prueba 1: 3 VMs, 2 newman en paralelo (punto 2)"
correr_newman 2 "3vms-2paralelo"

# ---------------------------------------------------------------------------
log "Agregando VM4 (zona 1, Brazil South solo tiene 3 zonas)"
crear_vm VM4 1
esperar_app VM4

log "Prueba 2: 4 VMs, 4 newman en paralelo (punto 3)"
correr_newman 4 "4vms-4paralelo"

# ---------------------------------------------------------------------------
log "Esperando 5 minutos a que Azure publique las métricas de CPU"
sleep 300
for i in 1 2 3 4; do
  {
    echo "== VM$i: Percentage CPU (timestamp, promedio, máximo) =="
    az monitor metrics list \
      --resource "$(az vm show -g $RG -n VM$i --query id -o tsv)" \
      --metric "Percentage CPU" --interval PT1M --aggregation Average Maximum \
      --start-time "$INICIO" \
      --query "value[0].timeseries[0].data[].[timeStamp, average, maximum]" -o tsv
  } | tee "$OUT/cpu-VM$i.txt"
done

log "Listo"
echo "   IP del balanceador: http://$LB_PUBLIC_IP/fibonacci/6"
echo "   Resultados de newman y CPU en: $OUT"
az vm list -g $RG -d --query "[].{VM:name, Zona:zones[0], Tamano:hardwareProfile.vmSize, Prioridad:priority, IP:publicIps}" -o table
echo
echo "   Cuando terminen el informe: bash parte2-azure.sh borrar"
