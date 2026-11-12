#!/bin/bash
# ==============================================================================
# antix-desktop-postinstall.sh
#
# Convierte una instalacion de antiX 26 Core (32 o 64 bits) en un equipo
# listo para uso general (hogar, estudio, oficina):
#   - Deja runit como UNICO init: retira sysVinit, dinit, s6-rc y s6-66 y
#     sus entradas del menu de arranque (GRUB).
#   - Instala un escritorio liviano a eleccion: LXDE, LXQt o Fluxbox.
#   - Instala solo lo necesario: explorador de archivos, Firefox ESR,
#     LibreOffice (Writer, Calc, Impress), lector de PDF, impresora y
#     escaner, visor de fotos, videos y YouTube (mpv), Bluetooth,
#     calculadora, bloc de notas, wifi con icono, volumen, fuentes
#     compatibles con documentos de Office y LightDM (inicio grafico).
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
#   sudo ./antix-desktop-postinstall.sh --sin-ajustes  # sin ajustes de rendimiento
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
TUNE=1
TARGET_USER=""
TARGET_HOME=""

# ------------------------------------------------------------------------------
# Listas de paquetes (se instalan sin los "recomendados" para no sumar peso)
# ------------------------------------------------------------------------------
PKGS_BASE="xorg dbus-x11 consolekit polkitd adwaita-icon-theme alsa-utils
 network-manager network-manager-gnome lightdm lightdm-gtk-greeter
 runit-service-network-manager runit-service-consolekit
 gvfs gvfs-backends udisks2 ntfs-3g exfatprogs"
# Para "YouTube ligero" (gtk-pipe-viewer se instala desde su pagina).
PKGS_YOUTUBE="python3 libmodule-build-perl libdata-dump-perl libjson-perl
 libjson-xs-perl libwww-perl liblwp-protocol-https-perl liburi-perl
 libgtk3-perl libfile-sharedir-perl libunicode-linebreak-perl
 libterm-readline-gnu-perl"
PKGS_LXDE="lxde-core lxde-icon-theme lxterminal lxappearance lxpolkit
 lxsession-logout volumeicon-alsa openbox"
PKGS_LXQT="lxqt-core qterminal openbox breeze-icon-theme"
PKGS_FLUXBOX="fluxbox pcmanfm lxterminal lxappearance lxpolkit lxsession-logout
 volumeicon-alsa"
PKGS_APPS="firefox-esr firefox-esr-l10n-es-es libreoffice-writer
 libreoffice-calc libreoffice-impress libreoffice-l10n-es libreoffice-gtk3
 libreoffice-style-colibre hunspell-es atril xarchiver unzip
 fonts-dejavu-core fonts-liberation2 fonts-crosextra-carlito
 fonts-crosextra-caladea
 cups runit-service-cups system-config-printer printer-driver-hpcups printer-driver-gutenprint
 simple-scan gpicview mpv earlyoom bluez runit-service-bluetooth blueman galculator mousepad scrot"

# Paquetes de los inits que se retiran. Se dejan SIEMPRE: runit-*, init,
# initscripts y sysv-rc (runit los usa al arrancar), init-diversity-tools
# y grub-init-diversity (apagado y menu de arranque).
# Tambien se dejan s6, s6-linux-init y sus utilidades: son bibliotecas
# pequenas que ya no arrancan nada, y el script de desinstalacion de
# s6-linux-init en antiX 26.1 falla (borra el usuario s6log y luego su
# grupo, que ya no existe), lo que dejaria apt a medio camino.
INIT_PKG_REGEX='^(sysvinit-init-antix|dinit|dinit-.*|s6-rc|s6-rc-.*|s6-66-.*|66|66-.*|libs6rc-.*)$'

desktop_pkgs() {
    case "$1" in
        LXDE) echo $PKGS_BASE $PKGS_LXDE $PKGS_APPS $PKGS_YOUTUBE ;;
        LXQT) echo $PKGS_BASE $PKGS_LXQT $PKGS_APPS $PKGS_YOUTUBE ;;
        FLUXBOX) echo $PKGS_BASE $PKGS_FLUXBOX $PKGS_APPS $PKGS_YOUTUBE ;;
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

