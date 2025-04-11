#!/bin/bash
# ----------------------------- VARIABLES MODIFICABLES -----------------------------
VMID=101                                      # ID único para la nueva VM
VM_NAME="github-runner"                       # Nombre de la VM (hostname)
VM_USER="ubuntu"                              # Nombre de usuario a crear dentro de la VM
VM_PASSWORD="cambiar123"                      # Contraseña del usuario (plano aquí; se encriptará para cloud-init)
VM_MEMORY=4096                                # RAM en MB
VM_CORES=2                                    # vCPUs
VM_BRIDGE="vmbr0"                             # Bridge de red Proxmox (ajustar a su entorno)
VM_DISK_SIZE_GB=20                            # Tamaño de disco deseado para la VM (GB)

STORAGE_ISO="local"                           # Almacenamiento para la imagen Ubuntu (debe permitir ISOs)
STORAGE_VM="local-lvm"                        # Almacenamiento para el disco de la VM (debe permitir images)
SNIPPET_STORAGE="local"                       # Almacenamiento para snippets cloud-init (ID configurado con Snippets)

GH_RUNNER_URL="https://github.com/owner/repo" # URL del repo u org de GitHub (e.g., https://github.com/orgs/MiOrg)
GH_RUNNER_TOKEN=""                            # Token de registro del runner (dejar vacío si no se desea auto-registro)
GH_RUNNER_LABEL="self-hosted"                 # Etiquetas adicionales para el runner (ejemplo)
GH_RUNNER_NAME="$VM_NAME"                     # Nombre del runner en GitHub (opcional, usar nombre de VM por defecto)
# ----------------------------------------------------------------------------------

# Determinar paths de almacenamiento
IMG_URL="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
IMG_PATH="/var/lib/vz/template/iso/ubuntu-24.04-server-cloudimg-amd64.img"
SNIPPET_DIR="/var/lib/vz/snippets"  # Carpeta en almacenamiento 'local' para snippets (ajuste si usa otro storage)
SNIPPET_FILE="${VM_NAME}-user-data.yaml"
SNIPPET_PATH="$SNIPPET_DIR/$SNIPPET_FILE"

# Encriptar la contraseña del usuario para cloud-init (SHA-512)
ENCRYPTED_PASS=$(openssl passwd -6 "$VM_PASSWORD")

echo "=== Descargando imagen Ubuntu 24.04 cloud-init ==="
mkdir -p /var/lib/vz/template/iso  # Asegurar directorio de ISOs
wget -O "$IMG_PATH" -nc "$IMG_URL" || { echo "Error descargando la imagen."; exit 1; }

echo "=== Creando VM ID $VMID (${VM_NAME}) en Proxmox ==="
# Crear VM con parametros básicos: nombre, RAM, CPU, red, y controlador SCSI (virtio-scsi-pci)
qm create $VMID --name "$VM_NAME" --memory $VM_MEMORY --cores $VM_CORES \
  --net0 virtio,bridge=$VM_BRIDGE --scsihw virtio-scsi-pci || exit 1

echo "=== Importando disco de la imagen en la VM (almacenamiento: $STORAGE_VM) ==="
# Importar el disco QCOW2 de la imagen Ubuntu al almacenamiento de VM
qm set $VMID --scsi0 $STORAGE_VM:0,import-from="$IMG_PATH" || exit 1

# (Alternativa: qm importdisk $VMID $IMG_PATH $STORAGE_VM && qm set $VMID --scsi0 $STORAGE_VM:vm-${VMID}-disk-0)

# Configurar disco de arranque y agregar unidad Cloud-Init
qm set $VMID --boot order=scsi0 --bootdisk scsi0 || exit 1
qm set $VMID --ide2 $STORAGE_VM:cloudinit || exit 1

# (Opcional) Configurar consola serial para la VM (mejora compatibilidad con cloud-init)
qm set $VMID --serial0 socket --vga serial0

# Red por DHCP en interfaz 0
qm set $VMID --ipconfig0 ip=dhcp

echo "=== Redimensionando disco de la VM a ${VM_DISK_SIZE_GB}G ==="
# Ampliar el tamaño del disco (la imagen base ~3GB) al tamaño deseado
qm resize $VMID scsi0 ${VM_DISK_SIZE_GB}G  || echo "Aviso: no se pudo ajustar el tamaño del disco (verificar almacenamiento)."

echo "=== Generando archivo cloud-init de usuario (${SNIPPET_PATH}) ==="
mkdir -p "$SNIPPET_DIR"
# Construir el user-data YAML para cloud-init
cat > "$SNIPPET_PATH" <<EOF
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true
users:
  - name: $VM_USER
    groups: sudo
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash
    lock_passwd: false
    passwd: $ENCRYPTED_PASS
package_update: true
packages:
  - docker.io
  - qemu-guest-agent
  - cloud-guest-utils
runcmd:
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get -y install docker.io qemu-guest-agent cloud-guest-utils
  - growpart /dev/sda 1 && resize2fs /dev/sda1
  - usermod -aG docker $VM_USER
  - systemctl enable qemu-guest-agent --now
  - su - $VM_USER -c "mkdir -p ~/actions-runner && cd ~/actions-runner && curl -o actions-runner-linux-x64-2.323.0.tar.gz -L https://github.com/actions/runner/releases/download/v2.323.0/actions-runner-linux-x64-2.323.0.tar.gz"
  - su - $VM_USER -c "cd ~/actions-runner && tar xzf actions-runner-linux-x64-2.323.0.tar.gz"
  - su - $VM_USER -c "cd ~/actions-runner && sudo ./bin/installdependencies.sh"
EOF

# Si se proporcionó un token de GitHub, agregar configuración automática del runner
if [[ -n "$GH_RUNNER_TOKEN" && -n "$GH_RUNNER_URL" ]]; then
  # Construir comando de registro (incluye opciones solo si variables no vacías)
  REG_CMD="./config.sh --url $GH_RUNNER_URL --token $GH_RUNNER_TOKEN --unattended"
  [[ -n "$GH_RUNNER_LABEL" ]] && REG_CMD+=" --labels $GH_RUNNER_LABEL"
  [[ -n "$GH_RUNNER_NAME" ]] && REG_CMD+=" --name $GH_RUNNER_NAME"
  cat >> "$SNIPPET_PATH" <<EOF
  - su - $VM_USER -c "cd ~/actions-runner && $REG_CMD"
  - su - $VM_USER -c "cd ~/actions-runner && sudo ./svc.sh install && sudo ./svc.sh start"
EOF
fi

# Aplicar el archivo de usuario cloud-init a la VM mediante el almacenamiento de snippets
echo "=== Asignando configuración cloud-init personalizada a la VM ==="
qm set $VMID --cicustom "user=${SNIPPET_STORAGE}:snippets/${SNIPPET_FILE}" || exit 1

echo "=== Iniciando VM ID $VMID (${VM_NAME}) ==="
qm start $VMID

echo ">>> VM creada y en proceso de arranque. Por favor, espere ~1-2 minutos a que cloud-init configure el sistema."
