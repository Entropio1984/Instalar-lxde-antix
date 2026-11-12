#!/bin/bash
# ==============================================================================
# antix-desktop-postinstall.sh
#
# Convierte una instalacion de antiX 26 Core (32 o 64 bits) en un equipo
# listo para un estudiante de colegio:
#   - Deja runit como UNICO init: retira sysVinit, dinit, s6-rc y s6-66 y
#     sus entradas del menu de arranque (GRUB).
#   - Instala un escritorio liviano a eleccion: LXDE, LXQt o Fluxbox.
#   - Instala solo lo necesario: explorador de archivos, Firefox ESR,
#     LibreOffice (Writer, Calc, Impress), lector de PDF, wifi con icono,
#     volumen, fuentes compatibles con documentos de Office y LightDM
#     (inicio de sesion grafico).
#
# Por que asi (problemas demostrados en maquinas virtuales con antiX 26):
#   - elogind instalado pero sin correr bajo runit hacia que cada consulta
#     de LightDM y de la sesion esperara 25 s. Se usa ConsoleKit.
#   - runit no trae servicio para NetworkManager: hay que crearlo.
#   - dhcpcd y NetworkManager no deben manejar la misma interfaz a la vez.
#   - LXQt usa Qt 6, que exige un procesador con SSE2: sin SSE2 no se ofrece.
#
# Uso:
#   sudo ./antix-desktop-postinstall.sh             # menu para elegir escritorio
#   sudo ./antix-desktop-postinstall.sh --lxde      # sin menu
#   sudo ./antix-desktop-postinstall.sh --lxqt
#   sudo ./antix-desktop-postinstall.sh --fluxbox
#   sudo ./antix-desktop-postinstall.sh --conservar-inits   # no retira inits
#   ./antix-desktop-postinstall.sh --listar lxde    # solo muestra paquetes
#
# Es idempotente: se puede volver a ejecutar sin duplicar cambios.
# ==============================================================================

# Sin "set -e" a proposito: cada paso maneja sus propios errores y los
# paquetes que no se pudieron instalar se listan en el informe final.
set -u

LOG_FILE="/var/log/antix-desktop-postinstall.log"
SV_DIR="/etc/sv"
SERVICE_DIR="/etc/service"
PIN_FILE="/etc/apt/preferences.d/00elogind"
FAILED_PKGS=""
DESKTOP=""
KEEP_INITS=0
TARGET_USER=""
TARGET_HOME=""

# ------------------------------------------------------------------------------
# Listas de paquetes (se instalan sin los "recomendados" para no sumar peso)
# ------------------------------------------------------------------------------
PKGS_BASE="xorg dbus-x11 consolekit polkitd adwaita-icon-theme alsa-utils
 network-manager network-manager-gnome lightdm lightdm-gtk-greeter"
PKGS_LXDE="lxde-core lxde-icon-theme lxterminal lxappearance lxpolkit
 lxsession-logout volumeicon-alsa openbox"
PKGS_LXQT="lxqt-core qterminal openbox breeze-icon-theme"
PKGS_FLUXBOX="fluxbox pcmanfm lxterminal lxappearance lxpolkit lxsession-logout
 volumeicon-alsa"
PKGS_APPS="firefox-esr firefox-esr-l10n-es-es libreoffice-writer
 libreoffice-calc libreoffice-impress libreoffice-l10n-es libreoffice-gtk3
 libreoffice-style-colibre hunspell-es atril xarchiver unzip
 fonts-dejavu-core fonts-liberation2 fonts-crosextra-carlito
 fonts-crosextra-caladea"

# Paquetes de los inits que se retiran. Se dejan SIEMPRE: runit-*, init,
# initscripts y sysv-rc (runit los usa al arrancar), init-diversity-tools
# y grub-init-diversity (apagado y menu de arranque).
INIT_PKG_REGEX='^(sysvinit-init-antix|dinit|dinit-.*|s6|s6-rc|s6-rc-.*|s6-66-.*|66|66-.*|s6-linux-init|s6-linux-utils|s6-portable-utils|libs6rc-.*|libs6-linux-init-.*)$'

