#!/bin/bash
# ==============================================================================
# antix-desktop-postinstall.sh
#
# Instala un escritorio LXDE o LXQt sobre antiX 26 Core (init runit), para
# comparar con desktop-postinstall.sh de Alpine Linux:
#   - LXQt: para comparar antiX contra Alpine con el mismo escritorio.
#   - LXDE: para comparar LXDE contra LXQt dentro de antiX.
# En ambos casos se usan el mismo gestor de ventanas (Openbox) y el mismo
# gestor de inicio de sesion (LightDM), para que la unica diferencia real
# entre las dos instalaciones sea el escritorio.
#
# Reemplaza a instalar_lxde_antix.sh. Cada decision viene de un problema
# demostrado en una maquina virtual con antiX 26 Core:
#   - elogind instalado pero sin correr bajo runit hacia que cada consulta
#     de LightDM y de la sesion esperara 25 s (unos 75 s perdidos por
#     arranque). Los paquetes de antiX estan preparados para ConsoleKit:
#     con ConsoleKit las esperas desaparecen y lxpolkit deja de mostrar
#     el error de ConsoleKit.
#   - runit no trae servicio para NetworkManager: hay que crearlo.
#   - dhcpcd y NetworkManager no deben manejar la misma interfaz a la vez.
#
# Uso:
#   sudo ./antix-desktop-postinstall.sh           # menu para elegir escritorio
#   sudo ./antix-desktop-postinstall.sh --lxqt    # sin menu
#   sudo ./antix-desktop-postinstall.sh --lxde
#
# Es idempotente: se puede volver a ejecutar sin duplicar cambios.
# ==============================================================================

# Sin "set -e" a proposito: la version anterior se detenia a mitad de
# camino ante el primer paquete que fallara. Aqui cada paso maneja sus
# propios errores, y los paquetes que no se pudieron instalar se listan
# en el informe final.
set -u

LOG_FILE="/var/log/antix-desktop-postinstall.log"
SV_DIR="/etc/sv"
SERVICE_DIR="/etc/service"
PIN_FILE="/etc/apt/preferences.d/00elogind"
FAILED_PKGS=""
DESKTOP=""
TARGET_USER=""
TARGET_HOME=""

log_file()  { printf '%s %s\n' "$(date '+%F %T')" "$1" >>"$LOG_FILE" 2>/dev/null || true; }
log_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1"; log_file "[INFO]  $1"; }
log_ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$1"; log_file "[OK]    $1"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1"; log_file "[WARN]  $1"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1"; log_file "[ERROR] $1"; }

is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

backup_file() {
    if [ -f "$1" ]; then
        cp -a "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)"
        log_info "Respaldo creado: $1.bak.*"
    fi
}

# Instala en una sola transaccion; si falla (por ejemplo, porque un nombre
# no existe en antiX 26), reintenta paquete por paquete para que un solo
# fallo no impida instalar el resto. La salida de apt va al log.
apt_install() {
    log_info "Instalando: $* (puede tardar varios minutos)"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >>"$LOG_FILE" 2>&1; then
        log_ok "Instalado: $*"
        return 0
    fi
    log_warn "Fallo la instalacion en lote; se reintenta paquete por paquete."
    for p in "$@"; do
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$p" >>"$LOG_FILE" 2>&1; then
            log_ok "'$p' instalado."
        else
            log_warn "No se pudo instalar '$p' (detalle en $LOG_FILE)."
            FAILED_PKGS="$FAILED_PKGS $p"
        fi
    done
}

# Crea (si no existe) y activa un servicio de runit. $1 = nombre,
# $2 = comando, $3 = "yes" si necesita D-Bus. runit arranca todos los
# servicios en paralelo y sin orden: un servicio que necesita D-Bus
# termina si D-Bus aun no esta listo, y runit lo reintenta al segundo.
# Si el paquete ya trae su propio servicio de runit, se usa ese.
ensure_runit_service() {
    name="$1"; cmd="$2"; needs_dbus="$3"
    if [ ! -d "$SV_DIR/$name" ]; then
        mkdir -p "$SV_DIR/$name"
        {
            echo '#!/bin/sh'
            echo 'exec 2>&1'
            if [ "$needs_dbus" = "yes" ]; then
                echo "sv check $SERVICE_DIR/dbus >/dev/null || exit 1"
            fi
            echo "exec $cmd"
        } > "$SV_DIR/$name/run"
        chmod 755 "$SV_DIR/$name/run"
        log_ok "Servicio de runit creado: $SV_DIR/$name"
    fi
    if [ ! -e "$SERVICE_DIR/$name" ]; then
        ln -s "$SV_DIR/$name" "$SERVICE_DIR/$name"
        log_ok "Servicio '$name' activado."
    else
        log_info "Servicio '$name' ya estaba activado."
    fi
}