# Nombre del servicio de runit que existe en /etc/sv, entre varios
# candidatos ($1, separados por espacios). antiX trae servicios propios
# (paquetes runit-service-*); si no hay, se usa el primero.
runit_name() {
    for c in $1; do
        [ -x "$SV_DIR/$c/run" ] && { echo "$c"; return 0; }
    done
    set -- $1
    echo "$1"
}

# Activa un servicio de runit. $1 = nombres posibles (el primero es el de
# antiX), $2 = comando, $3 = "yes" si necesita D-Bus. Si antiX ya trae el
# servicio, se usa ese; si no, se crea uno. runit arranca los servicios en
# paralelo: uno que necesita D-Bus termina si D-Bus aun no esta listo, y
# runit lo reintenta al segundo.
ensure_runit_service() {
    cands="$1"; cmd="$2"; needs_dbus="$3"
    name="$(runit_name "$cands")"
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
    # El mismo programa no debe quedar activado dos veces con otro nombre
    # (por ejemplo, uno creado por una version anterior de este script).
    for c in $cands; do
        [ "$c" = "$name" ] && continue
        if [ -L "$SERVICE_DIR/$c" ]; then
            sv down "$SERVICE_DIR/$c" >/dev/null 2>&1
            rm -f "$SERVICE_DIR/$c"
            log_ok "Servicio duplicado '$c' desactivado (se usa '$name')."
        fi
    done
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
            --sin-ajustes) TUNE=0 ;;
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
    log_info "== Instalando $DESKTOP y los programas de uso general =="
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

    ensure_runit_service "network-manager NetworkManager" "/usr/sbin/NetworkManager --no-daemon" yes
}

# ------------------------------------------------------------------------------
# 6b. Impresoras y Bluetooth
# ------------------------------------------------------------------------------
setup_services() {
    log_info "== Impresoras y Bluetooth =="
    # runit no arranca estos servicios por su cuenta: se crean si faltan.
    if [ -x /usr/sbin/cupsd ]; then
        ensure_runit_service cups "/usr/sbin/cupsd -f" no
    else
        log_warn "CUPS no se instalo: no se podra imprimir."
    fi
    btd=""
    for f in /usr/libexec/bluetooth/bluetoothd /usr/lib/bluetooth/bluetoothd; do
        [ -x "$f" ] && { btd="$f"; break; }
    done
    if [ -n "$btd" ]; then
        ensure_runit_service "bluetooth bluetoothd" "$btd -n" yes
    else
        log_warn "Bluetooth no se instalo."
    fi
}

# ------------------------------------------------------------------------------
# 6b2. YouTube ligero (el mismo de Lazaro Linux)
# ------------------------------------------------------------------------------
# Se busca con gtk-pipe-viewer y se ve en mpv, sin navegador: en un equipo
# viejo es mucho mas liviano que YouTube en Firefox. Limita a 480p (360p con
# un solo nucleo), H.264 y 30 cuadros: lo que un procesador viejo decodifica
# sin trabarse.
# Debian no trae gtk-pipe-viewer y su yt-dlp envejece rapido (YouTube cambia
# seguido), asi que se descargan de sus paginas oficiales:
#   - yt-dlp oficial (incluye yt-dlp-ejs); se actualiza solo cada semana.
#   - QuickJS-NG: motor de JavaScript liviano (2,5 MB) que yt-dlp necesita
#     para los desafios de YouTube. Hay version de 32 y de 64 bits.
#   - gtk-pipe-viewer (programa en Perl; sus piezas vienen de Debian).
# Las versiones de QuickJS-NG y pipe-viewer estan fijas y se comprueban con
# su huella (sha256): si la descarga no coincide, no se instala.
QJS_VERSION="v0.18.0"
QJS_SHA_X86="6e4e46849f6450a0afc572b8d10a0178d70040314f39669ca98ca8e95f114648"
QJS_SHA_X64="85ded23b9fabe8c1644fc40a8d2bbdd71157affcbd807359c618cc717ee24d7d"
PV_VERSION="0.5.9"
PV_SHA="b6c705e8d6d749ec90dea7988f20c60646ae14aaaf125a16a97965f036f73cf2"