desktop_pkgs() {
    case "$1" in
        LXDE) echo $PKGS_BASE $PKGS_LXDE $PKGS_APPS ;;
        LXQT) echo $PKGS_BASE $PKGS_LXQT $PKGS_APPS ;;
        FLUXBOX) echo $PKGS_BASE $PKGS_FLUXBOX $PKGS_APPS ;;
    esac
}

log_file()  { printf '%s %s\n' "$(date '+%F %T')" "$1" >>"$LOG_FILE" 2>/dev/null || true; }
log_info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$1"; log_file "[INFO]  $1"; }
log_ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$1"; log_file "[OK]    $1"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$1"; log_file "[WARN]  $1"; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$1"; log_file "[ERROR] $1"; }

is_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
}

has_sse2() {
    grep -qw sse2 /proc/cpuinfo 2>/dev/null
}

backup_file() {
    if [ -f "$1" ]; then
        cp -a "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)"
        log_info "Respaldo creado: $1.bak.*"
    fi
}

# Instala en una sola transaccion; si falla (por ejemplo, porque un nombre
# no existe), reintenta paquete por paquete para que un solo fallo no
# impida instalar el resto. La salida de apt va al log.
apt_install() {
    log_info "Instalando: $* (puede tardar varios minutos)"
    if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" >>"$LOG_FILE" 2>&1; then
        log_ok "Instalado."
        return 0
    fi
    log_warn "Fallo la instalacion en lote; se reintenta paquete por paquete."
    for p in "$@"; do
        if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p" >>"$LOG_FILE" 2>&1; then
            log_ok "'$p' instalado."
        else
            log_warn "No se pudo instalar '$p' (detalle en $LOG_FILE)."
            FAILED_PKGS="$FAILED_PKGS $p"
        fi
    done
}

# Crea (si no existe) y activa un servicio de runit. $1 = nombre,
# $2 = comando, $3 = "yes" si necesita D-Bus. runit arranca los servicios
# en paralelo: uno que necesita D-Bus termina si D-Bus aun no esta listo,
# y runit lo reintenta al segundo. Si el paquete ya trae su propio
# servicio de runit, se usa ese.
ensure_runit_service() {
    name="$1"; cmd="$2"; needs_dbus="$3"
    if [ ! -x "$SV_DIR/$name/run" ]; then
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

# Retira una linea exacta de un archivo, si esta.
remove_line() {
    file="$1"; line="$2"
    [ -f "$file" ] || return 0
    if grep -qxF "$line" "$file"; then
        backup_file "$file"
        grep -vxF "$line" "$file" > "$file.tmp" && cat "$file.tmp" > "$file"
        rm -f "$file.tmp"
        log_ok "Retirado '$line' de $file"
    fi
}

# ------------------------------------------------------------------------------
# 1. Comprobaciones iniciales
# ------------------------------------------------------------------------------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --lxde) DESKTOP="LXDE" ;;
            --lxqt) DESKTOP="LXQT" ;;
            --fluxbox) DESKTOP="FLUXBOX" ;;
            --conservar-inits) KEEP_INITS=1 ;;
            --listar)
                # Solo muestra los paquetes; lo usa la prueba automatica.
                case "${2:-}" in
                    lxde|lxqt|fluxbox) desktop_pkgs "$(echo "$2" | tr a-z A-Z)"; exit 0 ;;
                    inits) echo "$INIT_PKG_REGEX"; exit 0 ;;
                    *) echo "Uso: --listar lxde|lxqt|fluxbox|inits" >&2; exit 1 ;;
                esac ;;
            -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            *) echo "Opcion desconocida: $1 (usa --help)" >&2; exit 1 ;;
        esac
        shift
    done
}