# Agrega una linea a un archivo de autoarranque si no esta.
add_autostart_line() {
    file="$1"; line="$2"
    [ -f "$file" ] || return 0
    if grep -qxF "$line" "$file"; then
        log_info "'$line' ya estaba en $file"
    else
        echo "$line" >> "$file"
        log_ok "'$line' agregado a $file"
    fi
}

# ------------------------------------------------------------------------------
# 1. Comprobaciones iniciales
# ------------------------------------------------------------------------------
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --lxde) DESKTOP="LXDE" ;;
            --lxqt) DESKTOP="LXQT" ;;
            -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "Opcion desconocida: $arg (usa --lxde, --lxqt o --help)" >&2; exit 1 ;;
        esac
    done
}

check_environment() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Este script debe ejecutarse como root: sudo $0" >&2
        exit 1
    fi
    : >>"$LOG_FILE"
    log_file "===== Inicio de ejecucion ====="

    init_name="$(ps -p 1 -o comm= 2>/dev/null)"
    if [ "$init_name" != "runit" ]; then
        log_error "Este script esta hecho para antiX con init runit (el predeterminado); el init activo es '$init_name'."
        log_error "Reinicia eligiendo runit en el menu de arranque y vuelve a ejecutarlo."
        exit 1
    fi
    [ -f /etc/antix-version ] || log_warn "No se encontro /etc/antix-version: el script esta pensado para antiX 26."
    log_ok "Init runit confirmado."

    TARGET_USER="${SUDO_USER:-}"
    [ -z "$TARGET_USER" ] && TARGET_USER="$(logname 2>/dev/null || true)"
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        log_warn "No se detecto un usuario normal: se omiten los ajustes de su carpeta personal."
        TARGET_USER=""
    else
        TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
        log_ok "Usuario detectado: $TARGET_USER ($TARGET_HOME)"
    fi
}

# ------------------------------------------------------------------------------
# 2. Eleccion del escritorio
# ------------------------------------------------------------------------------
# Textos sin acentos a proposito: el menu puede aparecer en una consola TTY
# donde los acentos se ven como simbolos extranos.
choose_desktop() {
    if [ -n "$DESKTOP" ]; then
        log_info "Escritorio elegido por argumento: $DESKTOP"
        return 0
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        log_error "No hay una terminal interactiva: indica el escritorio con --lxde o --lxqt."
        exit 1
    fi
    command -v dialog >/dev/null 2>&1 || apt_install dialog

    if command -v dialog >/dev/null 2>&1; then
        choice="LXDE"
        while :; do
            if [ "$choice" = "LXQT" ]; then st_lxde=off; st_lxqt=on; else st_lxde=on; st_lxqt=off; fi
            if ! choice="$(dialog --stdout --no-tags \
                    --backtitle "Escritorio para antiX 26 Core" \
                    --title "Escritorio" \
                    --ok-label "Continuar" --cancel-label "Salir" \
                    --radiolist "ESPACIO elige, ENTER continua." 0 0 0 \
                    LXDE "LXDE: el mas liviano (GTK)" "$st_lxde" \
                    LXQT "LXQt: sucesor de LXDE (Qt), el mismo que en Alpine" "$st_lxqt")"; then
                clear 2>/dev/null || true
                log_info "Cancelado por el usuario: no se cambio la configuracion del sistema."
                exit 0
            fi
            if dialog --title "Confirmar" --yes-label "Comenzar" --no-label "Volver" \
                    --yesno "Se instalara $choice con:\n\n  - Openbox (gestor de ventanas)\n  - LightDM (inicio de sesion grafico)\n  - NetworkManager y su icono de red\n  - ConsoleKit en lugar de elogind\n\nA partir de aqui el script no hara mas preguntas." 0 0; then
                break
            fi
        done
        clear 2>/dev/null || true
        DESKTOP="$choice"
    else
        # Respaldo sin dialog: menu de texto.
        while :; do
            printf '\nEscritorio a instalar:\n  1) LXDE (el mas liviano)\n  2) LXQt (el mismo que en Alpine)\nElige 1 o 2: '
            read -r r || exit 1
            case "$r" in
                1) DESKTOP="LXDE"; break ;;
                2) DESKTOP="LXQT"; break ;;
            esac
        done
    fi
    log_ok "Escritorio elegido: $DESKTOP"
}