download_checked() {
    url="$1"; dest="$2"; sha="$3"
    if ! curl -fsSL --retry 3 -o "$dest" "$url" >>"$LOG_FILE" 2>&1; then
        log_warn "No se pudo descargar $url"
        return 1
    fi
    if [ -n "$sha" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$sha" ]; then
        log_warn "La descarga de $url no coincide con su huella: no se usa."
        rm -f "$dest"
        return 1
    fi
}

setup_youtube() {
    log_info "== YouTube ligero =="
    tmp="$(mktemp -d)"
    yt_alto=480
    [ "$(nproc 2>/dev/null || echo 2)" -gt 1 ] || yt_alto=360

    # yt-dlp oficial: el archivo "yt-dlp" funciona en 32 y 64 bits (Python).
    if [ ! -x /usr/local/bin/yt-dlp ]; then
        if download_checked "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp" "$tmp/yt-dlp" "" \
           && download_checked "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS" "$tmp/sums" ""; then
            want="$(awk '$2=="yt-dlp"{print $1}' "$tmp/sums")"
            if [ -n "$want" ] && [ "$(sha256sum "$tmp/yt-dlp" | cut -d' ' -f1)" = "$want" ]; then
                install -m 755 "$tmp/yt-dlp" /usr/local/bin/yt-dlp
                log_ok "yt-dlp oficial instalado."
            else
                log_warn "yt-dlp no coincide con su huella: no se instala."
            fi
        fi
    fi
    # Se actualiza solo cada semana (anacron lo hace aunque el equipo no
    # este encendido justo ese dia).
    if [ -d /etc/cron.weekly ]; then
        printf '#!/bin/sh\n# antix-desktop-postinstall: mantener yt-dlp al dia (YouTube cambia seguido).\n[ -x /usr/local/bin/yt-dlp ] && /usr/local/bin/yt-dlp -U >/dev/null 2>&1\ntrue\n' \
            > /etc/cron.weekly/antix-yt-dlp
        chmod 755 /etc/cron.weekly/antix-yt-dlp
    fi

    # QuickJS-NG segun la arquitectura.
    if [ ! -x /usr/local/bin/qjs ]; then
        case "$(dpkg --print-architecture)" in
            i386) qf=qjs-linux-x86; qs="$QJS_SHA_X86" ;;
            amd64) qf=qjs-linux-x86_64; qs="$QJS_SHA_X64" ;;
            *) qf="" ;;
        esac
        if [ -n "$qf" ] && download_checked "https://github.com/quickjs-ng/quickjs/releases/download/$QJS_VERSION/$qf" "$tmp/qjs" "$qs"; then
            install -m 755 "$tmp/qjs" /usr/local/bin/qjs
            log_ok "QuickJS-NG $QJS_VERSION instalado."
        fi
    fi
    if [ ! -e /etc/yt-dlp.conf ]; then
        cat > /etc/yt-dlp.conf <<'YTDLP'
