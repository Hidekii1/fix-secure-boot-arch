#!/bin/bash

# Script para configurar Secure Boot en Arch Linux
# Genera claves MOK, firma GRUB y kernel, registra certificados y configura el sistema

set -euo pipefail

# Colores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuración
KEYS_DIR="/etc/secure-boot-keys"
MOK_NAME="MOK"
CERT_NAME="db"
LOG_FILE="/var/log/secure-boot-setup.log"

# Función para logging
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Función para mostrar mensajes con colores
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
    log "INFO: $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    log "SUCCESS: $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    log "WARNING: $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    log "ERROR: $1"
}

# Verificar si se ejecuta como root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Este script debe ejecutarse como root"
        exit 1
    fi
}

# Verificar dependencias
check_dependencies() {
    print_status "Verificando dependencias..."
    
    local deps=("openssl" "sbsign" "mokutil" "efibootmgr")
    local missing_deps=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Faltan las siguientes dependencias: ${missing_deps[*]}"
        print_status "Instalando dependencias faltantes..."
        pacman -S --noconfirm "${missing_deps[@]}"
    fi
    
    print_success "Todas las dependencias están instaladas"
}

# Crear directorio para las claves
create_keys_directory() {
    print_status "Creando directorio para las claves..."
    
    if [[ ! -d "$KEYS_DIR" ]]; then
        mkdir -p "$KEYS_DIR"
        chmod 700 "$KEYS_DIR"
        print_success "Directorio $KEYS_DIR creado"
    else
        print_warning "El directorio $KEYS_DIR ya existe"
    fi
}

# Generar claves MOK
generate_mok_keys() {
    print_status "Generando claves MOK (Machine Owner Key)..."
    
    cd "$KEYS_DIR"
    
    # Generar clave privada
    if [[ ! -f "${MOK_NAME}.key" ]]; then
        openssl genrsa -out "${MOK_NAME}.key" 2048
        chmod 600 "${MOK_NAME}.key"
        print_success "Clave privada MOK generada"
    else
        print_warning "La clave privada MOK ya existe"
    fi
    
    # Generar certificado
    if [[ ! -f "${MOK_NAME}.crt" ]]; then
        openssl req -new -x509 -key "${MOK_NAME}.key" -out "${MOK_NAME}.crt" -days 3650 \
            -subj "/CN=Secure Boot MOK/O=Local Machine/C=ES"
        print_success "Certificado MOK generado"
    else
        print_warning "El certificado MOK ya existe"
    fi
    
    # Convertir a formato DER para MOK
    if [[ ! -f "${MOK_NAME}.der" ]]; then
        openssl x509 -in "${MOK_NAME}.crt" -outform DER -out "${MOK_NAME}.der"
        print_success "Certificado MOK convertido a formato DER"
    fi
}

# Firmar GRUB
sign_grub() {
    print_status "Firmando GRUB..."
    
    local grub_efi="/boot/EFI/BOOT/BOOTX64.efi"
    local grub_signed="/boot/EFI/BOOT/BOOTX64.efi.signed"

    if [[ ! -f "$grub_efi" ]]; then
        # Buscar GRUB en otras ubicaciones comunes
        local grub_locations=(
            "/boot/EFI/GRUB/grubx64.efi"
            "/boot/efi/EFI/GRUB/grubx64.efi"
            "/boot/efi/EFI/grub/grubx64.efi"
            "/boot/EFI/grub/grubx64.efi"
        )
        
        for location in "${grub_locations[@]}"; do
            if [[ -f "$location" ]]; then
                grub_efi="$location"
                grub_signed="${location}.signed"
                break
            fi
        done
        
        if [[ ! -f "$grub_efi" ]]; then
            print_error "No se pudo encontrar GRUB EFI"
            return 1
        fi
    fi
    
    print_status "GRUB encontrado en: $grub_efi"
    
    # Firmar GRUB
    sbsign --key "${KEYS_DIR}/${MOK_NAME}.key" --cert "${KEYS_DIR}/${MOK_NAME}.crt" \
           --output "$grub_signed" "$grub_efi"
    
    # Reemplazar el GRUB original con el firmado
    mv "$grub_efi" "${grub_efi}.backup"
    mv "$grub_signed" "$grub_efi"
    
    print_success "GRUB firmado correctamente"
}

