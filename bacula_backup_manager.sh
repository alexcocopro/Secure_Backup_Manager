#!/bin/bash
# =============================================================================
# BACULA BACKUP MANAGER - Enterprise Backup Solution
# Desarrollador: Alex Cabello Leiva - Consultor en Innovación y Ciberseguridad
# Versión: 2.1.1
# Licencia: GPL v3
# =============================================================================
# Sistema de respaldos empresarial con Bacula - Interfaz amigable bilingüe
# Protección inteligente de PostgreSQL existente (9+) - Compatible con producción
# Soporte amplio: Debian 9+, Ubuntu 18.04+, RHEL 7+, PostgreSQL 9+
# =============================================================================

# Configuración de shell para máxima compatibilidad
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# =============================================================================
# CONFIGURACIÓN GLOBAL / GLOBAL CONFIGURATION
# =============================================================================
# Limpiar variables de entorno conflictivas
unset VERSION 2>/dev/null || true

# Declarar variables readonly con protección
declare -r SCRIPT_VERSION="2.1.1"
declare -r AUTHOR="Alex Cabello Leiva"
declare -r TITLE="Consultor en Innovación y Ciberseguridad"
declare -r SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -r SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
declare -r LOG_DIR="/var/log/bacula-manager"
declare -r CONFIG_DIR="/etc/bacula-manager"
declare -r LOCK_FILE="/var/run/bacula-manager.lock"
declare -r SSH_DIR="/root/.ssh"
declare -r ENV_FILE="/etc/bacula-manager/environment"
declare -r REMOTE_CONFIG_DIR="/etc/bacula-manager/remote"

# Colores / Colors
declare -r COLOR_RESET='\033[0m'
declare -r COLOR_RED='\033[0;31m'
declare -r COLOR_GREEN='\033[0;32m'
declare -r COLOR_YELLOW='\033[1;33m'
declare -r COLOR_BLUE='\033[0;34m'
declare -r COLOR_CYAN='\033[0;36m'
declare -r COLOR_INFO='\033[0;36m'
declare -r COLOR_BOLD='\033[1m'
declare -r COLOR_DIM='\033[2m'

# Variables de idioma / Language variables
# NOTA: Se usa APP_LANG para evitar colisión con la variable de sistema LANG (ej. es_ES.UTF-8)
APP_LANG="${APP_LANG:-en}"

# Variables de conexión remota / Remote connection variables
REMOTE_MODE="${REMOTE_MODE:-false}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_TYPE="${REMOTE_TYPE:-ssh}"

# =============================================================================
# FUNCIONES DE UTILIDAD / UTILITY FUNCTIONS
# =============================================================================

# --- Manejo de errores / Error handling ---
error_exit() {
    local message="${1:-}"
    local code="${2:-1}"
    log_message "ERROR" "$message"
    echo -e "${COLOR_RED}✗ ERROR: $message${COLOR_RESET}" >&2
    cleanup
    exit "$code"
}

# --- Logging / Registro ---
log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/manager.log" 2>/dev/null || true
}

# --- Cleanup / Limpieza ---
cleanup() {
    rm -f "$LOCK_FILE" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# --- Verificar root / Check root ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        if [[ "$APP_LANG" == "en" ]]; then
            error_exit "This script must be run as root (use sudo)"
        else
            error_exit "Este script debe ejecutarse como root (use sudo)"
        fi
    fi
}

# --- Verificar bloqueo / Check lock ---
check_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local pid
        pid=$(cat "$LOCK_FILE" 2>/dev/null) || true
        if kill -0 "$pid" 2>/dev/null; then
            if [[ "$APP_LANG" == "en" ]]; then
                error_exit "Another instance is running (PID: $pid)"
            else
                error_exit "Otra instancia está en ejecución (PID: $pid)"
            fi
        fi
    fi
    echo $$ > "$LOCK_FILE"
}

# =============================================================================
# FUNCIONES DE SEGURIDAD Y CREDENCIALES / SECURITY AND CREDENTIAL FUNCTIONS
# =============================================================================

# --- Inicializar almacenamiento seguro / Initialize secure storage ---
init_secure_storage() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null || error_exit "Cannot create config directory"
    mkdir -p "$REMOTE_CONFIG_DIR" 2>/dev/null || error_exit "Cannot create remote config directory"
    mkdir -p "$SSH_DIR" 2>/dev/null || error_exit "Cannot create SSH directory"
    
    chmod 700 "$CONFIG_DIR"
    chmod 700 "$REMOTE_CONFIG_DIR"
    chmod 700 "$SSH_DIR"
    
    # Crear archivo de entorno seguro / Create secure environment file
    if [[ ! -f "$ENV_FILE" ]]; then
        touch "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        chown root:root "$ENV_FILE"
    fi
}

# --- Guardar credencial segura / Save secure credential ---
save_credential() {
    local key="${1:-}"
    local value="${2:-}"
    local credential_file="${3:-$ENV_FILE}"
    
    # Remover entrada anterior si existe / Remove previous entry if exists
    if [[ -f "$credential_file" ]]; then
        grep -v "^${key}=" "$credential_file" > "${credential_file}.tmp" 2>/dev/null || true
        mv "${credential_file}.tmp" "$credential_file"
    fi
    
    # Agregar nueva entrada cifrada con base64 / Add new base64-encoded entry
    local encoded_value
    encoded_value=$(echo -n "$value" | base64 -w 0)
    echo "${key}_ENCODED=${encoded_value}" >> "$credential_file"
    chmod 600 "$credential_file"
    
    log_message "INFO" "Credential saved securely: $key"
}

# --- Cargar credencial segura / Load secure credential ---
load_credential() {
    local key="${1:-}"
    local credential_file="${2:-$ENV_FILE}"
    
    if [[ -f "$credential_file" ]]; then
        local encoded_value
        encoded_value=$(grep "^${key}_ENCODED=" "$credential_file" 2>/dev/null | cut -d= -f2)
        if [[ -n "$encoded_value" ]]; then
            echo -n "$encoded_value" | base64 -d 2>/dev/null
            return 0
        fi
    fi
    return 1
}

# --- Verificar si credencial existe / Check if credential exists ---
credential_exists() {
    local key="${1:-}"
    local credential_file="${2:-$ENV_FILE}"
    
    if [[ -f "$credential_file" ]]; then
        grep -q "^${key}_ENCODED=" "$credential_file" 2>/dev/null && return 0
    fi
    return 1
}

# --- Configurar variables de entorno seguras / Setup secure environment variables ---
setup_secure_env() {
    local prefix="${1:-}"
    
    if [[ -f "$ENV_FILE" ]]; then
        while IFS='=' read -r key value; do
            if [[ "$key" == ${prefix}* && -n "$value" ]]; then
                local decoded
                decoded=$(echo -n "$value" | base64 -d 2>/dev/null)
                export "${key%_ENCODED}=$decoded"
            fi
        done < "$ENV_FILE"
    fi
}

# --- Generar par de claves SSH / Generate SSH key pair ---
generate_ssh_keys() {
    local key_name="${1:-bacula_backup}"
    local key_path="${SSH_DIR}/${key_name}"
    
    if [[ -f "$key_path" ]]; then
        log_message "INFO" "SSH keys already exist: $key_path"
        return 0
    fi
    
    echo -e "${COLOR_CYAN}$(t "msg_generating_ssh")${COLOR_RESET}"
    
    # Generar clave Ed25519 (más segura y rápida) / Generate Ed25519 key
    ssh-keygen -t ed25519 -a 100 -f "$key_path" -N "" -C "bacula-backup-$(hostname -s)" 2>/dev/null || \
    ssh-keygen -t rsa -b 4096 -f "$key_path" -N "" -C "bacula-backup-$(hostname -s)" 2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        chmod 600 "$key_path"
        chmod 644 "${key_path}.pub"
        log_message "INFO" "SSH keys generated: $key_path"
        return 0
    else
        log_message "ERROR" "Failed to generate SSH keys"
        return 1
    fi
}

# --- Distribuir clave SSH a host remoto / Distribute SSH key to remote host ---
distribute_ssh_key() {
    local remote_host="${1:-}"
    local remote_user="${2:-}"
    local remote_password="${3:-}"
    local key_name="${4:-bacula_backup}"
    local key_path="${SSH_DIR}/${key_name}.pub"
    
    if [[ ! -f "$key_path" ]]; then
        generate_ssh_keys "$key_name" || return 1
    fi
    
    echo -e "${COLOR_CYAN}$(t "msg_configuring_ssh")${COLOR_RESET}"
    
    # Verificar conectividad / Check connectivity
    if ! ping -c 1 -W 3 "$remote_host" &>/dev/null; then
        echo -e "${COLOR_YELLOW}⚠ $(t "msg_host_unreachable") $remote_host${COLOR_RESET}"
        if [[ "$APP_LANG" == "en" ]]; then
            echo "Please verify network connectivity (LAN/VLAN)"
        else
            echo "Por favor verifique la conectividad de red (LAN/VLAN)"
        fi
        return 1
    fi
    
    # Instalar sshpass si es necesario / Install sshpass if needed
    if ! command -v sshpass &>/dev/null && [[ -n "$remote_password" ]]; then
        apt-get install -y sshpass 2>/dev/null || yum install -y sshpass 2>/dev/null || true
    fi
    
    # Copiar clave pública / Copy public key
    local pub_key
    pub_key=$(cat "$key_path")
    
    if [[ -n "$remote_password" ]] && command -v sshpass &>/dev/null; then
        # Usar sshpass con contraseña temporal / Use sshpass with temporary password
        SSHPASS="$remote_password" sshpass -e ssh -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -o BatchMode=no \
            "${remote_user}@${remote_host}" \
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null
    else
        # Intentar ssh-copy-id / Try ssh-copy-id
        ssh-copy-id -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            -i "$key_path" \
            "${remote_user}@${remote_host}" 2>/dev/null || return 1
    fi
    
    # Verificar conexión / Verify connection
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -i "${key_path%.*}" \
        "${remote_user}@${remote_host}" "echo 'SSH_OK'" 2>/dev/null | grep -q "SSH_OK"; then
        echo -e "${COLOR_GREEN}✓ $(t "msg_ssh_configured")${COLOR_RESET}"
        log_message "INFO" "SSH key deployed to $remote_host"
        return 0
    else
        echo -e "${COLOR_RED}✗ $(t "msg_ssh_failed")${COLOR_RESET}"
        log_message "ERROR" "SSH key deployment failed for $remote_host"
        return 1
    fi
}

# --- Probar conexión SSH / Test SSH connection ---
test_ssh_connection() {
    local remote_host="${1:-}"
    local remote_user="${2:-}"
    local key_name="${3:-bacula_backup}"
    local key_path="${SSH_DIR}/${key_name}"
    
    if [[ ! -f "$key_path" ]]; then
        return 1
    fi
    
    ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=yes \
        -i "$key_path" "${remote_user}@${remote_host}" "echo 'CONNECTION_OK'" 2>/dev/null | grep -q "CONNECTION_OK"
}

# --- Detectar segmento de red / Detect network segment ---
detect_network_segment() {
    local interface="${1:-eth0}"
    local ip_info
    ip_info=$(ip addr show "$interface" 2>/dev/null | grep "inet " | head -1)
    
    if [[ -n "$ip_info" ]]; then
        local ip_cidr
        ip_cidr=$(echo "$ip_info" | awk '{print $2}')
        local ip=$(echo "$ip_cidr" | cut -d/ -f1)
        local prefix=$(echo "$ip_cidr" | cut -d/ -f2)
        
        # Calcular red sin usar ipcalc
        if [[ -n "$ip" && -n "$prefix" ]]; then
            # Convertir IP a array
            IFS='.' read -ra ADDR <<< "$ip"
            local network=""
            
            # Calcular máscara de red según prefix
            local mask=$((0xFFFFFFFF << (32 - prefix)))
            
            # Aplicar máscara a cada octeto
            for i in {0..3}; do
                local octet=${ADDR[$i]}
                local mask_octet=$((mask >> (24 - i*8) & 0xFF))
                local net_octet=$((octet & mask_octet))
                if [[ -z "$network" ]]; then
                    network="$net_octet"
                else
                    network="$network.$net_octet"
                fi
            done
            
            echo "$network"
        else
            echo "unknown"
        fi
    else
        echo "unknown"
    fi
}

# --- Verificar conectividad de red / Verify network connectivity ---
verify_network_connectivity() {
    local target="${1:-}"
    local port="${2:-22}"
    local timeout="${3:-5}"
    
    echo -e "${COLOR_CYAN}$(t "msg_testing_connectivity") $target:$port...${COLOR_RESET}"
    
    # Validar parámetros
    if [[ -z "$target" ]]; then
        echo -e "  ${COLOR_RED}✗ Invalid target${COLOR_RESET}"
        return 1
    fi
    
    if [[ -z "$port" || "$port" -lt 1 || "$port" -gt 65535 ]]; then
        echo -e "  ${COLOR_RED}✗ Invalid port: $port${COLOR_RESET}"
        return 1
    fi
    
    # Test ICMP ping (puede fallar por firewall)
    if command -v ping &>/dev/null; then
        if ping -c 1 -W "$timeout" "$target" &>/dev/null; then
            echo -e "  ${COLOR_GREEN}✓ $(t "msg_ping_success")${COLOR_RESET}"
        else
            echo -e "  ${COLOR_YELLOW}⚠ $(t "msg_ping_failed")${COLOR_RESET}"
        fi
    else
        echo -e "  ${COLOR_YELLOW}⚠ ping command not available${COLOR_RESET}"
    fi
    
    # Test TCP connection (método principal)
    local tcp_ok=false
    
    # Método 1: timeout con /dev/tcp (bash builtin)
    if command -v timeout &>/dev/null; then
        if timeout "$timeout" bash -c "</dev/tcp/$target/$port" 2>/dev/null; then
            tcp_ok=true
        fi
    fi
    
    # Método 2: nc (netcat) si el anterior falla
    if [[ "$tcp_ok" == false ]] && command -v nc &>/dev/null; then
        if echo "" | nc -w "$timeout" "$target" "$port" &>/dev/null; then
            tcp_ok=true
        fi
    fi
    
    # Método 3: telnet como último recurso
    if [[ "$tcp_ok" == false ]] && command -v telnet &>/dev/null; then
        if echo "quit" | timeout "$timeout" telnet "$target" "$port" &>/dev/null; then
            tcp_ok=true
        fi
    fi
    
    if [[ "$tcp_ok" == true ]]; then
        echo -e "  ${COLOR_GREEN}✓ $(t "msg_port_reachable")${COLOR_RESET}"
        return 0
    else
        echo -e "  ${COLOR_RED}✗ $(t "msg_port_unreachable")${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}$(t "msg_check_firewall")${COLOR_RESET}"
        return 1
    fi
}

# --- Mostrar banner / Show banner ---
show_banner() {
    clear
    echo -e "${COLOR_CYAN}"
    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║                                                                           ║"
    echo "║     ██████╗  █████╗  ██████╗██╗   ██╗██╗      █████╗                      ║"
    echo "║     ██╔══██╗██╔══██╗██╔════╝██║   ██║██║     ██╔══██╗                     ║"
    echo "║     ██████╔╝███████║██║     ██║   ██║██║     ███████║                     ║"
    echo "║     ██╔══██╗██╔══██║██║     ██║   ██║██║     ██╔══██║                     ║"
    echo "║     ██████╔╝██║  ██║╚██████╗╚██████╔╝███████╗██║  ██║                     ║"
    echo "║     ╚═════╝ ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝                     ║"
    echo "║                                                                           ║"
    echo "║              ENTERPRISE BACKUP MANAGER SOLUTION v${SCRIPT_VERSION}                      ║"
    echo "║                                                                           ║"
    echo "║     Developer: ${AUTHOR}                                      ║"
    echo "║     ${TITLE}                              ║"
    echo "║                                                                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo -e "${COLOR_RESET}"
    echo ""
}