# ------------------------------------------------------------------------------
# 3. Sesiones y permisos: ConsoleKit en lugar de elogind
# ------------------------------------------------------------------------------
# Con elogind instalado pero sin correr (runit no lo arranca), el sistema
# anuncia el servicio org.freedesktop.login1 y cada programa que lo
# consulta espera 25 s. Los paquetes de antiX (PolicyKit, LightDM) estan
# preparados para ConsoleKit, que si funciona bajo runit.
setup_session_tracking() {
    log_info "== Sesiones y permisos: ConsoleKit en lugar de elogind =="

    # Bloqueo en apt para que ningun paquete vuelva a instalar elogind: si
    # un paquete acepta "elogind o consolekit", apt elegira consolekit.
    # Mismo formato que el bloqueo de systemd que antiX ya trae.
    if [ ! -f "$PIN_FILE" ]; then
        printf 'Package: elogind libpam-elogind\nPin: origin *\nPin-Priority: -1\n' > "$PIN_FILE"
        log_ok "Bloqueo de elogind creado en $PIN_FILE"
    fi

    if is_installed elogind || is_installed libpam-elogind; then
        # Simulacion previa: solo se retira elogind si la operacion no
        # arrastra ningun otro paquete.
        extra="$(apt-get -s purge elogind libpam-elogind 2>/dev/null \
                 | awk '/^(Remv|Purg) /{print $2}' | sed 's/:.*//' \
                 | grep -vx -e elogind -e libpam-elogind || true)"
        if [ -n "$extra" ]; then
            log_warn "No se retira elogind porque tambien eliminaria: $(echo $extra)"
        elif DEBIAN_FRONTEND=noninteractive apt-get purge -y elogind libpam-elogind >>"$LOG_FILE" 2>&1; then
            log_ok "elogind retirado."
        else
            log_warn "No se pudo retirar elogind (detalle en $LOG_FILE)."
        fi
    fi

    # libelogind0 es una LIBRERIA que necesitan muchos paquetes de antiX: si
    # se elimina, se lleva consigo el entorno grafico. Al retirar elogind,
    # apt la marca como "ya no necesaria" y un futuro 'apt autoremove' la
    # borraria. Marcarla como instalada manualmente lo impide.
    for lib in libelogind0 libelogind-compat; do
        if is_installed "$lib"; then
            apt-mark manual "$lib" >>"$LOG_FILE" 2>&1 && log_ok "'$lib' protegida de 'apt autoremove'."
        fi
    done

    apt_install consolekit
}

# ------------------------------------------------------------------------------
# 4. Entorno grafico y escritorio
# ------------------------------------------------------------------------------
install_desktop() {
    log_info "== Instalando el escritorio $DESKTOP =="
    apt_install xorg dbus-x11 openbox alsa-utils
    case "$DESKTOP" in
        LXDE)
            apt_install lxde-core lxde-icon-theme lxterminal lxappearance lxpolkit volumeicon-alsa
            ;;
        LXQT)
            # lxqt-core ya incluye el agente de permisos (lxqt-policykit) y
            # un panel con control de volumen propio.
            apt_install lxqt-core qterminal
            # Si LXQt arrastro otro gestor de inicio de sesion (SDDM), se
            # desactiva: dos gestores a la vez pelean por la pantalla.
            if [ -e "$SERVICE_DIR/sddm" ]; then
                rm -f "$SERVICE_DIR/sddm"
                log_ok "SDDM desactivado: se usara LightDM, igual que con LXDE."
            fi
            # En su primer inicio, LXQt pregunta que gestor de ventanas usar
            # si no hay uno configurado.
            wm="$(grep -h '^window_manager=' /etc/xdg/lxqt/session.conf /usr/share/lxqt/session.conf 2>/dev/null | head -n1 | cut -d= -f2)"
            if [ -n "$wm" ]; then
                log_ok "Gestor de ventanas predeterminado de LXQt: $wm"
            else
                log_warn "Si al primer inicio LXQt pregunta por el gestor de ventanas, elige Openbox (el mismo que en LXDE)."
            fi
            ;;
    esac
}