# Firmar kernels
sign_kernels() {
    print_status "Firmando kernels..."
    
    local kernel_dir="/boot"
    local kernels=($(find "$kernel_dir" -name "vmlinuz-*" -type f))
    
    if [[ ${#kernels[@]} -eq 0 ]]; then
        print_error "No se encontraron kernels para firmar"
        return 1
    fi
    
    for kernel in "${kernels[@]}"; do
        local kernel_name=$(basename "$kernel")
        local signed_kernel="${kernel}.signed"
        
        print_status "Firmando kernel: $kernel_name"
        
        sbsign --key "${KEYS_DIR}/${MOK_NAME}.key" --cert "${KEYS_DIR}/${MOK_NAME}.crt" \
               --output "$signed_kernel" "$kernel"
        
        # Reemplazar kernel original con el firmado
        mv "$kernel" "${kernel}.backup"
        mv "$signed_kernel" "$kernel"
        
        print_success "Kernel $kernel_name firmado correctamente"
    done
}

# Registrar MOK
enroll_mok() {
    print_status "Registrando certificado MOK..."
    
    # Importar el certificado MOK
    mokutil --import "${KEYS_DIR}/${MOK_NAME}.der"
    
    print_success "Certificado MOK registrado para importación"
    print_warning "Será necesario confirmar la importación después del reinicio"
}

# Verificar estado de Secure Boot
check_secure_boot_status() {
    print_status "Verificando estado de Secure Boot..."
    
    if [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]]; then
        local sb_status=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* | awk '{print $NF}')
        if [[ "$sb_status" == "1" ]]; then
            print_success "Secure Boot está habilitado"
        else
            print_warning "Secure Boot está deshabilitado"
        fi
    else
        print_warning "No se puede determinar el estado de Secure Boot"
    fi
}

# Crear script post-reinicio
create_post_reboot_script() {
    print_status "Creando script post-reinicio..."
    
    cat > /usr/local/bin/secure-boot-post-reboot.sh << 'EOF'
#!/bin/bash

# Script post-reinicio para verificar Secure Boot

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

echo "=========================================="
echo "  VERIFICACIÓN POST-REINICIO SECURE BOOT"
echo "=========================================="
echo

# Verificar si MOK fue importado
print_status "Verificando importación de MOK..."
if mokutil --list-enrolled | grep -q "Secure Boot MOK"; then
    print_success "Certificado MOK importado correctamente"
else
    print_warning "El certificado MOK no fue importado o no se encuentra"
fi

# Verificar estado de Secure Boot
print_status "Verificando estado de Secure Boot..."
if [[ -f /sys/firmware/efi/efivars/SecureBoot-* ]]; then
    sb_status=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-* | awk '{print $NF}')
    if [[ "$sb_status" == "1" ]]; then
        print_success "¡Secure Boot está habilitado y funcionando!"
    else
        print_warning "Secure Boot está deshabilitado"
    fi
else
    print_warning "No se puede determinar el estado de Secure Boot"
fi

echo
echo "=========================================="
echo "  INSTRUCCIONES FINALES"
echo "=========================================="
echo
print_status "Si Secure Boot no está habilitado:"
echo "1. Reinicia el sistema"
echo "2. Entra en la BIOS/UEFI"
echo "3. Habilita Secure Boot"
echo "4. Guarda y reinicia"
echo
print_success "¡El sistema está listo para usar Secure Boot!"
echo

# Eliminar este script después de la ejecución
rm -f /usr/local/bin/secure-boot-post-reboot.sh
rm -f /etc/systemd/system/secure-boot-check.service
systemctl daemon-reload
EOF

    chmod +x /usr/local/bin/secure-boot-post-reboot.sh
    
    # Crear servicio systemd para ejecutar después del reinicio
    cat > /etc/systemd/system/secure-boot-check.service << EOF
[Unit]
Description=Secure Boot Post-Reboot Check
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/secure-boot-post-reboot.sh
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable secure-boot-check.service
    print_success "Script post-reinicio configurado"
}

# Función principal
main() {
    echo "=========================================="
    echo "  CONFIGURACIÓN DE SECURE BOOT - ARCH LINUX"
    echo "=========================================="
    echo
    
    check_root
    check_dependencies
    create_keys_directory
    generate_mok_keys
    sign_grub
    sign_kernels
    enroll_mok
    check_secure_boot_status
    create_post_reboot_script
    
    echo
    echo "=========================================="
    echo "  CONFIGURACIÓN COMPLETADA"
    echo "=========================================="
    echo
    print_success "¡Configuración de Secure Boot completada!"
    echo
    print_status "PRÓXIMOS PASOS:"
    echo "1. El sistema se reiniciará automáticamente en 10 segundos"
    echo "2. Durante el arranque, aparecerá una pantalla azul de MOK Manager"
    echo "3. Selecciona 'Enroll MOK' -> 'Continue' -> 'Yes'"
    echo "4. Ingresa una contraseña temporal cuando se solicite"
    echo "5. Selecciona 'Reboot'"
    echo "6. Después del reinicio, ejecuta el script de verificación"
    echo
    print_warning "¡IMPORTANTE! Guarda este log: $LOG_FILE"
    echo
    
    # Countdown para reinicio
    for i in {10..1}; do
        echo -ne "\rReiniciando en $i segundos... (Ctrl+C para cancelar)"
        sleep 1
    done
    echo
    
    print_status "Reiniciando sistema..."
    reboot
}

# Ejecutar función principal
main "$@"