# --- Función para traducciones / Translation function ---
t() {
    local key="${1:-}"
    case "$key" in
        # Menú principal / Main menu
        "menu_title")
            [[ "$APP_LANG" == "en" ]] && echo "MAIN MENU" || echo "MENÚ PRINCIPAL"
            ;;
        "menu_install")
            [[ "$APP_LANG" == "en" ]] && echo "Install & Configure Bacula" || echo "Instalar y Configurar Bacula"
            ;;
        "menu_backup")
            [[ "$APP_LANG" == "en" ]] && echo "Run Backup Job" || echo "Ejecutar Trabajo de Respaldo"
            ;;
        "menu_restore")
            [[ "$APP_LANG" == "en" ]] && echo "Restore from Backup" || echo "Restaurar desde Respaldo"
            ;;
        "menu_status")
            [[ "$APP_LANG" == "en" ]] && echo "View Backup Status" || echo "Ver Estado de Respaldos"
            ;;
        "menu_configure")
            [[ "$APP_LANG" == "en" ]] && echo "Reconfigure System" || echo "Reconfigurar Sistema"
            ;;
        "menu_logs")
            [[ "$APP_LANG" == "en" ]] && echo "View Logs" || echo "Ver Logs"
            ;;
        "menu_test")
            [[ "$APP_LANG" == "en" ]] && echo "Test Configuration" || echo "Probar Configuración"
            ;;
        "menu_language")
            [[ "$APP_LANG" == "en" ]] && echo "Change Language (Cambiar Idioma)" || echo "Cambiar Idioma (Change Language)"
            ;;
        "menu_exit")
            [[ "$APP_LANG" == "en" ]] && echo "Exit" || echo "Salir"
            ;;
        "menu_email_status")
            [[ "$APP_LANG" == "en" ]] && echo "Email Notifications Status" || echo "Estado de Notificaciones por Email"
            ;;
        "menu_port_management")
            [[ "$APP_LANG" == "en" ]] && echo "Port Management Status" || echo "Estado de Gestión de Puertos"
            ;;
        "menu_remote")
            [[ "$APP_LANG" == "en" ]] && echo "Remote Backup Configuration" || echo "Configuración de Respaldo Remoto"
            ;;
        "menu_ssh_manage")
            [[ "$APP_LANG" == "en" ]] && echo "Manage SSH Keys" || echo "Gestionar Claves SSH"
            ;;
        "menu_network_test")
            [[ "$APP_LANG" == "en" ]] && echo "Test Network Connectivity" || echo "Probar Conectividad de Red"
            ;;
        "select_option")
            [[ "$APP_LANG" == "en" ]] && echo "Select an option" || echo "Seleccione una opción"
            ;;
        "invalid_option")
            [[ "$APP_LANG" == "en" ]] && echo "Invalid option" || echo "Opción inválida"
            ;;
        "press_continue")
            [[ "$APP_LANG" == "en" ]] && echo "Press Enter to continue..." || echo "Presione Enter para continuar..."
            ;;
        # Instalación / Installation
        "install_title")
            [[ "$APP_LANG" == "en" ]] && echo "BACULA INSTALLATION" || echo "INSTALACIÓN DE BACULA"
            ;;
        "checking_deps")
            [[ "$APP_LANG" == "en" ]] && echo "Checking dependencies..." || echo "Verificando dependencias..."
            ;;
        "updating_repos")
            [[ "$APP_LANG" == "en" ]] && echo "Updating package repositories..." || echo "Actualizando repositorios..."
            ;;
        "installing_bacula")
            [[ "$APP_LANG" == "en" ]] && echo "Installing Bacula components..." || echo "Instalando componentes de Bacula..."
            ;;
        "install_success")
            [[ "$APP_LANG" == "en" ]] && echo "Installation completed successfully!" || echo "¡Instalación completada exitosamente!"
            ;;
        "install_error")
            [[ "$APP_LANG" == "en" ]] && echo "Installation failed" || echo "La instalación falló"
            ;;
        "already_installed")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula is already installed" || echo "Bacula ya está instalado"
            ;;
        # Configuración / Configuration
        "config_title")
            [[ "$APP_LANG" == "en" ]] && echo "SYSTEM CONFIGURATION" || echo "CONFIGURACIÓN DEL SISTEMA"
            ;;
        "config_welcome")
            [[ "$APP_LANG" == "en" ]] && echo "Welcome! Let's configure your backup system." || echo "¡Bienvenido! Configuraremos su sistema de respaldos."
            ;;
        "config_explain")
            [[ "$APP_LANG" == "en" ]] && echo "I will guide you through each step with explanations." || echo "Le guiaré paso a paso con explicaciones."
            ;;
        "ask_director_name")
            [[ "$APP_LANG" == "en" ]] && echo "Backup Server Name (Director):" || echo "Nombre del Servidor de Respaldo (Director):"
            ;;
        "explain_director")
            [[ "$APP_LANG" == "en" ]] && echo "This is the unique identifier for this backup server." || echo "Este es el identificador único para este servidor de respaldos."
            ;;
        "ask_password")
            [[ "$APP_LANG" == "en" ]] && echo "Enter secure password for Bacula services:" || echo "Ingrese contraseña segura para servicios Bacula:"
            ;;
        "explain_password")
            [[ "$APP_LANG" == "en" ]] && echo "Password must be 8+ chars with letters, numbers and symbols." || echo "La contraseña debe tener 8+ caracteres con letras, números y símbolos."
            ;;
        "password_weak")
            [[ "$APP_LANG" == "en" ]] && echo "Password too weak. Minimum 8 characters with mixed case, numbers and symbols." || echo "Contraseña débil. Mínimo 8 caracteres con mayúsculas, minúsculas, números y símbolos."
            ;;
        "ask_backup_path")
            [[ "$APP_LANG" == "en" ]] && echo "Path to store backups:" || echo "Ruta para almacenar respaldos:"
            ;;
        "explain_backup_path")
            [[ "$APP_LANG" == "en" ]] && echo "This directory will store all backup volumes. Ensure sufficient space." || echo "Este directorio almacenará todos los volúmenes. Asegure espacio suficiente."
            ;;
        "ask_what_to_backup")
            [[ "$APP_LANG" == "en" ]] && echo "What do you want to backup?" || echo "¿Qué desea respaldar?"
            ;;
        "option_system")
            [[ "$APP_LANG" == "en" ]] && echo "Complete System" || echo "Sistema Completo"
            ;;
        "option_home")
            [[ "$APP_LANG" == "en" ]] && echo "User Home Directories" || echo "Directorios de Usuarios"
            ;;
        "option_custom")
            [[ "$APP_LANG" == "en" ]] && echo "Custom Directories" || echo "Directorios Personalizados"
            ;;
        "option_databases")
            [[ "$APP_LANG" == "en" ]] && echo "Databases (PostgreSQL/MySQL)" || echo "Bases de Datos (PostgreSQL/MySQL)"
            ;;
        "ask_schedule")
            [[ "$APP_LANG" == "en" ]] && echo "Backup schedule:" || echo "Horario de respaldos:"
            ;;
        "option_daily")
            [[ "$APP_LANG" == "en" ]] && echo "Daily" || echo "Diario"
            ;;
        "option_weekly")
            [[ "$APP_LANG" == "en" ]] && echo "Weekly" || echo "Semanal"
            ;;
        "option_monthly")
            [[ "$APP_LANG" == "en" ]] && echo "Monthly" || echo "Mensual"
            ;;
        "option_custom_schedule")
            [[ "$APP_LANG" == "en" ]] && echo "Custom" || echo "Personalizado"
            ;;
        "ask_retention")
            [[ "$APP_LANG" == "en" ]] && echo "How long to keep backups?" || echo "¿Cuánto tiempo conservar los respaldos?"
            ;;
        "option_30days")
            [[ "$APP_LANG" == "en" ]] && echo "30 days" || echo "30 días"
            ;;
        "option_90days")
            [[ "$APP_LANG" == "en" ]] && echo "90 days" || echo "90 días"
            ;;
        "option_1year")
            [[ "$APP_LANG" == "en" ]] && echo "1 year" || echo "1 año"
            ;;
        "option_forever")
            [[ "$APP_LANG" == "en" ]] && echo "Forever" || echo "Para siempre"
            ;;
        "config_complete")
            [[ "$APP_LANG" == "en" ]] && echo "Configuration completed!" || echo "¡Configuración completada!"
            ;;
        "config_summary")
            [[ "$APP_LANG" == "en" ]] && echo "Configuration Summary:" || echo "Resumen de Configuración:"
            ;;
        # Backup / Respaldo
        "backup_title")
            [[ "$APP_LANG" == "en" ]] && echo "RUNNING BACKUP" || echo "EJECUTANDO RESPALDO"
            ;;
        "backup_starting")
            [[ "$APP_LANG" == "en" ]] && echo "Starting backup process..." || echo "Iniciando proceso de respaldo..."
            ;;
        "backup_progress")
            [[ "$APP_LANG" == "en" ]] && echo "Backup in progress..." || echo "Respaldo en progreso..."
            ;;
        "backup_success")
            [[ "$APP_LANG" == "en" ]] && echo "Backup completed successfully!" || echo "¡Respaldo completado exitosamente!"
            ;;
        "backup_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Backup failed!" || echo "¡El respaldo falló!"
            ;;
        "backup_job_id")
            [[ "$APP_LANG" == "en" ]] && echo "Backup Job ID:" || echo "ID del Trabajo de Respaldo:"
            ;;
        # Restore / Restauración
        "restore_title")
            [[ "$APP_LANG" == "en" ]] && echo "RESTORE FROM BACKUP" || echo "RESTAURAR DESDE RESPALDO"
            ;;
        "restore_listing")
            [[ "$APP_LANG" == "en" ]] && echo "Available backups:" || echo "Respaldos disponibles:"
            ;;
        "restore_select")
            [[ "$APP_LANG" == "en" ]] && echo "Select backup to restore:" || echo "Seleccione respaldo a restaurar:"
            ;;
        "restore_destination")
            [[ "$APP_LANG" == "en" ]] && echo "Restore destination path:" || echo "Ruta de destino para restaurar:"
            ;;
        "restore_confirm")
            [[ "$APP_LANG" == "en" ]] && echo "Confirm restore? This will overwrite existing files." || echo "¿Confirmar restauración? Esto sobrescribirá archivos existentes."
            ;;
        "restore_success")
            [[ "$APP_LANG" == "en" ]] && echo "Restore completed successfully!" || echo "¡Restauración completada exitosamente!"
            ;;
        "restore_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Restore failed!" || echo "¡La restauración falló!"
            ;;
        # Estado / Status
        "status_title")
            [[ "$APP_LANG" == "en" ]] && echo "BACKUP STATUS" || echo "ESTADO DE RESPALDOS"
            ;;
        "status_no_jobs")
            [[ "$APP_LANG" == "en" ]] && echo "No backup jobs found" || echo "No se encontraron trabajos de respaldo"
            ;;
        "status_last_backup")
            [[ "$APP_LANG" == "en" ]] && echo "Last Backup:" || echo "Último Respaldo:"
            ;;
        "status_next_backup")
            [[ "$APP_LANG" == "en" ]] && echo "Next Scheduled:" || echo "Próximo Programado:"
            ;;
        "status_total_jobs")
            [[ "$APP_LANG" == "en" ]] && echo "Total Jobs:" || echo "Total de Trabajos:"
            ;;
        "status_storage_used")
            [[ "$APP_LANG" == "en" ]] && echo "Storage Used:" || echo "Espacio Utilizado:"
            ;;
        # Pruebas / Testing
        "test_title")
            [[ "$APP_LANG" == "en" ]] && echo "CONFIGURATION TEST" || echo "PRUEBA DE CONFIGURACIÓN"
            ;;
        "test_running")
            [[ "$APP_LANG" == "en" ]] && echo "Testing Bacula configuration..." || echo "Probando configuración de Bacula..."
            ;;
        "test_passed")
            [[ "$APP_LANG" == "en" ]] && echo "All tests passed!" || echo "¡Todas las pruebas pasaron!"
            ;;
        "test_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Some tests failed!" || echo "¡Algunas pruebas fallaron!"
            ;;
        # Mensajes generales / General messages
        "warning")
            [[ "$APP_LANG" == "en" ]] && echo "WARNING" || echo "ADVERTENCIA"
            ;;
        "success")
            [[ "$APP_LANG" == "en" ]] && echo "SUCCESS" || echo "ÉXITO"
            ;;
        "error")
            [[ "$APP_LANG" == "en" ]] && echo "ERROR" || echo "ERROR"
            ;;
        "info")
            [[ "$APP_LANG" == "en" ]] && echo "INFO" || echo "INFO"
            ;;
        "yes")
            [[ "$APP_LANG" == "en" ]] && echo "Yes" || echo "Sí"
            ;;
        "no")
            [[ "$APP_LANG" == "en" ]] && echo "No" || echo "No"
            ;;
        "cancel")
            [[ "$APP_LANG" == "en" ]] && echo "Cancel" || echo "Cancelar"
            ;;
        "back")
            [[ "$APP_LANG" == "en" ]] && echo "Back" || echo "Volver"
            ;;
        "exit_confirm")
            [[ "$APP_LANG" == "en" ]] && echo "Are you sure you want to exit?" || echo "¿Está seguro de que desea salir?"
            ;;
        "coming_soon")
            [[ "$APP_LANG" == "en" ]] && echo "Feature coming soon!" || echo "¡Función próximamente!"
            ;;
        # Remote Backup / Respaldo Remoto
        "remote_title")
            [[ "$APP_LANG" == "en" ]] && echo "REMOTE BACKUP CONFIGURATION" || echo "CONFIGURACIÓN DE RESPALDO REMOTO"
            ;;
        "remote_enable")
            [[ "$APP_LANG" == "en" ]] && echo "Enable remote backup?" || echo "¿Habilitar respaldo remoto?"
            ;;
        "remote_explain")
            [[ "$APP_LANG" == "en" ]] && echo "Backups will be stored on a remote host via secure SSH connection." || echo "Los respaldos se almacenarán en un host remoto vía conexión SSH segura."
            ;;
        "ask_remote_host")
            [[ "$APP_LANG" == "en" ]] && echo "Remote host IP or hostname:" || echo "IP o nombre del host remoto:"
            ;;
        "ask_remote_user")
            [[ "$APP_LANG" == "en" ]] && echo "Remote username:" || echo "Usuario remoto:"
            ;;
        "ask_remote_password")
            [[ "$APP_LANG" == "en" ]] && echo "Remote password (for initial SSH setup):" || echo "Contraseña remota (para configuración SSH inicial):"
            ;;
        "ask_remote_path")
            [[ "$APP_LANG" == "en" ]] && echo "Remote path for backups:" || echo "Ruta remota para respaldos:"
            ;;
        "explain_remote_path")
            [[ "$APP_LANG" == "en" ]] && echo "Directory on remote host where backup volumes will be stored." || echo "Directorio en el host remoto donde se almacenarán los volúmenes de respaldo."
            ;;
        "remote_connection_type")
            [[ "$APP_LANG" == "en" ]] && echo "Connection type:" || echo "Tipo de conexión:"
            ;;
        "option_ssh_tunnel")
            [[ "$APP_LANG" == "en" ]] && echo "SSH Tunnel (Secure, recommended)" || echo "Túnel SSH (Seguro, recomendado)"
            ;;
        "option_direct")
            [[ "$APP_LANG" == "en" ]] && echo "Direct (same VLAN/LAN only)" || echo "Directo (misma VLAN/LAN solo)"
            ;;
        "option_vpn")
            [[ "$APP_LANG" == "en" ]] && echo "VPN Connection" || echo "Conexión VPN"
            ;;
        "remote_config_success")
            [[ "$APP_LANG" == "en" ]] && echo "Remote backup configured successfully!" || echo "¡Respaldo remoto configurado exitosamente!"
            ;;
        "remote_test_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Remote connection test failed. Check network connectivity." || echo "Prueba de conexión remota falló. Verifique conectividad de red."
            ;;
        "ssh_keys_title")
            [[ "$APP_LANG" == "en" ]] && echo "SSH KEY MANAGEMENT" || echo "GESTIÓN DE CLAVES SSH"
            ;;
        "ssh_key_generate")
            [[ "$APP_LANG" == "en" ]] && echo "Generate new SSH key pair" || echo "Generar nuevo par de claves SSH"
            ;;
        "ssh_key_deploy")
            [[ "$APP_LANG" == "en" ]] && echo "Deploy SSH key to remote host" || echo "Desplegar clave SSH a host remoto"
            ;;
        "ssh_key_test")
            [[ "$APP_LANG" == "en" ]] && echo "Test SSH connection" || echo "Probar conexión SSH"
            ;;
        "ssh_key_exists")
            [[ "$APP_LANG" == "en" ]] && echo "SSH key already exists" || echo "La clave SSH ya existe"
            ;;
        "network_test_title")
            [[ "$APP_LANG" == "en" ]] && echo "NETWORK CONNECTIVITY TEST" || echo "PRUEBA DE CONECTIVIDAD DE RED"
            ;;
        "network_segment")
            [[ "$APP_LANG" == "en" ]] && echo "Network segment:" || echo "Segmento de red:"
            ;;
        "network_host_check")
            [[ "$APP_LANG" == "en" ]] && echo "Host to check:" || echo "Host a verificar:"
            ;;
        "security_credentials_stored")
            [[ "$APP_LANG" == "en" ]] && echo "Credentials stored securely in encrypted format." || echo "Credenciales almacenadas de forma segura en formato cifrado."
            ;;
        "security_env_auto")
            [[ "$APP_LANG" == "en" ]] && echo "Environment variables configured automatically." || echo "Variables de entorno configuradas automáticamente."
            ;;
        # Menú y Configuración / Menu and Configuration
        "menu_config_view")
            [[ "$APP_LANG" == "en" ]] && echo "VIEW FULL CONFIGURATION" || echo "VER CONFIGURACIÓN COMPLETA"
            ;;
        "menu_config_reset")
            [[ "$APP_LANG" == "en" ]] && echo "RESET CONFIGURATION" || echo "RESETEAR CONFIGURACIÓN"
            ;;
        "config_installation")
            [[ "$APP_LANG" == "en" ]] && echo "INSTALLATION" || echo "INSTALACIÓN"
            ;;
        "config_bacula_installed")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula installed" || echo "Bacula instalado"
            ;;
        "config_version")
            [[ "$APP_LANG" == "en" ]] && echo "Version" || echo "Versión"
            ;;
        "config_configured")
            [[ "$APP_LANG" == "en" ]] && echo "Configured" || echo "Configurado"
            ;;
        "config_services")
            [[ "$APP_LANG" == "en" ]] && echo "SERVICES" || echo "SERVICIOS"
            ;;
        "running")
            [[ "$APP_LANG" == "en" ]] && echo "Running" || echo "Ejecutándose"
            ;;
        "stopped")
            [[ "$APP_LANG" == "en" ]] && echo "Stopped" || echo "Detenido"
            ;;
        "config_local")
            [[ "$APP_LANG" == "en" ]] && echo "LOCAL CONFIGURATION" || echo "CONFIGURACIÓN LOCAL"
            ;;
        "config_director_name")
            [[ "$APP_LANG" == "en" ]] && echo "Director name" || echo "Nombre del Director"
            ;;
        "config_backup_path")
            [[ "$APP_LANG" == "en" ]] && echo "Backup path" || echo "Ruta de respaldos"
            ;;
        "config_retention")
            [[ "$APP_LANG" == "en" ]] && echo "Retention" || echo "Retención"
            ;;
        "days")
            [[ "$APP_LANG" == "en" ]] && echo "days" || echo "días"
            ;;
        "config_compression")
            [[ "$APP_LANG" == "en" ]] && echo "Compression" || echo "Compresión"
            ;;
        "config_backup_type")
            [[ "$APP_LANG" == "en" ]] && echo "Backup type" || echo "Tipo de respaldo"
            ;;
        "config_not_configured")
            [[ "$APP_LANG" == "en" ]] && echo "Not configured" || echo "No configurado"
            ;;
        "config_remote")
            [[ "$APP_LANG" == "en" ]] && echo "REMOTE CONFIGURATION" || echo "CONFIGURACIÓN REMOTA"
            ;;
        "config_remote_enabled")
            [[ "$APP_LANG" == "en" ]] && echo "Remote backup enabled" || echo "Respaldo remoto habilitado"
            ;;
        "config_remote_host")
            [[ "$APP_LANG" == "en" ]] && echo "Remote host" || echo "Host remoto"
            ;;
        "config_remote_user")
            [[ "$APP_LANG" == "en" ]] && echo "Remote user" || echo "Usuario remoto"
            ;;
        "config_connection_type")
            [[ "$APP_LANG" == "en" ]] && echo "Connection type" || echo "Tipo de conexión"
            ;;
        "config_remote_path")
            [[ "$APP_LANG" == "en" ]] && echo "Remote path" || echo "Ruta remota"
            ;;
        "config_ssh_key")
            [[ "$APP_LANG" == "en" ]] && echo "SSH key" || echo "Clave SSH"
            ;;
        "config_connection_status")
            [[ "$APP_LANG" == "en" ]] && echo "Connection status" || echo "Estado de conexión"
            ;;
        "connected")
            [[ "$APP_LANG" == "en" ]] && echo "Connected" || echo "Conectado"
            ;;
        "disconnected")
            [[ "$APP_LANG" == "en" ]] && echo "Disconnected" || echo "Desconectado"
            ;;
        "config_remote_not_configured")
            [[ "$APP_LANG" == "en" ]] && echo "Remote backup not configured" || echo "Respaldo remoto no configurado"
            ;;
        "config_storage")
            [[ "$APP_LANG" == "en" ]] && echo "STORAGE" || echo "ALMACENAMIENTO"
            ;;
        "config_available")
            [[ "$APP_LANG" == "en" ]] && echo "Available space" || echo "Espacio disponible"
            ;;
        "config_used")
            [[ "$APP_LANG" == "en" ]] && echo "Used space" || echo "Espacio usado"
            ;;
        "config_total_volumes")
            [[ "$APP_LANG" == "en" ]] && echo "Total volumes" || echo "Volúmenes totales"
            ;;
        # PostgreSQL / PostgreSQL
        "checking_postgresql")
            [[ "$APP_LANG" == "en" ]] && echo "Checking PostgreSQL installation..." || echo "Verificando instalación de PostgreSQL..."
            ;;
        "postgresql_not_installed")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL not installed - safe to proceed" || echo "PostgreSQL no instalado - seguro para continuar"
            ;;
        "postgresql_version")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL version detected:" || echo "Versión PostgreSQL detectada:"
            ;;
        "postgresql_in_use")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL is in use with production databases" || echo "PostgreSQL está en uso con bases de datos de producción"
            ;;
        "postgresql_warning")
            [[ "$APP_LANG" == "en" ]] && echo "Installing Bacula will use existing PostgreSQL instance" || echo "La instalación de Bacula usará la instancia PostgreSQL existente"
            ;;
        "existing_databases")
            [[ "$APP_LANG" == "en" ]] && echo "Existing databases:" || echo "Bases de datos existentes:"
            ;;
        "postgresql_continue")
            [[ "$APP_LANG" == "en" ]] && echo "Continue using existing PostgreSQL?" || echo "¿Continuar usando PostgreSQL existente?"
            ;;
        "postgresql_incompatible")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL compatibility check failed" || echo "Verificación de compatibilidad de PostgreSQL falló"
            ;;
        "postgresql_existing")
            [[ "$APP_LANG" == "en" ]] && echo "Existing PostgreSQL detected:" || echo "PostgreSQL existente detectado:"
            ;;
        "postgresql_strategy")
            [[ "$APP_LANG" == "en" ]] && echo "Using existing PostgreSQL to avoid conflicts" || echo "Usando PostgreSQL existente para evitar conflictos"
            ;;
        "postgresql_not_running")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL service is not running" || echo "El servicio PostgreSQL no está corriendo"
            ;;
        "postgresql_starting")
            [[ "$APP_LANG" == "en" ]] && echo "Starting PostgreSQL service..." || echo "Iniciando servicio PostgreSQL..."
            ;;
        "postgresql_start_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Failed to start PostgreSQL service" || echo "Falló al iniciar el servicio PostgreSQL"
            ;;
        "postgresql_not_ready")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL service not ready after timeout" || echo "Servicio PostgreSQL no listo después del tiempo de espera"
            ;;
        "creating_bacula_db")
            [[ "$APP_LANG" == "en" ]] && echo "Creating Bacula database and user..." || echo "Creando base de datos y usuario Bacula..."
            ;;
        "bacula_user_exists")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula user already exists, updating password..." || echo "Usuario Bacula ya existe, actualizando contraseña..."
            ;;
        "bacula_user_update_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Failed to update Bacula user password" || echo "Falló al actualizar contraseña del usuario Bacula"
            ;;
        "bacula_user_create_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Failed to create Bacula user" || echo "Falló al crear usuario Bacula"
            ;;
        "bacula_db_exists")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula database already exists" || echo "Base de datos Bacula ya existe"
            ;;
        "bacula_db_create_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Failed to create Bacula database" || echo "Falló al crear base de datos Bacula"
            ;;
        "bacula_grant_failed")
            [[ "$APP_LANG" == "en" ]] && echo "Failed to grant privileges to Bacula user" || echo "Falló al otorgar privilegios al usuario Bacula"
            ;;
        "bacula_db_configured")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula database configured successfully" || echo "Base de datos Bacula configurada exitosamente"
            ;;
        "postgresql_version_incompatible")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL version incompatible:" || echo "Versión PostgreSQL incompatible:"
            ;;
        "postgresql_min_version_required")
            [[ "$APP_LANG" == "en" ]] && echo "Minimum required version:" || echo "Versión mínima requerida:"
            ;;
        "postgresql_upgrade_required")
            [[ "$APP_LANG" == "en" ]] && echo "Please upgrade PostgreSQL to continue" || echo "Por favor actualice PostgreSQL para continuar"
            ;;
        "postgresql_version_compatible")
            [[ "$APP_LANG" == "en" ]] && echo "PostgreSQL version compatible:" || echo "Versión PostgreSQL compatible:"
            ;;
        "installing_postgresql_version")
            [[ "$APP_LANG" == "en" ]] && echo "Installing PostgreSQL package:" || echo "Instalando paquete PostgreSQL:"
            ;;
        "ask_time")
            [[ "$APP_LANG" == "en" ]] && echo "Enter backup time (HH:MM):" || echo "Ingrese la hora del respaldo (HH:MM):"
            ;;
        "ask_strategy")
            [[ "$APP_LANG" == "en" ]] && echo "Backup strategy:" || echo "Estrategia de respaldo:"
            ;;
        "strategy_inc")
            [[ "$APP_LANG" == "en" ]] && echo "Incremental daily (Fastest)" || echo "Incremental diario (Más rápido)"
            ;;
        "strategy_full")
            [[ "$APP_LANG" == "en" ]] && echo "Full daily (Safest, slow)" || echo "Completo diario (Más seguro, lento)"
            ;;
        "strategy_mixed")
            [[ "$APP_LANG" == "en" ]] && echo "Mixed: Full on Sundays, Incremental daily" || echo "Mixto: Completo los domingos, Incremental diario (Recomendado)"
            ;;
        "ask_storage")
            [[ "$APP_LANG" == "en" ]] && echo "Storage destination:" || echo "Destino de almacenamiento:"
            ;;
        "storage_local")
            [[ "$APP_LANG" == "en" ]] && echo "Local storage" || echo "Almacenamiento local"
            ;;
        "storage_remote")
            [[ "$APP_LANG" == "en" ]] && echo "Remote storage (if configured)" || echo "Almacenamiento remoto (si está configurado)"
            ;;
        # Reset / Resetear
        "reset_warning")
            [[ "$APP_LANG" == "en" ]] && echo "WARNING: This will delete configuration data!" || echo "ADVERTENCIA: ¡Esto eliminará datos de configuración!"
            ;;
        "reset_local")
            [[ "$APP_LANG" == "en" ]] && echo "Reset local Bacula configuration" || echo "Resetear configuración local de Bacula"
            ;;
        "reset_remote")
            [[ "$APP_LANG" == "en" ]] && echo "Reset remote configuration" || echo "Resetear configuración remota"
            ;;
        "reset_ssh_keys")
            [[ "$APP_LANG" == "en" ]] && echo "Reset SSH keys" || echo "Resetear claves SSH"
            ;;
        "reset_logs")
            [[ "$APP_LANG" == "en" ]] && echo "Clear all logs" || echo "Borrar todos los logs"
            ;;
        "reset_all")
            [[ "$APP_LANG" == "en" ]] && echo "RESET EVERYTHING" || echo "RESETEAR TODO"
            ;;
        "confirm_reset_local")
            [[ "$APP_LANG" == "en" ]] && echo "Reset local configuration? This will stop services and delete config files." || echo "¿Resetear configuración local? Esto detendrá servicios y eliminará archivos de configuración."
            ;;
        "confirm_reset_remote")
            [[ "$APP_LANG" == "en" ]] && echo "Reset remote configuration? This will disconnect from remote hosts." || echo "¿Resetear configuración remota? Esto desconectará de hosts remotos."
            ;;
        "confirm_reset_ssh")
            [[ "$APP_LANG" == "en" ]] && echo "Reset SSH keys? You will need to reconfigure remote connections." || echo "¿Resetear claves SSH? Necesitará reconfigurar conexiones remotas."
            ;;
        "confirm_reset_logs")
            [[ "$APP_LANG" == "en" ]] && echo "Clear all logs? This cannot be undone." || echo "¿Borrar todos los logs? Esto no se puede deshacer."
            ;;
        "resetting_local")
            [[ "$APP_LANG" == "en" ]] && echo "Resetting local configuration" || echo "Reseteando configuración local"
            ;;
        "resetting_remote")
            [[ "$APP_LANG" == "en" ]] && echo "Resetting remote configuration" || echo "Reseteando configuración remota"
            ;;
        "resetting_ssh")
            [[ "$APP_LANG" == "en" ]] && echo "Resetting SSH keys" || echo "Reseteando claves SSH"
            ;;
        "resetting_logs")
            [[ "$APP_LANG" == "en" ]] && echo "Clearing logs" || echo "Borrando logs"
            ;;
        "resetting_all")
            [[ "$APP_LANG" == "en" ]] && echo "Resetting everything" || echo "Reseteando todo"
            ;;
        "reset_local_complete")
            [[ "$APP_LANG" == "en" ]] && echo "Local configuration reset complete" || echo "Configuración local reseteada completamente"
            ;;
        "reset_remote_complete")
            [[ "$APP_LANG" == "en" ]] && echo "Remote configuration reset complete" || echo "Configuración remota reseteada completamente"
            ;;
        "reset_ssh_complete")
            [[ "$APP_LANG" == "en" ]] && echo "SSH keys reset complete" || echo "Claves SSH reseteadas completamente"
            ;;
        "reset_logs_complete")
            [[ "$APP_LANG" == "en" ]] && echo "Logs cleared" || echo "Logs borrados"
            ;;
        "reset_all_complete")
            [[ "$APP_LANG" == "en" ]] && echo "Complete reset finished" || echo "Reset completo finalizado"
            ;;
        "reset_cancelled")
            [[ "$APP_LANG" == "en" ]] && echo "Reset cancelled" || echo "Reset cancelado"
            ;;
        "backup_saved")
            [[ "$APP_LANG" == "en" ]] && echo "Previous config backed up to" || echo "Configuración anterior respaldada en"
            ;;
        "reinstall_needed")
            [[ "$APP_LANG" == "en" ]] && echo "System needs reinstallation. Run the script again." || echo "El sistema necesita reinstalación. Ejecute el script nuevamente."
            ;;
        # Mensajes Hardcodeados / Hardcoded messages
        "msg_generating_ssh")
            [[ "$APP_LANG" == "en" ]] && echo "Generating SSH key pair (Ed25519)..." || echo "Generando par de claves SSH (Ed25519)..."
            ;;
        "msg_configuring_ssh")
            [[ "$APP_LANG" == "en" ]] && echo "Configuring SSH key authentication..." || echo "Configurando autenticación por clave SSH..."
            ;;
        "msg_host_unreachable")
            [[ "$APP_LANG" == "en" ]] && echo "Host unreachable:" || echo "Host inalcanzable:"
            ;;
        "msg_ssh_configured")
            [[ "$APP_LANG" == "en" ]] && echo "SSH key authentication configured" || echo "Autenticación SSH configurada"
            ;;
        "msg_ssh_failed")
            [[ "$APP_LANG" == "en" ]] && echo "SSH authentication failed" || echo "Autenticación SSH fallida"
            ;;
        "msg_testing_connectivity")
            [[ "$APP_LANG" == "en" ]] && echo "Testing connectivity to" || echo "Probando conectividad a"
            ;;
        "msg_ping_success")
            [[ "$APP_LANG" == "en" ]] && echo "ICMP ping successful" || echo "Ping ICMP exitoso"
            ;;
        "msg_ping_failed")
            [[ "$APP_LANG" == "en" ]] && echo "ICMP ping failed (firewall may block)" || echo "Ping ICMP fallido (firewall puede bloquear)"
            ;;
        "msg_port_reachable")
            [[ "$APP_LANG" == "en" ]] && echo "TCP port reachable" || echo "Puerto TCP alcanzable"
            ;;
        "msg_port_unreachable")
            [[ "$APP_LANG" == "en" ]] && echo "TCP port unreachable" || echo "Puerto TCP inalcanzable"
            ;;
        "msg_check_firewall")
            [[ "$APP_LANG" == "en" ]] && echo "Check: Firewall rules, VLAN routing, network ACLs" || echo "Verifique: Reglas firewall, routing VLAN, ACLs de red"
            ;;
        "msg_bacula_not_installed")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula not installed" || echo "Bacula no instalado"
            ;;
        "msg_starting_services")
            [[ "$APP_LANG" == "en" ]] && echo "Starting Bacula services..." || echo "Iniciando servicios de Bacula..."
            ;;
        "msg_check_logs")
            [[ "$APP_LANG" == "en" ]] && echo "Check logs:" || echo "Verifique logs:"
            ;;
        "msg_restoring")
            [[ "$APP_LANG" == "en" ]] && echo "Restoring..." || echo "Restaurando..."
            ;;
        "msg_files_restored")
            [[ "$APP_LANG" == "en" ]] && echo "Files restored to:" || echo "Archivos restaurados en:"
            ;;
        "msg_service_status")
            [[ "$APP_LANG" == "en" ]] && echo "Service Status:" || echo "Estado de Servicios:"
            ;;
        "msg_running")
            [[ "$APP_LANG" == "en" ]] && echo "Running" || echo "Ejecutándose"
            ;;
        "msg_stopped")
            [[ "$APP_LANG" == "en" ]] && echo "Stopped" || echo "Detenido"
            ;;
        "msg_job_queue")
            [[ "$APP_LANG" == "en" ]] && echo "Job Queue:" || echo "Cola de Trabajos:"
            ;;
        "msg_no_scheduled_jobs")
            [[ "$APP_LANG" == "en" ]] && echo "No scheduled jobs" || echo "No hay trabajos programados"
            ;;
        "msg_log_director")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula Director Log" || echo "Log del Director Bacula"
            ;;
        "msg_log_storage")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula Storage Log" || echo "Log del Storage Bacula"
            ;;
        "msg_log_fd")
            [[ "$APP_LANG" == "en" ]] && echo "Bacula File Daemon Log" || echo "Log del File Daemon Bacula"
            ;;
        "msg_log_manager")
            [[ "$APP_LANG" == "en" ]] && echo "Manager Log" || echo "Log del Gestor"
            ;;
        "msg_log_not_found")
            [[ "$APP_LANG" == "en" ]] && echo "Log file not found" || echo "Archivo de log no encontrado"
            ;;
        "msg_checking_config")
            [[ "$APP_LANG" == "en" ]] && echo "Checking configuration files..." || echo "Verificando archivos de configuración..."
            ;;
        "msg_validating_syntax")
            [[ "$APP_LANG" == "en" ]] && echo "Validating Bacula director syntax..." || echo "Validando sintaxis del Director Bacula..."
            ;;
        "msg_checking_services")
            [[ "$APP_LANG" == "en" ]] && echo "Checking Bacula services..." || echo "Verificando servicios Bacula..."
            ;;
        "msg_testing_db")
            [[ "$APP_LANG" == "en" ]] && echo "Testing database connection..." || echo "Probando conexión a base de datos..."
            ;;
        "msg_checking_storage")
            [[ "$APP_LANG" == "en" ]] && echo "Checking storage space..." || echo "Verificando espacio de almacenamiento..."
            ;;
        "msg_low_space")
            [[ "$APP_LANG" == "en" ]] && echo "Low space" || echo "Poco espacio"
            ;;
        "msg_no_config")
            [[ "$APP_LANG" == "en" ]] && echo "No config" || echo "Sin configuración"
            ;;
        "msg_results")
            [[ "$APP_LANG" == "en" ]] && echo "Results:" || echo "Resultados:"
            ;;
        "msg_passed")
            [[ "$APP_LANG" == "en" ]] && echo "passed" || echo "pasaron"
            ;;
        "msg_failed")
            [[ "$APP_LANG" == "en" ]] && echo "failed" || echo "fallaron"
            ;;
        "msg_processing")
            [[ "$APP_LANG" == "en" ]] && echo "Processing" || echo "Procesando"
            ;;
        "installing")
            [[ "$APP_LANG" == "en" ]] && echo "Installing missing packages" || echo "Instalando paquetes faltantes"
            ;;
        "no_internet")
            [[ "$APP_LANG" == "en" ]] && echo "No internet connectivity detected" || echo "Sin conectividad a internet detectada"
            ;;
        "no_internet_detail")
            [[ "$APP_LANG" == "en" ]] && echo "Cannot download packages. Check your network connection and try again." || echo "No se pueden descargar paquetes. Verifique su conexión de red e intente nuevamente."
            ;;
        "install_offline_tip")
            [[ "$APP_LANG" == "en" ]] && echo "TIP: Run 'sudo apt-get install -f' or reconnect to internet and retry." || echo "TIP: Ejecute 'sudo apt-get install -f' o reconéctese a internet e intente de nuevo."
            ;;
        "checking_connectivity")
            [[ "$APP_LANG" == "en" ]] && echo "Checking internet connectivity..." || echo "Verificando conectividad a internet..."
            ;;
        "connectivity_ok")
            [[ "$APP_LANG" == "en" ]] && echo "Internet connectivity OK" || echo "Conectividad a internet OK"
            ;;
        "install_fix_missing")
            [[ "$APP_LANG" == "en" ]] && echo "Retrying with --fix-missing..." || echo "Reintentando con --fix-missing..."
            ;;
        *)
            echo "$key"

            ;;
    esac
}