check_environment() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "Este script debe ejecutarse como root: sudo $0" >&2
        exit 1
    fi
    : >>"$LOG_FILE"
    log_file "===== Inicio de ejecucion ====="

    if mountpoint -q /live/aufs 2>/dev/null; then
        log_error "Esto es la sesion live (desde el USB). Primero instala antiX en el disco y ejecuta el script ahi."
        exit 1
    fi

    init_name="$(ps -p 1 -o comm= 2>/dev/null)"
    if [ "$init_name" != "runit" ]; then
        log_error "Este script esta hecho para antiX con init runit (el predeterminado); el init activo es '$init_name'."
        log_error "Reinicia eligiendo runit en el menu de arranque y vuelve a ejecutarlo."
        exit 1
    fi
    [ -f /etc/antix-version ] || log_warn "No se encontro /etc/antix-version: el script esta pensado para antiX 26."
    log_ok "Init runit confirmado. Arquitectura: $(dpkg --print-architecture)."
    if ! has_sse2; then
        log_warn "Este procesador no tiene SSE2 (Pentium III, Athlon XP o anterior)."
        log_warn "Firefox y LibreOffice exigen SSE2: se instalaran pero probablemente no abran."
    fi

    TARGET_USER="${SUDO_USER:-}"
    [ -z "$TARGET_USER" ] && TARGET_USER="$(logname 2>/dev/null || true)"
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
        log_warn "No se detecto un usuario normal: solo se configuran los usuarios nuevos."
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
    if [ "$DESKTOP" = "LXQT" ] && ! has_sse2; then
        log_error "Este procesador no tiene SSE2 y LXQt no funcionaria. Usa --lxde o --fluxbox."
        exit 1
    fi
    if [ -n "$DESKTOP" ]; then
        log_info "Escritorio elegido por argumento: $DESKTOP"
        return 0
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        log_error "No hay una terminal interactiva: indica el escritorio con --lxde, --lxqt o --fluxbox."
        exit 1
    fi
    command -v dialog >/dev/null 2>&1 || apt_install dialog

    if has_sse2; then
        lxqt_text="LXQt: moderno (Qt), necesita algo mas de memoria"
    else
        lxqt_text="LXQt: NO disponible (el procesador no tiene SSE2)"
    fi

    if command -v dialog >/dev/null 2>&1; then
        choice="LXDE"
        while :; do
            st_lxde=off; st_lxqt=off; st_flux=off
            case "$choice" in
                LXQT) st_lxqt=on ;; FLUXBOX) st_flux=on ;; *) st_lxde=on ;;
            esac
            if ! choice="$(dialog --stdout --no-tags \
                    --backtitle "Escritorio para antiX 26 Core" \
                    --title "Escritorio" \
                    --ok-label "Continuar" --cancel-label "Salir" \
                    --radiolist "ESPACIO elige, ENTER continua." 0 0 0 \
                    LXDE "LXDE: liviano y sencillo (recomendado)" "$st_lxde" \
                    FLUXBOX "Fluxbox: el mas liviano, para equipos muy viejos" "$st_flux" \
                    LXQT "$lxqt_text" "$st_lxqt")"; then
                clear 2>/dev/null || true
                log_info "Cancelado por el usuario: no se cambio la configuracion del sistema."
                exit 0
            fi
            if [ "$choice" = "LXQT" ] && ! has_sse2; then
                dialog --title "LXQt" --msgbox "Este procesador no tiene SSE2: LXQt no funcionaria. Elige LXDE o Fluxbox." 0 0
                choice="LXDE"
                continue
            fi
            if [ "$KEEP_INITS" -eq 1 ]; then inits_text="Se conservan los demas inits."; else inits_text="Se retiran sysVinit, dinit, s6-rc y s6-66: solo queda runit."; fi
            if dialog --title "Confirmar" --yes-label "Comenzar" --no-label "Volver" \
                    --yesno "Se instalara $choice con:\n\n  - Firefox ESR, LibreOffice, lector de PDF\n  - Explorador de archivos y wifi con icono\n  - LightDM (inicio de sesion grafico)\n\n$inits_text\n\nA partir de aqui el script no hara mas preguntas." 0 0; then
                break
            fi
        done
        clear 2>/dev/null || true
        DESKTOP="$choice"
    else
        while :; do
            printf '\nEscritorio a instalar:\n  1) LXDE (recomendado)\n  2) Fluxbox (el mas liviano)\n  3) LXQt\nElige 1, 2 o 3: '
            read -r r || exit 1
            case "$r" in
                1) DESKTOP="LXDE"; break ;;
                2) DESKTOP="FLUXBOX"; break ;;
                3) if has_sse2; then DESKTOP="LXQT"; break; else echo "LXQt no funciona en este procesador (sin SSE2)."; fi ;;
            esac
        done
    fi
    log_ok "Escritorio elegido: $DESKTOP"
}

