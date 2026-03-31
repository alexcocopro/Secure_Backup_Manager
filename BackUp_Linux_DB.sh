#!/bin/bash

# =============================================================
# TITLE: ENTERPRISE MULTI-DB BACKUP & AUTO-SCHEDULER (v2.0)
# COMPATIBILITY: Debian 9-12 | PG 9.4 to 18
# =============================================================

# --- Colores para la interfaz ---
BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# --- Función de limpieza ---
cleanup() {
    [ -f "$LOCAL_HASH" ] && rm -f "$LOCAL_HASH"
}
trap cleanup EXIT

# --- Modo Ejecución (Llamado por el Timer o manualmente) ---
if [[ "$1" == "--execute" ]]; then
    PARENT=$2
    REMOTE=$3
    EMAIL=$4
    TIMESTAMP=$(date +%Y%m%d_%H%M)
    MAIN_LOG="/var/log/backup_main_${TIMESTAMP}.log"
    
    # Uso de la variable de entorno para el password
    # Se asume que SSH_BACKUP_PASS está definida en /etc/environment
    SSH_CMD="sshpass -e ssh -o StrictHostKeyChecking=no"
    RSYNC_CMD="sshpass -e rsync"

    echo "Backup Job Started: $(date)" > "$MAIN_LOG"

    # Detectar directorios de bases de datos
    DATABASES=$(find "$PARENT" -maxdepth 1 -mindepth 1 -type d)

    for DB_PATH in $DATABASES; do
        DB_NAME=$(basename "$DB_PATH")
        echo -e "Processing Database: $DB_NAME" >> "$MAIN_LOG"
        
        # 1. Parar Servicio
        systemctl stop postgresql >> "$MAIN_LOG" 2>&1

        # 2. Hash de Integridad
        LOCAL_HASH="/tmp/${DB_NAME}_${TIMESTAMP}.sha256"
        (cd "$DB_PATH" && find . -type f -exec sha256sum {} + > "$LOCAL_HASH")

        # 3. Transferencia Remota
        REMOTE_DIR="${REMOTE#*:}/$TIMESTAMP/$DB_NAME"
        REMOTE_HOST="${REMOTE%%:*}"
        
        $SSH_CMD "$REMOTE_HOST" "mkdir -p $REMOTE_DIR"
        $RSYNC_CMD -avz -e "ssh -o StrictHostKeyChecking=no" "$DB_PATH/" "$REMOTE_HOST:$REMOTE_DIR/" >> "$MAIN_LOG" 2>&1
        RSYNC_EXIT=$?

        # 4. Reiniciar Servicio
        systemctl start postgresql

        # 5. Verificación de Integridad Remota
        $SSH_CMD "$REMOTE_HOST" "cd $REMOTE_DIR && sha256sum -c -" < "$LOCAL_HASH" >> "$MAIN_LOG" 2>&1
        VERIFY_EXIT=$?

        if [[ $RSYNC_EXIT -eq 0 && $VERIFY_EXIT -eq 0 ]]; then
            echo "[SUCCESS] $DB_NAME verified." >> "$MAIN_LOG"
        else
            echo "[ERROR] $DB_NAME FAILED integrity check." >> "$MAIN_LOG"
            FAIL_FLAG=1
        fi
        rm -f "$LOCAL_HASH"
    done

    # Notificación Final
    SUBJ=$([[ $FAIL_FLAG -eq 1 ]] && echo "CRITICAL: Backup Failure" || echo "SUCCESS: Backup Complete")
    mail -s "$SUBJ - $TIMESTAMP" "$EMAIL" < "$MAIN_LOG"
    exit 0
fi

# --- MODO INSTALACIÓN (Configuración Inicial) ---
echo -e "${BLUE}--- CONFIGURACIÓN DE BACKUP CORPORATIVO ---${NC}"

# Verificar dependencias
for pkg in sshpass mailutils rsync; do
    if ! command -v $pkg &> /dev/null; then
        echo -e "${RED}Instalando dependencia faltante: $pkg...${NC}"
        apt-get install -y $pkg
    fi
done

read -p "Ruta padre de Postgres (ej. /var/lib/postgresql/15/): " PARENT_PATH
read -p "Destino Remoto (user@ip:/ruta): " REMOTE_DEST
read -p "Email de Notificación: " USER_EMAIL
read -p "Frecuencia (daily/weekly/monthly): " FREQ
read -p "Hora (HH:MM): " B_TIME
read -s -p "Contraseña SSH (se guardará en variable de entorno): " SSH_PASS
echo ""

# Guardar variable de entorno de forma persistente
if ! grep -q "SSH_BACKUP_PASS" /etc/environment; then
    echo "SSH_BACKUP_PASS=\"$SSH_PASS\"" >> /etc/environment
fi
export SSH_BACKUP_PASS="$SSH_PASS"

# Instalación de Systemd Timer
SERVICE_NAME="db-secure-backup"
SCRIPT_PATH=$(realpath "$0")

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.service
[Unit]
Description=Secure Multi-DB Backup
After=network.target

[Service]
Type=oneshot
EnvironmentFile=/etc/environment
ExecStart=$SCRIPT_PATH --execute "$PARENT_PATH" "$REMOTE_DEST" "$USER_EMAIL"
EOF

# Definir OnCalendar basado en frecuencia
case $FREQ in
    daily) CAL="*-*-* $B_TIME:00" ;;
    weekly) CAL="Mon *-*-* $B_TIME:00" ;;
    monthly) CAL="*-*-01 $B_TIME:00" ;;
    *) CAL="*-*-* $B_TIME:00" ;;
esac

cat <<EOF > /etc/systemd/system/${SERVICE_NAME}.timer
[Unit]
Description=Run DB Backup with persistence

[Timer]
OnCalendar=$CAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload && systemctl enable --now ${SERVICE_NAME}.timer
echo -e "${GREEN}[+] Configuración completada y programada.${NC}"