# ------------------------------------------------------------------------------
# 5. Red: NetworkManager como servicio de runit
# ------------------------------------------------------------------------------
setup_network() {
    log_info "== Red: NetworkManager =="
    apt_install network-manager network-manager-gnome

    # NetworkManager ignora las interfaces declaradas en
    # /etc/network/interfaces. Si hay alguna ademas de 'lo', se deja solo
    # 'lo' (con respaldo) para que NetworkManager pueda manejarlas.
    ifaces=/etc/network/interfaces
    if [ -f "$ifaces" ] && grep -E '^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]' "$ifaces" | grep -qvw 'lo'; then
        backup_file "$ifaces"
        printf 'auto lo\niface lo inet loopback\n' > "$ifaces"
        log_ok "$ifaces reducido a 'lo' para que NetworkManager maneje la red."
    fi

    ensure_runit_service NetworkManager "/usr/sbin/NetworkManager --no-daemon" yes
}

# ------------------------------------------------------------------------------
# 6. Autoarranque: icono de red, volumen y agente de permisos
# ------------------------------------------------------------------------------
setup_autostart() {
    log_info "== Autoarranque del escritorio =="
    if [ "$DESKTOP" = "LXDE" ]; then
        # Se modifica el autoarranque del sistema (para usuarios nuevos) y,
        # si existe, el del usuario, que reemplaza por completo al del
        # sistema. nm-applet no abre una segunda copia si ya hay una, asi
        # que la linea es inofensiva aunque tambien arranque por
        # /etc/xdg/autostart.
        user_file=""
        [ -n "$TARGET_HOME" ] && user_file="$TARGET_HOME/.config/lxsession/LXDE/autostart"
        for f in /etc/xdg/lxsession/LXDE/autostart $user_file; do
            add_autostart_line "$f" "@nm-applet"
            add_autostart_line "$f" "@volumeicon"
            # lxsession inicia su agente de permisos si desktop.conf lo
            # indica; solo si no, se agrega al autoarranque (dos agentes a
            # la vez chocan entre si).
            if ! grep -q '^polkit/command=' /etc/xdg/lxsession/LXDE/desktop.conf 2>/dev/null; then
                add_autostart_line "$f" "@lxpolkit"
            fi
        done
    else
        # LXQt respeta el autoarranque estandar de /etc/xdg/autostart, donde
        # network-manager-gnome deja el de nm-applet. El volumen lo maneja
        # el propio panel y el agente de permisos arranca solo.
        if [ -f /etc/xdg/autostart/nm-applet.desktop ]; then
            log_ok "El icono de red se iniciara automaticamente."
        else
            log_warn "No se encontro /etc/xdg/autostart/nm-applet.desktop."
        fi
    fi
}

# ------------------------------------------------------------------------------
# 7. LightDM
# ------------------------------------------------------------------------------
setup_display_manager() {
    log_info "== Inicio de sesion grafico: LightDM =="
    apt_install lightdm lightdm-gtk-greeter

    case "$DESKTOP" in
        LXDE) session="LXDE" ;;
        LXQT) session="lxqt" ;;
    esac
    if [ ! -f "/usr/share/xsessions/$session.desktop" ]; then
        log_warn "No se encontro /usr/share/xsessions/$session.desktop: LightDM podria no ofrecer $DESKTOP."
    fi

    # La version anterior del script dejaba este archivo fijo en LXDE.
    old=/etc/lightdm/lightdm.conf.d/50-lxde.conf
    if [ -f "$old" ]; then
        backup_file "$old"
        rm -f "$old"
        log_ok "Retirada la configuracion de LightDM de la version anterior del script."
    fi

    mkdir -p /etc/lightdm/lightdm.conf.d
    printf '[Seat:*]\nuser-session=%s\ngreeter-session=lightdm-gtk-greeter\n' "$session" \
        > /etc/lightdm/lightdm.conf.d/90-antix-desktop.conf
    log_ok "Sesion predeterminada de LightDM: $session"

    backup_file /etc/X11/default-display-manager
    echo "/usr/sbin/lightdm" > /etc/X11/default-display-manager
}