# ------------------------------------------------------------------------------
# 3. Solo runit: retirar los demas inits y sus entradas de GRUB
# ------------------------------------------------------------------------------
# En antiX 26 cada init viene en paquetes propios (sysvinit-init-antix,
# dinit-init-antix, s6-rc-init-antix, s6-66-init-antix y sus servicios).
# El menu de GRUB muestra una entrada por cada init que siga instalado,
# asi que al retirar los paquetes y regenerar GRUB solo queda runit.
remove_other_inits() {
    if [ "$KEEP_INITS" -eq 1 ]; then
        log_info "Se conservan los demas inits (--conservar-inits)."
        return 0
    fi
    log_info "== Solo runit: retirando sysVinit, dinit, s6-rc y s6-66 =="
    if [ "$(readlink -f /sbin/init)" != "$(readlink -f /lib/runit/runit-init)" ]; then
        log_warn "/sbin/init no apunta a runit: no se retira ningun init por seguridad."
        return 0
    fi

    pkgs="$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
            | awk '$NF=="installed"{print $1}' | grep -E "$INIT_PKG_REGEX" || true)"
    if [ -z "$pkgs" ]; then
        log_ok "No quedan otros inits instalados."
    else
        # Simulacion previa: si la operacion arrastrara cualquier paquete
        # que no sea de esos inits, no se hace nada.
        extra="$(apt-get -s purge $pkgs 2>/dev/null \
                 | awk '/^(Remv|Purg) /{print $2}' | sed 's/:.*//' \
                 | grep -vE "$INIT_PKG_REGEX" || true)"
        if [ -n "$extra" ]; then
            log_warn "No se retiran los otros inits porque tambien se eliminaria: $(echo $extra)"
            return 0
        fi
        if DEBIAN_FRONTEND=noninteractive apt-get purge -y $pkgs >>"$LOG_FILE" 2>&1; then
            log_ok "Retirados: $(echo $pkgs)"
        else
            log_warn "No se pudieron retirar los otros inits (detalle en $LOG_FILE)."
            return 0
        fi
    fi

    # Un arranque guardado con otro init ya no existe: volver a la primera
    # entrada (runit).
    command -v grub-editenv >/dev/null 2>&1 && grub-editenv - unset saved_entry 2>/dev/null
    if command -v update-grub >/dev/null 2>&1 && update-grub >>"$LOG_FILE" 2>&1; then
        log_ok "Menu de arranque actualizado: solo queda runit."
    else
        log_warn "No se pudo actualizar GRUB (detalle en $LOG_FILE)."
    fi
}

# ------------------------------------------------------------------------------
# 4. Sesiones y permisos: ConsoleKit en lugar de elogind
# ------------------------------------------------------------------------------
setup_session_tracking() {
    log_info "== Sesiones y permisos: ConsoleKit en lugar de elogind =="
    # Bloqueo en apt para que ningun paquete vuelva a instalar elogind.
    # Mismo formato que el bloqueo de systemd que antiX ya trae.
    if [ ! -f "$PIN_FILE" ]; then
        printf 'Package: elogind libpam-elogind\nPin: origin *\nPin-Priority: -1\n' > "$PIN_FILE"
        log_ok "Bloqueo de elogind creado en $PIN_FILE"
    fi

    if is_installed elogind || is_installed libpam-elogind; then
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
    # libelogind0 es una LIBRERIA que necesitan muchos paquetes: se marca
    # como instalada a mano para que 'apt autoremove' no la borre.
    for lib in libelogind0 libelogind-compat; do
        if is_installed "$lib"; then
            apt-mark manual "$lib" >>"$LOG_FILE" 2>&1 && log_ok "'$lib' protegida de 'apt autoremove'."
        fi
    done
}