# --- Mostrar spinner de progreso / Show progress spinner ---
spinner() {
    local pid="${1:-}"
    local delay=0.1
    local spinstr='|/-\\'
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

# --- Esperar por bloqueos de APT / Wait for APT locks ---
wait_for_package_locks() {
    local max_wait=300
    local waited=0
    local locks=("/var/lib/dpkg/lock-frontend" "/var/lib/apt/lists/lock" "/var/cache/apt/archives/lock")

    for lock in "${locks[@]}"; do
        while [[ -f "$lock" ]] && fuser "$lock" >/dev/null 2>&1; do
            if [[ $waited -eq 0 ]]; then
                [[ "$APP_LANG" == "en" ]] && \
                    echo "Waiting for other package manager processes to finish..." || \
                    echo "Esperando a que otros procesos del gestor de paquetes terminen..."
            fi
            sleep 5
            waited=$((waited + 5))
            if [[ $waited -ge $max_wait ]]; then
                [[ "$APP_LANG" == "en" ]] && \
                    echo "Timeout waiting for package lock: $lock" || \
                    echo "Tiempo de espera agotado. Bloqueo: $lock"
                break
            fi
        done
    done
}

# --- Actualizar caché de repositorios UNA SOLA VEZ / Update repo cache once ---
update_package_cache() {
    local distro="${1:-}"
    [[ -z "$distro" ]] && distro=$(detect_distro)

    echo -e "${COLOR_CYAN}$(t "updating_repos")${COLOR_RESET}"

    case "$distro" in
        debian-family)
            wait_for_package_locks
            # --allow-releaseinfo-change es necesario en Kali rolling y Debian unstable/testing
            if ! DEBIAN_FRONTEND=noninteractive apt-get update --allow-releaseinfo-change -y -qq 2>&1; then
                echo -e "${COLOR_YELLOW}⚠ $(t "warning"): Retrying apt-get update without quiet mode...${COLOR_RESET}"
                DEBIAN_FRONTEND=noninteractive apt-get update --allow-releaseinfo-change -y 2>&1 || {
                    echo -e "${COLOR_RED}✗ ERROR: apt-get update failed.${COLOR_RESET}"
                    if grep -qi "kali" /etc/os-release 2>/dev/null; then
                        echo -e "${COLOR_YELLOW}  TIP (Kali): sudo apt clean && sudo rm -rf /var/lib/apt/lists/* && sudo apt update${COLOR_RESET}"
                    fi
                    return 1
                }
            fi
            ;;
        rhel-family)
            dnf makecache -q 2>/dev/null || true
            ;;
        arch-family)
            pacman -Sy --nocolor --noconfirm >/dev/null 2>&1 || true
            ;;
        suse-family)
            zypper refresh >/dev/null 2>&1 || true
            ;;
    esac
    return 0
}

# --- Verificar conectividad a internet / Check internet connectivity ---
check_internet_connectivity() {
    local timeout=5
    local test_hosts=("8.8.8.8" "1.1.1.1" "9.9.9.9")

    # Método 1: ping a DNS público
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W "$timeout" "$host" >/dev/null 2>&1; then
            return 0
        fi
    done

    # Método 2: TCP a puerto 80/443 (por si ICMP está bloqueado)
    for host in "${test_hosts[@]}"; do
        if timeout "$timeout" bash -c "</dev/tcp/$host/53" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

# --- Instalar paquetes con reintentos / Install packages with retries ---
apt_install_with_retry() {
    local packages=("$@")
    local max_attempts=2

    for attempt in $(seq 1 $max_attempts); do
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
            --no-install-recommends \
            --allow-unauthenticated \
            "${packages[@]}" 2>&1; then
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            echo -e "${COLOR_YELLOW}   $(t "install_fix_missing")${COLOR_RESET}"
            DEBIAN_FRONTEND=noninteractive apt-get install -y --fix-missing \
                --allow-unauthenticated \
                "${packages[@]}" 2>&1 && return 0
        fi
    done

    return 1
}


# --- Barra de progreso / Progress bar ---
progress_bar() {
    local current="${1:-0}"
    local total="${2:-100}"
    local width=50
    local percentage=$((current * 100 / total))
    local filled=$((width * current / total))
    local empty=$((width - filled))
    
    printf "\r[" 
    printf "%${filled}s" | tr ' ' '█'
    printf "%${empty}s" | tr ' ' '░'
    printf "] %3d%%" "$percentage"
}

# --- Validar contraseña / Validate password ---
validate_password() {
    local password="${1:-}"
    local length=${#password}
    
    # Verificar longitud mínima
    if [[ $length -lt 8 ]]; then
        return 1
    fi
    
    # Verificar mayúsculas
    if ! [[ "$password" =~ [A-Z] ]]; then
        return 1
    fi
    
    # Verificar minúsculas
    if ! [[ "$password" =~ [a-z] ]]; then
        return 1
    fi
    
    # Verificar números
    if ! [[ "$password" =~ [0-9] ]]; then
        return 1
    fi
    
    # Verificar caracteres especiales (versión segura)
    if [[ "$password" != *'!'* && "$password" != *'@'* && "$password" != *'#'* && "$password" != *'$'* && "$password" != *'%'* && "$password" != *'^'* && "$password" != *'&&'* && "$password" != *'('* && "$password" != *')'* && "$password" != *'_'* && "$password" != *'+'* && "$password" != *'-'* && "$password" != *'='* ]]; then
        return 1
    fi
    
    return 0
}

# --- Generar contraseña segura / Generate secure password ---
generate_password() {
    openssl rand -base64 16 | tr -d '=+/'
}

# --- Confirmar acción / Confirm action ---
confirm() {
    local message="${1:-}"
    local response
    
    while true; do
        read -rp "$(echo -e "${COLOR_YELLOW}$message [S/n]: ${COLOR_RESET}")" response
        case "$response" in
            [Ss]*|"") return 0 ;;
            [Nn]*) return 1 ;;
            *) 
                if [[ "$APP_LANG" == "en" ]]; then
                    echo "Please answer yes or no"
                else
                    echo "Por favor responda sí o no"
                fi
                ;;
        esac
    done
}

# =============================================================================
# FUNCIONES DE INSTALACIÓN / INSTALLATION FUNCTIONS
# =============================================================================

# --- Detectar distribución / Detect distribution ---
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        # Primero intentamos clasificar por familia basándonos en ID e ID_LIKE
        if [[ "$ID" =~ ^(debian|ubuntu|kali|linuxmint|pop|mx|raspbian|neon|parrot|deepin)$ ]] || [[ "${ID_LIKE:-}" =~ (debian|ubuntu) ]]; then
            echo "debian-family"
        elif [[ "$ID" =~ ^(rhel|centos|fedora|rocky|almalinux|oracle|amazon|scientific)$ ]] || [[ "${ID_LIKE:-}" =~ (rhel|fedora|centos) ]]; then
            echo "rhel-family"
        elif [[ "$ID" =~ ^(arch|manjaro|endeavouros|garuda)$ ]] || [[ "${ID_LIKE:-}" =~ (arch) ]]; then
            echo "arch-family"
        elif [[ "$ID" =~ ^(suse|opensuse|tumbleweed|leap)$ ]] || [[ "${ID_LIKE:-}" =~ (suse) ]]; then
            echo "suse-family"
        elif [[ "$ID" == "alpine" ]]; then
            echo "alpine-family"
        else
            # Si no se detecta familia, devolver el ID original
            echo "$ID"
        fi
    elif [[ -f /etc/debian_version ]]; then
        echo "debian-family"
    elif [[ -f /etc/redhat-release ]]; then
        echo "rhel-family"
    else
        echo "unknown"
    fi
}

# --- Detectar versión PostgreSQL / Detect PostgreSQL version ---
detect_postgresql_version() {
    if command -v psql &> /dev/null; then
        local version
        version=$(psql --version 2>/dev/null | awk '{print $3}' | cut -d. -f1-2)
        echo "$version"
    else
        echo "not_installed"
    fi
}

# --- Verificar si PostgreSQL está en uso / Check if PostgreSQL is in use ---
is_postgresql_in_use() {
    # Verificar si hay procesos PostgreSQL corriendo
    if pgrep -x "postgres" > /dev/null 2>&1; then
        # Verificar si hay bases de datos existentes (excepto las del sistema)
        local db_count
        db_count=$(su - postgres -c "psql -tAc \"SELECT count(*) FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres')\"" 2>/dev/null || echo "0")
        if [[ $db_count -gt 0 ]]; then
            return 0  # Hay bases de datos en producción
        fi
    fi
    return 1  # No hay PostgreSQL en uso o solo bases del sistema
}

# --- Verificar compatibilidad PostgreSQL / Check PostgreSQL compatibility ---
check_postgresql_compatibility() {
    local current_version
    current_version=$(detect_postgresql_version)
    
    echo -e "${COLOR_CYAN}$(t "checking_postgresql")${COLOR_RESET}"
    
    if [[ "$current_version" == "not_installed" ]]; then
        echo -e "   ${COLOR_GREEN}✓ $(t "postgresql_not_installed")${COLOR_RESET}"
        return 0
    fi
    
    echo -e "   ${COLOR_INFO}$(t "postgresql_version") $current_version${COLOR_RESET}"
    
    # Verificar versión mínima compatible (PostgreSQL 9+)
    local major_version
    major_version=$(echo "$current_version" | cut -d. -f1)
    
    if [[ $major_version -lt 9 ]]; then
        echo -e "   ${COLOR_RED}✗ $(t "postgresql_version_incompatible") $current_version${COLOR_RESET}"
        echo -e "   ${COLOR_YELLOW}  $(t "postgresql_min_version_required") 9.x${COLOR_RESET}"
        echo -e "   ${COLOR_YELLOW}  $(t "postgresql_upgrade_required")${COLOR_RESET}"
        return 1
    fi
    
    echo -e "   ${COLOR_GREEN}✓ $(t "postgresql_version_compatible") $current_version${COLOR_RESET}"
    
    if is_postgresql_in_use; then
        echo -e "   ${COLOR_YELLOW}⚠ $(t "postgresql_in_use")${COLOR_RESET}"
        echo -e "   ${COLOR_YELLOW}  $(t "postgresql_warning")${COLOR_RESET}"
        
        # Mostrar bases de datos existentes
        echo -e "   ${COLOR_INFO}$(t "existing_databases")${COLOR_RESET}"
        su - postgres -c "psql -tAc \"SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1', 'postgres') ORDER BY datname\"" 2>/dev/null | while read -r db; do
            echo -e "     - ${COLOR_CYAN}$db${COLOR_RESET}"
        done
        
        echo ""
        if ! confirm "$(t "postgresql_continue")"; then
            return 1
        fi
    fi
    
    return 0
}

# --- Verificar si Bacula está instalado / Check if Bacula is installed ---
is_bacula_installed() {
    # Verificar múltiples posibles nombres de comandos según la distro
    local has_director=false
    local has_storage=false
    local has_client=false
    
    # Verificar director (varios nombres posibles)
    if command -v bacula-dir &> /dev/null || \
       command -v bacula-director &> /dev/null || \
       command -v bacula-dir-sqlite3 &> /dev/null || \
       command -v bacula-dir-postgresql &> /dev/null; then
        has_director=true
    fi
    
    # Verificar storage daemon
    if command -v bacula-sd &> /dev/null || \
       command -v bacula-storage &> /dev/null; then
        has_storage=true
    fi
    
    # Verificar file daemon (cliente)
    if command -v bacula-fd &> /dev/null || \
       command -v bacula-client &> /dev/null || \
       command -v bacula-fd-sqlite3 &> /dev/null; then
        has_client=true
    fi
    
    # También verificar si existe el archivo de configuración
    if [[ -f /etc/bacula/bacula-dir.conf ]] && \
       [[ -f /etc/bacula/bacula-sd.conf ]] && \
       [[ -f /etc/bacula/bacula-fd.conf ]]; then
        # Si existen configs, considerar instalado aunque los comandos tengan nombres diferentes
        return 0
    fi
    
    if [[ "$has_director" == true ]] && [[ "$has_storage" == true ]] && [[ "$has_client" == true ]]; then
        return 0
    fi
    
    return 1
}

# --- Instalar Bacula / Install Bacula ---
install_bacula() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "install_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    log_message "INFO" "Starting Bacula installation"
    
    if is_bacula_installed; then
        echo -e "${COLOR_GREEN}✓ $(t "already_installed")${COLOR_RESET}"
        log_message "INFO" "Bacula already installed"
        sleep 2
        return 0
    fi
    
    local distro
    distro=$(detect_distro)
    
    # Verificar compatibilidad PostgreSQL antes de instalar
    if ! check_postgresql_compatibility; then
        echo -e "${COLOR_RED}✗ $(t "postgresql_incompatible")${COLOR_RESET}"
        log_message "ERROR" "PostgreSQL compatibility check failed"
        return 1
    fi
    
    echo -e "${COLOR_CYAN}$(t "checking_deps")${COLOR_RESET}"
    
    # Verificar dependencias esenciales / Check essential dependencies
    local deps=("wget" "curl" "openssl")
    
    # Solo agregar PostgreSQL si no está instalado
    if [[ "$(detect_postgresql_version)" == "not_installed" ]]; then
        case "$distro" in
            debian-family) deps+=("postgresql" "postgresql-contrib") ;;
            rhel-family) deps+=("postgresql-server" "postgresql-contrib") ;;
            arch-family) deps+=("postgresql") ;;
            suse-family) deps+=("postgresql-server") ;;
        esac
    fi
    
    local missing_deps=()
    for dep in "${deps[@]}"; do
        local installed=false
        case "$distro" in
            debian-family) dpkg -l | grep -q "^ii  $dep " 2>/dev/null && installed=true ;;
            rhel-family|suse-family) rpm -q "$dep" &>/dev/null && installed=true ;;
            arch-family) pacman -Qs "^$dep$" &>/dev/null && installed=true ;;
            *) command -v "$dep" &>/dev/null && installed=true ;;
        esac
        [[ "$installed" == false ]] && missing_deps+=("$dep")
    done
    
    # ── Verificar conectividad ANTES de intentar descargas ──────────────────
    echo -e "${COLOR_CYAN}$(t "checking_connectivity")${COLOR_RESET}"
    local has_internet=true
    if ! check_internet_connectivity; then
        has_internet=false
        echo -e "${COLOR_YELLOW}⚠ $(t "no_internet")${COLOR_RESET}"
        echo -e "  ${COLOR_YELLOW}$(t "no_internet_detail")${COLOR_RESET}"
        echo -e "  ${COLOR_DIM}$(t "install_offline_tip")${COLOR_RESET}"
        echo ""
        if ! confirm "¿Intentar instalar de todas formas con caché local? / Try with local cache anyway?"; then
            echo -e "${COLOR_YELLOW}Instalación cancelada por falta de conectividad.${COLOR_RESET}"
            log_message "WARN" "Installation cancelled: no internet connectivity"
            read -rp "$(t "press_continue")"
            return 1
        fi
    else
        echo -e "  ${COLOR_GREEN}✓ $(t "connectivity_ok")${COLOR_RESET}"
    fi
    echo ""

    # ── Actualizar índice de repositorios ───────────────────────────────────
    # Los warnings de repos caídos (W:) son normales y no deben bloquear la instalación
    if [[ "$has_internet" == true ]]; then
        update_package_cache "$distro" || {
            echo -e "${COLOR_YELLOW}⚠ $(t "updating_repos") falló parcialmente, continuando con caché existente...${COLOR_RESET}"
        }
    fi

    # ── Instalar dependencias faltantes ─────────────────────────────────────
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${COLOR_YELLOW}⚠ $(t "installing"): ${missing_deps[*]}${COLOR_RESET}"
        (
            case "$distro" in
                debian-family) apt_install_with_retry "${missing_deps[@]}" ;;
                rhel-family)   dnf install -y -q "${missing_deps[@]}" ;;
                arch-family)   pacman -S --nocolor --noconfirm "${missing_deps[@]}" ;;
                suse-family)   zypper install -y "${missing_deps[@]}" ;;
            esac
        ) &
        spinner $!
        wait $! || echo -e "  ${COLOR_YELLOW}⚠ Algunas dependencias opcionales no se pudieron instalar, continuando...${COLOR_RESET}"
    fi

    # ── Instalar Bacula ──────────────────────────────────────────────────────
    echo -e "${COLOR_CYAN}$(t "installing_bacula")${COLOR_RESET}"

    case "$distro" in
        debian-family)
            local pg_version
            pg_version=$(detect_postgresql_version)

            local bacula_pkgs=(bacula-director bacula-sd bacula-fd bacula-console)

            if [[ "$pg_version" != "not_installed" ]]; then
                echo -e "   ${COLOR_YELLOW}⚠ $(t "postgresql_existing") $pg_version${COLOR_RESET}"
                echo -e "   ${COLOR_INFO}$(t "postgresql_strategy")${COLOR_RESET}"
                # PostgreSQL ya existe — solo instalar componentes de Bacula sin traer PG nuevo
            else
                bacula_pkgs+=(postgresql)
            fi

            (
                export DEBIAN_FRONTEND=noninteractive
                apt_install_with_retry "${bacula_pkgs[@]}"
            ) &
            spinner $!
            wait $! || {
                echo -e "${COLOR_RED}✗ $(t "install_error")${COLOR_RESET}"
                echo -e "  ${COLOR_YELLOW}$(t "no_internet_detail")${COLOR_RESET}"
                echo -e "  ${COLOR_YELLOW}$(t "install_offline_tip")${COLOR_RESET}"
                read -rp "$(t "press_continue")"
                return 1
            }
            ;;
        rhel-family)
            local pg_version
            pg_version=$(detect_postgresql_version)
            local bacula_pkgs_rhel=(bacula-director bacula-sd bacula-client bacula-console)
            if [[ "$pg_version" == "not_installed" ]]; then
                bacula_pkgs_rhel+=(postgresql-server)
            fi
            (
                dnf install -y -q "${bacula_pkgs_rhel[@]}"
                if [[ "$pg_version" == "not_installed" ]]; then
                    postgresql-setup --initdb 2>/dev/null || true
                    systemctl enable --now postgresql
                fi
            ) &
            spinner $!
            wait $! || {
                echo -e "${COLOR_RED}✗ $(t "install_error")${COLOR_RESET}"
                read -rp "$(t "press_continue")"
                return 1
            }
            ;;
        arch-family)
            echo -e "   ${COLOR_INFO}Installing Bacula via Pacman...${COLOR_RESET}"
            ( pacman -S --noconfirm --needed bacula-dir bacula-sd bacula-fd bacula-console ) &
            spinner $!
            wait $! || { echo -e "${COLOR_RED}✗ $(t "install_error")${COLOR_RESET}"; read -rp "$(t "press_continue")"; return 1; }
            ;;
        suse-family)
            echo -e "   ${COLOR_INFO}Installing Bacula via Zypper...${COLOR_RESET}"
            ( zypper install -y bacula-director bacula-sd-mysql bacula-fd bacula-console ) &
            spinner $!
            wait $! || { echo -e "${COLOR_RED}✗ $(t "install_error")${COLOR_RESET}"; read -rp "$(t "press_continue")"; return 1; }
            ;;
        *)
            echo -e "${COLOR_RED}✗ Distribución no soportada: $distro${COLOR_RESET}"
            echo -e "  ${COLOR_YELLOW}Distribuciones soportadas: Debian, Ubuntu, Kali, RHEL, CentOS, Fedora, Arch, openSUSE${COLOR_RESET}"
            read -rp "$(t "press_continue")"
            return 1
            ;;
    esac

    
    # Configurar PostgreSQL para Bacula / Configure PostgreSQL for Bacula
    setup_bacula_database &
    spinner $!
    wait $!
    
    # Iniciar servicios / Start services - intentar múltiples nombres
    systemctl daemon-reload 2>/dev/null || true
    
    echo -e "${COLOR_CYAN}Starting Bacula services...${COLOR_RESET}"
    
    # Habilitar servicios (intentar con nombres estándar primero)
    systemctl enable bacula-dir bacula-sd bacula-fd 2>/dev/null || \
    systemctl enable bacula-director bacula-sd bacula-client 2>/dev/null || true
    
    # Iniciar servicios
    if systemctl start bacula-dir bacula-sd bacula-fd 2>/dev/null; then
        echo -e "  ${COLOR_GREEN}✓ Services started (standard names)${COLOR_RESET}"
    elif systemctl start bacula-director bacula-sd bacula-client 2>/dev/null; then
        echo -e "  ${COLOR_GREEN}✓ Services started (alternative names)${COLOR_RESET}"
    else
        echo -e "  ${COLOR_YELLOW}⚠ Some services failed to start${COLOR_RESET}"
        # Intentar individualmente
        for svc in bacula-dir bacula-director; do
            if systemctl is-enabled "$svc" 2>/dev/null; then
                systemctl start "$svc" 2>/dev/null && echo -e "    ${COLOR_GREEN}✓ $svc started${COLOR_RESET}"
            fi
        done
        systemctl start bacula-sd 2>/dev/null && echo -e "    ${COLOR_GREEN}✓ bacula-sd started${COLOR_RESET}"
        for svc in bacula-fd bacula-client; do
            if systemctl is-enabled "$svc" 2>/dev/null; then
                systemctl start "$svc" 2>/dev/null && echo -e "    ${COLOR_GREEN}✓ $svc started${COLOR_RESET}"
            fi
        done
    fi
    
    echo ""
    echo -e "${COLOR_GREEN}✓ $(t "install_success")${COLOR_RESET}"
    log_message "INFO" "Bacula installation completed"
    
    sleep 2
}

setup_bacula_database() {
    local db_password
    db_password=$(generate_password)
    
    # Verificar si PostgreSQL está corriendo
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        echo -e "   ${COLOR_YELLOW}⚠ $(t "postgresql_not_running")${COLOR_RESET}"
        echo -e "   ${COLOR_INFO}$(t "postgresql_starting")${COLOR_RESET}"
        systemctl start postgresql || {
            echo -e "   ${COLOR_RED}✗ $(t "postgresql_start_failed")${COLOR_RESET}"
            return 1
        }
    fi
    
    # Esperar a que PostgreSQL esté completamente disponible
    local max_attempts=30
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        if su - postgres -c "pg_isready -q" 2>/dev/null; then
            break
        fi
        sleep 1
        ((attempt++))
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        echo -e "   ${COLOR_RED}✗ $(t "postgresql_not_ready")${COLOR_RESET}"
        return 1
    fi
    
    # Crear usuario y base de datos con manejo de errores mejorado
    echo -e "   ${COLOR_INFO}$(t "creating_bacula_db")${COLOR_RESET}"
    
    # Verificar si el usuario ya existe
    if su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='bacula'\"" 2>/dev/null | grep -q 1; then
        echo -e "   ${COLOR_YELLOW}⚠ $(t "bacula_user_exists")${COLOR_RESET}"
        # Generar nueva contraseña para usuario existente
        su - postgres -c "psql -c \"ALTER USER bacula WITH PASSWORD '${db_password}';\"" 2>/dev/null || {
            echo -e "   ${COLOR_RED}✗ $(t "bacula_user_update_failed")${COLOR_RESET}"
            return 1
        }
    else
        # Crear nuevo usuario
        su - postgres -c "psql -c \"CREATE USER bacula WITH PASSWORD '${db_password}';\"" 2>/dev/null || {
            echo -e "   ${COLOR_RED}✗ $(t "bacula_user_create_failed")${COLOR_RESET}"
            return 1
        }
    fi
    
    # Verificar si la base de datos ya existe
    if su - postgres -c "psql -lqt" 2>/dev/null | cut -d \| -f1 | grep -qw bacula; then
        echo -e "   ${COLOR_YELLOW}⚠ $(t "bacula_db_exists")${COLOR_RESET}"
    else
        # Crear base de datos
        su - postgres -c "psql -c \"CREATE DATABASE bacula OWNER bacula;\"" 2>/dev/null || {
            echo -e "   ${COLOR_RED}✗ $(t "bacula_db_create_failed")${COLOR_RESET}"
            return 1
        }
    fi
    
    # Asegurar permisos
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE bacula TO bacula;\"" 2>/dev/null || {
        echo -e "   ${COLOR_RED}✗ $(t "bacula_grant_failed")${COLOR_RESET}"
        return 1
    }
    
    # Guardar credenciales / Save credentials
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    
    cat > "$CONFIG_DIR/db_credentials.conf" << EOF
DB_NAME=bacula
DB_USER=bacula
DB_PASSWORD=$db_password
DB_HOST=localhost
DB_PORT=5432
EOF
    chmod 600 "$CONFIG_DIR/db_credentials.conf"
    
    # Actualizar configuración Bacula / Update Bacula config
    sed -i 's/dbname = .*/dbname = "bacula"/g' /etc/bacula/bacula-dir.conf 2>/dev/null || true
    sed -i 's/dbuser = .*/dbuser = "bacula"/g' /etc/bacula/bacula-dir.conf 2>/dev/null || true
    sed -i "s/dbpassword = .*/dbpassword = \"$db_password\"/g" /etc/bacula/bacula-dir.conf 2>/dev/null || true
    
    echo -e "   ${COLOR_GREEN}✓ $(t "bacula_db_configured")${COLOR_RESET}"
}

# =============================================================================
# FUNCIONES DE CONFIGURACIÓN MÚLTIPLE / MULTI-BACKUP CONFIGURATION FUNCTIONS
# =============================================================================

# --- Crear nuevo Job de respaldo / Create new backup job ---
create_backup_job() {
    local job_name="${1:-}"
    local job_description="${2:-}"
    local backup_path="${3:-}"
    local schedule_type="${4:-}"
    local retention="${5:-}"
    local include_paths=(${@:6})
    
    echo -e "${COLOR_BOLD}${COLOR_GREEN}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  CREATE NEW BACKUP JOB / CREAR NUEVO JOB DE RESPALDO${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_GREEN}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    # Validar nombre del job
    if [[ -z "$job_name" ]]; then
        echo -e "${COLOR_BOLD}Job Name / Nombre del Job:${COLOR_RESET}"
        read -rp "   $(t "select_option"): " job_name
        [[ -z "$job_name" ]] && job_name="BackupJob$(date +%H%M%S)"
    fi
    
    # Validar que el nombre no exista (verificar archivo primero)
    if [[ -f /etc/bacula/bacula-dir.conf ]] && grep -q "Name = \"$job_name\"" /etc/bacula/bacula-dir.conf 2>/dev/null; then
        echo -e "${COLOR_RED}✗ Job '$job_name' already exists!${COLOR_RESET}"
        return 1
    fi
    
    # Descripción
    if [[ -z "$job_description" ]]; then
        echo -e "${COLOR_BOLD}Job Description / Descripción del Job:${COLOR_RESET}"
        read -rp "   $(t "select_option"): " job_description
        [[ -z "$job_description" ]] && job_description="Backup job created on $(date)"
    fi
    
    # Ruta de respaldo
    if [[ -z "$backup_path" ]]; then
        echo -e "${COLOR_BOLD}Backup Path / Ruta de Respaldo:${COLOR_RESET}"
        backup_path=$(read_line_edit "   $(t "select_option")" "/backups")
        backup_path=${backup_path:-/backups}
    fi
    
    # Crear directorio si no existe
    if [[ ! -d "$backup_path" ]]; then
        mkdir -p "$backup_path"
        chmod 750 "$backup_path"
        chown root:bacula "$backup_path"
    fi
    
    # Tipo de respaldo (qué respaldar)
    echo -e "${COLOR_BOLD}What to backup / ¿Qué desea respaldar:${COLOR_RESET}"
    echo "   1) $(t "option_system")"
    echo "   2) $(t "option_home")"
    echo "   3) $(t "option_custom")"
    echo "   4) $(t "option_databases")"
    
    local job_include_paths=()
    local job_exclude_paths=()
    
    while true; do
        backup_type=$(read_menu_choice "   $(t "select_option")" 1 4 1)
        case $backup_type in
            1)
                job_include_paths=("/etc" "/home" "/var/www" "/usr/local")
                job_exclude_paths=("/proc" "/sys" "/dev" "/run" "/tmp")
                break
                ;;
            2)
                job_include_paths=("/home")
                job_exclude_paths=()
                break
                ;;
            3)
                echo -e "   ${COLOR_CYAN}Enter directories to backup (one per line, empty to finish):${COLOR_RESET}"
                while true; do
                    custom_path=$(read_line_edit "   Path")
                    [[ -z "$custom_path" ]] && break
                    if [[ -d "$custom_path" ]]; then
                        job_include_paths+=("$custom_path")
                        echo -e "   ${COLOR_GREEN}✓ Added${COLOR_RESET}"
                    else
                        echo -e "   ${COLOR_RED}✗ Directory not found${COLOR_RESET}"
                    fi
                done
                break
                ;;
            4)
                configure_database_backup
                job_include_paths=("/var/lib/postgresql" "/var/lib/mysql" "/etc/mysql" "/etc/postgresql")
                job_exclude_paths=()
                break
                ;;
            *)
                echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}"
                ;;
        esac
    done
    
    # Horario y Estrategia
    local backup_time="02:00"
    local strategy_type="3"
    
    echo -e "${COLOR_BOLD}$(t "ask_time")${COLOR_RESET}"
    read -rp "   [00:00 - 23:59] [$backup_time]: " input_time
    [[ -n "$input_time" ]] && backup_time="$input_time"
    
    # Validar formato HH:MM
    if ! [[ "$backup_time" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        echo -e "   ${COLOR_YELLOW}⚠ Invalid format, using 02:00${COLOR_RESET}"
        backup_time="02:00"
    fi

    echo -e "${COLOR_BOLD}$(t "ask_strategy")${COLOR_RESET}"
    echo "   1) $(t "strategy_inc")"
    echo "   2) $(t "strategy_full")"
    echo "   3) $(t "strategy_mixed")"
    
    while true; do
        strategy_type=$(read_menu_choice "   $(t "select_option")" 1 3 3)
        case "$strategy_type" in
            1|2|3) break ;;
            *) echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}" ;;
        esac
    done

    # Destino de almacenamiento
    local storage_target="local"
    if [[ -f "$REMOTE_CONFIG_DIR/active.conf" ]]; then
        echo -e "${COLOR_BOLD}$(t "ask_storage")${COLOR_RESET}"
        echo "   1) $(t "storage_local")"
        echo "   2) $(t "storage_remote")"
        read -rp "   $(t "select_option") [1-2]: " storage_choice
        [[ "$storage_choice" == "2" ]] && storage_target="remote"
    fi
    
    # Retención
    if [[ -z "$retention" ]]; then
        echo -e "${COLOR_BOLD}Retention / Retención:${COLOR_RESET}"
        echo "   1) $(t "option_30days")"
        echo "   2) $(t "option_90days")"
        echo "   3) $(t "option_1year")"
        echo "   4) $(t "option_forever")"
        
        while true; do
            retention=$(read_menu_choice "   $(t "select_option")" 1 4 1)
            case $retention in
                1|2|3|4) break ;;
                *) echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}" ;;
            esac
        done
    fi
    
    # Guardar configuración del job
    save_job_config "$job_name" "$job_description" "$backup_path" "$schedule_type" "$retention" "$backup_time" "$strategy_type" "$storage_target" "${job_include_paths[@]}"
    
    # Agregar job a la configuración de Bacula
    add_job_to_bacula_config "$job_name" "$job_description" "$backup_path" "$schedule_type" "$retention" "$backup_time" "$strategy_type" "$storage_target" "${job_include_paths[@]}"
    
    echo -e "${COLOR_GREEN}✓ Backup job '$job_name' created successfully!${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}Description: $job_description${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}Time: $backup_time${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}Strategy: $strategy_type${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}Storage: $storage_target${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}Retention: $(get_retention_description "$retention")${COLOR_RESET}"
    
    log_message "INFO" "Backup job created: $job_name"
    
    read -rp "$(t "press_continue")"
}

