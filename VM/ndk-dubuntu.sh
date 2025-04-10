#!/usr/bin/env bash
set -e

# 👉 Datos del usuario
USERNAME=$(whiptail --inputbox "Nombre de la VM (y del usuario dentro de Ubuntu):" 10 60 --title "Nombre" 3>&1 1>&2 2>&3) || exit
if [[ -z "$USERNAME" ]]; then
  echo "❌ El nombre no puede estar vacío."
  exit 1
fi

# 👉 Parámetros base
VMID=$(pvesh get /cluster/nextid)
STORAGE="local-lvm"   # Cambia a "local" si usas almacenamiento tipo 'dir'
DISK_SIZE="32G"
RAM_SIZE="8192"
CORE_COUNT="1"
HOSTNAME="ndk"
PASSWORD="NDK25"
BRIDGE="vmbr0"
ARCH="amd64"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ARCH}.img"
IMAGE_FILE=$(basename "$IMAGE_URL")
CI_DIR="/var/lib/vz/snippets"
USER_DATA_FILE="${CI_DIR}/vm-${VMID}-user-data.yml"

# 👉 Descargar imagen si no está
if [ ! -f "$IMAGE_FILE" ]; then
  echo "📥 Descargando imagen Ubuntu..."
  wget -q --show-progress "$IMAGE_URL"
fi

# 👉 Detectar tipo de storage
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')

# 👉 Convertir imagen a RAW si storage es lvmthin
if [[ "$STORAGE_TYPE" == "lvmthin" ]]; then
  echo "🔄 Convirtiendo imagen a RAW para LVM-Thin..."
  RAW_IMAGE="ubuntu-${VMID}.raw"
  qemu-img convert -f qcow2 -O raw "$IMAGE_FILE" "$RAW_IMAGE"
  IMPORT_IMAGE="$RAW_IMAGE"
  DISK_FORMAT="raw"
else
  IMPORT_IMAGE="$IMAGE_FILE"
  DISK_FORMAT="qcow2"
fi

# 👉 Asignar disco
DISK_NAME="vm-${VMID}-disk-0"
pvesm alloc $STORAGE $VMID $DISK_NAME 4M >/dev/null
qm importdisk $VMID "$IMPORT_IMAGE" $STORAGE -format $DISK_FORMAT >/dev/null

# 👉 Cloud-init personalizado
mkdir -p "$CI_DIR"
cat > "$USER_DATA_FILE" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
users:
  - name: $USERNAME
    groups: sudo,docker
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: '$PASSWORD'
    ssh_pwauth: true

package_update: true
package_upgrade: true
packages:
  - ca-certificates
  - curl
  - gnupg
  - lsb-release
  - nginx

runcmd:
  - mkdir -p /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  - echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  - systemctl enable docker
  - systemctl start docker
EOF

# 👉 Crear VM
qm create $VMID \
  --name "$HOSTNAME" \
  --memory $RAM_SIZE \
  --cores $CORE_COUNT \
  --net0 virtio,bridge=$BRIDGE \
  --scsihw virtio-scsi-pci \
  --serial0 socket \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1

# 👉 Añadir disco y cloud-init
qm set $VMID \
  --efidisk0 ${STORAGE}:${DISK_NAME},efitype=4m \
  --scsi0 ${STORAGE}:${DISK_NAME},size=$DISK_SIZE \
  --ide2 ${STORAGE}:cloudinit \
  --cicustom "user=${USER_DATA_FILE}"

# 👉 Arrancar VM
qm start $VMID

echo -e "\n✅ VM $VMID creada y encendida"
echo "👤 Usuario: $USERNAME"
echo "🔐 Contraseña: $PASSWORD"
echo "🐳 Docker y Nginx listos tras primer arranque"