# yt-dlp para todo el sistema (lo usan mpv y gtk-pipe-viewer).
# Motor de JavaScript para los desafios de YouTube: QuickJS-NG, el mas liviano.
--js-runtimes quickjs:/usr/local/bin/qjs
YTDLP
    elif ! grep -q -e '--js-runtimes' /etc/yt-dlp.conf; then
        printf '%s\n' '--js-runtimes quickjs:/usr/local/bin/qjs' >> /etc/yt-dlp.conf
    fi

    # gtk-pipe-viewer: se instala en /usr/local con el instalador de Perl.
    if ! command -v gtk-pipe-viewer >/dev/null 2>&1; then
        if download_checked "https://codeload.github.com/trizen/pipe-viewer/tar.gz/refs/tags/$PV_VERSION" "$tmp/pv.tgz" "$PV_SHA" \
           && tar -xzf "$tmp/pv.tgz" -C "$tmp" \
           && ( cd "$tmp/pipe-viewer-$PV_VERSION" && perl Build.PL --gtk3 && ./Build && ./Build install ) >>"$LOG_FILE" 2>&1; then
            log_ok "gtk-pipe-viewer $PV_VERSION instalado."
        else
            log_warn "No se pudo instalar gtk-pipe-viewer (detalle en $LOG_FILE)."
        fi
    fi
    rm -rf "$tmp"

    mkdir -p /etc/mpv
    if ! grep -q '^ytdl-format=' /etc/mpv/mpv.conf 2>/dev/null; then
        cat >> /etc/mpv/mpv.conf <<'MPV'
# antix-desktop-postinstall: mpv pensado para equipos viejos.
# Videos de internet (YouTube y otros): hasta 480p, H.264 (avc1) y 30
# cuadros, con audio AAC; si no hay, lo mas parecido hasta 480p; si no hay
# nada hasta 480p, la calidad mas baja (nunca la mas alta).
ytdl-format=bestvideo[height<=?480][vcodec^=avc1][fps<=30]+bestaudio[acodec^=mp4a]/best[height<=?480][vcodec^=avc1][fps<=?30]/best[height<=?480][vcodec^=avc1]/best[height<=?480]/worst
# Decodificar con la grafica si puede; si no, con el procesador.
hwdec=auto-safe
# Memoria para el video ya descargado: unos minutos de 480p.
cache=yes
demuxer-max-bytes=50MiB
demuxer-max-back-bytes=10MiB
MPV
        [ "$yt_alto" = 480 ] || sed -i "/^ytdl-format=/s/480/$yt_alto/g" /etc/mpv/mpv.conf
    fi

    if ! command -v gtk-pipe-viewer >/dev/null 2>&1; then
        log_warn "YouTube ligero incompleto: los videos se pueden abrir con 'mpv <enlace>'."
        return 0
    fi
    for base in /etc/skel ${TARGET_HOME:+"$TARGET_HOME"}; do
        mkdir -p "$base/.config/pipe-viewer"
        for pv in gtk-pipe-viewer pipe-viewer; do
            f="$base/.config/pipe-viewer/$pv.conf"
            [ -e "$f" ] && continue
            cat > "$f" <<PIPEVIEWER
#!/usr/bin/perl
# antix-desktop-postinstall: solo las opciones que cambian; las demas
# las agrega pipe-viewer con su valor por defecto.
use utf8;
our \$CONFIG = {
  video_player_selected => "mpv",
  # Para 360p: "360".
  resolution            => "$yt_alto",
  prefer_mp4            => 1,
  prefer_m4a            => 1,
  ignore_av1            => 1,
  hfr                   => 0,
  ytdl_cmd              => "/usr/local/bin/yt-dlp",
  srt_languages         => ["es", "en"],
};
PIPEVIEWER
        done
    done
    [ -n "$TARGET_HOME" ] && chown -R "$TARGET_USER": "$TARGET_HOME/.config/pipe-viewer"

    # En el menu aparece como "YouTube".
    mkdir -p /usr/local/share/applications
    cat > /usr/local/share/applications/antix-youtube.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=YouTube
GenericName=Videos de YouTube
Comment=Search and watch YouTube videos without a web browser
Comment[es]=Buscar y ver videos de YouTube sin navegador
Exec=gtk-pipe-viewer
Icon=applications-multimedia
Terminal=false
StartupNotify=true
Categories=AudioVideo;Video;Player;Network;
Keywords=youtube;video;videos;musica;pipe-viewer;
DESKTOP
    for d in /usr/local/share/applications /usr/share/applications; do
        if [ -f "$d/gtk-pipe-viewer.desktop" ]; then
            sed '/^\[Desktop Entry\]/a NoDisplay=true' "$d/gtk-pipe-viewer.desktop" \
                > /usr/local/share/applications/gtk-pipe-viewer.desktop.tmp \
                && mv /usr/local/share/applications/gtk-pipe-viewer.desktop.tmp /usr/local/share/applications/gtk-pipe-viewer.desktop
            break
        fi
    done
    log_ok "YouTube ligero listo: menu > YouTube (${yt_alto}p, H.264, QuickJS)."
}