# --- Guardar configuración de job / Save job configuration ---
save_job_config() {
    local job_name="${1:-}"
    local job_description="${2:-}"
    local backup_path="${3:-}"
    local schedule_type="${4:-}"
    local retention="${5:-}"
    local backup_time="${6:-02:00}"
    local strategy_type="${7:-3}"
    local storage_target="${8:-local}"
    shift 8
    local include_paths=("$@")
    
    # Crear directorio de configuración de jobs si no existe
    mkdir -p "$CONFIG_DIR/jobs"
    
    # Guardar configuración del job de forma segura
    {
        echo "JOB_NAME=\"$job_name\""
        echo "JOB_DESCRIPTION=\"$job_description\""
        echo "BACKUP_PATH=\"$backup_path\""
        echo "SCHEDULE_TYPE=\"$schedule_type\""
        echo "RETENTION=\"$retention\""
        echo "BACKUP_TIME=\"$backup_time\""
        echo "STRATEGY_TYPE=\"$strategy_type\""
        echo "STORAGE_TARGET=\"$storage_target\""
        echo -n "INCLUDE_PATHS=("
        for p in "${include_paths[@]}"; do echo -n "\"$p\" "; done
        echo ")"
    } > "$CONFIG_DIR/jobs/${job_name}.conf"
    
    chmod 600 "$CONFIG_DIR/jobs/${job_name}.conf"
}

# --- Agregar job a configuración Bacula / Add job to Bacula configuration ---
add_job_to_bacula_config() {
    local job_name="${1:-}"
    local job_description="${2:-}"
    local backup_path="${3:-}"
    local schedule_type="${4:-}"
    local retention="${5:-}"
    local backup_time="${6:-02:00}"
    local strategy_type="${7:-3}"
    local storage_target="${8:-local}"
    shift 8
    local include_paths=("$@")
    
    # Calcular valores de retención
    local vol_retention job_retention file_retention
    case "$retention" in
        1) vol_retention="30 days"; job_retention="30 days"; file_retention="30 days" ;;
        2) vol_retention="90 days"; job_retention="90 days"; file_retention="90 days" ;;
        3) vol_retention="1 year"; job_retention="1 year"; file_retention="1 year" ;;
        4) vol_retention="3 years"; job_retention="3 years"; file_retention="3 years" ;;
    esac
    
    # Extraer hora y minuto
    local hour=$(echo "$backup_time" | cut -d: -f1)
    local min=$(echo "$backup_time" | cut -d: -f2)

    # Definir Schedule basado en la estrategia y hora
    local schedule_lines=""
    case "$strategy_type" in
        1) # Incremental diario
            schedule_lines="Run = Level=Incremental daily at ${hour}:${min}"
            ;;
        2) # Completo diario
            schedule_lines="Run = Level=Full daily at ${hour}:${min}"
            ;;
        3) # Mixto: Completo el domingo, Incremental resto de días
            schedule_lines="Run = Level=Full sun at ${hour}:${min}
    Run = Level=Incremental mon-sat at ${hour}:${min}"
            ;;
    esac
    
    # Determinar almacenamiento
    local storage_name="File1"
    if [[ "$storage_target" == "remote" ]]; then
        # Intentar detectar el nombre del almacenamiento remoto configurado
        if grep -q "Name = RemoteStorage" /etc/bacula/bacula-sd-remote.conf 2>/dev/null; then
            storage_name=$(grep "Name =" /etc/bacula/bacula-sd-remote.conf | head -1 | cut -d= -f2 | tr -d ' "')
        fi
    fi

    # Crear FileSet específico para este job
    local fileset_name="FS_${job_name}"
    
    cat >> /etc/bacula/bacula-dir.conf << EOF

# FileSet for job: $job_name
FileSet {
    Name = "$fileset_name"
    Include {
        Options {
            signature = MD5
            compression = GZIP9
        }
EOF
    
    # Agregar paths de inclusión
    for path in "${include_paths[@]}"; do
        echo "        File = \"$path\"" >> /etc/bacula/bacula-dir.conf
    done
    
    cat >> /etc/bacula/bacula-dir.conf << EOF
    }
    Exclude {
        File = /proc
        File = /sys
        File = /dev
        File = /run
        File = /tmp
        File = /var/tmp
        File = /var/lib/bacula
        File = *.tmp
        File = *.temp
        File = *.log
        File = *.pid
    }
}

# Schedule for job: $job_name
Schedule {
    Name = "Schedule_${job_name}"
    $schedule_lines
}

# Client resource for job: $job_name
Client {
    Name = $(hostname -s)-fd
    Address = 127.0.0.1
    FDPort = 9102
    Catalog = MyCatalog
    Password = "$(generate_password)"
    File Retention = 30 days
    Job Retention = 6 months
    AutoPrune = yes
}

# Storage resource for job: $job_name
Storage {
    Name = $storage_name
    Address = 127.0.0.1
    SDPort = 9103
    Password = "$(generate_password)"
    Device = FileStorage
    Media Type = File
    Maximum Concurrent Jobs = 10
}

# Job: $job_name
Job {
    Name = "$job_name"
    Type = Backup
    Level = Incremental
    Client = $(hostname -s)-fd
    FileSet = "$fileset_name"
    Schedule = "Schedule_${job_name}"
    Storage = $storage_name
    Messages = Standard
    Pool = File
    SpoolAttributes = yes
    Priority = 10
    Write Bootstrap = "/var/lib/bacula/${job_name}.bsr"
    Enabled = yes
    
    # Manejo automático de puertos por seguridad / Automatic port management for security
    RunScript {
        RunsWhen = Before
        FailJobOnError = No
        Command = "/usr/local/bin/baculamanager --open-ports"
    }
    RunScript {
        RunsWhen = After
        RunsOnFailure = Yes
        RunsOnSuccess = Yes
        Command = "/usr/local/bin/baculamanager --close-ports"
    }
}

# Restore job for: $job_name
Job {
    Name = "Restore_${job_name}"
    Type = Restore
    Client = $(hostname -s)-fd
    Storage = $storage_name
    FileSet = "$fileset_name"
    Pool = File
    Messages = Standard
    Where = /tmp/bacula-restores-${job_name}
    Enabled = yes
}
EOF
    
    # Reiniciar servicios para aplicar cambios - con pre-flight check y diagnóstico detallado
    echo -e "${COLOR_CYAN}Restarting Director service to apply changes...${COLOR_RESET}"
    
    # Validar configuración antes de reiniciar
    if ! preflight_check_bacula_dir; then
        echo -e "  ${COLOR_YELLOW}⚠ Director service restart aborted due to configuration errors${COLOR_RESET}"
        echo ""
        echo -e "  ${COLOR_CYAN}Pasos recomendados:${COLOR_RESET}"
        echo -e "    1. Revisar los errores mostrados arriba"
        echo -e "    2. Corregir la configuración: sudo nano /etc/bacula/bacula-dir.conf"
        echo -e "    3. Validar manualmente: sudo bacula-dir -t -c /etc/bacula/bacula-dir.conf"
        echo -e "    4. Reiniciar el servicio: sudo systemctl restart bacula-dir"
        return 1
    fi
    
    # Intentar reiniciar con nombres alternativos
    local restart_success=false
    local error_output=""
    
    if systemctl restart bacula-dir 2>/dev/null; then
        restart_success=true
        echo -e "  ${COLOR_GREEN}✓ bacula-dir restarted${COLOR_RESET}"
    elif systemctl restart bacula-director 2>/dev/null; then
        restart_success=true
        echo -e "  ${COLOR_GREEN}✓ bacula-director restarted${COLOR_RESET}"
    else
        # Capturar el error detallado
        error_output=$(systemctl status bacula-dir 2>&1 || systemctl status bacula-director 2>&1 || echo "No se pudo obtener estado del servicio")
    fi
    
    if [[ "$restart_success" == false ]]; then
        echo -e "  ${COLOR_RED}✗ Director service restart failed${COLOR_RESET}"
        echo ""
        echo -e "  ${COLOR_YELLOW}Diagnóstico del error:${COLOR_RESET}"
        echo ""
        echo -e "  ${COLOR_DIM}$error_output${COLOR_RESET}" | head -20
        echo ""
        echo -e "  ${COLOR_CYAN}Pasos de solución:${COLOR_RESET}"
        echo -e "    1. Verificar estado: sudo systemctl status bacula-dir"
        echo -e "    2. Ver logs: sudo journalctl -u bacula-dir -n 50"
        echo -e "    3. Validar config: sudo bacula-dir -t -c /etc/bacula/bacula-dir.conf"
        echo -e "    4. Ver permisos: ls -la /etc/bacula/"
        return 1
    fi
}

