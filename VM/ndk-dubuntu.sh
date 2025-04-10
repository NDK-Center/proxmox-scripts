#!/usr/bin/env bash
set -e

# 👤 Solicitar nombre de usuario y contenedor
USERNAME=$(whiptail --inputbox "Nombre de la VM (y usuario):" 10 60 --title "Nombre" 3>&1 1>&2 2>&3) || exit
if [[ -z "$USERNAME" ]]; then
  echo "❌ El nombre no puede estar vacío."
  exit 1
fi

VMID=$(pvesh get /cluster/nextid)
STORAGE="local-lvm"
DISK_SIZE="32G"
RAM_SIZE="8192"
CORE_COUNT="1"
HOSTNAME="ndk"
PASSWORD="NDK25"
BRIDGE="vmbr0"
ARCH="amd64"
IMAGE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-${ARCH}.img"
IMAGE_FILE=$(basename "$IMAGE_URL")

# 📥 Descargar imagen si no existe
if [ ! -f "$IMAGE_FILE" ]; then
  echo "➡️ Descargando imagen de Ubuntu..."
  wget -q --show-progress "$IMAGE_URL"
fi

# 💾 Preparar disco
DISK_IMAGE="vm-${VMID}-disk-0.qcow2"
pvesm alloc $STORAGE $VMID $DISK_IMAGE 4M >/dev/null
qm importdisk $VMID "$IMAGE_FILE" $STORAGE -format qcow2 >/dev/null

# 📄 Crear cloud-init personalizado
CI_DIR="/var/lib/vz/snippets"
mkdir -p "$CI_DIR"
USER_DATA_FILE="${CI_DIR}/vm-${VMID}-user-data.yml"

cat > "$USER_DATA_FILE" <<EOF
#cloud-config
hostname: $HOSTNAME
manage_etc_hosts: true
users:
  - name: $USERNAME
    gecos: Ubuntu User
    groups: sudo,docker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
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

# 🖥️ Crear la VM
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

# 📦 Añadir disco y cloud-init personalizado
qm set $VMID \
  --efidisk0 ${STORAGE}:${DISK_IMAGE},efitype=4m \
  --scsi0 ${STORAGE}:${DISK_IMAGE},size=${DISK_SIZE} \
  --ide2 ${STORAGE}:cloudinit \
  --cicustom "user=${USER_DATA_FILE}"

# 🚀 Iniciar la VM
qm start $VMID

echo -e "\n✅ VM $VMID creada"
echo "👤 Usuario: $USERNAME"
echo "🔐 Contraseña: $PASSWORD"
echo "🐳 Docker y nginx instalados al arranque"