# ------------------------------------------------------------------------------
# 6c. Ajustes de rendimiento para equipos viejos (los mismos de Lazaro,
#     adaptados a antiX y a su kernel 5.10)
# ------------------------------------------------------------------------------
# - zram: parte de la memoria se usa como "swap comprimido". Con 1 o 2 GB
#   el equipo aguanta muchas mas pestanas antes de ponerse lento. Tamano
#   igual a la RAM; zstd comprime mas, lz4 gasta menos procesador (se usa
#   lz4 en procesadores de un solo nucleo).
# - earlyoom: si la memoria se acaba, cierra el programa que mas usa en vez
#   de dejar el equipo congelado varios minutos.
# - Disco mecanico: planificador BFQ (el equipo responde mientras copia
#   archivos) y escritura en bloques pequenos (sin pausas largas).
# - Disco SSD: TRIM semanal para que no se vuelva lento con el tiempo.
# - Con 4 GB o menos: paginas enormes de memoria solo a pedido (THP).
TUNE_SYSCTL=/etc/sysctl.d/90-antix-equipos-viejos.conf
TUNE_BOOT=/etc/runit/boot-run/S76-antix-equipos-viejos.stage1.sh
setup_tuning() {
    if [ "$TUNE" -eq 0 ]; then
        log_info "Ajustes de rendimiento omitidos (--sin-ajustes)."
        return 0
    fi
    log_info "== Ajustes de rendimiento para equipos viejos =="
    ram_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    cores=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    if [ "${cores:-1}" -ge 2 ]; then algo=zstd; else algo=lz4; fi
    log_info "Memoria: ${ram_mb} MB, nucleos: ${cores}."

    cat > "$TUNE_SYSCTL" <<'SYSCTL'
# antix-desktop-postinstall: ajustes para equipos viejos.
# Con zram conviene usar el swap comprimido antes que vaciar la cache.
vm.swappiness=100
vm.page-cluster=0
# Escribir al disco en bloques de 48 MB como maximo: evita pausas largas
# en discos lentos y memorias USB.
vm.dirty_bytes=50331648
vm.dirty_background_bytes=16777216
SYSCTL
    log_ok "Ajustes de memoria en $TUNE_SYSCTL"

    if [ -d /etc/runit/boot-run ]; then
        thp=""
        [ "$ram_mb" -le 4096 ] && thp="madvise"
        {
            echo '#!/bin/sh'
            echo '# antix-desktop-postinstall: se ejecuta en cada arranque (etapa 1 de runit).'
            echo "ZRAM_ALGO=$algo"
            echo "THP=$thp"
            echo "SYSCTL_FILE=$TUNE_SYSCTL"
            cat <<'BOOT'
# zram: swap comprimido del tamano de la RAM.
if [ ! -e /dev/zram0 ] && modprobe zram num_devices=1 2>/dev/null; then
    ram_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    zramctl /dev/zram0 --algorithm "$ZRAM_ALGO" --size "${ram_kb}KiB" 2>/dev/null \
        || zramctl /dev/zram0 --size "${ram_kb}KiB" 2>/dev/null
    mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 2>/dev/null
fi
# Planificador BFQ para discos mecanicos.
modprobe bfq 2>/dev/null
for q in /sys/block/sd*/queue /sys/block/hd*/queue; do
    [ -r "$q/rotational" ] && [ "$(cat "$q/rotational")" = 1 ] || continue
    grep -qw bfq "$q/scheduler" 2>/dev/null && echo bfq > "$q/scheduler"
done
# Paginas enormes solo a pedido (equipos de 4 GB o menos).
if [ -n "$THP" ] && [ -w /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo "$THP" > /sys/kernel/mm/transparent_hugepage/enabled
fi
sysctl -q -p "$SYSCTL_FILE" 2>/dev/null
true
BOOT
        } > "$TUNE_BOOT"
        chmod 755 "$TUNE_BOOT"
        log_ok "zram ($algo, ${ram_mb} MB), BFQ y THP en cada arranque: $TUNE_BOOT"
        # Se aplica tambien ahora, sin esperar al reinicio.
        sh "$TUNE_BOOT" && log_ok "Ajustes aplicados en esta sesion."
    else
        log_warn "No se encontro /etc/runit/boot-run: zram y BFQ no se configuraron."
    fi

    if is_installed earlyoom; then
        ensure_runit_service earlyoom "/usr/bin/earlyoom -r 3600" no
    fi

    # TRIM semanal solo si hay un SSD que lo acepte.
    ssd=""
    for q in /sys/block/*/queue; do
        dev="${q%/queue}"; dev="${dev##*/}"
        case "$dev" in loop*|ram*|zram*|sr*) continue ;; esac
        [ "$(cat "$q/rotational" 2>/dev/null)" = 0 ] || continue
        [ "$(cat "$q/discard_max_bytes" 2>/dev/null || echo 0)" != 0 ] && ssd="$ssd $dev"
    done
    if [ -n "$ssd" ] && [ -d /etc/cron.weekly ]; then
        printf '#!/bin/sh\n# antix-desktop-postinstall: TRIM semanal de los SSD.\nfstrim -a >/dev/null 2>&1 || true\n' \
            > /etc/cron.weekly/antix-fstrim
        chmod 755 /etc/cron.weekly/antix-fstrim
        log_ok "TRIM semanal para:$ssd"
    fi
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
blueman-applet &
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
  [exec] (YouTube) {gtk-pipe-viewer}
  [exec] (Fotos) {gpicview}
  [exec] (Calculadora) {galculator}
  [exec] (Bloc de notas) {mousepad}
  [exec] (Escaner) {simple-scan}
  [exec] (Impresoras) {system-config-printer}
  [exec] (Bluetooth) {blueman-manager}
  [exec] (Captura de pantalla) {scrot -e 'mv $f ~/'}
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
    for grp in netdev audio video plugdev lpadmin scanner bluetooth; do
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
    nm="$(runit_name "network-manager NetworkManager")"
    [ -e "$SERVICE_DIR/$nm" ] || return 0
    log_info "== Esperando a que NetworkManager se estabilice para retirar:$others =="
    up=0; i=0
    while [ "$i" -lt 12 ]; do
        up="$(sv status "$SERVICE_DIR/$nm" 2>/dev/null \
              | sed -n 's/^run: [^(]*(pid [0-9]*) \([0-9]*\)s.*/\1/p')"
        [ "${up:-0}" -ge 15 ] && break
        sleep 3; i=$((i + 1))
    done
    if [ "${up:-0}" -ge 15 ]; then
        for s in $others; do
            sv down "$SERVICE_DIR/$s" >/dev/null 2>&1
            rm -f "$SERVICE_DIR/$s"
        done
        sv restart "$SERVICE_DIR/$nm" >/dev/null 2>&1
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
    for s in dbus seatd "$(runit_name "network-manager NetworkManager")" cups "$(runit_name "bluetooth bluetoothd")"; do
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
    # El servicio de antiX para LightDM se instala recien aqui: al
    # instalarse se activa solo y la pantalla cambia al inicio grafico.
    is_installed runit-service-lightdm || apt_install runit-service-lightdm
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
    setup_services
    setup_tuning
    setup_youtube
    setup_desktop_config
    setup_display_manager
    setup_user
    retire_other_network
    final_report
    enable_display_manager
}

# La prueba automatica carga el script sin ejecutarlo para probar partes.
[ "${ANTIX_SOLO_FUNCIONES:-0}" = 1 ] || main "$@"
