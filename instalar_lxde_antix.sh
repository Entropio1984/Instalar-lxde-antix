#!/bin/bash
#
# instalar_lxde_antix.sh
# Instala y configura LXDE en antiX Linux (init runit) con:
#   - Gestor de red gráfico (NetworkManager + nm-applet) para WiFi
#   - Control de volumen gráfico (volumeicon + alsa-utils / pavucontrol si hay pulse)
#   - Gestor de inicio de sesión gráfico (LightDM) que arranca siempre al encender
#
# Uso:
#   chmod +x instalar_lxde_antix.sh
#   sudo ./instalar_lxde_antix.sh
#
set -euo pipefail

# ------------------------------------------------------------------
# 0. Comprobaciones previas
# ------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script debe ejecutarse como root (usa sudo)." >&2
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "==> Usuario detectado: $REAL_USER (home: $REAL_HOME)"

# ------------------------------------------------------------------
# Funciones auxiliares para manejar servicios de runit
# ------------------------------------------------------------------
enable_runit_service() {
    local wanted="$1"
    local found=""

    for candidate in "$wanted" "${wanted,,}" "${wanted^}"; do
        if [ -d "/etc/sv/$candidate" ]; then
            found="$candidate"
            break
        fi
    done

    if [ -z "$found" ]; then
        echo "    AVISO: no se encontró /etc/sv/$wanted (ni variantes)."
        return 1
    fi

    mkdir -p /var/service
    ln -sf "/etc/sv/$found" "/var/service/$found"
    echo "    Servicio '$found' habilitado y enlazado en /var/service/."
    return 0
}

disable_runit_service() {
    local name="$1"
    if [ -L "/var/service/$name" ]; then
        rm -f "/var/service/$name"
        echo "    Servicio '$name' deshabilitado (enlace removido)."
    fi
}

# ------------------------------------------------------------------
# 1. Actualizar el sistema
# ------------------------------------------------------------------
echo "==> Actualizando índices de paquetes..."
apt update

# ------------------------------------------------------------------
# 2. Instalar LXDE y dependencias base
# ------------------------------------------------------------------
echo "==> Instalando LXDE..."
apt install -y \
    lxde-core \
    lxde-icon-theme \
    lxterminal \
    lxappearance \
    lxsession \
    pcmanfm \
    lxpanel \
    openbox \
    xorg

# ------------------------------------------------------------------
# 3. WiFi: NetworkManager + applet gráfico
# ------------------------------------------------------------------
echo "==> Instalando NetworkManager y su applet..."
apt install -y network-manager network-manager-gnome wireless-tools wpasupplicant

if [ -f /etc/network/interfaces ]; then
    echo "==> Ajustando /etc/network/interfaces para dejar el manejo a NetworkManager..."
    cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s)
    cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback
EOF
fi

# ------------------------------------------------------------------
# 4. Volumen: ALSA + volumeicon (y pavucontrol si hay pulseaudio)
# ------------------------------------------------------------------
echo "==> Instalando herramientas de audio..."
apt install -y alsa-utils volumeicon-alsa

if command -v pulseaudio >/dev/null 2>&1 || dpkg -l | grep -q pulseaudio; then
    apt install -y pavucontrol
fi

# ------------------------------------------------------------------
# 5. Gestor de inicio de sesión: LightDM (ligero, ideal para LXDE)
# ------------------------------------------------------------------
echo "==> Instalando LightDM..."
DEBIAN_FRONTEND=noninteractive apt install -y lightdm lightdm-gtk-greeter

if [ -e /etc/X11/default-display-manager ]; then
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
fi

# Definir LXDE como sesión por defecto en el saludo de LightDM
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-lxde.conf <<'EOF'
[Seat:*]
user-session=LXDE
greeter-session=lightdm-gtk-greeter
EOF

# ------------------------------------------------------------------
# 6. Habilitar servicios bajo runit para que arranquen siempre al
#    encender el equipo
# ------------------------------------------------------------------
echo "==> Habilitando NetworkManager en runit..."
enable_runit_service "NetworkManager" || true

disable_runit_service "networking"

echo "==> Habilitando LightDM en runit (arranque automático)..."
if ! enable_runit_service "lightdm"; then
    echo "    Registrando el servicio lightdm manualmente para runit..."
    mkdir -p /etc/sv/lightdm/log
    cat > /etc/sv/lightdm/run <<'EOF'
#!/bin/sh
exec /usr/sbin/lightdm
EOF
    chmod +x /etc/sv/lightdm/run
    ln -sf /etc/sv/lightdm /var/service/lightdm
    echo "    Servicio lightdm creado y habilitado manualmente."
fi

# Deshabilitar otros gestores de sesión que puedan competir por la
# terminal gráfica (si estuvieran instalados y habilitados)
for OTHER_DM in sddm gdm gdm3 slim xdm; do
    disable_runit_service "$OTHER_DM"
done

if [ -L /var/service/agetty-tty1 ]; then
    disable_runit_service "agetty-tty1"
fi

# ------------------------------------------------------------------
# 7. Autostart de LXDE: nm-applet + volumeicon
# ------------------------------------------------------------------
echo "==> Configurando autostart de LXDE para el usuario $REAL_USER..."

AUTOSTART_DIR="$REAL_HOME/.config/lxsession/LXDE"
mkdir -p "$AUTOSTART_DIR"

AUTOSTART_FILE="$AUTOSTART_DIR/autostart"

if [ ! -f "$AUTOSTART_FILE" ] && [ -f /etc/xdg/lxsession/LXDE/autostart ]; then
    cp /etc/xdg/lxsession/LXDE/autostart "$AUTOSTART_FILE"
fi
touch "$AUTOSTART_FILE"

for LINE in "@nm-applet" "@volumeicon"; do
    grep -qxF "$LINE" "$AUTOSTART_FILE" || echo "$LINE" >> "$AUTOSTART_FILE"
done

chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.config"

# ------------------------------------------------------------------
# 8. Sesión LXDE de respaldo (por si alguna vez se arranca con startx)
# ------------------------------------------------------------------
XSESSION_RC="$REAL_HOME/.xsessionrc"
if [ ! -f "$XSESSION_RC" ]; then
    echo "exec startlxde" > "$XSESSION_RC"
    chown "$REAL_USER":"$REAL_USER" "$XSESSION_RC"
fi

# ------------------------------------------------------------------
# 9. Añadir el usuario al grupo netdev (permisos de red sin ser root)
# ------------------------------------------------------------------
if getent group netdev >/dev/null; then
    usermod -aG netdev "$REAL_USER"
fi

echo ""
echo "=================================================================="
echo " Instalación completada."
echo " - LXDE instalado."
echo " - LightDM instalado y habilitado: arrancará automáticamente al"
echo "   encender el portátil y cargará la sesión LXDE."
echo " - WiFi: icono de NetworkManager (nm-applet) en el panel."
echo " - Volumen: icono de volumeicon en el panel."
echo ""
echo " Reinicia el equipo para que todo tome efecto:"
echo "   sudo reboot"
echo "=================================================================="
