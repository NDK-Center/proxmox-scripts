#!/bin/bash
# Script para crear una VM Ubuntu 24.04 con cloud-init, Docker y Nginx en Proxmox VE 8.x
set -e

# 🔐 Verificación de permisos
if [ "$EUID" -ne 0 ]; then
  echo "❌ Este script debe ejecutarse como root."
  exit 1
fi

# 🧰 Verificación de dependencias
NEEDED_PKGS=""
command -v whiptail >/dev/null 2>&1 || NEEDED_PKGS+=" whiptail"
command -v genisoimage >/dev/null 2>&1 || command -v mkisofs >/dev/null 2>&1 || NEEDED_PKGS+=" genisoimage"
command -v wget >/dev/null 2>&1 || NEEDED_PKGS+=" wget"
if [ -n "$NEEDED_PKGS" ]; then
  echo "Instalando dependencias necesarias: $NEEDED_PKGS..."
  apt update -y && apt install -y $NEEDED_PKGS
fi

# 👤 Solicitar nombre de usuario
USERNAME=$(whiptail --inputbox "Nombre de usuario (y nombre de la VM):" 8 60 --title "Crear VM Ubuntu 24.04" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && echo "❌ Operación cancelada." && exit 1
USERNAME=$(echo "$USERNAME" | xargs)
[[ -z "$USERNAME" || ! "$USERNAME" =~ ^[a-z][-a-z0-9]*$ ]] && echo "❌ Nombre inválido." && exit 1

# 🔐 Contraseña
PASSWORD=$(whiptail --passwordbox "Contraseña para $USERNAME:" 8 60 --title "Contraseña" 3>&1 1>&2 2>&3)
[ $? -ne 0 ] && echo "❌ Operación cancelada." && exit 1
PASSWORD=$(echo "$PASSWORD" | xargs)
[ -z "$PASSWORD" ] && echo "❌ Contraseña vacía." && exit 1

# ⚙️ Parámetros
VMID=$(pvesh get /cluster/nextid)
VMNAME="$USERNAME"
DISK_SIZE="32G"
RAM="4096"
CORES="2"
BRIDGE="vmbr0"
ISO_STORAGE="local"
DISK_STORAGE=$(pvesm status | grep -qw "local-lvm" && echo "local-lvm" || echo "local")
IMAGE_URL="http://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
TMP_IMAGE="/tmp/ubuntu-24.04-cloudimg-${VMID}.img"

echo "✅ VMID asignado: $VMID"
echo "📦 Almacenamiento disco: $DISK_STORAGE"

# 📥 Descargar imagen
echo "Descargando imagen de Ubuntu 24.04..."
wget -q --show-progress -O "$TMP_IMAGE" "$IMAGE_URL" || { echo "❌ Error descargando imagen"; exit 1; }

# 🔧 Crear VM
echo "Creando VM..."
qm create "$VMID" --name "$VMNAME" --memory "$RAM" --cores "$CORES" --net0 virtio,bridge=$BRIDGE

# 🧠 BIOS y EFI
echo "Configurando BIOS UEFI..."
qm set "$VMID" --bios ovmf
qm set "$VMID" --efidisk0 ${DISK_STORAGE}:0,format=raw

# 📂 Tipo de almacenamiento
STORAGE_TYPE=$(pvesm status -storage "$DISK_STORAGE" | awk 'NR>1 {print $2}')
RAW_IMAGE=""
if [[ "$STORAGE_TYPE" == "lvmthin" ]]; then
  echo "Convirtiendo imagen a RAW para LVM-thin..."
  RAW_IMAGE="/tmp/ubuntu-24.04-${VMID}.raw"
  qemu-img convert -f qcow2 -O raw "$TMP_IMAGE" "$RAW_IMAGE"
  IMAGE_TO_IMPORT="$RAW_IMAGE"
else
  IMAGE_TO_IMPORT="$TMP_IMAGE"
fi

# 💽 Importar disco
echo "Importando disco al almacenamiento..."
qm importdisk "$VMID" "$IMAGE_TO_IMPORT" "$DISK_STORAGE" >/dev/null

# 🔗 Conectar disco
echo "Conectando disco como scsi0..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 ${DISK_STORAGE}:vm-${VMID}-disk-0,size=$DISK_SIZE

# 🚀 Configurar boot
qm set "$VMID" --boot order=scsi0 --bootdisk scsi0

# 🌩️ Crear archivos cloud-init
echo "Generando archivos de cloud-init..."
CIDATA_DIR=$(mktemp -d)
cat > "$CIDATA_DIR/meta-data" <<EOF
instance-id: iid-${VMID}-${USERNAME}
local-hostname: $VMNAME
EOF

cat > "$CIDATA_DIR/user-data" <<EOF
#cloud-config
hostname: $VMNAME
manage_etc_hosts: true
users:
  - default
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

cat > "$CIDATA_DIR/network-config" <<EOF
version: 2
ethernets:
  net0:
    match:
      name: "e*"
    dhcp4: true
EOF

# 💿 Crear ISO de cloud-init
CIDATA_ISO="/var/lib/vz/template/iso/${VMID}-${VMNAME}-cidata.iso"
GENISO_CMD=$(command -v genisoimage || command -v mkisofs)
$GENISO_CMD -output "$CIDATA_ISO" -volid cidata -joliet -rock \
  "$CIDATA_DIR/user-data" "$CIDATA_DIR/meta-data" "$CIDATA_DIR/network-config" >/dev/null
echo "✅ ISO de cloud-init creada: $CIDATA_ISO"

# 🔗 Adjuntar ISO a la VM
echo "Adjuntando ISO a la VM..."
qm set "$VMID" --ide2 ${ISO_STORAGE}:iso/$(basename "$CIDATA_ISO"),media=cdrom

# 🧹 Limpieza
rm -f "$TMP_IMAGE"
[ -n "$RAW_IMAGE" ] && rm -f "$RAW_IMAGE"
rm -rf "$CIDATA_DIR"

# 🔥 Iniciar VM
echo "Iniciando VM..."
qm start "$VMID"

# ✅ Final
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " ✅ VM creada exitosamente"
echo " VMID:      $VMID"
echo " Usuario:   $USERNAME"
echo " Contraseña: $PASSWORD"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
