#!/bin/bash
#
# instalar_lxde_antix.sh
#
# Instala y configura LXDE en antiX Linux con:
#   - WiFi (NetworkManager + nm-applet)
#   - Volumen (ALSA + volumeicon)
#   - Gestión de sesión (elogind + seatd) y PolicyKit (policykit-1/polkitd
#     + lxpolkit)
#   - LightDM como gestor de inicio de sesión gráfico
#
# antiX-26 soporta 5 init (runit, sysVinit, dinit, s6-rc, s6-66), pero
# solo runit y sysVinit son considerados estables por el propio proyecto
# antiX. Por eso este script:
#   1. Habilita los servicios ÚNICAMENTE para runit y sysVinit.
#   2. Restringe el menú de GRUB para que solo ofrezca esos dos init,
#      usando la herramienta oficial de antiX (grub-multi-init-enabler).
#
# COMPORTAMIENTO SEGURO:
#   - Registra todo en un log con fecha/hora.
#   - Hace respaldo de cada archivo antes de modificarlo.
#   - Pide confirmación antes de tocar GRUB (usa --yes para omitir).
#   - Es idempotente: se puede volver a ejecutar sin duplicar cambios.
#   - Verifica al final el estado real de cada servicio, en vez de
#     asumir que todo funcionó.
#
# Uso:
#   chmod +x instalar_lxde_antix.sh
#   sudo ./instalar_lxde_antix.sh          # modo interactivo
#   sudo ./instalar_lxde_antix.sh --yes    # sin confirmaciones
#
set -Eeuo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------
# 0. Comportamiento seguro: log, confirmaciones, manejo de errores
# ------------------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    echo "Este script debe ejecutarse como root (usa sudo)." >&2
    exit 1
fi

ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=1 ;;
    esac
done

LOG_FILE="/var/log/instalar_lxde_antix_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    echo ""
    echo "‼ ERROR en la línea $1 (comando: \"$2\")." >&2
    echo "  El script se detuvo para no dejar el sistema a medio configurar." >&2
    echo "  Revisa el detalle completo en: $LOG_FILE" >&2
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
trap 'echo "==> Log completo guardado en: $LOG_FILE"' EXIT

confirm() {
    local prompt="$1"
    if [ "$ASSUME_YES" -eq 1 ]; then
        return 0
    fi
    read -r -p "$prompt [s/N]: " resp
    case "$resp" in
        [sS]|[sS][iI]) return 0 ;;
        *) return 1 ;;
    esac
}

backup_file() {
    local f="$1"
    if [ -f "$f" ]; then
        cp -a "$f" "${f}.bak.$(date +%Y%m%d_%H%M%S)"
        echo "    Respaldo creado: ${f}.bak.*"
    fi
}

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CURRENT_INIT=$(ps -p 1 -o comm= 2>/dev/null || echo "desconocido")

echo "==> Usuario detectado: $REAL_USER (home: $REAL_HOME)"
echo "==> Init activo en este arranque: $CURRENT_INIT"
echo "==> Registrando toda la ejecución en: $LOG_FILE"

# ------------------------------------------------------------------
# Funciones para habilitar/verificar servicios SOLO en runit y
# sysVinit (los dos init estables). Nada se hace para dinit, s6-rc
# ni s6-66.
# ------------------------------------------------------------------
RUNIT_SVDIR="/etc/service"

enable_runit_service() {
    local wanted="$1" found=""
    for candidate in "$wanted" "${wanted,,}" "${wanted^}"; do
        [ -d "/etc/sv/$candidate" ] && { found="$candidate"; break; }
    done
    if [ -z "$found" ]; then
        echo "    [runit] AVISO: no se encontró /etc/sv/$wanted."
        return 1
    fi
    mkdir -p "$RUNIT_SVDIR"
    ln -sf "/etc/sv/$found" "$RUNIT_SVDIR/$found"
    echo "    [runit] '$found' habilitado en $RUNIT_SVDIR/."
}

disable_runit_service() {
    local name="$1"
    if [ -L "$RUNIT_SVDIR/$name" ]; then
        rm -f "$RUNIT_SVDIR/$name"
        echo "    [runit] '$name' deshabilitado."
    fi
}

enable_sysvinit_service() {
    local svc="$1"
    if [ -x "/etc/init.d/$svc" ] && command -v update-rc.d >/dev/null 2>&1; then
        # "defaults" es la única forma válida en Debian/antiX; no existe
        # un subcomando "enable" en update-rc.d (eso es de otras distros).
        if update-rc.d "$svc" defaults >/dev/null 2>&1; then
            echo "    [sysvinit] '$svc' habilitado."
        else
            echo "    [sysvinit] AVISO: 'update-rc.d $svc defaults' falló."
        fi
    else
        echo "    [sysvinit] AVISO: no se encontró /etc/init.d/$svc."
        return 1
    fi
}

