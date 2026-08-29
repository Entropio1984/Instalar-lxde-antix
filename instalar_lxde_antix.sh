#!/bin/bash
#
# instalar_lxde_antix.sh
# Instala y configura LXDE en antiX Linux (init runit) con:
#   - Gestor de red gráfico (NetworkManager + nm-applet) para WiFi
#   - Control de volumen gráfico (volumeicon + alsa-utils / pavucontrol si hay pulse)
#   - Gestión de sesión: elogind + seatd (antiX no los trae por defecto)
#   - PolicyKit (policykit-1 + lxpolkit) para autorizar acciones como
#     apagar/reiniciar, montar USB, etc. desde el escritorio
#   - Gestor de inicio de sesión gráfico (LightDM) que arranca siempre
#     al encender, con dbus/elogind/NetworkManager habilitados en el
#     orden correcto bajo runit
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
#
# IMPORTANTE: antiX activa los servicios de runit enlazándolos en
# /etc/service/ (a diferencia de Void Linux, que usa /var/service/).
# Ese es el directorio que realmente supervisa runsvdir al arrancar.
# ------------------------------------------------------------------
RUNIT_SVDIR="/etc/service"

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

    mkdir -p "$RUNIT_SVDIR"
    ln -sf "/etc/sv/$found" "$RUNIT_SVDIR/$found"
    echo "    Servicio '$found' habilitado y enlazado en $RUNIT_SVDIR/."
    return 0
}