# ------------------------------------------------------------------------------
# 5. Escritorio y programas
# ------------------------------------------------------------------------------
install_packages() {
    log_info "== Instalando $DESKTOP y los programas del estudiante =="
    # shellcheck disable=SC2046
    apt_install $(desktop_pkgs "$DESKTOP")

    # Si algo arrastro otro gestor de inicio de sesion, se desactiva: dos
    # gestores a la vez pelean por la pantalla.
    for dm in sddm slim slimski xdm gdm3; do
        if [ -L "$SERVICE_DIR/$dm" ]; then
            rm -f "$SERVICE_DIR/$dm"
            log_ok "'$dm' desactivado: se usa LightDM."
        fi
    done
}

# ------------------------------------------------------------------------------
# 6. Red: NetworkManager como servicio de runit
# ------------------------------------------------------------------------------
setup_network() {
    log_info "== Red: NetworkManager =="
    # Sin NetworkManager no se toca la red: borrar la configuracion actual
    # dejaria el equipo sin internet para poder arreglarlo.
    if ! is_installed network-manager; then
        log_error "NetworkManager no se instalo: la configuracion de red NO se modifica."
        return 0
    fi

    # NetworkManager ignora las interfaces declaradas en
    # /etc/network/interfaces (por ejemplo, las que configura ceni). Si hay
    # alguna ademas de 'lo', se deja solo 'lo' (con respaldo).
    ifaces=/etc/network/interfaces
    if [ -f "$ifaces" ] && grep -E '^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]' "$ifaces" | grep -qvE '^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+lo([[:space:]]|$)'; then
        backup_file "$ifaces"
        printf 'auto lo\niface lo inet loopback\n' > "$ifaces"
        log_ok "$ifaces reducido a 'lo' para que NetworkManager maneje la red."
        log_info "Si usabas wifi, vuelve a conectarte desde el icono de red."
    fi

    ensure_runit_service NetworkManager "/usr/sbin/NetworkManager --no-daemon" yes
}

# ------------------------------------------------------------------------------
# 7. Autoarranque y configuracion de cada escritorio
# ------------------------------------------------------------------------------
write_fluxbox_files() {
    dir="$1"
    mkdir -p "$dir"
    if [ ! -f "$dir/startup" ]; then
        cat > "$dir/startup" <<'EOF'
#!/bin/sh
# Programas que arrancan junto con Fluxbox.
nm-applet &
volumeicon &
lxpolkit &
exec fluxbox
EOF
        chmod 755 "$dir/startup"
    fi
    if [ ! -f "$dir/menu" ]; then
        cat > "$dir/menu" <<'EOF'
[begin] (Menu)
  [exec] (Navegador Firefox) {firefox-esr}
  [exec] (Archivos) {pcmanfm}
  [exec] (Documentos - Writer) {libreoffice --writer}
  [exec] (Hojas de calculo - Calc) {libreoffice --calc}
  [exec] (Presentaciones - Impress) {libreoffice --impress}
  [exec] (Lector de PDF) {atril}
  [exec] (Terminal) {lxterminal}
  [separator]
  [submenu] (Todos los programas)
    [include] (/etc/X11/fluxbox/fluxbox-menu)
  [end]
  [submenu] (Apariencia)
    [exec] (Temas y tipos de letra) {lxappearance}
    [config] (Opciones de Fluxbox)
    [stylesdir] (/usr/share/fluxbox/styles)
  [end]
  [separator]
  [exec] (Salir / Apagar / Reiniciar) {lxsession-logout}
[end]
EOF
    fi
}

setup_desktop_config() {
    log_info "== Configuracion de $DESKTOP =="

    # Restos de versiones anteriores del script: lineas de autoarranque que
    # ahora se manejan desde /etc/xdg/autostart (evita iconos repetidos y
    # dos agentes de permisos peleando).
    lx_files="/etc/xdg/lxsession/LXDE/autostart"
    [ -n "$TARGET_HOME" ] && lx_files="$lx_files $TARGET_HOME/.config/lxsession/LXDE/autostart"
    for f in $lx_files; do
        for l in "@nm-applet" "@volumeicon" "@lxpolkit"; do
            remove_line "$f" "$l"
        done
    done

    case "$DESKTOP" in
        LXDE)
            # nm-applet ya se inicia desde /etc/xdg/autostart y lxsession
            # inicia su propio agente de permisos. Falta el volumen.
            cat > /etc/xdg/autostart/volumeicon-antix.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Volumen