disable_sysvinit_service() {
    local svc="$1"
    if [ -x "/etc/init.d/$svc" ] && command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d "$svc" remove >/dev/null 2>&1 || true
        echo "    [sysvinit] '$svc' deshabilitado (si estaba habilitado)."
    fi
}

verify_runit_service() {
    local svc="$1"
    if [ -L "$RUNIT_SVDIR/$svc" ]; then
        echo "    [runit]    $svc -> HABILITADO ($(readlink -f "$RUNIT_SVDIR/$svc"))"
    else
        echo "    [runit]    $svc -> NO habilitado"
    fi
}

verify_sysvinit_service() {
    local svc="$1"
    if ls /etc/rc*.d/ 2>/dev/null | grep -q "S[0-9]*${svc}$"; then
        echo "    [sysvinit] $svc -> HABILITADO (enlaces en /etc/rcN.d/)"
    else
        echo "    [sysvinit] $svc -> NO habilitado"
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
    lxde-core lxde-icon-theme lxterminal lxappearance \
    lxsession pcmanfm lxpanel openbox xorg

# ------------------------------------------------------------------
# 3. WiFi: NetworkManager + applet gráfico
# ------------------------------------------------------------------
echo "==> Instalando NetworkManager y su applet..."
apt install -y network-manager network-manager-gnome wireless-tools wpasupplicant

if [ -f /etc/network/interfaces ]; then
    echo "==> Ajustando /etc/network/interfaces para dejar el manejo a NetworkManager..."
    backup_file /etc/network/interfaces
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
# ------------------------------------------------------------------
echo "==> Instalando elogind y dependencias de gestión de sesión..."
apt install -y elogind libpam-elogind seatd dbus-x11

# ------------------------------------------------------------------
# 6. PolicyKit: policykit-1 (o polkitd) + lxpolkit
# ------------------------------------------------------------------
echo "==> Instalando PolicyKit..."
if ! apt install -y policykit-1 lxpolkit; then
    echo "    'policykit-1' no disponible, probando con 'polkitd'..."
    apt install -y polkitd lxpolkit
fi

# ------------------------------------------------------------------
# 7. LightDM
# ------------------------------------------------------------------
echo "==> Instalando LightDM..."
DEBIAN_FRONTEND=noninteractive apt install -y lightdm lightdm-gtk-greeter

if [ -e /etc/X11/default-display-manager ]; then
    backup_file /etc/X11/default-display-manager
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
fi

mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-lxde.conf <<'EOF'
[Seat:*]
user-session=LXDE
greeter-session=lightdm-gtk-greeter
EOF

# ------------------------------------------------------------------
# 8. Restringir el menú de GRUB a solo sysVinit y runit
#
# antiX incluye una herramienta oficial (grub-multi-init-enabler) para
# esto, reconfigurable con dpkg-reconfigure. Como su formato interno de
# configuración no es de dominio público, este script NO edita
# grub.cfg a ciegas: usa la herramienta oficial, respalda todo antes,
# y verifica el resultado después.
# ------------------------------------------------------------------
echo "==> Configurando el menú de GRUB (solo sysVinit + runit)..."
backup_file /etc/default/grub
if [ -f /boot/grub/grub.cfg ]; then
    cp -a /boot/grub/grub.cfg "/boot/grub/grub.cfg.bak.$(date +%Y%m%d_%H%M%S)"
    echo "    Respaldo creado: /boot/grub/grub.cfg.bak.*"
fi

if ! dpkg -s grub-multi-init-enabler >/dev/null 2>&1; then
    echo "    Instalando grub-multi-init-enabler..."
    apt install -y grub-multi-init-enabler || true
fi

if dpkg -s grub-multi-init-enabler >/dev/null 2>&1; then
    echo "    A continuación se abre la configuración interactiva de arranque."
    echo "    Selecciona ÚNICAMENTE 'sysVinit' y 'runit'; desmarca dinit,"
    echo "    s6-rc y s6-66."
    if confirm "    ¿Abrir la configuración de GRUB ahora?"; then
        dpkg-reconfigure grub-multi-init-enabler
        update-grub
        echo "    Entradas de init detectadas en grub.cfg:"
        grep -oE "init=/sbin/init-[a-zA-Z0-9._-]+" /boot/grub/grub.cfg 2>/dev/null \
            | sort -u | sed 's/^/      /' \
            || echo "      (no se detectaron parámetros init= explícitos; revisa el menú manualmente)"
    else
        echo "    Configuración de GRUB omitida por el usuario."
        echo "    Puedes ejecutarla después con: sudo dpkg-reconfigure grub-multi-init-enabler"
    fi
else
    echo "    AVISO: 'grub-multi-init-enabler' no está disponible en tus repositorios."
    echo "    El menú de GRUB NO se modificó (no se edita a ciegas por seguridad)."
    echo "    Si tu sistema ofrece un submenú de 'Advanced options', ahí puedes"
    echo "    elegir manualmente sysVinit o runit en cada arranque."
fi

# ------------------------------------------------------------------
# 9. Habilitar dbus, elogind, NetworkManager y lightdm — SOLO para
#    runit y sysVinit, en orden (dbus/elogind antes que lightdm).
# ------------------------------------------------------------------
echo "==> Habilitando servicios en runit..."
enable_runit_service "dbus" || true
enable_runit_service "elogind" || true
enable_runit_service "NetworkManager" || true
disable_runit_service "networking"
if ! enable_runit_service "lightdm"; then
    echo "    [runit] Registrando lightdm manualmente..."
    mkdir -p /etc/sv/lightdm/log
    cat > /etc/sv/lightdm/run <<'EOF'
#!/bin/sh
exec /usr/sbin/lightdm
EOF
    chmod +x /etc/sv/lightdm/run
    ln -sf /etc/sv/lightdm "$RUNIT_SVDIR/lightdm"
    echo "    [runit] lightdm creado y habilitado manualmente."
fi
for OTHER_DM in sddm gdm gdm3 slim slimski xdm; do
    disable_runit_service "$OTHER_DM"
done
[ -L "$RUNIT_SVDIR/agetty-tty1" ] && disable_runit_service "agetty-tty1"

echo "==> Habilitando servicios en sysVinit..."
enable_sysvinit_service "dbus" || true
enable_sysvinit_service "elogind" || true
enable_sysvinit_service "network-manager" || enable_sysvinit_service "networking" || true
enable_sysvinit_service "lightdm" || true
for OTHER_DM in sddm gdm gdm3 slim xdm; do
    disable_sysvinit_service "$OTHER_DM"
done

# ------------------------------------------------------------------
# 10. Autostart de LXDE: nm-applet + volumeicon + lxpolkit
# ------------------------------------------------------------------
echo "==> Configurando autostart de LXDE para $REAL_USER..."
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
# 11. Intento (best-effort) de arreglar el botón de apagado del panel
# ------------------------------------------------------------------
echo "==> Revisando el comando de apagado del panel de LXDE..."
if command -v desktop-session-exit >/dev/null 2>&1; then
    for PANEL_FILE in \
        "$REAL_HOME/.config/lxpanel/LXDE/panels/panel" \
        "$REAL_HOME/.config/lxpanel/LXDE/config"
    do
        if [ -f "$PANEL_FILE" ] && grep -q "logout" "$PANEL_FILE"; then
            backup_file "$PANEL_FILE"
            sed -i -E 's/(logout(_command)?\s*=\s*).*/\1desktop-session-exit/' "$PANEL_FILE"
            chown "$REAL_USER":"$REAL_USER" "$PANEL_FILE"
            echo "    Actualizado '$PANEL_FILE' para usar desktop-session-exit."
            break
        fi
    done
else
    echo "    'desktop-session-exit' no está disponible; si el botón de"
    echo "    apagar falla, usa 'sudo poweroff' / 'sudo reboot' por ahora."
fi

# ------------------------------------------------------------------
# 12. Sesión LXDE de respaldo + grupos necesarios
# ------------------------------------------------------------------
XSESSION_RC="$REAL_HOME/.xsessionrc"
if [ ! -f "$XSESSION_RC" ]; then
    echo "exec startlxde" > "$XSESSION_RC"
    chown "$REAL_USER":"$REAL_USER" "$XSESSION_RC"
fi
getent group netdev >/dev/null && usermod -aG netdev "$REAL_USER"
getent group seat >/dev/null && usermod -aG seat "$REAL_USER"

# ------------------------------------------------------------------
# 13. Verificación final: reporte real del estado de cada servicio
# ------------------------------------------------------------------
echo ""
echo "=================================================================="
echo " VERIFICACIÓN FINAL"
echo "=================================================================="
for SVC in dbus elogind NetworkManager lightdm; do
    verify_runit_service "$SVC"
done
for SVC in dbus elogind network-manager lightdm; do
    verify_sysvinit_service "$SVC"
done
echo ""
echo " Init activo en este arranque: $CURRENT_INIT"
echo " Recuerda: el init con el que reinicies ahora quedará como"
echo " predeterminado para el siguiente arranque."
echo ""
echo " Instalación completada. Reinicia con: sudo reboot"
echo " Log completo: $LOG_FILE"
echo "=================================================================="