disable_runit_service() {
    local name="$1"
    if [ -L "$RUNIT_SVDIR/$name" ]; then
        rm -f "$RUNIT_SVDIR/$name"
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
# 5. Gestión de sesión: elogind + seatd
#
# antiX, desde la versión 22, no trae elogind instalado por defecto.
# Sin esto, dbus intenta activar 'org.freedesktop.login1' al iniciar
# sesión y falla con un timeout, y LightDM no puede manejar la sesión
# gráfica correctamente.
# ------------------------------------------------------------------
echo "==> Instalando elogind y dependencias de gestión de sesión..."
apt install -y elogind libpam-elogind seatd dbus-x11

# ------------------------------------------------------------------
# 6. PolicyKit: autoriza acciones administrativas desde el escritorio
#    (apagar/reiniciar, montar USB, cambiar configuración de red, etc.)
#
# El nombre del paquete cambió entre versiones de Debian: en las más
# recientes es "polkitd", en las más antiguas "policykit-1". Se prueba
# primero el nombre clásico y, si no existe, se usa el nuevo.
# lxpolkit es el agente gráfico que muestra los diálogos de
# autorización dentro de una sesión LXDE.
# ------------------------------------------------------------------
echo "==> Instalando PolicyKit..."
if ! apt install -y policykit-1 lxpolkit; then
    echo "    'policykit-1' no disponible, probando con 'polkitd'..."
    apt install -y polkitd lxpolkit
fi

# ------------------------------------------------------------------
# 7. Gestor de inicio de sesión: LightDM (ligero, ideal para LXDE)
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
# 8. Habilitar servicios bajo runit para que arranquen siempre al
#    encender el equipo. El orden importa: dbus y elogind deben
#    quedar activos antes que lightdm, porque lightdm depende de
#    ellos para manejar la sesión gráfica.
# ------------------------------------------------------------------
echo "==> Habilitando dbus en runit..."
enable_runit_service "dbus" || true

echo "==> Habilitando elogind en runit..."
enable_runit_service "elogind" || true

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
    ln -sf /etc/sv/lightdm "$RUNIT_SVDIR/lightdm"
    echo "    Servicio lightdm creado y habilitado manualmente."
fi

# Deshabilitar otros gestores de sesión que puedan competir por la
# terminal gráfica (si estuvieran instalados y habilitados)
for OTHER_DM in sddm gdm gdm3 slim slimski xdm; do
    disable_runit_service "$OTHER_DM"
done

if [ -L "$RUNIT_SVDIR/agetty-tty1" ]; then
    disable_runit_service "agetty-tty1"
fi

# ------------------------------------------------------------------
# 9. Autostart de LXDE: nm-applet + volumeicon + lxpolkit
#
# lxpolkit debe iniciarse junto con la sesión para poder mostrar los
# diálogos de autorización de PolicyKit (sin esto, aunque esté
# instalado, no hay quien muestre la ventana de "Autenticación
# requerida").
# ------------------------------------------------------------------
echo "==> Configurando autostart de LXDE para el usuario $REAL_USER..."

AUTOSTART_DIR="$REAL_HOME/.config/lxsession/LXDE"
mkdir -p "$AUTOSTART_DIR"

AUTOSTART_FILE="$AUTOSTART_DIR/autostart"

if [ ! -f "$AUTOSTART_FILE" ] && [ -f /etc/xdg/lxsession/LXDE/autostart ]; then
    cp /etc/xdg/lxsession/LXDE/autostart "$AUTOSTART_FILE"
fi
touch "$AUTOSTART_FILE"

for LINE in "@nm-applet" "@volumeicon" "@lxpolkit"; do
    grep -qxF "$LINE" "$AUTOSTART_FILE" || echo "$LINE" >> "$AUTOSTART_FILE"
done

chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/.config"

# ------------------------------------------------------------------
# 10. Intentar corregir el botón de apagado/reinicio del panel
#
# En antiX, el diálogo clásico de LXDE (lxsession-logout) solo sabe
# hablar con ConsoleKit y falla con elogind. antiX incluye un script
# propio, desktop-session-exit, que detecta automáticamente el
# backend correcto (elogind o ConsoleKit). Si existe, se intenta
# apuntar el botón de logout del panel hacia él; si no se encuentra
# el archivo de configuración esperado, se deja aviso para ajustarlo
# a mano.
# ------------------------------------------------------------------
echo "==> Revisando el comando de apagado del panel de LXDE..."
if command -v desktop-session-exit >/dev/null 2>&1; then
    PANEL_CONFIG_CANDIDATES=(
        "$REAL_HOME/.config/lxpanel/LXDE/panels/panel"
        "$REAL_HOME/.config/lxpanel/LXDE/config"
    )
    FIXED_PANEL=0
    for PANEL_FILE in "${PANEL_CONFIG_CANDIDATES[@]}"; do
        if [ -f "$PANEL_FILE" ] && grep -q "logout" "$PANEL_FILE"; then
            cp "$PANEL_FILE" "$PANEL_FILE.bak.$(date +%s)"
            sed -i -E 's/(logout(_command)?\s*=\s*).*/\1desktop-session-exit/' "$PANEL_FILE"
            chown "$REAL_USER":"$REAL_USER" "$PANEL_FILE"
            echo "    Se actualizó '$PANEL_FILE' para usar desktop-session-exit."
            FIXED_PANEL=1
            break
        fi
    done
    if [ "$FIXED_PANEL" -eq 0 ]; then
        echo "    AVISO: 'desktop-session-exit' existe, pero no se encontró"
        echo "    un archivo de configuración de panel reconocible todavía"
        echo "    (se genera la primera vez que abras sesión en LXDE)."
        echo "    Si el botón de apagar falla, abre después de tu primer"
        echo "    login: ~/.config/lxpanel/LXDE/panels/panel y reemplaza"
        echo "    el comando de logout por: desktop-session-exit"
    fi
else
    echo "    'desktop-session-exit' no está disponible en este sistema."
    echo "    Si el botón de apagar/reiniciar del panel falla con un error"
    echo "    de ConsoleKit, usa 'sudo poweroff' / 'sudo reboot' desde una"
    echo "    terminal mientras se investiga una alternativa."
fi

# ------------------------------------------------------------------
# 11. Sesión LXDE de respaldo (por si alguna vez se arranca con startx)
# ------------------------------------------------------------------
XSESSION_RC="$REAL_HOME/.xsessionrc"
if [ ! -f "$XSESSION_RC" ]; then
    echo "exec startlxde" > "$XSESSION_RC"
    chown "$REAL_USER":"$REAL_USER" "$XSESSION_RC"
fi

# ------------------------------------------------------------------
# 12. Añadir el usuario a los grupos necesarios:
#     - netdev: permisos de red sin ser root
#     - seat: permisos para que seatd le dé control de la sesión
# ------------------------------------------------------------------
if getent group netdev >/dev/null; then
    usermod -aG netdev "$REAL_USER"
fi
if getent group seat >/dev/null; then
    usermod -aG seat "$REAL_USER"
fi

echo ""
echo "=================================================================="
echo " Instalación completada."
echo " - LXDE instalado."
echo " - elogind + seatd instalados para la gestión de sesión."
echo " - PolicyKit (policykit-1/polkitd + lxpolkit) instalado y agregado"
echo "   al autostart, para autorizar apagar, montar USB, etc."
echo " - LightDM instalado y habilitado: arrancará automáticamente al"
echo "   encender el portátil y cargará la sesión LXDE."
echo " - Servicios runit habilitados en /etc/service: dbus, elogind,"
echo "   NetworkManager y lightdm."
echo " - WiFi: icono de NetworkManager (nm-applet) en el panel."
echo " - Volumen: icono de volumeicon en el panel."
echo ""
echo " Reinicia el equipo para que todo tome efecto:"
echo "   sudo reboot"
echo "=================================================================="