# ------------------------------------------------------------------------------
# 8. Ajustes del usuario y restos de la version anterior del script
# ------------------------------------------------------------------------------
setup_user() {
    [ -n "$TARGET_USER" ] || return 0
    log_info "== Ajustes del usuario $TARGET_USER =="
    for grp in netdev audio video; do
        if getent group "$grp" >/dev/null; then
            usermod -aG "$grp" "$TARGET_USER" && log_ok "Agregado al grupo '$grp'."
        fi
    done

    # La version anterior escribia "exec startlxde" en ~/.xsessionrc. Ese
    # archivo se incluye al iniciar CUALQUIER sesion grafica, asi que la
    # linea forzaba LXDE sin importar lo que se eligiera en LightDM.
    rc="$TARGET_HOME/.xsessionrc"
    if [ -f "$rc" ] && grep -qx 'exec startlxde' "$rc"; then
        backup_file "$rc"
        sed -i '/^exec startlxde$/d' "$rc"
        [ -s "$rc" ] || rm -f "$rc"
        log_ok "Retirado 'exec startlxde' de $rc"
    fi
}

# ------------------------------------------------------------------------------
# 9. Retirar dhcpcd, solo cuando NetworkManager ya esta estable
# ------------------------------------------------------------------------------
# dhcpcd y NetworkManager no deben manejar la misma interfaz. dhcpcd se
# retira al final y solo si NetworkManager lleva al menos 15 s en marcha
# sin reiniciarse: si NetworkManager fallara, retirar dhcpcd dejaria el
# equipo sin red.
retire_dhcpcd() {
    [ -e "$SERVICE_DIR/dhcpcd" ] || return 0
    log_info "== Esperando a que NetworkManager se estabilice para retirar dhcpcd =="
    up=0; i=0
    while [ "$i" -lt 12 ]; do
        up="$(sv status "$SERVICE_DIR/NetworkManager" 2>/dev/null \
              | sed -n 's/^run: [^(]*(pid [0-9]*) \([0-9]*\)s.*/\1/p')"
        [ "${up:-0}" -ge 15 ] && break
        sleep 3; i=$((i + 1))
    done
    if [ "${up:-0}" -ge 15 ]; then
        sv down "$SERVICE_DIR/dhcpcd" >/dev/null 2>&1
        rm -f "$SERVICE_DIR/dhcpcd"
        sv restart "$SERVICE_DIR/NetworkManager" >/dev/null 2>&1
        log_ok "dhcpcd retirado: NetworkManager maneja la red."
    else
        log_warn "NetworkManager no se estabilizo (en marcha: ${up:-?} s). Se mantiene dhcpcd para no dejar el equipo sin red."
    fi
}

# ------------------------------------------------------------------------------
# 10. Informe final y activacion de LightDM
# ------------------------------------------------------------------------------
final_report() {
    echo
    log_info "===== Verificacion final ====="
    if is_installed elogind; then
        log_warn "elogind sigue instalado: habra esperas de 25 s al iniciar sesion."
    else
        log_ok "elogind no esta instalado."
    fi
    if is_installed consolekit; then log_ok "ConsoleKit instalado."; else log_warn "ConsoleKit NO esta instalado."; fi
    for s in dbus seatd NetworkManager; do
        st="$(sv status "$SERVICE_DIR/$s" 2>/dev/null | cut -d: -f1)"
        if [ "$st" = "run" ]; then log_ok "Servicio '$s' corriendo."; else log_warn "Servicio '$s': ${st:-no activado}."; fi
    done
    [ -n "$FAILED_PKGS" ] && log_warn "Paquetes que no se pudieron instalar:$FAILED_PKGS"
    log_info "No ejecutes 'apt autoremove' sin revisar la lista: libelogind0 quedo protegida, pero conviene mirar."
    log_info "Registro completo: $LOG_FILE"
}

# Se activa al final: al activarse, LightDM arranca en segundos y la
# pantalla puede cambiar al inicio de sesion grafico.
enable_display_manager() {
    if [ ! -e "$SERVICE_DIR/lightdm" ]; then
        log_info "Listo. LightDM se activara ahora y la pantalla puede cambiar al inicio de sesion grafico."
        log_info "Para que todos los cambios surtan efecto, reinicia despues: sudo reboot"
    else
        log_info "Listo. Reinicia para empezar a usar $DESKTOP: sudo reboot"
    fi
    ensure_runit_service lightdm "/usr/sbin/lightdm" yes
}

main() {
    parse_args "$@"
    check_environment
    log_info "Actualizando indices de paquetes..."
    apt-get update >>"$LOG_FILE" 2>&1 || log_warn "apt-get update tuvo errores (detalle en $LOG_FILE)."
    choose_desktop
    setup_session_tracking
    install_desktop
    setup_network
    setup_autostart
    setup_display_manager
    setup_user
    retire_dhcpcd
    final_report
    enable_display_manager
}

main "$@"
