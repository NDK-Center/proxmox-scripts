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
STORAGE="local-lvm"
SNIPPET_STORAGE="local"
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

# 📥 Descargar imagen si no está
if [ ! -f "$IMAGE_FILE" ]; then
  echo "📥 Descargando imagen Ubuntu..."
  wget -q --show-progress "$IMAGE_URL"
fi

# 📂 Detectar tipo de storage
STORAGE_TYPE=$(pvesm status -storage $STORAGE | awk 'NR>1 {print $2}')

# 🔄 Convertir imagen si es lvmthin
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

# 📄 Crear cloud-init personalizado
mkdir -p "$CI_DIR"
TEMP_YAML=$(mktemp)
cat > "$TEMP_YAML" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: true
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
  - apt-get update
  - apt-get install -y curl gnupg lsb-release nginx
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable docker
  - systemctl start docker
EOF

pvesm set ${SNIPPET_STORAGE} --content snippets 2>/dev/null || true
cp "$TEMP_YAML" "$CI_DIR/$(basename "$USER_DATA_FILE")"

rm -f "$TEMP_YAML"

# 🧱 Crear la VM (primero se crea antes del importdisk)
qm create "$VMID" \
  --name "$USERNAME" \
  --memory $RAM_SIZE \
  --cores $CORE_COUNT \
  --net0 virtio,bridge=$BRIDGE \
  --scsihw virtio-scsi-pci \
  --serial0 socket \
  --boot order=scsi0 \
  --ostype l26 \
  --agent enabled=1

# 💾 Importar disco y obtener nombre real asignado
qm importdisk "$VMID" "$IMPORT_IMAGE" $STORAGE -format $DISK_FORMAT >/dev/null

REAL_DISK=$(pvesm list $STORAGE | grep "vm-${VMID}-disk" | awk '{print $1}' | head -n1)

# 🔧 Conectar disco y cloud-init
qm set "$VMID" \
  --efidisk0 "${REAL_DISK}",efitype=4m \
  --scsi0 "${REAL_DISK}",size=$DISK_SIZE \
  --ide2 ${STORAGE}:cloudinit \
  --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$USER_DATA_FILE")"


# 🚀 Iniciar VM
qm start "$VMID"

echo -e "\n✅ VM $VMID creada y encendida"
echo "👤 Usuario: $USERNAME"
echo "🔐 Contraseña: $PASSWORD"
echo "🐳 Docker y Nginx listos tras primer arranque"