Exec=volumeicon
OnlyShowIn=LXDE;
EOF
            log_ok "Icono de volumen en el autoarranque de LXDE."
            ;;
        LXQT)
            # Sin esto, LXQt pregunta en el primer inicio que gestor de
            # ventanas usar.
            for d in /etc/skel/.config/lxqt ${TARGET_HOME:+$TARGET_HOME/.config/lxqt}; do
                mkdir -p "$d"
                if [ ! -f "$d/session.conf" ]; then
                    printf '[General]\nwindow_manager=openbox\n' > "$d/session.conf"
                    log_ok "Gestor de ventanas de LXQt: Openbox ($d)"
                fi
            done
            ;;
        FLUXBOX)
            write_fluxbox_files /etc/skel/.fluxbox
            if [ -n "$TARGET_HOME" ]; then
                write_fluxbox_files "$TARGET_HOME/.fluxbox"
                chown -R "$TARGET_USER": "$TARGET_HOME/.fluxbox"
            fi
            log_ok "Menu y autoarranque de Fluxbox listos (wifi, volumen, permisos)."
            ;;
    esac
    [ -n "$TARGET_HOME" ] && [ -d "$TARGET_HOME/.config" ] && chown -R "$TARGET_USER": "$TARGET_HOME/.config"
}

# ------------------------------------------------------------------------------
# 8. LightDM
# ------------------------------------------------------------------------------
setup_display_manager() {
    log_info "== Inicio de sesion grafico: LightDM =="
    if ! is_installed lightdm; then
        log_error "LightDM no se instalo: el equipo seguira arrancando en modo texto."
        return 0
    fi
    case "$DESKTOP" in
        LXDE) session="LXDE" ;;
        LXQT) session="lxqt" ;;
        FLUXBOX) session="fluxbox" ;;
    esac
    if [ ! -f "/usr/share/xsessions/$session.desktop" ]; then
        log_warn "No se encontro /usr/share/xsessions/$session.desktop: LightDM podria no ofrecer $DESKTOP."
    fi

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
# 9. Ajustes del usuario y restos de la version anterior del script
# ------------------------------------------------------------------------------
setup_user() {
    # Restos del script viejo (instalar_lxde_antix.sh):
    # enlace a un servicio de elogind que ya no existe.
    if [ -L "$SERVICE_DIR/elogind" ] && [ ! -e "$SERVICE_DIR/elogind" ]; then
        rm -f "$SERVICE_DIR/elogind"
        log_ok "Retirado el servicio roto de elogind."
    fi
    # Carpeta de registro vacia que runit intenta arrancar sin exito.
    if [ -d "$SV_DIR/lightdm/log" ] && [ ! -e "$SV_DIR/lightdm/log/run" ]; then
        rmdir "$SV_DIR/lightdm/log" 2>/dev/null && log_ok "Retirada la carpeta vacia $SV_DIR/lightdm/log."
    fi
    # Consola de texto 1 desactivada: se vuelve a activar como respaldo.
    if [ -d "$SV_DIR/getty-tty1" ] && [ ! -e "$SERVICE_DIR/getty-tty1" ]; then
        ln -s "$SV_DIR/getty-tty1" "$SERVICE_DIR/getty-tty1"
        log_ok "Consola de texto 1 reactivada (Ctrl+Alt+F1)."
    fi

    [ -n "$TARGET_USER" ] || return 0
    log_info "== Ajustes del usuario $TARGET_USER =="
    for grp in netdev audio video plugdev; do
        if getent group "$grp" >/dev/null; then
            usermod -aG "$grp" "$TARGET_USER" && log_ok "Agregado al grupo '$grp'."
        fi
    done

    # La version vieja escribia "exec startlxde" en ~/.xsessionrc, lo que
    # forzaba LXDE sin importar lo que se eligiera en LightDM.
    rc="$TARGET_HOME/.xsessionrc"
    if [ -f "$rc" ] && grep -qx 'exec startlxde' "$rc"; then
        backup_file "$rc"
        sed -i '/^exec startlxde$/d' "$rc"
        [ -s "$rc" ] || rm -f "$rc"
        log_ok "Retirado 'exec startlxde' de $rc"
    fi
}

