#!/bin/bash
# Script para crear una VM Ubuntu 24.04 con cloud-init, Docker y Nginx en Proxmox VE 8.x usando snippets
set -e

# Verificación de permisos
if [ "$EUID" -ne 0 ]; then
  echo "❌ Este script debe ejecutarse como root."
  exit 1
fi

# Verificación de dependencias
NEEDED_PKGS=""
command -v whiptail >/dev/null 2>&1 || NEEDED_PKGS+=" whiptail"
command -v wget >/dev/null 2>&1 || NEEDED_PKGS+=" wget"
command -v qemu-img >/dev/null 2>&1 || NEEDED_PKGS+=" qemu-utils"
if [ -n "$NEEDED_PKGS" ]; then
  echo "Instalando dependencias necesarias: $NEEDED_PKGS..."
  apt update -y && apt install -y $NEEDED_PKGS
fi

# Solicitar nombre de usuario
USERNAME=$(whiptail --inputbox "Nombre de usuario (y nombre de la VM):" 8 60 --title "Crear VM Ubuntu 24.04" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && echo "❌ Operación cancelada." && exit 1
USERNAME=$(echo "$USERNAME" | xargs)
[[ -z "$USERNAME" || ! "$USERNAME" =~ ^[a-z][-a-z0-9]*$ ]] && echo "❌ Nombre inválido." && exit 1

# Solicitar contraseña
PASSWORD=$(whiptail --passwordbox "Contraseña para $USERNAME:" 8 60 --title "Contraseña" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && echo "❌ Operación cancelada." && exit 1
PASSWORD=$(echo "$PASSWORD" | xargs)
[ -z "$PASSWORD" ] && echo "❌ Contraseña vacía." && exit 1

# Parámetros base
VMID=$(pvesh get /cluster/nextid)
VMNAME="$USERNAME"
DISK_SIZE="32G"
RAM="4096"
CORES="2"
BRIDGE="vmbr0"
DISK_STORAGE=$(pvesm status | grep -qw "local-lvm" && echo "local-lvm" || echo "local")
SNIPPET_STORAGE="local" # Debe tener habilitado el tipo "snippets"
CI_DIR="/var/lib/vz/snippets"
mkdir -p "$CI_DIR"
USER_DATA_FILE="$CI_DIR/vm-${VMID}-user-data.yaml"
IMAGE_NAME="ubuntu-24.04-server-cloudimg-amd64.img"
IMAGE_URL="http://cloud-images.ubuntu.com/releases/24.04/release/$IMAGE_NAME"

CACHED_IMAGE="/var/lib/vz/template/cache/$IMAGE_NAME"
if [ ! -f "$CACHED_IMAGE" ]; then
  echo "Descargando imagen de Ubuntu 24.04 (solo una vez)..."
  wget -q --show-progress -O "$CACHED_IMAGE" "$IMAGE_URL"
fi

TMP_IMAGE="$CACHED_IMAGE"

# Crear VM base
qm create "$VMID" --name "$VMNAME" --memory "$RAM" --cores "$CORES" --net0 virtio,bridge=$BRIDGE --agent enabled=1

# Configurar UEFI y disco EFI
qm set "$VMID" --bios ovmf
qm set "$VMID" --efidisk0 ${DISK_STORAGE}:0,format=raw,efitype=4m

# Convertir imagen si LVM-thin
STORAGE_TYPE=$(pvesm status -storage "$DISK_STORAGE" | awk 'NR>1 {print $2}')
RAW_IMAGE=""
if [[ "$STORAGE_TYPE" == "lvmthin" ]]; then
  echo "Convirtiendo a RAW para LVM-thin..."
  RAW_IMAGE="/tmp/ubuntu-24.04-${VMID}.raw"
  qemu-img convert -f qcow2 -O raw "$TMP_IMAGE" "$RAW_IMAGE"
  IMAGE_TO_IMPORT="$RAW_IMAGE"
else
  IMAGE_TO_IMPORT="$TMP_IMAGE"
fi

# Importar disco y conectarlo
qm importdisk "$VMID" "$IMAGE_TO_IMPORT" "$DISK_STORAGE" >/dev/null
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 ${DISK_STORAGE}:vm-${VMID}-disk-0,size=$DISK_SIZE

# Configurar orden de booteo
qm set "$VMID" --boot order=scsi0 --bootdisk scsi0

# Crear archivo de cloud-init personalizado (user-data)
cat > "$USER_DATA_FILE" <<EOF
#cloud-config
hostname: $VMNAME
manage_etc_hosts: true
users:
  - name: $USERNAME
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_pwauth: true
chpasswd:
  list: |
    $USERNAME:$PASSWORD
  expire: False
package_update: true
packages:
  - nginx
runcmd:
  - curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  - sh /tmp/get-docker.sh
  - usermod -aG docker $USERNAME
  - systemctl enable --now docker
EOF

# Asegurar que el almacenamiento permite 'snippets'
pvesm set "$SNIPPET_STORAGE" --content snippets,iso,vztmpl,backup 2>/dev/null || true

# Adjuntar disco cloud-init
qm set "$VMID" --ide2 ${DISK_STORAGE}:cloudinit
qm set "$VMID" --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$USER_DATA_FILE")"

# Limpiar
[ -n "$RAW_IMAGE" ] && rm -f "$RAW_IMAGE"

# Iniciar VM
qm start "$VMID"

# Mostrar resumen
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ VM creada exitosamente"
echo " VMID:      $VMID"
echo " Usuario:   $USERNAME"
echo " Contraseña: $PASSWORD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