# --- Listar jobs existentes / List existing jobs ---
list_backup_jobs() {
    echo -e "${COLOR_BOLD}${COLOR_CYAN}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  EXISTING BACKUP JOBS / JOBS DE RESPALDO EXISTENTES${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_CYAN}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    if [[ ! -d "$CONFIG_DIR/jobs" ]] || [[ -z "$(ls -A "$CONFIG_DIR/jobs" 2>/dev/null)" ]]; then
        echo -e "${COLOR_YELLOW}No backup jobs configured yet.${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}No hay jobs de respaldo configurados aún.${COLOR_RESET}"
        echo ""
        read -rp "$(t "press_continue")"
        return
    fi
    
    local job_count=0
    for job_config in "$CONFIG_DIR/jobs"/*.conf; do
        if [[ -f "$job_config" ]]; then
            ((job_count++))
            local job_name=$(basename "$job_config" .conf)
            source "$job_config" 2>/dev/null
            
            echo -e "${COLOR_GREEN}Job $job_count: ${COLOR_BOLD}$job_name${COLOR_RESET}"
            echo -e "  ${COLOR_DIM}Description: $JOB_DESCRIPTION${COLOR_RESET}"
            echo -e "  ${COLOR_DIM}Path: $BACKUP_PATH${COLOR_RESET}"
            echo -e "  ${COLOR_DIM}Schedule: $(get_schedule_description $SCHEDULE_TYPE)${COLOR_RESET}"
            echo -e "  ${COLOR_DIM}Retention: $(get_retention_description $RETENTION)${COLOR_RESET}"
            echo ""
        fi
    done
    
    echo -e "${COLOR_BLUE}Total jobs configured: $job_count${COLOR_RESET}"
    echo ""
    read -rp "$(t "press_continue")"
}

# --- Eliminar job de respaldo / Delete backup job ---
delete_backup_job() {
    list_backup_jobs
    
    echo -e "${COLOR_BOLD}Delete Backup Job / Eliminar Job de Respaldo${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}WARNING: This will permanently delete the job and its configuration!${COLOR_RESET}"
    echo ""
    
    read -rp "Enter job name to delete / Ingrese nombre del job a eliminar: " input_name
    
    # Sanitizar el nombre para evitar inyecciones en sed
    local job_name=$(echo "$input_name" | tr -dc 'a-zA-Z0-9_-')
    
    if [[ -z "$job_name" ]]; then
        echo -e "${COLOR_RED}Invalid or empty job name provided.${COLOR_RESET}"
        return
    fi
    
    # Verificar que el job exista
    if [[ ! -f "$CONFIG_DIR/jobs/${job_name}.conf" ]]; then
        echo -e "${COLOR_RED}Job '$job_name' not found.${COLOR_RESET}"
        return
    fi
    
    # Confirmar eliminación
    if confirm "Are you sure you want to delete job '$job_name'? / ¿Está seguro de eliminar el job '$job_name'?"; then
        # Eliminar configuración del job
        rm -f "$CONFIG_DIR/jobs/${job_name}.conf"
        
        # Eliminar job de la configuración de Bacula
        sed -i "/# Job: $job_name/,/^$/d" /etc/bacula/bacula-dir.conf
        sed -i "/# FileSet for job: $job_name/,/^$/d" /etc/bacula/bacula-dir.conf
        sed -i "/# Schedule for job: $job_name/,/^$/d" /etc/bacula/bacula-dir.conf
        sed -i "/# Restore job for: $job_name/,/^$/d" /etc/bacula/bacula-dir.conf
        sed -i "/# Client resource for job: $job_name/,/^$/d" /etc/bacula/bacula-dir.conf
        sed -i "/# Storage resource for job: $job_name/,/^$/d" /etc/bacula/bacula-dir.conf
        
        # Reiniciar servicios - con pre-flight check y diagnóstico detallado
        echo -e "${COLOR_CYAN}Restarting Director service to apply changes...${COLOR_RESET}"
        
        # Validar configuración antes de reiniciar
        if ! preflight_check_bacula_dir; then
            echo -e "  ${COLOR_YELLOW}⚠ Director service restart aborted due to configuration errors${COLOR_RESET}"
            return 1
        fi
        
        # Intentar reiniciar con nombres alternativos
        local restart_success=false
        
        if systemctl restart bacula-dir 2>/dev/null; then
            restart_success=true
            echo -e "  ${COLOR_GREEN}✓ bacula-dir restarted${COLOR_RESET}"
        elif systemctl restart bacula-director 2>/dev/null; then
            restart_success=true
            echo -e "  ${COLOR_GREEN}✓ bacula-director restarted${COLOR_RESET}"
        fi
        
        if [[ "$restart_success" == false ]]; then
            echo -e "  ${COLOR_RED}✗ Director service restart failed${COLOR_RESET}"
            echo ""
            echo -e "  ${COLOR_CYAN}Diagnóstico:${COLOR_RESET}"
            echo -e "    - Verificar estado: sudo systemctl status bacula-dir"
            echo -e "    - Ver logs: sudo journalctl -u bacula-dir -n 50"
        fi
        
        echo -e "${COLOR_GREEN}✓ Job '$job_name' deleted successfully!${COLOR_RESET}"
        log_message "INFO" "Backup job deleted: $job_name"
    else
        echo -e "${COLOR_YELLOW}Operation cancelled.${COLOR_RESET}"
    fi
    
    read -rp "$(t "press_continue")"
}

# =============================================================================
# FUNCIONES DE GESTIÓN DE PUERTOS Y FIREWALL / PORT AND FIREWALL MANAGEMENT
# =============================================================================

# --- Abrir puertos de Bacula / Open Bacula ports ---
open_bacula_ports() {
    local action="${1:-}"  # "backup" o "close"
    
    # Puertos estándar de Bacula
    local ports=("9101" "9102" "9103" "9104")
    
    case "$action" in
        "backup")
            log_message "INFO" "Opening Bacula ports for backup operation"
            
            # Usar iptables si está disponible
            if command -v iptables &>/dev/null; then
                for port in "${ports[@]}"; do
                    # Verificar si la regla ya existe
                    if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                        iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
                        log_message "INFO" "Opened port $port with iptables"
                    fi
                done
                
                # Guardar reglas iptables
                if command -v iptables-save &>/dev/null; then
                    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                    iptables-save > /etc/iptables.rules 2>/dev/null || true
                fi
            fi
            
            # Usar ufw si está disponible (Ubuntu)
            if command -v ufw &>/dev/null; then
                for port in "${ports[@]}"; do
                    ufw allow "$port"/tcp 2>/dev/null || true
                    log_message "INFO" "Opened port $port with ufw"
                done
            fi
            
            # Usar firewalld si está disponible (RHEL/CentOS)
            if command -v firewall-cmd &>/dev/null; then
                for port in "${ports[@]}"; do
                    firewall-cmd --permanent --add-port="$port/tcp" 2>/dev/null || true
                    log_message "INFO" "Opened port $port with firewalld"
                done
                firewall-cmd --reload 2>/dev/null || true
            fi
            
            echo -e "${COLOR_GREEN}✓ Bacula ports opened for backup${COLOR_RESET}"
            ;;
            
        "close")
            log_message "INFO" "Closing Bacula ports after backup operation"
            
            # Usar iptables si está disponible
            if command -v iptables &>/dev/null; then
                for port in "${ports[@]}"; do
                    # Eliminar regla si existe
                    if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                        iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
                        log_message "INFO" "Closed port $port with iptables"
                    fi
                done
                
                # Guardar reglas iptables
                if command -v iptables-save &>/dev/null; then
                    iptables-save > /etc/iptables/rules.v4 2>/dev/null || \
                    iptables-save > /etc/iptables.rules 2>/dev/null || true
                fi
            fi
            
            # Usar ufw si está disponible
            if command -v ufw &>/dev/null; then
                for port in "${ports[@]}"; do
                    ufw --force delete allow "$port"/tcp 2>/dev/null || true
                    log_message "INFO" "Closed port $port with ufw"
                done
            fi
            
            # Usar firewalld si está disponible
            if command -v firewall-cmd &>/dev/null; then
                for port in "${ports[@]}"; do
                    firewall-cmd --permanent --remove-port="$port/tcp" 2>/dev/null || true
                    log_message "INFO" "Closed port $port with firewalld"
                done
                firewall-cmd --reload 2>/dev/null || true
            fi
            
            echo -e "${COLOR_YELLOW}✓ Bacula ports closed after backup${COLOR_RESET}"
            ;;
    esac
}

# --- Verificar estado de puertos / Check port status ---
check_bacula_ports() {
    local ports=("9101" "9102" "9103" "9104")
    local port_names=("Director" "Storage" "File Daemon" "Console")
    local open_count=0
    
    echo -e "${COLOR_BOLD}Bacula Port Configuration / Configuración de Puertos Bacula:${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_DIM}Bacula uses these ports for communication between components:${COLOR_RESET}"
    echo ""
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local name="${port_names[$i]}"
        local port_status="CLOSED"
        local status_color="COLOR_RED"
        
        # Verificar si el puerto está abierto
        if netstat -tuln 2>/dev/null | grep -q ":$port "; then
            port_status="OPEN"
            status_color="COLOR_GREEN"
            ((open_count++))
        elif ss -tuln 2>/dev/null | grep -q ":$port "; then
            port_status="OPEN"
            status_color="COLOR_GREEN"
            ((open_count++))
        fi
        
        echo -e "  ${name} (Port $port): ${!status_color}$port_status${COLOR_RESET}"
    done
    
    echo ""
    echo -e "  ${COLOR_BOLD}Open ports: $open_count/4${COLOR_RESET}"
    echo ""
    
    # Mostrar configuración actual de puertos
    echo -e "${COLOR_BOLD}Current Port Configuration / Configuración Actual de Puertos:${COLOR_RESET}"
    echo ""
    
    # Buscar configuración en archivos de Bacula
    local config_paths=("/etc/bacula" "/usr/local/etc/bacula" "/opt/bacula/etc")
    local found_config=false
    
    for path in "${config_paths[@]}"; do
        if [[ -f "$path/bacula-dir.conf" ]]; then
            echo -e "  ${COLOR_CYAN}Director config ($path/bacula-dir.conf):${COLOR_RESET}"
            grep -E "(Port|FDPort|SDPort)" "$path/bacula-dir.conf" 2>/dev/null | while read -r line; do
                echo -e "    ${COLOR_DIM}$line${COLOR_RESET}"
            done
            found_config=true
        fi
        
        if [[ -f "$path/bacula-sd.conf" ]]; then
            echo -e "  ${COLOR_CYAN}Storage config ($path/bacula-sd.conf):${COLOR_RESET}"
            grep -E "(Port|FDPort|SDPort)" "$path/bacula-sd.conf" 2>/dev/null | while read -r line; do
                echo -e "    ${COLOR_DIM}$line${COLOR_RESET}"
            done
            found_config=true
        fi
        
        if [[ -f "$path/bacula-fd.conf" ]]; then
            echo -e "  ${COLOR_CYAN}File Daemon config ($path/bacula-fd.conf):${COLOR_RESET}"
            grep -E "(Port|FDPort|SDPort)" "$path/bacula-fd.conf" 2>/dev/null | while read -r line; do
                echo -e "    ${COLOR_DIM}$line${COLOR_RESET}"
            done
            found_config=true
        fi
    done
    
    if [[ "$found_config" == false ]]; then
        echo -e "  ${COLOR_YELLOW}No Bacula configuration files found${COLOR_RESET}"
    fi
    
    echo ""
    
    # Verificar reglas de firewall
    echo -e "${COLOR_BOLD}Firewall Rules / Reglas de Firewall:${COLOR_RESET}"
    
    if command -v iptables &>/dev/null; then
        echo -e "  ${COLOR_CYAN}iptables:${COLOR_RESET}"
        for port in "${ports[@]}"; do
            if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                echo -e "    ${COLOR_GREEN}✓ Port $port allowed${COLOR_RESET}"
            else
                echo -e "    ${COLOR_DIM}  - Port $port not explicitly allowed${COLOR_RESET}"
            fi
        done
    fi
    
    if command -v ufw &>/dev/null; then
        echo -e "  ${COLOR_CYAN}ufw:${COLOR_RESET}"
        for port in "${ports[@]}"; do
            if ufw status | grep -q "$port"; then
                echo -e "    ${COLOR_GREEN}✓ Port $port allowed${COLOR_RESET}"
            else
                echo -e "    ${COLOR_DIM}  - Port $port not explicitly allowed${COLOR_RESET}"
            fi
        done
    fi
    
    if command -v firewall-cmd &>/dev/null; then
        echo -e "  ${COLOR_CYAN}firewalld:${COLOR_RESET}"
        for port in "${ports[@]}"; do
            if firewall-cmd --list-ports | grep -q "$port/tcp"; then
                echo -e "    ${COLOR_GREEN}✓ Port $port allowed${COLOR_RESET}"
            else
                echo -e "    ${COLOR_DIM}  - Port $port not explicitly allowed${COLOR_RESET}"
            fi
        done
    fi
    
    echo ""
}

# --- Configurar política de puertos / Configure port policy ---
configure_port_policy() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  PORT MANAGEMENT POLICY / POLÍTICA DE GESTIÓN DE PUERTOS${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    echo -e "${COLOR_CYAN}Configure how Bacula ports should be managed:${COLOR_RESET}"
    echo ""
    echo "   1) Automatic: Open only during backups (recommended)"
    echo "   2) Manual: Always open (less secure)"
    echo "   3) Disabled: No automatic port management"
    echo ""
    
    while true; do
        read -rp "   Select option [1-3]: " port_policy
        case $port_policy in
            1|2|3) break ;;
            *) echo -e "   ${COLOR_RED}Invalid option${COLOR_RESET}" ;;
        esac
    done
    
    # Guardar política
    cat > "$CONFIG_DIR/port_policy.conf" << EOF
PORT_POLICY="$port_policy"
EOF
    chmod 600 "$CONFIG_DIR/port_policy.conf"
    
    case $port_policy in
        1)
            echo -e "${COLOR_GREEN}✓ Automatic port management enabled${COLOR_RESET}"
            echo -e "   ${COLOR_DIM}Ports will open only during backups${COLOR_RESET}"
            ;;
        2)
            echo -e "${COLOR_YELLOW}⚠ Manual port management selected${COLOR_RESET}"
            echo -e "   ${COLOR_DIM}Ports will remain always open${COLOR_RESET}"
            open_bacula_ports "backup"
            ;;
        3)
            echo -e "${COLOR_RED}✗ Automatic port management disabled${COLOR_RESET}"
            echo -e "   ${COLOR_DIM}You must manage ports manually${COLOR_RESET}"
            ;;
    esac
    
    log_message "INFO" "Port policy set to: $port_policy"
    
    read -rp "$(t "press_continue")"
}

# --- Obtener política de puertos / Get port policy ---
get_port_policy() {
    if [[ -f "$CONFIG_DIR/port_policy.conf" ]]; then
        source "$CONFIG_DIR/port_policy.conf" 2>/dev/null
        echo "${PORT_POLICY:-1}"  # Default: automatic
    else
        echo "1"  # Default: automatic
    fi
}

# =============================================================================
# FUNCIONES DE NOTIFICACIONES POR EMAIL / EMAIL NOTIFICATION FUNCTIONS
# =============================================================================

# --- Configurar notificaciones por email / Configure email notifications ---
configure_email_notifications() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  EMAIL NOTIFICATIONS CONFIGURATION / CONFIGURACIÓN DE EMAIL${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    # Crear archivo de configuración de email si no existe
    local email_config="$CONFIG_DIR/email.conf"
    
    echo -e "${COLOR_CYAN}Configure email notification settings / Configurar notificaciones por email:${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_YELLOW}Note / Nota:${COLOR_RESET}"
    echo -e "  - SMTP Username and Password are optional for some providers"
    echo -e "  - For Gmail: Use smtp.gmail.com:587, enable 'Less secure app access' or use App Passwords"
    echo -e "  - For local mail: Leave SMTP fields empty to use system's mail command"
    echo -e "  - Notifications include: backup status, job details, server info, destination email"
    echo ""
    
    # Servidor SMTP
    local smtp_server=""
    if [[ -f "$email_config" ]]; then
        smtp_server=$(grep "SMTP_SERVER=" "$email_config" 2>/dev/null | cut -d= -f2)
    fi
    read -rp "   SMTP Server / Servidor SMTP [$smtp_server]: " input_server
    smtp_server=${input_server:-$smtp_server}
    
    # Puerto SMTP
    local smtp_port=""
    if [[ -f "$email_config" ]]; then
        smtp_port=$(grep "SMTP_PORT=" "$email_config" 2>/dev/null | cut -d= -f2)
    fi
    [[ -z "$smtp_port" ]] && smtp_port="587"
    read -rp "   SMTP Port / Puerto SMTP [$smtp_port]: " input_port
    smtp_port=${input_port:-$smtp_port}
    
    # Usuario SMTP
    local smtp_user=""
    if [[ -f "$email_config" ]]; then
        smtp_user=$(grep "SMTP_USER=" "$email_config" 2>/dev/null | cut -d= -f2)
    fi
    read -rp "   SMTP Username / Usuario SMTP [$smtp_user]: " input_user
    smtp_user=${input_user:-$smtp_user}
    
    # Contraseña SMTP
    local smtp_password=""
    if [[ -f "$email_config" ]]; then
        smtp_password=$(load_credential "SMTP_PASSWORD" "$email_config")
    fi
    
    echo -e "   ${COLOR_DIM}SMTP Password / Contraseña SMTP:${COLOR_RESET}"
    read -rsp "   Password: " input_password
    [[ -n "$input_password" ]] && smtp_password="$input_password"
    echo ""
    
    # Email de destino
    local email_to=""
    if [[ -f "$email_config" ]]; then
        email_to=$(grep "EMAIL_TO=" "$email_config" 2>/dev/null | cut -d= -f2)
    fi
    read -rp "   Notification Email / Email de notificación [$email_to]: " input_email
    email_to=${input_email:-$email_to}
    
    # Email de origen
    local email_from=""
    if [[ -f "$email_config" ]]; then
        email_from=$(grep "EMAIL_FROM=" "$email_config" 2>/dev/null | cut -d= -f2)
    fi
    [[ -z "$email_from" ]] && email_from="bacula@$(hostname -f)"
    read -rp "   From Email / Email de origen [$email_from]: " input_from
    email_from=${input_user:-$email_from}
    
    # Usar TLS
    local use_tls=""
    if [[ -f "$email_config" ]]; then
        use_tls=$(grep "USE_TLS=" "$email_config" 2>/dev/null | cut -d= -f2)
    fi
    [[ -z "$use_tls" ]] && use_tls="yes"
    read -rp "   Use TLS / Usar TLS (yes/no) [$use_tls]: " input_tls
    use_tls=${input_tls:-$use_tls}
    
    # Guardar configuración
    cat > "$email_config" << EOF
SMTP_SERVER="$smtp_server"
SMTP_PORT="$smtp_port"
SMTP_USER="$smtp_user"
EMAIL_TO="$email_to"
EMAIL_FROM="$email_from"
USE_TLS="$use_tls"
EOF
    
    # Guardar contraseña de forma segura
    if [[ -n "$smtp_password" ]]; then
        save_credential "SMTP_PASSWORD" "$smtp_password" "$email_config"
    fi
    
    chmod 600 "$email_config"
    
    # Probar conexión
    echo ""
    echo -e "${COLOR_CYAN}Testing email configuration / Probando configuración de email...${COLOR_RESET}"
    
    if test_email_connection; then
        echo -e "${COLOR_GREEN}✓ Email configuration successful!${COLOR_RESET}"
        echo -e "   ${COLOR_GREEN}✓ ¡Configuración de email exitosa!${COLOR_RESET}"
        
        # Enviar email de prueba
        send_test_email
        
        log_message "INFO" "Email notifications configured successfully"
    else
        echo -e "${COLOR_RED}✗ Email configuration failed!${COLOR_RESET}"
        echo -e "   ${COLOR_RED}✗ ¡Configuración de email falló!${COLOR_RESET}"
        log_message "ERROR" "Email notifications configuration failed"
    fi
    
    read -rp "$(t "press_continue")"
}

# --- Probar conexión email / Test email connection ---
test_email_connection() {
    local email_config="$CONFIG_DIR/email.conf"
    
    if [[ ! -f "$email_config" ]]; then
        return 1
    fi
    
    source "$email_config" 2>/dev/null
    
    # Verificar que se tenga postfix o sendmail
    if ! command -v sendmail &>/dev/null && ! command -v postfix &>/dev/null; then
        echo -e "${COLOR_YELLOW}Installing postfix for email delivery...${COLOR_RESET}"
        apt-get update >/dev/null 2>&1
        apt-get install -y postfix mailutils >/dev/null 2>&1 || yum install -y postfix mailx >/dev/null 2>&1
    fi
    
    # Crear script de prueba
    local test_script="/tmp/test_email_$$.sh"
    cat > "$test_script" << EOF
#!/bin/bash
echo "Test email from Bacula Manager on $(hostname) at $(date)" | mail -s "Test Email - Bacula Manager" "$EMAIL_TO" 2>/dev/null
EOF
    
    chmod +x "$test_script"
    
    # Ejecutar prueba
    if timeout 10 "$test_script" 2>/dev/null; then
        rm -f "$test_script"
        return 0
    else
        rm -f "$test_script"
        return 1
    fi
}

# --- Enviar email de prueba / Send test email ---
send_test_email() {
    local email_config="$CONFIG_DIR/email.conf"
    
    if [[ ! -f "$email_config" ]]; then
        return 1
    fi
    
    source "$email_config" 2>/dev/null
    
    local hostname=$(hostname)
    local date_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    local email_body="
BACULA MANAGER - TEST EMAIL
==================================

This is a test email from Bacula Backup Manager.

Server Information:
- Hostname: $hostname
- Date: $date_time
- Version: $SCRIPT_VERSION

If you receive this email, notifications are working correctly.

---
Bacula Backup Manager v$SCRIPT_VERSION
Developed by: $AUTHOR
"
    
    echo "$email_body" | mail -s "✅ Test Email - Bacula Manager [$hostname]" "$EMAIL_TO" 2>/dev/null
    
    echo -e "   ${COLOR_CYAN}Test email sent to: $EMAIL_TO${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}Email de prueba enviado a: $EMAIL_TO${COLOR_RESET}"
}

# --- Enviar notificación de backup / Send backup notification ---
send_backup_notification() {
    local job_name="${1:-}"
    local job_status="${2:-}"
    local job_id="${3:-}"
    local error_message="${4:-}"
    
    local email_config="$CONFIG_DIR/email.conf"
    
    # Verificar que las notificaciones estén habilitadas
    if [[ ! -f "$email_config" ]]; then
        return 1
    fi
    
    source "$email_config" 2>/dev/null
    
    local hostname=$(hostname)
    local date_time=$(date '+%Y-%m-%d %H:%M:%S')
    local job_info=""
    
    # Obtener información del job
    if [[ -f "$CONFIG_DIR/jobs/${job_name}.conf" ]]; then
        source "$CONFIG_DIR/jobs/${job_name}.conf" 2>/dev/null
        job_info="
Job Configuration:
- Description: $JOB_DESCRIPTION
- Backup Path: $BACKUP_PATH
- Schedule: $(get_schedule_description $SCHEDULE_TYPE)
- Retention: $(get_retention_description $RETENTION)
- Include Paths: ${INCLUDE_PATHS[*]}
"
    fi
    
    # Determinar asunto y estado
    local subject_prefix="❌ FAILED"
    local status_color="COLOR_RED"
    local status_text="FAILED"
    
    if [[ "$job_status" == "success" ]]; then
        subject_prefix="✅ SUCCESS"
        status_color="COLOR_GREEN"
        status_text="SUCCESS"
    fi
    
    local email_subject="$subject_prefix Backup Report - $job_name [$hostname]"
    
    local email_body="
BACULA BACKUP NOTIFICATION
============================

Server Information:
- Hostname: $hostname
- Date: $date_time
- Job ID: $job_id
- Job Name: $job_name
- Status: $status_text

$job_info
"
    
    # Agregar detalles del resultado
    if [[ "$job_status" == "success" ]]; then
        email_body+="
Backup Result:
✅ Backup completed successfully
✅ Backup files are available and verified
✅ All directories were processed without errors

Storage Information:
- Check available space in your backup destination
- Backup integrity has been verified
"
    else
        email_body+="
Backup Result:
❌ Backup failed to complete
❌ Some files may not be backed up
❌ Please check the error details below

Error Details:
$error_message

Troubleshooting:
1. Check available disk space
2. Verify network connectivity
3. Review Bacula logs: /var/log/bacula/bacula.log
4. Check service status: systemctl status bacula-*
"
    fi
    
    email_body+="
System Information:
- OS: $(uname -s) $(uname -r)
- Available Space: $(df -h / | awk 'NR==2 {print $4}')
- Load Average: $(uptime | awk -F'load average:' '{print $2}')

Next Steps:
- For successful backups: No action required
- For failed backups: Please investigate immediately

---
Bacula Backup Manager v$SCRIPT_VERSION
Developed by: $AUTHOR
Email: $EMAIL_FROM
"
    
    # Enviar email
    echo "$email_body" | mail -s "$email_subject" "$EMAIL_TO" 2>/dev/null
    
    log_message "INFO" "Backup notification sent: $job_name - $job_status"
}

# --- Enviar notificación de eliminación por retención / Send retention notification ---
send_retention_notification() {
    local job_name="${1:-}"
    local deleted_volumes="${2:-}"
    local retention_policy="${3:-}"
    
    local email_config="$CONFIG_DIR/email.conf"
    
    if [[ ! -f "$email_config" ]]; then
        return 1
    fi
    
    source "$email_config" 2>/dev/null
    
    local hostname=$(hostname)
    local date_time=$(date '+%Y-%m-%d %H:%M:%S')
    
    local email_subject="🗑️ Retention Cleanup - $job_name [$hostname]"
    
    local email_body="
BACULA RETENTION NOTIFICATION
=============================

Server Information:
- Hostname: $hostname
- Date: $date_time
- Job Name: $job_name

Retention Action Completed:
🗑️ Old backup volumes have been automatically deleted
📊 This cleanup was performed according to retention policy

Deleted Volumes:
$deleted_volumes

Retention Policy:
$retention_policy

Storage Impact:
- Disk space has been freed
- Recent backups remain available
- System compliance maintained

Important Notes:
- Only expired backups were removed
- Current retention period is respected
- No active backups were affected

Storage Statistics:
- Total volumes before cleanup: $(test -f /etc/bacula/bacula-dir.conf && grep -c "Volume=" /etc/bacula/bacula-dir.conf 2>/dev/null || echo "N/A")
- Cleanup completed at: $date_time
- Next scheduled cleanup: Tomorrow 02:00 AM

---
Bacula Backup Manager v$SCRIPT_VERSION
Developed by: $AUTHOR
Email: $EMAIL_FROM
"
    
    # Enviar email
    echo "$email_body" | mail -s "$email_subject" "$EMAIL_TO" 2>/dev/null
    
    log_message "INFO" "Retention notification sent: $job_name - $deleted_volumes deleted"
}

# --- Ver estado de notificaciones / View notification status ---
view_notification_status() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  EMAIL NOTIFICATION STATUS / ESTADO DE NOTIFICACIONES${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    local email_config="$CONFIG_DIR/email.conf"
    
    if [[ ! -f "$email_config" ]]; then
        echo -e "${COLOR_YELLOW}⚠ Email notifications not configured${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}⚠ Notificaciones por email no configuradas${COLOR_RESET}"
        echo ""
        echo -e "${COLOR_CYAN}To configure email notifications:${COLOR_RESET}"
        echo -e "${COLOR_CYAN}1. Go to main menu option 5 (Reconfigure System)${COLOR_RESET}"
        echo -e "${COLOR_CYAN}2. Select option for email configuration${COLOR_RESET}"
        echo ""
        read -rp "$(t "press_continue")"
        return
    fi
    
    source "$email_config" 2>/dev/null
    
    echo -e "${COLOR_BOLD}Email Configuration / Configuración de Email:${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}✓ SMTP Server: $SMTP_SERVER:$SMTP_PORT${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}✓ Username: $SMTP_USER${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}✓ From: $EMAIL_FROM${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}✓ To: $EMAIL_TO${COLOR_RESET}"
    echo -e "  ${COLOR_GREEN}✓ TLS: $USE_TLS${COLOR_RESET}"
    echo ""
    
    # Probar conexión
    echo -e "${COLOR_BOLD}Testing Connection / Probando Conexión:${COLOR_RESET}"
    if test_email_connection; then
        echo -e "  ${COLOR_GREEN}✓ Email connection successful${COLOR_RESET}"
        echo -e "  ${COLOR_GREEN}✓ Conexión email exitosa${COLOR_RESET}"
    else
        echo -e "  ${COLOR_RED}✗ Email connection failed${COLOR_RESET}"
        echo -e "  ${COLOR_RED}✗ Conexión email falló${COLOR_RESET}"
    fi
    echo ""
    
    # Mostrar notificaciones recientes
    echo -e "${COLOR_BOLD}Recent Notifications / Notificaciones Recientes:${COLOR_RESET}"
    echo ""
    
    local recent_logs
    recent_logs=$(grep -i "notification\|email\|mail" "$LOG_DIR/manager.log" 2>/dev/null | tail -10)
    
    if [[ -n "$recent_logs" ]]; then
        echo -e "$recent_logs" | while IFS= read -r line; do
            echo -e "  ${COLOR_DIM}$line${COLOR_RESET}"
        done
    else
        echo -e "  ${COLOR_YELLOW}No recent notifications found${COLOR_RESET}"
    fi
    echo ""
    
    read -rp "$(t "press_continue")"
}

# =============================================================================
# FUNCIONES DE CONFIGURACIÓN / CONFIGURATION FUNCTIONS
# =============================================================================

# --- Configurar Bacula / Configure Bacula ---
configure_bacula() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "config_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    log_message "INFO" "Starting Bacula configuration"
    
    echo -e "${COLOR_CYAN}$(t "config_welcome")${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(t "config_explain")${COLOR_RESET}"
    echo ""
    
    # Menú de configuración
    echo -e "${COLOR_BOLD}Configuration Options / Opciones de Configuración:${COLOR_RESET}"
    echo "   1) Create new backup job / Crear nuevo job de respaldo"
    echo "   2) List existing jobs / Listar jobs existentes"
    echo "   3) Delete backup job / Eliminar job de respaldo"
    echo "   4) Basic configuration (legacy) / Configuración básica (legado)"
    echo "   5) Email notifications / Notificaciones por email"
    echo "   6) Port management policy / Política de gestión de puertos"
    echo "   7) Back / Volver"
    echo ""
    
    while true; do
        config_option=$(read_menu_choice "   $(t "select_option")" 1 7 1)
        case $config_option in
            1)
                create_backup_job
                return
                ;;
            2)
                list_backup_jobs
                return
                ;;
            3)
                delete_backup_job
                return
                ;;
            4)
                configure_bacula_legacy
                return
                ;;
            5)
                configure_email_notifications
                return
                ;;
            6)
                configure_port_policy
                return
                ;;
            7)
                return
                ;;
            *)
                echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}"
                ;;
        esac
    done
}

# --- Configuración Bacula Legacy (método original) / Legacy Bacula Configuration ---
configure_bacula_legacy() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  BASIC CONFIGURATION (LEGACY) / CONFIGURACIÓN BÁSICA (LEGAZO)${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    log_message "INFO" "Starting legacy Bacula configuration"
    
    echo -e "${COLOR_CYAN}$(t "config_welcome")${COLOR_RESET}"
    echo -e "${COLOR_DIM}$(t "config_explain")${COLOR_RESET}"
    echo ""
    
    # Variables de configuración / Configuration variables
    local director_name
    local bacula_password
    local backup_path
    local backup_type
    local schedule_type
    local retention
    local include_paths=()
    local exclude_paths=()
    
    # 1. Nombre del Director / Director Name
    echo -e "${COLOR_BOLD}1. $(t "ask_director_name")${COLOR_RESET}"
    echo -e "   ${COLOR_DIM}$(t "explain_director")${COLOR_RESET}"
    read -rp "   $(t "select_option") [$(hostname -s)-dir]: " director_name
    director_name=${director_name:-$(hostname -s)-dir}
    echo ""
    
    # 2. Contraseña / Password
    echo -e "${COLOR_BOLD}2. $(t "ask_password")${COLOR_RESET}"
    echo -e "   ${COLOR_DIM}$(t "explain_password")${COLOR_RESET}"
    while true; do
        read -rsp "   Password: " bacula_password
        echo ""
        if validate_password "$bacula_password"; then
            read -rsp "   Confirm password: " confirm_password
            echo ""
            if [[ "$bacula_password" == "$confirm_password" ]]; then
                break
            else
                echo -e "   ${COLOR_RED}$(t "error"): Passwords don't match${COLOR_RESET}"
            fi
        else
            echo -e "   ${COLOR_RED}$(t "password_weak")${COLOR_RESET}"
        fi
    done
    echo ""
    
    # 3. Ruta de respaldos / Backup path
    echo -e "${COLOR_BOLD}3. $(t "ask_backup_path")${COLOR_RESET}"
    echo -e "   ${COLOR_DIM}$(t "explain_backup_path")${COLOR_RESET}"
    backup_path=$(read_line_edit "   $(t "select_option")" "/backups")
    backup_path=${backup_path:-/backups}
    
    # Crear directorio si no existe / Create directory if not exists
    if [[ ! -d "$backup_path" ]]; then
        mkdir -p "$backup_path"
        chmod 750 "$backup_path"
        chown root:bacula "$backup_path"
    fi
    
    # Verificar espacio disponible / Check available space
    local available_space
    available_space=$(df -h "$backup_path" | awk 'NR==2 {print $4}')
    echo -e "   ${COLOR_GREEN}✓ Space available: $available_space${COLOR_RESET}"
    echo ""
    
    # 4. Qué respaldar / What to backup
    echo -e "${COLOR_BOLD}4. $(t "ask_what_to_backup")${COLOR_RESET}"
    echo "   1) $(t "option_system")"
    echo "   2) $(t "option_home")"
    echo "   3) $(t "option_custom")"
    echo "   4) $(t "option_databases")"
    
    while true; do
        backup_type=$(read_menu_choice "   $(t "select_option")" 1 4 1)
        case $backup_type in
            1)
                include_paths=("/etc" "/home" "/var/www" "/usr/local")
                exclude_paths=("/proc" "/sys" "/dev" "/run" "/tmp")
                break
                ;;
            2)
                include_paths=("/home")
                exclude_paths=()
                break
                ;;
            3)
                echo -e "   ${COLOR_CYAN}Enter directories to backup (one per line, empty to finish):${COLOR_RESET}"
                while true; do
                    custom_path=$(read_line_edit "   Path")
                    [[ -z "$custom_path" ]] && break
                    if [[ -d "$custom_path" ]]; then
                        include_paths+=("$custom_path")
                        echo -e "   ${COLOR_GREEN}✓ Added${COLOR_RESET}"
                    else
                        echo -e "   ${COLOR_RED}✗ Directory not found${COLOR_RESET}"
                    fi
                done
                break
                ;;
            4)
                configure_database_backup
                include_paths=("/var/lib/postgresql" "/var/lib/mysql" "/etc/mysql" "/etc/postgresql")
                exclude_paths=()
                break
                ;;
            *)
                echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}"
                ;;
        esac
    done
    echo ""
    
    # 5. Horario / Schedule
    echo -e "${COLOR_BOLD}5. $(t "ask_schedule")${COLOR_RESET}"
    echo "   1) $(t "option_daily") - 02:00 AM"
    echo "   2) $(t "option_weekly") - Sundays 02:00 AM"
    echo "   3) $(t "option_monthly") - 1st day 02:00 AM"
    echo "   4) $(t "option_custom_schedule")"
    
    while true; do
        read -rp "   $(t "select_option") [1-4]: " schedule_type
        case $schedule_type in
            1|2|3|4) break ;;
            *) echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}" ;;
        esac
    done
    echo ""
    
    # 6. Retención / Retention
    echo -e "${COLOR_BOLD}6. $(t "ask_retention")${COLOR_RESET}"
    echo "   1) $(t "option_30days")"
    echo "   2) $(t "option_90days")"
    echo "   3) $(t "option_1year")"
    echo "   4) $(t "option_forever")"
    
    while true; do
        retention=$(read_menu_choice "   $(t "select_option")" 1 4 1)
        case $retention in
            1|2|3|4) break ;;
            *) echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}" ;;
        esac
    done
    echo ""
    
    # Generar archivos de configuración / Generate configuration files
    generate_bacula_config "$director_name" "$bacula_password" "$backup_path" "$schedule_type" "$retention" "${include_paths[@]}" "${exclude_paths[@]}"
    
    # Mostrar resumen / Show summary
    echo -e "${COLOR_BOLD}${COLOR_GREEN}✓ $(t "config_complete")${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD}$(t "config_summary")${COLOR_RESET}"
    echo -e "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    echo -e "  Director Name:    ${COLOR_CYAN}$director_name${COLOR_RESET}"
    echo -e "  Backup Path:      ${COLOR_CYAN}$backup_path${COLOR_RESET}"
    echo -e "  Schedule:         ${COLOR_CYAN}$(get_schedule_description $schedule_type)${COLOR_RESET}"
    echo -e "  Retention:        ${COLOR_CYAN}$(get_retention_description $retention)${COLOR_RESET}"
    echo -e "  Include Paths:    ${COLOR_CYAN}${include_paths[*]}${COLOR_RESET}"
    echo -e "${COLOR_BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}"
    
    log_message "INFO" "Configuration completed for director: $director_name"
    
    read -rp "$(t "press_continue")"
}

# --- Obtener descripción de horario / Get schedule description ---
get_schedule_description() {
    case ${1:-} in
        1) [[ "$APP_LANG" == "en" ]] && echo "Daily at 02:00 AM" || echo "Diario a las 02:00 AM" ;;
        2) [[ "$APP_LANG" == "en" ]] && echo "Weekly Sundays 02:00 AM" || echo "Semanal Domingos 02:00 AM" ;;
        3) [[ "$APP_LANG" == "en" ]] && echo "Monthly 1st day 02:00 AM" || echo "Mensual día 1 a las 02:00 AM" ;;
        4) [[ "$APP_LANG" == "en" ]] && echo "Custom" || echo "Personalizado" ;;
    esac
}

# --- Obtener descripción de retención / Get retention description ---
get_retention_description() {
    case ${1:-} in
        1) [[ "$APP_LANG" == "en" ]] && echo "30 days" || echo "30 días" ;;
        2) [[ "$APP_LANG" == "en" ]] && echo "90 days" || echo "90 días" ;;
        3) [[ "$APP_LANG" == "en" ]] && echo "1 year" || echo "1 año" ;;
        4) [[ "$APP_LANG" == "en" ]] && echo "Forever" || echo "Para siempre" ;;
    esac
}

# --- Configurar respaldo de bases de datos / Configure database backup ---
configure_database_backup() {
    echo -e "   ${COLOR_CYAN}$(t "info"): Database backup configuration${COLOR_RESET}"
    echo -e "   ${COLOR_YELLOW}⚠ WARNING: Configure pg_dump or mysqldump in a pre-backup script for consistent hot backups.${COLOR_RESET}"
    
    # Detectar bases de datos instaladas / Detect installed databases
    local has_postgres=false
    local has_mysql=false
    
    if command -v psql &> /dev/null && systemctl is-active --quiet postgresql 2>/dev/null; then
        has_postgres=true
        echo -e "   ${COLOR_GREEN}✓ PostgreSQL detected${COLOR_RESET}"
    fi
    
    if command -v mysql &> /dev/null && systemctl is-active --quiet mysql 2>/dev/null; then
        has_mysql=true
        echo -e "   ${COLOR_GREEN}✓ MySQL/MariaDB detected${COLOR_RESET}"
    fi
    
    if [[ "$has_postgres" == false && "$has_mysql" == false ]]; then
        echo -e "   ${COLOR_YELLOW}⚠ No active databases detected${COLOR_RESET}"
    fi
}

# --- Generar configuración Bacula / Generate Bacula configuration ---
generate_bacula_config() {
    local director_name="${1:-}"
    local password="${2:-}"
    local backup_path="${3:-}"
    local schedule_type="${4:-}"
    local retention="${5:-}"
    shift 5
    local include_paths=("$@")
    
    # Cargar configuración de email si existe
    local email_config="$CONFIG_DIR/email.conf"
    local smtp_server="localhost"
    local email_to="root@localhost"
    local email_from="bacula@$(hostname -f)"
    
    if [[ -f "$email_config" ]]; then
        source "$email_config" 2>/dev/null
        smtp_server="${SMTP_SERVER:-localhost}"
        email_to="${EMAIL_TO:-root@localhost}"
        email_from="${EMAIL_FROM:-bacula@$(hostname -f)}"
    fi
    
    # Calcular valores de retención / Calculate retention values
    local vol_retention
    local job_retention
    local file_retention
    
    case $retention in
        1) vol_retention="30 days"; job_retention="30 days"; file_retention="30 days" ;;
        2) vol_retention="90 days"; job_retention="90 days"; file_retention="90 days" ;;
        3) vol_retention="1 year"; job_retention="1 year"; file_retention="1 year" ;;
        4) vol_retention="3 years"; job_retention="3 years"; file_retention="3 years" ;;
    esac
    
    # Calcular horario en sintaxis válida de Bacula / Calculate schedule in valid Bacula syntax
    local schedule_cron
    case $schedule_type in
        1) schedule_cron="Run = Level=Full daily at 02:00" ;;
        2) schedule_cron="Run = Level=Full sun at 02:00
    Run = Level=Incremental mon-sat at 02:00" ;;
        3) schedule_cron="Run = Level=Full 1st sun at 02:00
    Run = Level=Differential 1st mon-sat at 02:00" ;;
        4) schedule_cron="Run = Level=Full daily at 02:00" ;;
    esac
    
    # Director configuration
    cat > /etc/bacula/bacula-dir.conf << EOF
# Bacula Director Configuration
# Generated by Bacula Manager v${SCRIPT_VERSION}
# Author: ${AUTHOR}

Director {
    Name = "$director_name"
    DIRport = 9101
    QueryFile = "/etc/bacula/scripts/query.sql"
    WorkingDirectory = "/var/lib/bacula"
    PidDirectory = "/run/bacula"
    Maximum Concurrent Jobs = 20
    Password = "$password"
    Messages = Daemon
    DirAddress = 127.0.0.1
}

JobDefs {
    Name = "DefaultJob"
    Type = Backup
    Level = Incremental
    Client = $(hostname -s)-fd
    FileSet = "Full Set"
    Schedule = "WeeklyCycle"
    Storage = File1
    Messages = Standard
    Pool = File
    SpoolAttributes = yes
    Priority = 10
    Write Bootstrap = "/var/lib/bacula/%c.bsr"
}

Job {
    Name = "BackupLocalFiles"
    JobDefs = "DefaultJob"
    Enabled = yes
    FileSet = "Full Set"
}

Job {
    Name = "RestoreFiles"
    Type = Restore
    Client = $(hostname -s)-fd
    Storage = File1
    FileSet = "Full Set"
    Pool = File
    Messages = Standard
    Where = /tmp/bacula-restores
}

FileSet {
    Name = "Full Set"
    Include {
        Options {
            signature = MD5
            compression = GZIP9
        }
EOF
    
    # Agregar paths de inclusión / Add include paths
    for path in "${include_paths[@]}"; do
        echo "        File = $path" >> /etc/bacula/bacula-dir.conf
    done
    
    cat >> /etc/bacula/bacula-dir.conf << EOF
    }
    Exclude {
        File = /proc
        File = /sys
        File = /dev
        File = /run
        File = /tmp
        File = /var/tmp
        File = /var/lib/bacula
        File = *.tmp
        File = *.temp
        File = *.log
        File = *.pid
    }
}

Schedule {
    Name = "WeeklyCycle"
    $schedule_cron
}

Client {
    Name = $(hostname -s)-fd
    Address = 127.0.0.1
    FDPort = 9102
    Catalog = MyCatalog
    Password = "$password"
    File Retention = $file_retention
    Job Retention = $job_retention
    AutoPrune = yes
}

Storage {
    Name = File1
    Address = 127.0.0.1
    SDPort = 9103
    Password = "$password"
    Device = FileStorage
    Media Type = File
    Maximum Concurrent Jobs = 10
}

Catalog {
    Name = MyCatalog
    dbname = "bacula"
    dbuser = "bacula"
    dbpassword = "$(grep DB_PASSWORD $CONFIG_DIR/db_credentials.conf | cut -d= -f2)"
}

Pool {
    Name = File
    Pool Type = Backup
    Recycle = yes
    AutoPrune = yes
    Volume Retention = $vol_retention
    Maximum Volume Bytes = 50G
    Maximum Volumes = 100
    Label Format = "Vol-"
}

Messages {
    Name = Standard
    mailcommand = "/usr/bin/bsmtp -h $smtp_server -f \"$email_from\" -s \"Bacula Report %t %e %c %l\" %r"
    operatorcommand = "/usr/bin/bsmtp -h $smtp_server -f \"$email_from\" -s \"Bacula Intervention Required %r\" %r"
    mail = $email_to = all, !skipped
    operator = $email_to = mount
    console = all, !skipped, !saved
    append = "/var/log/bacula/bacula.log" = all, !skipped
    catalog = all
}

Messages {
    Name = Daemon
    mailcommand = "/usr/bin/bsmtp -h $smtp_server -f \"$email_from\" -s \"Bacula Daemon Message %t %e %c %l\" %r"
    mail = $email_to = all, !skipped
    console = all, !skipped, !saved
    append = "/var/log/bacula/bacula.log" = all, !skipped
}
EOF
    
    # Storage Daemon configuration
    cat > /etc/bacula/bacula-sd.conf << EOF
# Bacula Storage Daemon Configuration

Storage {
    Name = $(hostname -s)-sd
    SDPort = 9103
    WorkingDirectory = "/var/lib/bacula"
    PidDirectory = "/run/bacula"
    Maximum Concurrent Jobs = 20
    SDAddress = 127.0.0.1
}

Director {
    Name = "$director_name"
    Password = "$password"
}

Device {
    Name = FileStorage
    Media Type = File
    Archive Device = $backup_path
    LabelMedia = yes
    Random Access = yes
    AutomaticMount = yes
    RemovableMedia = no
    AlwaysOpen = no
    Maximum Concurrent Jobs = 5
}

Messages {
    Name = Standard
    director = $director_name = all
}
EOF
    
    # File Daemon configuration
    cat > /etc/bacula/bacula-fd.conf << EOF
# Bacula File Daemon Configuration

Director {
    Name = "$director_name"
    Password = "$password"
}

FileDaemon {
    Name = $(hostname -s)-fd
    FDport = 9102
    WorkingDirectory = "/var/lib/bacula"
    PidDirectory = "/run/bacula"
    Maximum Concurrent Jobs = 20
    FDAddress = 127.0.0.1
}

Messages {
    Name = Standard
    director = $director_name = all, !skipped, !restored
}
EOF
    
    # bconsole configuration
    cat > /etc/bacula/bconsole.conf << EOF
# Bacula Console Configuration

Director {
    Name = "$director_name"
    DIRport = 9101
    address = 127.0.0.1
    Password = "$password"
}
EOF
    
    # Establecer permisos / Set permissions
    chown root:bacula /etc/bacula/*.conf
    chmod 640 /etc/bacula/*.conf
    
    # Crear directorios de log / Create log directories
    mkdir -p /var/log/bacula
    chown bacula:bacula /var/log/bacula
    
    # Reiniciar servicios / Restart services - intentar múltiples nombres
    echo -e "${COLOR_CYAN}Restarting Bacula services...${COLOR_RESET}"
    
    # Intentar con nombres estándar primero
    if systemctl restart bacula-dir bacula-sd bacula-fd 2>/dev/null; then
        echo -e "  ${COLOR_GREEN}✓ Services restarted (standard names)${COLOR_RESET}"
    elif systemctl restart bacula-director bacula-sd bacula-client 2>/dev/null; then
        echo -e "  ${COLOR_GREEN}✓ Services restarted (alternative names)${COLOR_RESET}"
    else
        echo -e "  ${COLOR_YELLOW}⚠ Some services failed to restart${COLOR_RESET}"
        # Intentar individualmente
        for svc in bacula-dir bacula-director; do
            if systemctl is-enabled "$svc" 2>/dev/null; then
                systemctl restart "$svc" 2>/dev/null && echo -e "    ${COLOR_GREEN}✓ $svc restarted${COLOR_RESET}"
            fi
        done
        systemctl restart bacula-sd 2>/dev/null && echo -e "    ${COLOR_GREEN}✓ bacula-sd restarted${COLOR_RESET}"
        for svc in bacula-fd bacula-client; do
            if systemctl is-enabled "$svc" 2>/dev/null; then
                systemctl restart "$svc" 2>/dev/null && echo -e "    ${COLOR_GREEN}✓ $svc restarted${COLOR_RESET}"
            fi
        done
    fi
    
    # Guardar configuración del manager / Save manager config
    cat > "$CONFIG_DIR/manager.conf" << EOF
DIRECTOR_NAME=$director_name
BACKUP_PATH=$backup_path
SCHEDULE_TYPE=$schedule_type
RETENTION=$retention
CONFIG_DATE=$(date -Iseconds)
SCRIPT_VERSION=$SCRIPT_VERSION
EOF
    
    log_message "INFO" "Bacula configuration files generated"
}

# =============================================================================
# FUNCIONES DE OPERACIÓN / OPERATION FUNCTIONS
# =============================================================================

# --- Ejecutar respaldo / Run backup ---
run_backup() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "backup_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    if ! is_bacula_installed; then
        error_exit "$(t "install_title") - Bacula not installed"
    fi
    
    echo -e "${COLOR_CYAN}$(t "backup_starting")${COLOR_RESET}"
    log_message "INFO" "Starting manual backup"
    
    # Verificar que los servicios estén corriendo / Check services running
    local services_need_start=false
    
    # Verificar director con múltiples nombres
    local director_running=false
    for svc in bacula-dir bacula-director; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            director_running=true
            break
        fi
    done
    
    # Verificar storage
    local storage_running=false
    if systemctl is-active --quiet bacula-sd 2>/dev/null; then
        storage_running=true
    fi
    
    # Verificar cliente con múltiples nombres
    local client_running=false
    for svc in bacula-fd bacula-client; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            client_running=true
            break
        fi
    done
    
    if [[ "$director_running" == false ]] || [[ "$storage_running" == false ]] || [[ "$client_running" == false ]]; then
        echo -e "${COLOR_YELLOW}⚠ $(t "warning"): $(t "msg_starting_services")${COLOR_RESET}"
        # Intentar iniciar con nombres estándar
        systemctl start bacula-dir bacula-sd bacula-fd 2>/dev/null || \
        systemctl start bacula-director bacula-sd bacula-client 2>/dev/null || true
        sleep 2
    fi
    
    # Menú de selección de jobs
    echo -e "${COLOR_BOLD}Select backup job to run / Seleccione job de respaldo a ejecutar:${COLOR_RESET}"
    echo ""
    
    # Listar jobs disponibles
    local available_jobs=()
    local job_count=0
    
    # Buscar jobs de backup (no restore)
    while IFS= read -r line; do
        if [[ $line =~ Name[[:space:]]*=[[:space:]]*\"(.+)\" ]] && [[ ! $line =~ Restore_ ]]; then
            local job_name="${BASH_REMATCH[1]}"
            # Filtrar solo jobs de backup
            if [[ $job_name != "BackupLocalFiles" ]] || [[ ! -d "$CONFIG_DIR/jobs" ]]; then
                available_jobs+=("$job_name")
                ((job_count++))
                echo "   $job_count) $job_name"
            fi
        fi
    done < <(test -f /etc/bacula/bacula-dir.conf && grep -iE '^Job[[:space:]]*\{' /etc/bacula/bacula-dir.conf 2>/dev/null -A 5 | grep "Name = " || echo "")
    
    # Si no hay jobs configurados, usar el legacy
    if [[ $job_count -eq 0 ]]; then
        echo -e "${COLOR_YELLOW}No backup jobs configured. Running legacy backup...${COLOR_RESET}"
        run_legacy_backup
        return
    fi
    
    echo "   0) Run all jobs / Ejecutar todos los jobs"
    echo ""
    
    while true; do
        read -rp "   $(t "select_option") [0-$job_count]: " job_choice
        if [[ "$job_choice" =~ ^[0-9]+$ ]] && [[ "$job_choice" -ge 0 ]] && [[ "$job_choice" -le $job_count ]]; then
            break
        else
            echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}"
        fi
    done
    
    echo ""
    
    # Ejecutar jobs seleccionados
    if [[ "$job_choice" -eq 0 ]]; then
        # Ejecutar todos los jobs
        echo -e "${COLOR_CYAN}Running all backup jobs...${COLOR_RESET}"
        for job_name in "${available_jobs[@]}"; do
            echo -e "${COLOR_BOLD}Running job: $job_name${COLOR_RESET}"
            run_single_backup_job "$job_name"
            echo ""
        done
    else
        # Ejecutar job específico
        local selected_job="${available_jobs[$((job_choice-1))]}"
        echo -e "${COLOR_CYAN}Running backup job: $selected_job${COLOR_RESET}"
        run_single_backup_job "$selected_job"
    fi
    
    read -rp "$(t "press_continue")"
}

# --- Ejecutar un job específico / Run single backup job ---
run_single_backup_job() {
    local job_name="${1:-}"
    
    # Obtener política de puertos
    local port_policy
    port_policy=$(get_port_policy)
    
    # Abrir puertos si la política es automática
    if [[ "$port_policy" == "1" ]]; then
        open_bacula_ports "backup"
        echo -e "${COLOR_CYAN}✓ Ports opened automatically for backup${COLOR_RESET}"
    fi
    
    # Ejecutar backup
    local job_output
    local job_id
    
    echo -e "${COLOR_CYAN}$(t "backup_progress")${COLOR_RESET}"
    echo ""
    
    # Iniciar trabajo en segundo plano y mostrar progreso
    (
        echo "run job=$job_name yes" | bconsole 2>&1
    ) > /tmp/backup_output.log &
    
    local pid=$!
    local dots=""
    
    while kill -0 $pid 2>/dev/null; do
        dots="${dots}."
        [[ ${#dots} -gt 3 ]] && dots="."
        printf "\r   ${COLOR_CYAN}$(t "msg_processing")%s${COLOR_RESET}   " "$dots"
        sleep 1
    done
    
    wait $pid
    
    echo ""
    echo ""
    
    # Verificar resultado
    if grep -q "JobId=" /tmp/backup_output.log; then
        job_id=$(grep "JobId=" /tmp/backup_output.log | head -1 | grep -oP '\d+')
        echo -e "${COLOR_GREEN}✓ $(t "backup_success")${COLOR_RESET}"
        echo -e "   $(t "backup_job_id") ${COLOR_CYAN}$job_id${COLOR_RESET}"
        echo -e "   ${COLOR_CYAN}Job: $job_name${COLOR_RESET}"
        log_message "INFO" "Backup completed successfully, JobId: $job_id, Job: $job_name"
        
        # Enviar notificación de éxito
        send_backup_notification "$job_name" "success" "$job_id" ""
    else
        local error_msg
        error_msg=$(cat /tmp/backup_output.log 2>/dev/null | head -5)
        echo -e "${COLOR_RED}✗ $(t "backup_failed")${COLOR_RESET}"
        echo -e "   ${COLOR_DIM}$(t "msg_check_logs") /var/log/bacula/bacula.log${COLOR_RESET}"
        log_message "ERROR" "Backup failed for job: $job_name"
        
        # Enviar notificación de fallo
        send_backup_notification "$job_name" "failed" "" "$error_msg"
    fi
    
    # Cerrar puertos si la política es automática
    if [[ "$port_policy" == "1" ]]; then
        open_bacula_ports "close"
        echo -e "${COLOR_YELLOW}✓ Ports closed automatically after backup${COLOR_RESET}"
    fi
    
    rm -f /tmp/backup_output.log
}

# --- Ejecutar backup legacy / Run legacy backup ---
run_legacy_backup() {
    # Obtener política de puertos
    local port_policy
    port_policy=$(get_port_policy)
    
    # Abrir puertos si la política es automática
    if [[ "$port_policy" == "1" ]]; then
        open_bacula_ports "backup"
        echo -e "${COLOR_CYAN}✓ Ports opened automatically for backup${COLOR_RESET}"
    fi
    
    # Ejecutar backup / Run backup
    local job_output
    local job_id
    
    echo -e "${COLOR_CYAN}$(t "backup_progress")${COLOR_RESET}"
    echo ""
    
    # Iniciar trabajo en segundo plano y mostrar progreso / Start job in background and show progress
    (
        echo "run job=BackupLocalFiles yes" | bconsole 2>&1
    ) > /tmp/backup_output.log &
    
    local pid=$!
    local dots=""
    
    while kill -0 $pid 2>/dev/null; do
        dots="${dots}."
        [[ ${#dots} -gt 3 ]] && dots="."
        printf "\r   ${COLOR_CYAN}$(t "msg_processing")%s${COLOR_RESET}   " "$dots"
        sleep 1
    done
    
    wait $pid
    
    echo ""
    echo ""
    
    # Verificar resultado / Check result
    if grep -q "JobId=" /tmp/backup_output.log; then
        job_id=$(grep "JobId=" /tmp/backup_output.log | head -1 | grep -oP '\d+')
        echo -e "${COLOR_GREEN}✓ $(t "backup_success")${COLOR_RESET}"
        echo -e "   $(t "backup_job_id") ${COLOR_CYAN}$job_id${COLOR_RESET}"
        log_message "INFO" "Legacy backup completed successfully, JobId: $job_id"
        
        # Enviar notificación de éxito
        send_backup_notification "BackupLocalFiles" "success" "$job_id" ""
    else
        local error_msg
        error_msg=$(cat /tmp/backup_output.log 2>/dev/null | head -5)
        echo -e "${COLOR_RED}✗ $(t "backup_failed")${COLOR_RESET}"
        echo -e "   ${COLOR_DIM}$(t "msg_check_logs") /var/log/bacula/bacula.log${COLOR_RESET}"
        log_message "ERROR" "Legacy backup failed"
        
        # Enviar notificación de fallo
        send_backup_notification "BackupLocalFiles" "failed" "" "$error_msg"
    fi
    
    # Cerrar puertos si la política es automática
    if [[ "$port_policy" == "1" ]]; then
        open_bacula_ports "close"
        echo -e "${COLOR_YELLOW}✓ Ports closed automatically after backup${COLOR_RESET}"
    fi
    
    rm -f /tmp/backup_output.log
    
    read -rp "$(t "press_continue")"
}

# --- Restaurar respaldo / Restore backup ---
restore_backup() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "restore_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    if ! is_bacula_installed; then
        error_exit "$(t "msg_bacula_not_installed")"
    fi
    
    echo -e "${COLOR_CYAN}$(t "restore_listing")${COLOR_RESET}"
    echo ""
    
    # Listar trabajos disponibles / List available jobs
    local jobs_output
    jobs_output=$(echo "list jobs" | bconsole 2>/dev/null | grep -E "^\|" | tail -n +3 | head -20)
    
    if [[ -z "$jobs_output" ]]; then
        echo -e "${COLOR_YELLOW}$(t "status_no_jobs")${COLOR_RESET}"
        read -rp "$(t "press_continue")"
        return
    fi
    
    echo -e "${COLOR_DIM}JobId | Name | StartTime | Type | Level | JobFiles | JobBytes | JobStatus${COLOR_RESET}"
    echo "$jobs_output"
    echo ""
    
    # Seleccionar trabajo / Select job
    local selected_job
    read -rp "   $(t "restore_select") JobId: " selected_job
    
    if ! [[ "$selected_job" =~ ^[0-9]+$ ]]; then
        echo -e "${COLOR_RED}$(t "invalid_option")${COLOR_RESET}"
        read -rp "$(t "press_continue")"
        return
    fi
    
    # Obtener información del job para determinar el restore job correspondiente
    local job_info
    job_info=$(echo "list jobs" | bconsole 2>/dev/null | grep "^\| *$selected_job " | head -1)
    
    if [[ -z "$job_info" ]]; then
        echo -e "${COLOR_RED}JobId $selected_job not found${COLOR_RESET}"
        read -rp "$(t "press_continue")"
        return
    fi
    
    # Extraer nombre del job original
    local original_job_name
    original_job_name=$(echo "$job_info" | awk '{print $2}')
    
    # Determinar el restore job correspondiente
    local restore_job_name
    if [[ "$original_job_name" == "BackupLocalFiles" ]]; then
        restore_job_name="RestoreFiles"
    else
        restore_job_name="Restore_${original_job_name}"
    fi
    
    # Seleccionar destino / Select destination
    local restore_path
    restore_path=$(read_line_edit "   $(t "restore_destination")" "/tmp/bacula-restores")
    restore_path=${restore_path:-/tmp/bacula-restores}
    
    # Crear directorio de restauración si no existe
    if [[ ! -d "$restore_path" ]]; then
        mkdir -p "$restore_path"
        chmod 755 "$restore_path"
    fi
    
    # Confirmar / Confirm
    echo ""
    echo -e "${COLOR_CYAN}Restore Details / Detalles de Restauración:${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Original Job: $original_job_name${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Restore Job: $restore_job_name${COLOR_RESET}"
    echo -e "  ${COLOR_DIM}Destination: $restore_path${COLOR_RESET}"
    echo ""
    
    if ! confirm "$(t "restore_confirm")"; then
        echo -e "${COLOR_YELLOW}$(t "cancel")${COLOR_RESET}"
        read -rp "$(t "press_continue")"
        return
    fi
    
    # Ejecutar restauración / Execute restore
    echo ""
    echo -e "${COLOR_CYAN}$(t "msg_restoring")${COLOR_RESET}"
    
    local restore_result
    restore_result=$(echo "restore jobid=$selected_job client=$(hostname -s)-fd where=$restore_path yes" | bconsole 2>&1)
    
    if echo "$restore_result" | grep -Eiq "Restore OK|Job queued|Job started|OK"; then
        echo -e "${COLOR_GREEN}✓ $(t "restore_success")${COLOR_RESET}"
        echo -e "   ${COLOR_CYAN}$(t "msg_files_restored") $restore_path${COLOR_RESET}"
        echo -e "   ${COLOR_CYAN}Original Job: $original_job_name${COLOR_RESET}"
        log_message "INFO" "Restore completed for JobId: $selected_job, Original Job: $original_job_name"
    else
        echo -e "${COLOR_RED}✗ $(t "restore_failed")${COLOR_RESET}"
        log_message "ERROR" "Restore failed for JobId: $selected_job, Original Job: $original_job_name"
    fi
    
    read -rp "$(t "press_continue")"
}

# --- Ver estado / View status ---
view_status() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "status_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    if ! is_bacula_installed; then
        echo -e "${COLOR_YELLOW}⚠ $(t "msg_bacula_not_installed")${COLOR_RESET}"
        read -rp "$(t "press_continue")"
        return
    fi
    
    # Estado de servicios / Services status - verificar múltiples nombres posibles
    echo -e "${COLOR_BOLD}$(t "msg_service_status")${COLOR_RESET}"
    
    # Verificar director con múltiples nombres posibles
    local director_running=false
    for svc in bacula-dir bacula-director; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            director_running=true
            echo -e "  ${COLOR_GREEN}✓ $svc: $(t "msg_running")${COLOR_RESET}"
            break
        fi
    done
    if [[ "$director_running" == false ]]; then
        echo -e "  ${COLOR_RED}✗ bacula-dir/director: $(t "msg_stopped")${COLOR_RESET}"
    fi
    
    # Verificar storage daemon
    if systemctl is-active --quiet bacula-sd 2>/dev/null; then
        echo -e "  ${COLOR_GREEN}✓ bacula-sd: $(t "msg_running")${COLOR_RESET}"
    else
        echo -e "  ${COLOR_RED}✗ bacula-sd: $(t "msg_stopped")${COLOR_RESET}"
    fi
    
    # Verificar file daemon (cliente) con múltiples nombres
    local client_running=false
    for svc in bacula-fd bacula-client; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            client_running=true
            echo -e "  ${COLOR_GREEN}✓ $svc: $(t "msg_running")${COLOR_RESET}"
            break
        fi
    done
    if [[ "$client_running" == false ]]; then
        echo -e "  ${COLOR_RED}✗ bacula-fd/client: $(t "msg_stopped")${COLOR_RESET}"
    fi
    echo ""
    
    # Estado de Jobs configurados / Configured jobs status
    echo -e "${COLOR_BOLD}Configured Backup Jobs / Jobs de Respaldo Configurados:${COLOR_RESET}"
    echo ""
    
    local job_count=0
    local configured_jobs=()
    
    # Buscar jobs configurados
    if [[ -d "$CONFIG_DIR/jobs" ]]; then
        for job_config in "$CONFIG_DIR/jobs"/*.conf; do
            if [[ -f "$job_config" ]]; then
                local job_name=$(basename "$job_config" .conf)
                configured_jobs+=("$job_name")
                ((job_count++))
                
                # Mostrar información del job
                source "$job_config" 2>/dev/null
                echo -e "  ${COLOR_GREEN}• $job_name${COLOR_RESET}"
                echo -e "    ${COLOR_DIM}Description: $JOB_DESCRIPTION${COLOR_RESET}"
                echo -e "    ${COLOR_DIM}Path: $BACKUP_PATH${COLOR_RESET}"
                echo -e "    ${COLOR_DIM}Schedule: $(get_schedule_description $SCHEDULE_TYPE)${COLOR_RESET}"
                echo -e "    ${COLOR_DIM}Retention: $(get_retention_description $RETENTION)${COLOR_RESET}"
                echo ""
            fi
        done
    fi
    
    # Buscar jobs en configuración de Bacula
    if [[ -f /etc/bacula/bacula-dir.conf ]]; then
        while IFS= read -r line; do
            if [[ $line =~ Name[[:space:]]*=[[:space:]]*\"(.+)\" ]] && [[ ! $line =~ Restore_ ]]; then
                local bacula_job_name="${BASH_REMATCH[1]}"
                # Verificar si ya está en la lista del manager
                local already_listed=false
                for existing_job in "${configured_jobs[@]}"; do
                    if [[ "$existing_job" == "$bacula_job_name" ]]; then
                        already_listed=true
                        break
                    fi
                done
                if [[ "$already_listed" == false ]]; then
                    configured_jobs+=("$bacula_job_name")
                    ((job_count++))
                    echo -e "  ${COLOR_GREEN}• $bacula_job_name (from Bacula config)${COLOR_RESET}"
                    echo -e "    ${COLOR_DIM}Type: Bacula Job${COLOR_RESET}"
                    echo ""
                fi
            fi
        done < <(grep -iE '^Job[[:space:]]*\{' /etc/bacula/bacula-dir.conf 2>/dev/null -A 5 | grep "Name = " || echo "")
    fi
    
    # Si no hay jobs configurados, mostrar mensaje
    if [[ $job_count -eq 0 ]]; then
        echo -e "${COLOR_YELLOW}  No backup jobs found${COLOR_RESET}"
        echo ""
    fi
    
    # Últimos respaldos / Recent backups
    echo -e "${COLOR_BOLD}Recent Backups / Respaldos Recientes:${COLOR_RESET}"
    echo ""
    
    local recent_jobs
    recent_jobs=$(echo "list jobs" | bconsole 2>/dev/null | grep -E "^\|" | tail -n +3 | head -10)
    
    if [[ -n "$recent_jobs" ]]; then
        echo -e "${COLOR_DIM}JobId | Name | StartTime | Type | Level | JobFiles | JobBytes | JobStatus${COLOR_RESET}"
        echo "$recent_jobs"
    else
        echo -e "${COLOR_YELLOW}No backup jobs found.${COLOR_RESET}"
    fi
    echo ""
    
    # Espacio utilizado / Storage used
    echo -e "${COLOR_BOLD}Storage Usage / Uso de Almacenamiento:${COLOR_RESET}"
    echo ""
    
    local total_used=0
    local backup_paths=()
    
    # Recolectar paths de todos los jobs
    if [[ -d "$CONFIG_DIR/jobs" ]]; then
        for job_config in "$CONFIG_DIR/jobs"/*.conf; do
            if [[ -f "$job_config" ]]; then
                source "$job_config" 2>/dev/null
                if [[ -d "$BACKUP_PATH" ]]; then
                    backup_paths+=("$BACKUP_PATH")
                fi
            fi
        done
    fi
    
    # Agregar path legacy si existe
    if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
        local legacy_path
        legacy_path=$(grep BACKUP_PATH "$CONFIG_DIR/manager.conf" | cut -d= -f2)
        if [[ -d "$legacy_path" ]]; then
            backup_paths+=("$legacy_path")
        fi
    fi
    
    # Mostrar espacio usado por cada path
    for path in "${backup_paths[@]}"; do
        local used
        used=$(du -sh "$path" 2>/dev/null | cut -f1)
        echo -e "  ${COLOR_CYAN}• $path: $used${COLOR_RESET}"
    done
    echo ""
    
    # Cola de trabajos / Job queue
    echo -e "${COLOR_BOLD}$(t "msg_job_queue")${COLOR_RESET}"
    local queue_status
    queue_status=$(echo "status dir" | bconsole 2>/dev/null | grep -A 3 "Scheduled Jobs" || echo "No scheduled jobs")
    echo -e "  ${COLOR_DIM}$queue_status${COLOR_RESET}"
    echo ""
    
    # Estado remoto / Remote status
    if [[ -f "$REMOTE_CONFIG_DIR/active.conf" ]]; then
        source "$REMOTE_CONFIG_DIR/active.conf" 2>/dev/null
        if [[ "$REMOTE_ENABLED" == "true" ]]; then
            echo -e "${COLOR_BOLD}Remote Backup Status / Estado de Respaldo Remoto:${COLOR_RESET}"
            echo -e "  ${COLOR_GREEN}• Host: $REMOTE_HOST${COLOR_RESET}"
            echo -e "  ${COLOR_GREEN}• Path: $REMOTE_PATH${COLOR_RESET}"
            echo -e "  ${COLOR_GREEN}• Type: $CONNECTION_TYPE${COLOR_RESET}"
            echo ""
        fi
    fi
    
    read -rp "$(t "press_continue")"
}

# --- Ver logs / View logs ---
view_logs() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "menu_logs")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    echo "  1) $(t "msg_log_director")"
    echo "  2) $(t "msg_log_storage")"
    echo "  3) $(t "msg_log_fd")"
    echo "  4) $(t "msg_log_manager")"
    echo "  5) $(t "back")"
    echo ""
    
    read -rp "   $(t "select_option") [1-5]: " log_choice
    
    case $log_choice in
        1) 
            if [[ -f /var/log/bacula/bacula.log ]]; then
                less +G /var/log/bacula/bacula.log
            else
                echo -e "${COLOR_RED}Log file not found${COLOR_RESET}"
                read -rp "$(t "press_continue")"
            fi
            ;;
        2)
            if [[ -f /var/log/bacula/bacula-sd.log ]]; then
                less +G /var/log/bacula/bacula-sd.log
            else
                echo -e "${COLOR_RED}Log file not found${COLOR_RESET}"
                read -rp "$(t "press_continue")"
            fi
            ;;
        3)
            if [[ -f /var/log/bacula/bacula-fd.log ]]; then
                less +G /var/log/bacula/bacula-fd.log
            else
                echo -e "${COLOR_RED}Log file not found${COLOR_RESET}"
                read -rp "$(t "press_continue")"
            fi
            ;;
        4)
            if [[ -f $LOG_DIR/manager.log ]]; then
                less +G "$LOG_DIR/manager.log"
            else
                echo -e "${COLOR_RED}Log file not found${COLOR_RESET}"
                read -rp "$(t "press_continue")"
            fi
            ;;
        5) return ;;
        *) 
            echo -e "${COLOR_RED}$(t "invalid_option")${COLOR_RESET}"
            sleep 1
            ;;
    esac
}

# --- Probar configuración / Test configuration ---
test_configuration() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "test_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    echo -e "${COLOR_CYAN}$(t "test_running")${COLOR_RESET}"
    echo ""
    
    local tests_passed=0
    local tests_failed=0
    
    # Test 1: Verificar archivos de configuración / Check config files
    echo -n "  $(t "msg_checking_config") "
    
    # Buscar archivos de configuración en múltiples ubicaciones posibles
    local bacula_dir_conf=""
    local bacula_sd_conf=""
    local bacula_fd_conf=""
    
    # Ubicaciones comunes de configuración de Bacula
    local config_paths=("/etc/bacula" "/usr/local/etc/bacula" "/opt/bacula/etc")
    
    for path in "${config_paths[@]}"; do
        [[ -f "$path/bacula-dir.conf" ]] && bacula_dir_conf="$path/bacula-dir.conf"
        [[ -f "$path/bacula-sd.conf" ]] && bacula_sd_conf="$path/bacula-sd.conf"
        [[ -f "$path/bacula-fd.conf" ]] && bacula_fd_conf="$path/bacula-fd.conf"
    done
    
    # Verificar si se encontraron los archivos
    if [[ -n "$bacula_dir_conf" && -n "$bacula_sd_conf" && -n "$bacula_fd_conf" ]]; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET}"
        ((tests_passed++))
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET}"
        echo -e "    ${COLOR_DIM}Director config: ${bacula_dir_conf:-Not found}${COLOR_RESET}"
        echo -e "    ${COLOR_DIM}Storage config: ${bacula_sd_conf:-Not found}${COLOR_RESET}"
        echo -e "    ${COLOR_DIM}File daemon config: ${bacula_fd_conf:-Not found}${COLOR_RESET}"
        ((tests_failed++))
    fi
    
    # Test 2: Validar sintaxis / Validate syntax
    echo -n "  $(t "msg_validating_syntax") "
    if [[ -n "$bacula_dir_conf" ]] && bacula-dir -t -c "$bacula_dir_conf" 2>/dev/null; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET}"
        ((tests_passed++))
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET}"
        ((tests_failed++))
    fi
    
    # Test 3: Verificar servicios / Check services
    echo -n "  $(t "msg_checking_services") "
    local director_ok=false
    local storage_ok=false
    local client_ok=false
    
    # Verificar director con múltiples nombres
    for svc in bacula-dir bacula-director; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            director_ok=true
            break
        fi
    done
    
    # Verificar storage
    if systemctl is-active --quiet bacula-sd 2>/dev/null; then
        storage_ok=true
    fi
    
    # Verificar cliente con múltiples nombres
    for svc in bacula-fd bacula-client; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            client_ok=true
            break
        fi
    done
    
    if [[ "$director_ok" == true ]] && [[ "$storage_ok" == true ]] && [[ "$client_ok" == true ]]; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET}"
        ((tests_passed++))
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET}"
        ((tests_failed++))
    fi
    
    # Test 4: Conexión a base de datos / Database connection
    echo -n "  $(t "msg_testing_db") "
    if echo "status" | bconsole 2>/dev/null | grep -q "Connected"; then
        echo -e "${COLOR_GREEN}✓${COLOR_RESET}"
        ((tests_passed++))
    else
        echo -e "${COLOR_RED}✗${COLOR_RESET}"
        ((tests_failed++))
    fi
    
    # Test 5: Espacio de almacenamiento / Storage space
    echo -n "  $(t "msg_checking_storage") "
    if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
        local backup_path
        backup_path=$(grep BACKUP_PATH "$CONFIG_DIR/manager.conf" | cut -d= -f2)
        local available
        available=$(df "$backup_path" 2>/dev/null | awk 'NR==2 {print $4}')
        if [[ -n "$available" && "$available" -gt 100000 ]]; then  # > 100MB
            echo -e "${COLOR_GREEN}✓${COLOR_RESET}"
            ((tests_passed++))
        else
            echo -e "${COLOR_RED}✗ ($(t "msg_low_space"))${COLOR_RESET}"
            ((tests_failed++))
        fi
    else
        echo -e "${COLOR_YELLOW}⚓ ($(t "msg_no_config"))${COLOR_RESET}"
    fi
    
    echo ""
    echo -e "${COLOR_BOLD}$(t "msg_results") ${COLOR_GREEN}$tests_passed $(t "msg_passed")${COLOR_RESET}, ${COLOR_RED}$tests_failed $(t "msg_failed")${COLOR_RESET}"
    
    if [[ $tests_failed -eq 0 ]]; then
        echo -e "${COLOR_GREEN}✓ $(t "test_passed")${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}✗ $(t "test_failed")${COLOR_RESET}"
    fi
    
    read -rp "$(t "press_continue")"
}

# --- Cambiar idioma / Change language ---
change_language() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "menu_language")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    echo "  1) Español"
    echo "  2) English"
    echo ""
    
    read -rp "   Select language / Seleccione idioma [1-2]: " lang_choice
    
    case $lang_choice in
        1) APP_LANG="es" ;;
        2) APP_LANG="en" ;;
        *) 
            echo -e "${COLOR_RED}$(t "invalid_option")${COLOR_RESET}"
            sleep 1
            return
            ;;
    esac
    
    # Guardar preferencia / Save preference
    mkdir -p "$CONFIG_DIR"
    echo "APP_LANG=$APP_LANG" > "$CONFIG_DIR/lang.conf"
    
    echo ""
    echo -e "${COLOR_GREEN}✓ Language changed / Idioma cambiado${COLOR_RESET}"
    sleep 1
}

# --- Cargar idioma guardado / Load saved language ---
load_language() {
    if [[ -f "$CONFIG_DIR/lang.conf" ]]; then
        source "$CONFIG_DIR/lang.conf"
    fi
}

# --- Verificar si existe configuración previa / Check for existing configuration ---
check_existing_config() {
    local config_exists=0
    local has_local=false
    local has_remote=false
    local has_manager=false
    
    if [[ -f /etc/bacula/bacula-dir.conf ]] && [[ -s /etc/bacula/bacula-dir.conf ]]; then
        has_local=true
        config_exists=$((config_exists + 1))
    fi
    
    if [[ -f "$REMOTE_CONFIG_DIR/active.conf" ]]; then
        has_remote=true
        config_exists=$((config_exists + 1))
    fi
    
    if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
        has_manager=true
        config_exists=$((config_exists + 1))
    fi
    
    echo "$config_exists"
}

# --- Mostrar información de configuración existente / Show existing config info ---
show_existing_config_info() {
    local config_count
    config_count=$(check_existing_config)
    
    if [[ $config_count -gt 0 ]]; then
        echo ""
        echo -e "${COLOR_YELLOW}⚠ Configuración existente detectada / Existing configuration detected:${COLOR_RESET}"
        
        if [[ -f /etc/bacula/bacula-dir.conf ]]; then
            local director_name
            director_name=$(grep -E "^Director {" /etc/bacula/bacula-dir.conf -A 5 2>/dev/null | grep "Name" | head -1 | cut -d'=' -f2 | tr -d ' ;')
            [[ -n "$director_name" ]] && echo -e "   ${COLOR_CYAN}• Director: $director_name${COLOR_RESET}"
        fi
        
        if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
            local backup_path
            backup_path=$(grep "^BACKUP_PATH=" "$CONFIG_DIR/manager.conf" 2>/dev/null | cut -d'=' -f2)
            [[ -n "$backup_path" ]] && echo -e "   ${COLOR_CYAN}• Backup path: $backup_path${COLOR_RESET}"
        fi
        
        if [[ -f "$REMOTE_CONFIG_DIR/active.conf" ]]; then
            source "$REMOTE_CONFIG_DIR/active.conf" 2>/dev/null
            if [[ "$REMOTE_ENABLED" == "true" ]]; then
                echo -e "   ${COLOR_CYAN}• Remote host: $REMOTE_HOST${COLOR_RESET}"
            fi
        fi
        
        echo ""
        if [[ "$APP_LANG" == "en" ]]; then
            echo -e "${COLOR_DIM}Use option 12 in the menu to reset configuration if needed.${COLOR_RESET}"
        else
            echo -e "${COLOR_DIM}Use la opción 12 en el menú para resetear la configuración si es necesario.${COLOR_RESET}"
        fi
        echo ""
    fi
}

# --- Instalar comando baculamanager / Install baculamanager command ---
install_command() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  COMMAND INSTALLATION / INSTALACIÓN DE COMANDO${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    local script_path
    script_path=$(readlink -f "$0")
    
    echo -e "${COLOR_CYAN}Installing command: baculamanager${COLOR_RESET}"
    echo ""
    
    # Crear enlaces simbólicos
    ln -sf "$script_path" /usr/local/bin/baculamanager 2>/dev/null
    ln -sf "$script_path" /usr/local/bin/bacula-manager 2>/dev/null
    
    if [[ -L /usr/local/bin/baculamanager ]]; then
        echo -e "${COLOR_GREEN}✓ Command installed successfully${COLOR_RESET}"
        echo ""
        echo -e "${COLOR_CYAN}Usage:${COLOR_RESET}"
        echo -e "  ${COLOR_DIM}sudo baculamanager${COLOR_RESET}           - Launch menu"
        echo -e "  ${COLOR_DIM}sudo baculamanager --config${COLOR_RESET}  - View configuration"
        echo -e "  ${COLOR_DIM}sudo baculamanager --status${COLOR_RESET}  - View status"
        echo -e "  ${COLOR_DIM}sudo baculamanager --logs${COLOR_RESET}    - View logs"
        echo -e "  ${COLOR_DIM}sudo baculamanager --help${COLOR_RESET}    - Show help"
        log_message "INFO" "Command baculamanager installed"
    else
        echo -e "${COLOR_RED}✗ Installation failed${COLOR_RESET}"
        log_message "ERROR" "Command installation failed"
    fi
    
    echo ""
}

# --- Ver configuración completa / View full configuration ---
view_full_config() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "menu_config_view")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    # Instalación
    echo -e "${COLOR_BOLD}${COLOR_YELLOW}$(t "config_installation")${COLOR_RESET}"
    
    if is_bacula_installed; then
        local bacula_version
        bacula_version=$(bacula-dir --version 2>&1 | head -1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" || echo "Unknown")
        echo -e "  $(t "config_bacula_installed"): ${COLOR_GREEN}✓ $(t "yes")${COLOR_RESET}"
        echo -e "  $(t "config_version"): ${COLOR_CYAN}$bacula_version${COLOR_RESET}"
    else
        echo -e "  $(t "config_bacula_installed"): ${COLOR_RED}✗ $(t "no")${COLOR_RESET}"
    fi
    
    if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
        local config_date
        config_date=$(stat -c %y "$CONFIG_DIR/manager.conf" 2>/dev/null | cut -d' ' -f1)
        echo -e "  $(t "config_configured"): ${COLOR_GREEN}✓ $(t "yes") ($config_date)${COLOR_RESET}"
    else
        echo -e "  $(t "config_configured"): ${COLOR_YELLOW}$(t "no")${COLOR_RESET}"
    fi
    echo ""
    
    # Servicios - verificar múltiples posibles nombres de servicios
    echo -e "${COLOR_BOLD}${COLOR_YELLOW}$(t "config_services")${COLOR_RESET}"
    
    # Mapear posibles nombres de servicios según distro
    declare -A service_names
    service_names[director]="bacula-dir bacula-director"
    service_names[storage]="bacula-sd bacula-storage"
    service_names[client]="bacula-fd bacula-client bacula-filedaemon"
    
    local running_services=0
    local total_services=3
    
    # Verificar servicio director
    local director_running=false
    local director_name=""
    for svc in ${service_names[director]}; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            director_running=true
            director_name="$svc"
            ((running_services++))
            local pid
            pid=$(systemctl show "$svc" --property=MainPID 2>/dev/null | cut -d= -f2)
            echo -e "  ${COLOR_GREEN}✓ $svc${COLOR_RESET}: $(t "running") (PID: $pid)"
            break
        fi
    done
    if [[ "$director_running" == false ]]; then
        echo -e "  ${COLOR_RED}✗ bacula-dir/director${COLOR_RESET}: $(t "stopped")"
    fi
    
    # Verificar servicio storage
    local storage_running=false
    for svc in ${service_names[storage]}; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            storage_running=true
            ((running_services++))
            local pid
            pid=$(systemctl show "$svc" --property=MainPID 2>/dev/null | cut -d= -f2)
            echo -e "  ${COLOR_GREEN}✓ $svc${COLOR_RESET}: $(t "running") (PID: $pid)"
            break
        fi
    done
    if [[ "$storage_running" == false ]]; then
        echo -e "  ${COLOR_RED}✗ bacula-sd${COLOR_RESET}: $(t "stopped")"
    fi
    
    # Verificar servicio cliente
    local client_running=false
    for svc in ${service_names[client]}; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            client_running=true
            ((running_services++))
            local pid
            pid=$(systemctl show "$svc" --property=MainPID 2>/dev/null | cut -d= -f2)
            echo -e "  ${COLOR_GREEN}✓ $svc${COLOR_RESET}: $(t "running") (PID: $pid)"
            break
        fi
    done
    if [[ "$client_running" == false ]]; then
        echo -e "  ${COLOR_RED}✗ bacula-fd/client${COLOR_RESET}: $(t "stopped")"
    fi
    
    # Resumen de servicios
    if [[ $running_services -eq $total_services ]]; then
        echo -e "  ${COLOR_GREEN}✓ All services running ($running_services/$total_services)${COLOR_RESET}"
    elif [[ $running_services -gt 0 ]]; then
        echo -e "  ${COLOR_YELLOW}⚠ Some services running ($running_services/$total_services)${COLOR_RESET}"
    fi
    echo ""
    
    # Configuración local
    echo -e "${COLOR_BOLD}${COLOR_YELLOW}$(t "config_local")${COLOR_RESET}"
    if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
        source "$CONFIG_DIR/manager.conf" 2>/dev/null
        echo -e "  $(t "config_director_name"): ${COLOR_CYAN}${DIRECTOR_NAME:-$(hostname -s)-dir}${COLOR_RESET}"
        echo -e "  $(t "config_backup_path"): ${COLOR_CYAN}${BACKUP_PATH:-/backups}${COLOR_RESET}"
        echo -e "  $(t "config_retention"): ${COLOR_CYAN}${RETENTION_DAYS:-30} $(t "days")${COLOR_RESET}"
        echo -e "  $(t "config_compression"): ${COLOR_CYAN}${COMPRESSION:-GZIP level 6}${COLOR_RESET}"
        echo -e "  $(t "config_backup_type"): ${COLOR_CYAN}${BACKUP_TYPE:-Incremental}${COLOR_RESET}"
    else
        echo -e "  ${COLOR_YELLOW}$(t "config_not_configured")${COLOR_RESET}"
    fi
    echo ""
    
    # Configuración remota
    echo -e "${COLOR_BOLD}${COLOR_YELLOW}$(t "config_remote")${COLOR_RESET}"
    if [[ -f "$REMOTE_CONFIG_DIR/active.conf" ]]; then
        source "$REMOTE_CONFIG_DIR/active.conf" 2>/dev/null
        if [[ "$REMOTE_ENABLED" == "true" ]]; then
            echo -e "  $(t "config_remote_enabled"): ${COLOR_GREEN}✓ $(t "yes")${COLOR_RESET}"
            echo -e "  $(t "config_remote_host"): ${COLOR_CYAN}$REMOTE_HOST${COLOR_RESET}"
            echo -e "  $(t "config_remote_user"): ${COLOR_CYAN}$REMOTE_USER${COLOR_RESET}"
            
            local conn_type_text
            case $CONNECTION_TYPE in
                1) conn_type_text="$(t "option_ssh_tunnel")" ;;
                2) conn_type_text="$(t "option_direct")" ;;
                3) conn_type_text="$(t "option_vpn")" ;;
                *) conn_type_text="Unknown" ;;
            esac
            echo -e "  $(t "config_connection_type"): ${COLOR_CYAN}$conn_type_text${COLOR_RESET}"
            echo -e "  $(t "config_remote_path"): ${COLOR_CYAN}$REMOTE_PATH${COLOR_RESET}"
            echo -e "  $(t "config_ssh_key"): ${COLOR_CYAN}${SSH_KEY:-bacula_remote}${COLOR_RESET}"
            
            # Verificar estado de conexión
            if test_ssh_connection "$REMOTE_HOST" "$REMOTE_USER" "${SSH_KEY:-bacula_remote}" 2>/dev/null; then
                echo -e "  $(t "config_connection_status"): ${COLOR_GREEN}✓ $(t "connected")${COLOR_RESET}"
            else
                echo -e "  $(t "config_connection_status"): ${COLOR_RED}✗ $(t "disconnected")${COLOR_RESET}"
            fi
        else
            echo -e "  $(t "config_remote_enabled"): ${COLOR_YELLOW}$(t "no")${COLOR_RESET}"
        fi
    else
        echo -e "  $(t "config_remote_not_configured")${COLOR_RESET}"
    fi
    echo ""
    
    # Almacenamiento
    echo -e "${COLOR_BOLD}${COLOR_YELLOW}$(t "config_storage")${COLOR_RESET}"
    if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
        local backup_path
        backup_path=$(grep BACKUP_PATH "$CONFIG_DIR/manager.conf" 2>/dev/null | cut -d= -f2)
        if [[ -d "$backup_path" ]]; then
            local available used
            available=$(df -h "$backup_path" 2>/dev/null | awk 'NR==2 {print $4}')
            used=$(df -h "$backup_path" 2>/dev/null | awk 'NR==2 {print $3}')
            echo -e "  $(t "config_available"): ${COLOR_GREEN}$available${COLOR_RESET}"
            echo -e "  $(t "config_used"): ${COLOR_CYAN}$used${COLOR_RESET}"
        fi
    fi
    
    # Contar volumes de Bacula
    if command -v bconsole &>/dev/null; then
        local volume_count
        volume_count=$(echo "list volumes" | bconsole 2>/dev/null | grep -c "^" || echo "0")
        echo -e "  $(t "config_total_volumes"): ${COLOR_CYAN}$volume_count${COLOR_RESET}"
    fi
    echo ""
    
    read -rp "$(t "press_continue")"
}

# --- Resetear configuración / Reset configuration ---
reset_configuration() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "menu_config_reset")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    echo -e "${COLOR_RED}${COLOR_BOLD}⚠ $(t "reset_warning")${COLOR_RESET}"
    echo ""
    
    echo "  1) $(t "reset_local")"
    echo "  2) $(t "reset_remote")"
    echo "  3) $(t "reset_ssh_keys")"
    echo "  4) $(t "reset_logs")"
    echo "  5) $(t "reset_all") ${COLOR_RED}[DANGER]${COLOR_RESET}"
    echo "  6) $(t "back")"
    echo ""
    
    read -rp "   $(t "select_option") [1-6]: " reset_choice
    
    case $reset_choice in
        1)
            if confirm "$(t "confirm_reset_local")"; then
                echo -e "${COLOR_CYAN}$(t "resetting_local")...${COLOR_RESET}"
                systemctl stop bacula-dir bacula-sd bacula-fd 2>/dev/null || true
                
                # Backup de configuración anterior
                local backup_dir="/etc/bacula/backup-$(date +%Y%m%d-%H%M%S)"
                mkdir -p "$backup_dir"
                cp /etc/bacula/*.conf "$backup_dir/" 2>/dev/null || true
                
                rm -f /etc/bacula/bacula-dir.conf /etc/bacula/bacula-sd.conf /etc/bacula/bacula-fd.conf /etc/bacula/bacula-sd-remote.conf 2>/dev/null || true
                rm -f "$CONFIG_DIR/manager.conf" "$CONFIG_DIR/db_credentials.conf" 2>/dev/null || true
                
                echo -e "${COLOR_GREEN}✓ $(t "reset_local_complete")${COLOR_RESET}"
                echo -e "   ${COLOR_DIM}$(t "backup_saved"): $backup_dir${COLOR_RESET}"
                log_message "INFO" "Local configuration reset"
            fi
            ;;
        2)
            if confirm "$(t "confirm_reset_remote")"; then
                echo -e "${COLOR_CYAN}$(t "resetting_remote")...${COLOR_RESET}"
                
                # Detener túneles SSH
                pkill -f "bacula-ssh-tunnel" 2>/dev/null || true
                
                # Remover configuración remota
                rm -rf "$REMOTE_CONFIG_DIR"/* 2>/dev/null || true
                rm -f /etc/bacula/bacula-sd-remote.conf 2>/dev/null || true
                
                # Remover credenciales remotas del environment
                if [[ -f "$ENV_FILE" ]]; then
                    grep -v "^REMOTE_" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
                    mv "${ENV_FILE}.tmp" "$ENV_FILE" 2>/dev/null || true
                fi
                
                echo -e "${COLOR_GREEN}✓ $(t "reset_remote_complete")${COLOR_RESET}"
                log_message "INFO" "Remote configuration reset"
            fi
            ;;
        3)
            if confirm "$(t "confirm_reset_ssh")"; then
                echo -e "${COLOR_CYAN}$(t "resetting_ssh")...${COLOR_RESET}"
                rm -f "$SSH_DIR/bacula_remote" "$SSH_DIR/bacula_remote.pub" 2>/dev/null || true
                echo -e "${COLOR_GREEN}✓ $(t "reset_ssh_complete")${COLOR_RESET}"
                log_message "INFO" "SSH keys reset"
            fi
            ;;
        4)
            if confirm "$(t "confirm_reset_logs")"; then
                echo -e "${COLOR_CYAN}$(t "resetting_logs")...${COLOR_RESET}"
                rm -f "$LOG_DIR"/*.log 2>/dev/null || true
                echo -e "${COLOR_GREEN}✓ $(t "reset_logs_complete")${COLOR_RESET}"
                log_message "INFO" "Logs cleared"
            fi
            ;;
        5)
            echo -e "${COLOR_RED}${COLOR_BOLD}"
            echo "╔═══════════════════════════════════════════════════════════════════════════╗"
            echo "║                    ⚠️  DANGER - TOTAL RESET  ⚠️                            ║"
            echo "╠═══════════════════════════════════════════════════════════════════════════╣"
            echo "║  This will DELETE ALL configuration, databases, and backups!             ║"
            echo "║  Esta acción ELIMINARÁ TODA la configuración, bases de datos y respaldos  ║"
            echo "╚═══════════════════════════════════════════════════════════════════════════╝"
            echo -e "${COLOR_RESET}"
            
            read -rp "Type 'RESET' to confirm / Escriba 'RESET' para confirmar: " confirm_text
            
            if [[ "$confirm_text" == "RESET" ]]; then
                echo -e "${COLOR_RED}$(t "resetting_all")...${COLOR_RESET}"
                
                systemctl stop bacula-dir bacula-sd bacula-fd postgresql 2>/dev/null || true
                
                rm -rf /etc/bacula/*.conf 2>/dev/null || true
                rm -rf "$CONFIG_DIR" 2>/dev/null || true
                rm -rf "$REMOTE_CONFIG_DIR" 2>/dev/null || true
                rm -f "$SSH_DIR/bacula_remote"* 2>/dev/null || true
                rm -f /usr/local/bin/baculamanager /usr/local/bin/bacula-manager 2>/dev/null || true
                rm -f /usr/local/bin/bacula-ssh-tunnel.sh 2>/dev/null || true
                
                # Limpiar crontab
                crontab -l 2>/dev/null | grep -v "bacula" | crontab - 2>/dev/null || true
                
                echo -e "${COLOR_GREEN}✓ $(t "reset_all_complete")${COLOR_RESET}"
                echo -e "${COLOR_YELLOW}$(t "reinstall_needed")${COLOR_RESET}"
                log_message "INFO" "Complete reset executed"
            else
                echo -e "${COLOR_YELLOW}$(t "reset_cancelled")${COLOR_RESET}"
            fi
            ;;
        6) return ;;
        *) echo -e "${COLOR_RED}$(t "invalid_option")${COLOR_RESET}" ;;
    esac
    
    read -rp "$(t "press_continue")"
}

# =============================================================================
# FUNCIONES DE RESPALDO REMOTO / REMOTE BACKUP FUNCTIONS
# =============================================================================

# --- Configurar respaldo remoto / Configure remote backup ---
configure_remote_backup() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "remote_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    log_message "INFO" "Starting remote backup configuration"
    
    # Inicializar almacenamiento seguro
    init_secure_storage
    
    # Preguntar si habilitar respaldo remoto
    echo -e "${COLOR_CYAN}$(t "remote_explain")${COLOR_RESET}"
    echo ""
    
    if ! confirm "$(t "remote_enable")"; then
        echo -e "${COLOR_YELLOW}$(t "cancel")${COLOR_RESET}"
        read -rp "$(t "press_continue")"
        return
    fi
    
    echo ""
    
    # Recopilar información del host remoto
    local remote_host
    local remote_user
    local remote_password
    local remote_path
    local connection_type
    
    # 1. Host remoto
    echo -e "${COLOR_BOLD}1. $(t "ask_remote_host")${COLOR_RESET}"
    read -rp "   $(t "select_option"): " remote_host
    
    if [[ -z "$remote_host" ]]; then
        error_exit "Remote host is required"
    fi
    
    # Verificar formato de IP o hostname
    if ! [[ "$remote_host" =~ ^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$ ]] && ! [[ "$remote_host" =~ ^[a-zA-Z0-9][a-zA-Z0-9\-\.]*$ ]]; then
        echo -e "${COLOR_YELLOW}⚠ Invalid host format. Using anyway...${COLOR_RESET}"
    fi
    echo ""
    
    # 2. Usuario remoto
    echo -e "${COLOR_BOLD}2. $(t "ask_remote_user")${COLOR_RESET}"
    read -rp "   $(t "select_option") [root]: " remote_user
    remote_user=${remote_user:-root}
    echo ""
    
    # 3. Contraseña para configuración inicial SSH
    echo -e "${COLOR_BOLD}3. $(t "ask_remote_password")${COLOR_RESET}"
    echo -e "   ${COLOR_DIM}(Leave empty if SSH key already configured)${COLOR_RESET}"
    read -rsp "   Password: " remote_password
    echo ""
    echo ""
    
    # 4. Ruta remota
    echo -e "${COLOR_BOLD}4. $(t "ask_remote_path")${COLOR_RESET}"
    echo -e "   ${COLOR_DIM}$(t "explain_remote_path")${COLOR_RESET}"
    remote_path=$(read_line_edit "   $(t "select_option")" "/backups/remote")
    remote_path=${remote_path:-/backups/remote}
    echo ""
    
    # 5. Tipo de conexión
    echo -e "${COLOR_BOLD}5. $(t "remote_connection_type")${COLOR_RESET}"
    echo "   1) $(t "option_ssh_tunnel")"
    echo "   2) $(t "option_direct")"
    echo "   3) $(t "option_vpn")"
    
    while true; do
        read -rp "   $(t "select_option") [1-3]: " connection_type
        case $connection_type in
            1|2|3) break ;;
            *) echo -e "   ${COLOR_RED}$(t "invalid_option")${COLOR_RESET}" ;;
        esac
    done
    echo ""
    
    # Verificar conectividad de red
    echo -e "${COLOR_CYAN}$(t "network_test_title")${COLOR_RESET}"
    if ! verify_network_connectivity "$remote_host" 22 10; then
        echo ""
        echo -e "${COLOR_YELLOW}$(t "remote_test_failed")${COLOR_RESET}"
        if ! confirm "Continue anyway?"; then
            return
        fi
    fi
    echo ""
    
    # Generar y desplegar claves SSH
    echo -e "${COLOR_CYAN}$(t "ssh_keys_title")${COLOR_RESET}"
    generate_ssh_keys "bacula_remote"
    
    # Desplegar clave al host remoto
    if distribute_ssh_key "$remote_host" "$remote_user" "$remote_password" "bacula_remote"; then
        echo -e "   ${COLOR_GREEN}✓ SSH authentication configured${COLOR_RESET}"
    else
        echo -e "   ${COLOR_RED}✗ SSH setup failed${COLOR_RESET}"
        read -rp "$(t "press_continue")"
        return 1
    fi
    echo ""
    
    # Guardar credenciales de forma segura
    save_credential "REMOTE_HOST" "$remote_host" "$ENV_FILE"
    save_credential "REMOTE_USER" "$remote_user" "$ENV_FILE"
    save_credential "REMOTE_PATH" "$remote_path" "$ENV_FILE"
    save_credential "REMOTE_TYPE" "$connection_type" "$ENV_FILE"
    
    # Configurar Bacula para respaldo remoto
    configure_remote_storage "$remote_host" "$remote_user" "$remote_path" "$connection_type"
    
    # Guardar configuración remota
    cat > "$REMOTE_CONFIG_DIR/active.conf" << EOF
REMOTE_ENABLED=true
REMOTE_HOST=$remote_host
REMOTE_USER=$remote_user
REMOTE_PATH=$remote_path
CONNECTION_TYPE=$connection_type
SSH_KEY=bacula_remote
CONFIG_DATE=$(date -Iseconds)
EOF
    chmod 600 "$REMOTE_CONFIG_DIR/active.conf"
    
    echo -e "${COLOR_GREEN}✓ $(t "remote_config_success")${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}$(t "security_credentials_stored")${COLOR_RESET}"
    echo -e "   ${COLOR_CYAN}$(t "security_env_auto")${COLOR_RESET}"
    
    log_message "INFO" "Remote backup configured for host: $remote_host"
    
    read -rp "$(t "press_continue")"
}

# --- Configurar almacenamiento remoto Bacula / Configure remote Bacula storage ---
configure_remote_storage() {
    local remote_host="${1:-}"
    local remote_user="${2:-}"
    local remote_path="${3:-}"
    local connection_type="${4:-}"
    
    # Crear configuración de dispositivo remoto
    local storage_config="/etc/bacula/bacula-sd-remote.conf"
    
    case $connection_type in
        1)  # SSH Tunnel
            cat > "$storage_config" << EOF
# Remote Storage via SSH Tunnel
# Generated by Bacula Manager

Storage {
    Name = RemoteStorage-SSH
    Address = 127.0.0.1
    SDPort = 9104
    Password = "$(generate_password)"
    Device = RemoteFileStorage
    Media Type = RemoteFile
    Maximum Concurrent Jobs = 5
}

Device {
    Name = RemoteFileStorage
    Media Type = RemoteFile
    Archive Device = "ssh:${remote_user}@${remote_host}:${remote_path}"
    LabelMedia = yes
    Random Access = yes
    AutomaticMount = yes
    RemovableMedia = no
    AlwaysOpen = no
}
EOF
            # Configurar túnel SSH automático
            setup_ssh_tunnel "$remote_host" "$remote_user" 9104 9103
            ;;
        2|3)  # Direct o VPN
            cat > "$storage_config" << EOF
# Remote Storage Direct Connection
# Generated by Bacula Manager

Storage {
    Name = RemoteStorage-Direct
    Address = $remote_host
    SDPort = 9103
    Password = "$(generate_password)"
    Device = RemoteFileStorage
    Media Type = RemoteFile
    Maximum Concurrent Jobs = 5
}
EOF
            ;;
    esac
    
    chmod 640 "$storage_config"
    chown root:bacula "$storage_config"
    
    # Actualizar configuración del Director para incluir almacenamiento remoto
    update_director_for_remote "$storage_config"
}

# --- Configurar túnel SSH / Setup SSH tunnel ---
setup_ssh_tunnel() {
    local remote_host="${1:-}"
    local remote_user="${2:-}"
    local local_port="${3:-9104}"
    local remote_port="${4:-9103}"
    
    # Crear script de inicio del túnel
    local tunnel_script="/usr/local/bin/bacula-ssh-tunnel.sh"
    
    cat > "$tunnel_script" << EOF
#!/bin/bash
# Bacula SSH Tunnel Script
# Auto-generated by Bacula Manager

SSH_KEY="${SSH_DIR}/bacula_remote"
REMOTE_HOST="$remote_host"
REMOTE_USER="$remote_user"
LOCAL_PORT="$local_port"
REMOTE_PORT="$remote_port"

# Verificar si el túnel ya está activo
if ! pgrep -f "ssh.*$LOCAL_PORT.*$REMOTE_PORT" > /dev/null; then
    ssh -o BatchMode=yes -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \\
        -o StrictHostKeyChecking=yes \\
        -i "\$SSH_KEY" \\
        -L "\$LOCAL_PORT:localhost:\$REMOTE_PORT" \\
        -N "\$REMOTE_USER@\$REMOTE_HOST" &
fi
EOF
    
    chmod 750 "$tunnel_script"
    
    # Agregar al cron para inicio automático
    (crontab -l 2>/dev/null | grep -v "bacula-ssh-tunnel"; echo "@reboot $tunnel_script") | crontab -
    
    # Iniciar túnel ahora
    "$tunnel_script"
    
    log_message "INFO" "SSH tunnel configured: localhost:$local_port -> $remote_host:$remote_port"
}

# --- Actualizar Director para soporte remoto / Update Director for remote support ---
update_director_for_remote() {
    local storage_config="${1:-}"
    
    # Agregar @include al bacula-dir.conf si no existe
    if ! grep -q "@$storage_config" /etc/bacula/bacula-dir.conf 2>/dev/null; then
        echo "@$storage_config" >> /etc/bacula/bacula-dir.conf
    fi
    
    # Agregar job de respaldo remoto
    if ! grep -q "BackupRemoteFiles" /etc/bacula/bacula-dir.conf 2>/dev/null; then
        cat >> /etc/bacula/bacula-dir.conf << EOF

Job {
    Name = "BackupRemoteFiles"
    JobDefs = "DefaultJob"
    Storage = RemoteStorage-SSH
    Enabled = yes
}
EOF
    fi
    
    # Recargar configuración
    systemctl restart bacula-dir 2>/dev/null || true
}

# --- Gestionar claves SSH / Manage SSH keys ---
manage_ssh_keys() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "ssh_keys_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    init_secure_storage
    
    echo "  1) $(t "ssh_key_generate")"
    echo "  2) $(t "ssh_key_deploy")"
    echo "  3) $(t "ssh_key_test")"
    echo "  4) $(t "back")"
    echo ""
    
    read -rp "   $(t "select_option") [1-4]: " ssh_choice
    
    case $ssh_choice in
        1)
            generate_ssh_keys "bacula_remote"
            echo -e "${COLOR_GREEN}✓ SSH keys generated${COLOR_RESET}"
            ;;
        2)
            local remote_host
            local remote_user
            local remote_password
            
            read -rp "   $(t "ask_remote_host"): " remote_host
            read -rp "   $(t "ask_remote_user") [root]: " remote_user
            remote_user=${remote_user:-root}
            read -rsp "   $(t "ask_remote_password"): " remote_password
            echo ""
            
            if distribute_ssh_key "$remote_host" "$remote_user" "$remote_password" "bacula_remote"; then
                echo -e "${COLOR_GREEN}✓ SSH key deployed successfully${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}✗ Failed to deploy SSH key${COLOR_RESET}"
            fi
            ;;
        3)
            local remote_host
            local remote_user
            
            read -rp "   $(t "ask_remote_host"): " remote_host
            read -rp "   $(t "ask_remote_user") [root]: " remote_user
            remote_user=${remote_user:-root}
            
            echo -e "${COLOR_CYAN}Testing SSH connection...${COLOR_RESET}"
            if test_ssh_connection "$remote_host" "$remote_user" "bacula_remote"; then
                echo -e "${COLOR_GREEN}✓ SSH connection successful${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}✗ SSH connection failed${COLOR_RESET}"
            fi
            ;;
        4) return ;;
        *) echo -e "${COLOR_RED}$(t "invalid_option")${COLOR_RESET}" ;;
    esac
    
    read -rp "$(t "press_continue")"
}

# --- Probar conectividad de red / Test network connectivity menu ---
test_network_connectivity() {
    show_banner
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "network_test_title")${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    # Mostrar segmento de red actual
    echo -e "${COLOR_BOLD}$(t "network_segment")${COLOR_RESET}"
    for interface in eth0 ens160 enp3s0; do
        local segment
        segment=$(detect_network_segment "$interface" 2>/dev/null)
        if [[ "$segment" != "unknown" ]]; then
            echo -e "  ${COLOR_CYAN}$interface: $segment${COLOR_RESET}"
        fi
    done
    echo ""
    
    # Probar host específico
    read -rp "   $(t "network_host_check"): " target_host
    
    if [[ -n "$target_host" ]]; then
        echo ""
        if ! verify_network_connectivity "$target_host" 22 10; then
            echo -e "${COLOR_YELLOW}Network test completed with issues${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_YELLOW}No host specified, skipping network test${COLOR_RESET}"
    fi
    
    echo ""
    read -rp "$(t "press_continue")"
}

# =============================================================================
# MENÚ PRINCIPAL / MAIN MENU
# =============================================================================

# --- Leer selección de menú simplificado / Simple menu input ---
read_menu_choice() {
    local prompt="${1:-Select option}"
    local min_choice="${2:-0}"
    local max_choice="${3:-15}"
    local default_choice="${4:-1}"
    local input

    while true; do
        # Prompt va a stderr para no contaminar el retorno
        echo -ne "${prompt} [${min_choice}-${max_choice}]: " >&2
        read -r input
        
        # Eliminar espacios en blanco / Trim whitespace
        input=$(echo "$input" | tr -d '[:space:]')
        
        # Si no hay entrada, usar default
        if [[ -z "$input" ]]; then
            input="$default_choice"
        fi
        
        # Validar que sea número
        if [[ "$input" =~ ^[0-9]+$ ]]; then
            if [[ "$input" -ge "$min_choice" ]] && [[ "$input" -le "$max_choice" ]]; then
                echo "$input"
                return 0
            fi
        fi
        
        # Error también va a stderr
        echo -e "${COLOR_RED}Invalid option. Please enter a number between ${min_choice} and ${max_choice}.${COLOR_RESET}" >&2
    done
}

# --- Leer entrada de texto simplificada / Read text input simplified ---
read_line_edit() {
    local prompt="${1:-Enter text}"
    local default="${2:-}"
    local input
    
    # Mostrar prompt con default
    if [[ -n "$default" ]]; then
        echo -ne "${prompt} [${default}]: " >&2
    else
        echo -ne "${prompt}: " >&2
    fi
    
    # Leer entrada básica
    read -r input
    
    # Si no hay entrada, usar default
    if [[ -z "$input" ]] && [[ -n "$default" ]]; then
        input="$default"
    fi
    
    # Retornar solo el valor (a stdout)
    echo "$input"
}

# --- Reparar permisos de Bacula / Fix Bacula permissions ---
fix_bacula_permissions() {
    # Crear usuario/grupo bacula si no existen
    if ! getent group bacula >/dev/null 2>&1; then
        groupadd bacula 2>/dev/null || true
    fi
    if ! getent passwd bacula >/dev/null 2>&1; then
        useradd -g bacula -d /var/lib/bacula -s /bin/false bacula 2>/dev/null || true
    fi
    
    # Directorios de configuración
    if [[ -d /etc/bacula ]]; then
        chown -R root:bacula /etc/bacula 2>/dev/null || true
        chmod 755 /etc/bacula 2>/dev/null || true
        chmod 640 /etc/bacula/*.conf 2>/dev/null || true
    fi
    
    # Directorio de trabajo (working directory) - CRÍTICO
    mkdir -p /var/lib/bacula 2>/dev/null || true
    chown -R bacula:bacula /var/lib/bacula 2>/dev/null || true
    chmod 755 /var/lib/bacula 2>/dev/null || true
    
    # Directorio de logs
    mkdir -p /var/log/bacula 2>/dev/null || true
    chown -R bacula:bacula /var/log/bacula 2>/dev/null || true
    chmod 755 /var/log/bacula 2>/dev/null || true
    
    # Directorio de PID
    mkdir -p /run/bacula /var/run/bacula 2>/dev/null || true
    chown -R bacula:bacula /run/bacula /var/run/bacula 2>/dev/null || true
    chmod 755 /run/bacula /var/run/bacula 2>/dev/null || true
    
    # Script directory (para PostgreSQL scripts)
    mkdir -p /etc/bacula/scripts 2>/dev/null || true
    chown -R bacula:bacula /etc/bacula/scripts 2>/dev/null || true
    chmod 755 /etc/bacula/scripts 2>/dev/null || true
    
    # Backup path (si existe configuración)
    if [[ -f "$CONFIG_DIR/manager.conf" ]]; then
        source "$CONFIG_DIR/manager.conf" 2>/dev/null
        if [[ -n "$BACKUP_PATH" ]] && [[ -d "$BACKUP_PATH" ]]; then
            chown -R bacula:bacula "$BACKUP_PATH" 2>/dev/null || true
            chmod 755 "$BACKUP_PATH" 2>/dev/null || true
        fi
    fi
    
    # Archivos de log específicos
    touch /var/log/bacula/bacula.log 2>/dev/null || true
    chown bacula:bacula /var/log/bacula/bacula.log 2>/dev/null || true
    chmod 644 /var/log/bacula/bacula.log 2>/dev/null || true
}

# --- Pre-flight check para bacula-dir / Pre-flight check for bacula-dir ---
preflight_check_bacula_dir() {
    local error_log="/tmp/bacula_dir_error.log"
    local config_file="/etc/bacula/bacula-dir.conf"
    
    # Verificar que el archivo de configuración existe
    if [[ ! -f "$config_file" ]]; then
        echo -e "    ${COLOR_RED}✗ Configuration file not found: $config_file${COLOR_RESET}"
        return 1
    fi
    
    # Ejecutar validación de configuración
    echo -e "    ${COLOR_CYAN}→ Validating bacula-dir configuration...${COLOR_RESET}"
    
    if sudo bacula-dir -t -c "$config_file" > "$error_log" 2>&1; then
        echo -e "    ${COLOR_GREEN}✓ Configuration validation passed${COLOR_RESET}"
        rm -f "$error_log"
        return 0
    else
        echo -e "    ${COLOR_RED}╔══════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
        echo -e "    ${COLOR_RED}║  ✗ Error fatal en la configuración de bacula-dir                 ║${COLOR_RESET}"
        echo -e "    ${COLOR_RED}╚══════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
        echo ""
        echo -e "    ${COLOR_YELLOW}Detalles del error:${COLOR_RESET}"
        echo ""
        # Mostrar el contenido del log de errores
        while IFS= read -r line; do
            echo -e "      ${COLOR_RED}$line${COLOR_RESET}"
        done < "$error_log"
        echo ""
        echo -e "    ${COLOR_YELLOW}➤ El servicio no se reiniciará hasta que se corrija la configuración.${COLOR_RESET}"
        echo -e "    ${COLOR_DIM}  Use la opción 6 (Reconfigure) o edite manualmente:${COLOR_RESET}"
        echo -e "    ${COLOR_DIM}    sudo nano $config_file${COLOR_RESET}"
        rm -f "$error_log"
        return 1
    fi
}

# --- Pre-flight check para bacula-sd / Pre-flight check for bacula-sd ---
preflight_check_bacula_sd() {
    local error_log="/tmp/bacula_sd_error.log"
    local config_file="/etc/bacula/bacula-sd.conf"
    
    # Verificar que el archivo de configuración existe
    if [[ ! -f "$config_file" ]]; then
        echo -e "    ${COLOR_RED}✗ Configuration file not found: $config_file${COLOR_RESET}"
        return 1
    fi
    
    # Ejecutar validación de configuración
    echo -e "    ${COLOR_CYAN}→ Validating bacula-sd configuration...${COLOR_RESET}"
    
    if sudo bacula-sd -t -c "$config_file" > "$error_log" 2>&1; then
        echo -e "    ${COLOR_GREEN}✓ Configuration validation passed${COLOR_RESET}"
        rm -f "$error_log"
        return 0
    else
        echo -e "    ${COLOR_RED}╔══════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
        echo -e "    ${COLOR_RED}║  ✗ Error fatal en la configuración de bacula-sd                  ║${COLOR_RESET}"
        echo -e "    ${COLOR_RED}╚══════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
        echo ""
        echo -e "    ${COLOR_YELLOW}Detalles del error:${COLOR_RESET}"
        echo ""
        # Mostrar el contenido del log de errores
        while IFS= read -r line; do
            echo -e "      ${COLOR_RED}$line${COLOR_RESET}"
        done < "$error_log"
        echo ""
        echo -e "    ${COLOR_YELLOW}➤ El servicio no se iniciará hasta que se corrija la configuración.${COLOR_RESET}"
        echo -e "    ${COLOR_DIM}  Use la opción 6 (Reconfigure) o edite manualmente:${COLOR_RESET}"
        echo -e "    ${COLOR_DIM}    sudo nano $config_file${COLOR_RESET}"
        return 1
    fi
}

show_menu() {
    show_banner
    
    local lang_indicator="🇪🇸"
    [[ "$APP_LANG" == "en" ]] && lang_indicator="🇺🇸"
    
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo -e "${COLOR_BOLD}  $(t "menu_title") ${lang_indicator}${COLOR_RESET}"
    echo -e "${COLOR_BOLD}${COLOR_BLUE}═══════════════════════════════════════════════════════════════════════════${COLOR_RESET}"
    echo ""
    
    # Verificar estado de instalación y remoto / Check installation and remote status
    local install_status="${COLOR_RED}✗ Not installed${COLOR_RESET}"
    local remote_status=""
    local bacula_installed=false
    if is_bacula_installed; then
        install_status="${COLOR_GREEN}✓ Installed${COLOR_RESET}"
        bacula_installed=true
    fi
    
    if [[ -f "$REMOTE_CONFIG_DIR/active.conf" ]]; then
        remote_status=" | ${COLOR_GREEN}🌐 Remote${COLOR_RESET}"
        source "$REMOTE_CONFIG_DIR/active.conf" 2>/dev/null
        if [[ "$REMOTE_ENABLED" == "true" ]]; then
            remote_status=" | ${COLOR_GREEN}🌐 Remote: $REMOTE_HOST${COLOR_RESET}"
        fi
    fi
    
    echo -e "  ${COLOR_DIM}Status: $install_status$remote_status${COLOR_RESET}"

    # Extra brief status of services continuously
    echo -e "  ${COLOR_DIM}Services:${COLOR_RESET}"
    local services_stopped=false
    for svc in bacula-dir bacula-sd bacula-fd; do
        if systemctl is-active --quiet $svc 2>/dev/null; then
            echo -e "    ${COLOR_GREEN}✓ $svc is running${COLOR_RESET}"
        else
            echo -e "    ${COLOR_RED}✗ $svc is stopped${COLOR_RESET}"
            services_stopped=true
        fi
    done
    
    # Try to start stopped services automatically
    if [[ "$services_stopped" == true ]]; then
        echo -e "  ${COLOR_YELLOW}Attempting to start stopped services...${COLOR_RESET}"
        for svc in bacula-dir bacula-sd bacula-fd; do
            if ! systemctl is-active --quiet $svc 2>/dev/null; then
                # Check if service exists first
                if ! systemctl list-unit-files | grep -q "^${svc}.service"; then
                    echo -e "    ${COLOR_YELLOW}⚠ $svc service not installed${COLOR_RESET}"
                    continue
                fi
                
                # Para bacula-sd, ejecutar pre-flight check antes de iniciar
                if [[ "$svc" == "bacula-sd" ]]; then
                    if ! preflight_check_bacula_sd; then
                        # El pre-flight check falló, no intentar iniciar
                        continue
                    fi
                fi
                
                if systemctl start $svc 2>/dev/null; then
                    echo -e "    ${COLOR_GREEN}✓ $svc started${COLOR_RESET}"
                else
                    echo -e "    ${COLOR_RED}✗ $svc failed to start${COLOR_RESET}"
                    # Try to fix permissions and restart
                    echo -e "    ${COLOR_YELLOW}  Attempting to fix permissions...${COLOR_RESET}"
                    fix_bacula_permissions >/dev/null 2>&1
                    if systemctl start $svc 2>/dev/null; then
                        echo -e "    ${COLOR_GREEN}✓ $svc started after fixing permissions${COLOR_RESET}"
                    else
                        echo -e "    ${COLOR_RED}✗ $svc still failed (check: systemctl status $svc)${COLOR_RESET}"
                    fi
                fi
            fi
        done
    fi
    echo ""
    
    # Si Bacula no está instalado, mostrar mensaje prominente
    if [[ "$bacula_installed" == false ]]; then
        echo -e "${COLOR_RED}╔═══════════════════════════════════════════════════════════════════════════╗${COLOR_RESET}"
        echo -e "${COLOR_RED}║  ⚠ BACULA IS NOT INSTALLED                                               ║${COLOR_RESET}"
        echo -e "${COLOR_RED}║                                                                            ║${COLOR_RESET}"
        echo -e "${COLOR_RED}║  Please select option 2 to install Bacula first.                          ║${COLOR_RESET}"
        echo -e "${COLOR_RED}║  Options 3-15 require Bacula to be installed.                            ║${COLOR_RESET}"
        echo -e "${COLOR_RED}╚═══════════════════════════════════════════════════════════════════════════╝${COLOR_RESET}"
        echo ""
    fi
    
    # Language toggle option
    local lang_toggle
    if [[ "$APP_LANG" == "en" ]]; then
        lang_toggle="Translate to Spanish"
    else
        lang_toggle="Traducir al Inglés"
    fi
    
    echo -e "  ${COLOR_CYAN}1)${COLOR_RESET} $lang_toggle"
    echo -e "  ${COLOR_CYAN}2)${COLOR_RESET} $(t "menu_install")"
    echo -e "  ${COLOR_CYAN}3)${COLOR_RESET} $(t "menu_backup")"
    echo -e "  ${COLOR_CYAN}4)${COLOR_RESET} $(t "menu_restore")"
    echo -e "  ${COLOR_CYAN}5)${COLOR_RESET} $(t "menu_status")"
    echo -e "  ${COLOR_CYAN}6)${COLOR_RESET} $(t "menu_configure")"
    echo -e "  ${COLOR_CYAN}7)${COLOR_RESET} $(t "menu_logs")"
    echo -e "  ${COLOR_CYAN}8)${COLOR_RESET} $(t "menu_test")"
    echo ""
    echo -e "${COLOR_YELLOW}  Remote Backup Options:${COLOR_RESET}"
    echo -e "  ${COLOR_CYAN}9)${COLOR_RESET} $(t "menu_remote")"
    echo -e "  ${COLOR_CYAN}10)${COLOR_RESET} $(t "menu_ssh_manage")"
    echo -e "  ${COLOR_CYAN}11)${COLOR_RESET} $(t "menu_network_test")"
    echo ""
    echo -e "${COLOR_YELLOW}  Management Options:${COLOR_RESET}"
    echo -e "  ${COLOR_CYAN}12)${COLOR_RESET} $(t "menu_config_reset")"
    echo -e "  ${COLOR_CYAN}13)${COLOR_RESET} $(t "menu_config_view")"
    echo -e "  ${COLOR_CYAN}14)${COLOR_RESET} $(t "menu_email_status")"
    echo -e "  ${COLOR_CYAN}15)${COLOR_RESET} $(t "menu_port_management")"
    echo ""
    echo -e "  ${COLOR_RED}0)${COLOR_RESET} $(t "menu_exit")"
    echo ""
    echo -e "${COLOR_BLUE}───────────────────────────────────────────────────────────────────────────${COLOR_RESET}"
}

# --- Bucle principal / Main loop ---
main() {
    check_root
    check_lock
    load_language
    
    while true; do
        show_menu
        
        # Verificar estado de instalación para opciones que lo requieren
        local bacula_installed_check=false
        if is_bacula_installed; then
            bacula_installed_check=true
        fi
        
        choice=$(read_menu_choice "   Select option" 0 15 1)
        
        case $choice in
            1) 
                if [[ "$APP_LANG" == "en" ]]; then
                    APP_LANG="es"
                else
                    APP_LANG="en"
                fi
                continue
                ;;
            2) install_bacula && configure_bacula ;;
            3) 
                if [[ "$bacula_installed_check" == false ]]; then
                    echo -e "${COLOR_RED}Error: Bacula is not installed. Please install first (option 2).${COLOR_RESET}"
                    read -rp "Press Enter to continue..."
                else
                    run_backup
                fi
                ;;
            4) 
                if [[ "$bacula_installed_check" == false ]]; then
                    echo -e "${COLOR_RED}Error: Bacula is not installed. Please install first (option 2).${COLOR_RESET}"
                    read -rp "Press Enter to continue..."
                else
                    restore_backup
                fi
                ;;
            5) 
                if [[ "$bacula_installed_check" == false ]]; then
                    echo -e "${COLOR_RED}Error: Bacula is not installed. Please install first (option 2).${COLOR_RESET}"
                    read -rp "Press Enter to continue..."
                else
                    view_status
                fi
                ;;
            6) 
                if [[ "$bacula_installed_check" == false ]]; then
                    echo -e "${COLOR_RED}Error: Bacula is not installed. Please install first (option 2).${COLOR_RESET}"
                    read -rp "Press Enter to continue..."
                else
                    configure_bacula
                fi
                ;;
            7) 
                if [[ "$bacula_installed_check" == false ]]; then
                    echo -e "${COLOR_RED}Error: Bacula is not installed. Please install first (option 2).${COLOR_RESET}"
                    read -rp "Press Enter to continue..."
                else
                    view_logs
                fi
                ;;
            8) 
                if [[ "$bacula_installed_check" == false ]]; then
                    echo -e "${COLOR_RED}Error: Bacula is not installed. Please install first (option 2).${COLOR_RESET}"
                    read -rp "Press Enter to continue..."
                else
                    test_configuration
                fi
                ;;
            9) configure_remote_backup ;;
            10) manage_ssh_keys ;;
            11) test_network_connectivity ;;
            12) reset_configuration ;;
            13) view_full_config ;;
            14) view_notification_status ;;
            15) check_bacula_ports ;;
            0) 
                if confirm "$(t "exit_confirm")"; then
                    echo ""
                    echo -e "${COLOR_GREEN}$(t "success"): Hasta luego / Goodbye!${COLOR_RESET}"
                    echo ""
                    exit 0
                fi
                ;;
            *) 
                echo -e "${COLOR_RED}   $(t "invalid_option")${COLOR_RESET}"
                echo ""
                echo -e "  ${COLOR_CYAN}0)${COLOR_RESET} $(t "back")"
                echo ""
                read -rp "   $(t "select_option") [0]: " back_choice
                case $back_choice in
                    0|"") continue ;;
                    *) continue ;;
                esac
                ;;
        esac
    done
}

# --- Manejar argumentos de línea de comandos / Handle command line arguments ---
handle_args() {
    if [[ $# -eq 0 ]]; then
        # No arguments provided, start main function
        main
        return
    fi
    
    case "$1" in
        --install-command)
            install_command
            exit 0
            ;;
        --config)
            check_root
            load_language
            view_full_config
            exit 0
            ;;
        --status)
            check_root
            load_language
            view_status
            exit 0
            ;;
        --logs)
            check_root
            load_language
            view_logs
            exit 0
            ;;
        --check)
            check_root
            load_language
            test_configuration
            exit 0
            ;;
        --open-ports)
            check_root
            open_bacula_ports "backup"
            exit 0
            ;;
        --close-ports)
            check_root
            open_bacula_ports "close"
            exit 0
            ;;
        --help|-h)
            echo ""
            echo "Bacula Backup Manager - v${SCRIPT_VERSION}"
            echo ""
            echo "Usage: sudo $0 [OPTION]"
            echo ""
            echo "Options:"
            echo "  (no args)           Launch interactive menu"
            echo "  --install-command   Install 'baculamanager' command globally"
            echo "  --config            View full configuration"
            echo "  --status            View system status"
            echo "  --logs              View logs"
            echo "  --check             Run configuration tests"
            echo "  --open-ports        Open Bacula firewall ports"
            echo "  --close-ports       Close Bacula firewall ports"
            echo "  --help, -h          Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo $0                    # Start menu"
            echo "  sudo $0 --install-command    # Install command"
            echo "  sudo baculamanager --status  # Quick status check"
            echo "  sudo baculamanager --open-ports # Open firewall manually"
            echo ""
            exit 0
            ;;
        *)
            # No arguments or unknown, run main menu
            main "$@"
            ;;
    esac
}

# Iniciar script / Start script
handle_args "$@"