# ------------------------------------------------------------------------------
# 10. Retirar dhcpcd y connman, solo cuando NetworkManager ya esta estable
# ------------------------------------------------------------------------------
# Dos programas no deben manejar la misma interfaz de red. Se retiran al
# final y solo si NetworkManager lleva al menos 15 s en marcha sin
# reiniciarse: si NetworkManager fallara, el equipo quedaria sin red.
retire_other_network() {
    others=""
    for s in dhcpcd connman; do
        [ -e "$SERVICE_DIR/$s" ] && others="$others $s"
    done
    [ -n "$others" ] || return 0
    [ -e "$SERVICE_DIR/NetworkManager" ] || return 0
    log_info "== Esperando a que NetworkManager se estabilice para retirar:$others =="
    up=0; i=0
    while [ "$i" -lt 12 ]; do
        up="$(sv status "$SERVICE_DIR/NetworkManager" 2>/dev/null \
              | sed -n 's/^run: [^(]*(pid [0-9]*) \([0-9]*\)s.*/\1/p')"
        [ "${up:-0}" -ge 15 ] && break
        sleep 3; i=$((i + 1))
    done
    if [ "${up:-0}" -ge 15 ]; then
        for s in $others; do
            sv down "$SERVICE_DIR/$s" >/dev/null 2>&1
            rm -f "$SERVICE_DIR/$s"
        done
        sv restart "$SERVICE_DIR/NetworkManager" >/dev/null 2>&1
        log_ok "Retirado:$others. NetworkManager maneja la red."
    else
        log_warn "NetworkManager no se estabilizo (en marcha: ${up:-?} s). Se mantiene:$others para no dejar el equipo sin red."
    fi
}

# ------------------------------------------------------------------------------
# 11. Informe final y activacion de LightDM
# ------------------------------------------------------------------------------
final_report() {
    echo
    log_info "===== Verificacion final ====="
    if is_installed elogind; then
        log_warn "elogind sigue instalado: habra esperas de 25 s al iniciar sesion."
    else
        log_ok "elogind no esta instalado."
    fi
    for s in dbus seatd NetworkManager; do
        st="$(sv status "$SERVICE_DIR/$s" 2>/dev/null | cut -d: -f1)"
        if [ "$st" = "run" ]; then log_ok "Servicio '$s' corriendo."; else log_warn "Servicio '$s': ${st:-no activado}."; fi
    done
    left="$(dpkg-query -W -f='${Package} ${Status}\n' 2>/dev/null \
            | awk '$NF=="installed"{print $1}' | grep -E '^(sysvinit|dinit|s6-rc|s6-66)-init-antix$' || true)"
    if [ -z "$left" ]; then
        log_ok "Init: solo runit."
    else
        log_warn "Siguen instalados otros inits: $(echo $left)"
    fi
    for app in firefox-esr libreoffice-writer atril; do
        if is_installed "$app"; then log_ok "'$app' instalado."; else log_warn "'$app' NO esta instalado."; fi
    done
    [ -n "$FAILED_PKGS" ] && log_warn "Paquetes que no se pudieron instalar:$FAILED_PKGS"
    log_info "Registro completo: $LOG_FILE"
}

# Se activa al final: al activarse, LightDM arranca en segundos y la
# pantalla puede cambiar al inicio de sesion grafico.
enable_display_manager() {
    if ! is_installed lightdm; then
        log_warn "LightDM no esta instalado: no se activa el inicio grafico."
        return 0
    fi
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
    remove_other_inits
    setup_session_tracking
    install_packages
    setup_network
    setup_desktop_config
    setup_display_manager
    setup_user
    retire_other_network
    final_report
    enable_display_manager
}

main "$@"
