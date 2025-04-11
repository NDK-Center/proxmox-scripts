#!/bin/bash
# Script para crear una VM Ubuntu 24.04 LTS cloud-init en Proxmox VE 8.3.5
# Solicita un nombre de usuario y contraseña, y crea la VM con:
#  - 2 vCPUs, 4GB RAM, disco 32GB en 'local-lvm'
#  - BIOS UEFI (OVMF) con disco EFI
#  - Imagen oficial Ubuntu 24.04 cloud-init
#  - Configuración cloud-init (usuario, contraseña, hostname, red DHCP)
# Al primer arranque, la VM tendrá hostname igual al usuario, permitirá login con las credenciales dadas,
# instalará Docker (get.docker.com) y Nginx automáticamente.

set -e  # Terminar si ocurre algún error

# Verificar ejecución como root en un host Proxmox
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script debe ejecutarse como root." >&2
    exit 1
fi

# Verificar comandos de Proxmox
if ! command -v qm >/dev/null 2>&1 || ! command -v pvesm >/dev/null 2>&1; then
    echo "Comandos de Proxmox VE no encontrados. Ejecute en un host Proxmox 8.3.5." >&2
    exit 1
fi

# Solicitar usuario y contraseña mediante interfaz de texto (whiptail)
USERNAME=$(whiptail --title "Crear VM Ubuntu 24.04 LTS" --inputbox "Ingrese el nombre de usuario (será también el nombre de la VM):" 10 60 3>&1 1>&2 2>&3)
STATUS=$?
if [ $STATUS -ne 0 ] || [ -z "$USERNAME" ]; then
    echo "Proceso cancelado o nombre de usuario inválido." >&2
    exit 1
fi

PASSWORD=$(whiptail --title "Crear VM Ubuntu 24.04 LTS" --passwordbox "Ingrese la contraseña para el usuario $USERNAME:" 10 60 3>&1 1>&2 2>&3)
STATUS=$?
if [ $STATUS -ne 0 ]; then
    echo "Proceso cancelado durante el ingreso de contraseña." >&2
    exit 1
fi

if [ -z "$PASSWORD" ]; then
    whiptail --msgbox "No se ingresó una contraseña. Saliendo." 8 50
    exit 1
fi

VMNAME="$USERNAME"

# Obtener un ID de VM disponible (a partir de 100, por convención)
NEXTID=100
existing_ids=$( (qm list | awk 'NR>1 {print $1}'; pct list 2>/dev/null | awk 'NR>1 {print $1}') )
existing_ids=$(echo "$existing_ids" | tr '\n' ' ')  # combinar IDs existentes en una línea
while echo "$existing_ids" | grep -qw $NEXTID; do
    NEXTID=$((NEXTID+1))
done
VMID=$NEXTID
echo "Usando VMID $VMID para la nueva VM."

# Descargar imagen oficial Ubuntu Server 24.04 LTS cloud-init
IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
IMG_FILE="/tmp/ubuntu-24.04-server-cloudimg-amd64.img"
echo "Descargando imagen base Ubuntu 24.04 LTS..."
if ! wget -q --show-progress -O "$IMG_FILE" "$IMG_URL"; then
    echo "Error al descargar la imagen desde $IMG_URL" >&2
    exit 1
fi

# Determinar formato de disco según tipo de almacenamiento 'local-lvm'
STOR="local-lvm"
STOR_TYPE=$(pvesm status | awk -v S="$STOR" '$1==S {print $2}')
DISK_FORMAT="qcow2"
if [ "$STOR_TYPE" = "lvmthin" ] || [ "$STOR_TYPE" = "lvm" ]; then
    DISK_FORMAT="raw"
    echo "Almacenamiento '$STOR' es tipo LVM; se usará formato RAW para el disco."
else
    echo "Almacenamiento '$STOR' no es LVM; se usará formato QCOW2 para el disco."
fi

# Crear VM con configuración básica
echo "Creando VM $VMID ('$VMNAME')..."
qm create $VMID --name "$VMNAME" --memory 4096 --cores 2 --net0 virtio,bridge=vmbr0 --ostype l26 --bios ovmf

# Agregar disco EFI para BIOS UEFI
echo "Agregando disco EFI..."
qm set $VMID --efidisk0 ${STOR}:1,efitype=4m,format=raw

# Importar disco del sistema desde la imagen descargada
echo "Importando disco del sistema operativo (puede tardar)..."
qm importdisk $VMID "$IMG_FILE" $STOR --format $DISK_FORMAT

# Adjuntar el disco importado al bus SCSI0 de la VM
echo "Adjuntando disco del sistema a VM (SCSI0)..."
qm set $VMID --scsihw virtio-scsi-pci --scsi0 $STOR:vm-$VMID-disk-0

# Agregar unidad de Cloud-Init en bus SCSI1 (evitar IDE para primer arranque correcto)
echo "Creando unidad de Cloud-Init (SCSI1)..."
qm set $VMID --scsi1 $STOR:cloudinit

# Establecer orden de arranque: primero disco SCSI0 (sistema) luego Cloud-Init
qm set $VMID --boot order=scsi0

# Generar archivo de configuración Cloud-Init personalizado
echo "Generando configuración Cloud-Init personalizada..."
CI_CFG="/var/lib/vz/snippets/ci-${VMID}-user.yaml"
mkdir -p /var/lib/vz/snippets
cat > "$CI_CFG" <<EOF
#cloud-config
hostname: $USERNAME
manage_etc_hosts: true
ssh_pwauth: true
users:
  - name: $USERNAME
    groups: sudo
    lock_passwd: false
    shell: /bin/bash
chpasswd:
  list: |
    $USERNAME:$PASSWORD
  expire: False
package_update: true
packages:
  - nginx
runcmd:
  - [ "sh", "-c", "curl -fsSL https://get.docker.com | sh" ]
EOF

# Aplicar configuración Cloud-Init (usuario/hostname personalizado, red DHCP)
qm set $VMID --cicustom "user=local:snippets/ci-${VMID}-user.yaml" --ipconfig0 ip=dhcp

# Regenerar disco de Cloud-Init con la nueva configuración
qm cloudinit update $VMID

# Limpiar archivo temporal de imagen descargada
echo "Limpiando archivos temporales..."
rm -f "$IMG_FILE"

# (Opcional) Iniciar la VM automáticamente:
qm start $VMID

# Notificar éxito
whiptail --msgbox "VM '$VMNAME' (ID $VMID) creada exitosamente.\nPuede iniciarla desde la interfaz web de Proxmox." 10 60
