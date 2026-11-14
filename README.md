# antiX para uso general

Un script que convierte una instalación de **antiX 26 Core** (32 o 64 bits) en un equipo listo para el uso diario en casa, el estudio o la oficina. Está pensado para revivir portátiles y computadores viejos.

Al terminar, el equipo queda con:

- **Un escritorio liviano**, a elección: LXDE, Fluxbox o LXQt.
- **Firefox ESR** en español, para navegar.
- **LibreOffice** en español: Writer (documentos), Calc (hojas de cálculo) e Impress (presentaciones), con corrector ortográfico.
- **Atril**, para leer PDF.
- **Impresoras y escáner**: CUPS con controladores para HP, Epson y Canon, y Simple Scan para escanear.
- **Fotos** (gpicview), **calculadora** (galculator), **bloc de notas** (mousepad) y **captura de pantalla** (scrot).
- **Videos y música** con mpv.
- **YouTube ligero**: en el menú aparece "YouTube". Buscas el video y se abre en mpv, sin navegador, que es mucho más liviano para un equipo viejo. La calidad queda limitada a 480p (360p si el procesador tiene un solo núcleo) para que no se trabe. Funciona en 32 y 64 bits y se mantiene al día solo cada semana.
- **Bluetooth**, para audífonos y parlantes, con su icono.
- **Un explorador de archivos** que muestra las memorias USB al conectarlas (también las formateadas en Windows), y un programa para abrir archivos `.zip`.
- **Wifi con icono** para elegir la red, e **icono de volumen**.
- **Tipos de letra compatibles con Word** (Calibri, Cambria, Arial, Times), para que los documentos se vean igual que en Office.
- **Pantalla de inicio de sesión** gráfica (LightDM).
- **Solo runit** como sistema de arranque (más abajo se explica qué es esto).

No instala nada más: se omiten los paquetes "recomendados" que apt agregaría por su cuenta, para que el equipo quede liviano.

## Qué escritorio elegir

| Escritorio | Para qué equipo | Notas |
| --- | --- | --- |
| **LXDE** (recomendado) | Casi cualquiera, desde 1 GB de memoria | Sencillo, con barra de tareas y menú de inicio parecidos a Windows. |
| **Fluxbox** | Muy viejo o con poca memoria (512 MB) | El más liviano. Trae una barra inferior al estilo de MX Linux (botón Menú, ventanas abiertas, wifi, volumen y reloj) con tema oscuro. El menú también aparece con clic derecho sobre el fondo de pantalla. |
| **LXQt** | Con 2 GB de memoria o más | El más moderno. No funciona en procesadores sin SSE2 (ver abajo). |

## Cómo usarlo

1. Instala **antiX 26 Core** en el disco (32 bits `386` o 64 bits `x64`) y deja **runit** como sistema de arranque, que es lo que antiX trae por defecto.
2. Conéctate a internet (con cable es lo más fácil).
3. Inicia sesión con tu usuario y escribe en la terminal:

```
wget https://raw.githubusercontent.com/Entropio1984/antix-desktop-setup/main/antix-desktop-postinstall.sh
chmod +x antix-desktop-postinstall.sh
sudo ./antix-desktop-postinstall.sh
```

4. Elige el escritorio en el menú y confirma. El script ya no hace más preguntas; tarda entre 15 minutos y una hora, según el equipo y el internet.
5. Al terminar, reinicia con `sudo reboot`.

También se puede elegir el escritorio sin menú:

```
sudo ./antix-desktop-postinstall.sh --lxde
sudo ./antix-desktop-postinstall.sh --fluxbox
sudo ./antix-desktop-postinstall.sh --lxqt
```

## antiX Full: quedarse con IceWM y quitar lo que sobra

Si instalaste **antiX Full** (la versión grande, de unos 2 GB), ya tienes casi todo, pero también muchas cosas que un usuario común no usa. En vez de descargar otro escritorio, el script puede dejar el **IceWM** que trae antiX y quitar lo que sobra. **No necesita internet**, porque quitar programas no descarga nada, y tarda unos 5 minutos.

```
sudo ./antix-desktop-postinstall.sh --limpiar
```

En antiX Full el menú del script también ofrece esta opción, ya marcada.

**Se quita:**

- Los otros escritorios: Fluxbox, JWM y herbstluftwm (y sus opciones en la pantalla de inicio de sesión).
- Lo que solo sirve en el USB de instalación: el instalador, la creación de ISO y la persistencia.
- Programas para usuarios avanzados: correo Claws Mail, chat (HexChat, irssi), FTP, Geany, Meld, CherryTree, DOSBox, Xine, WinFF, copias de seguridad, módem de acceso telefónico, MuPDF y LibreOffice Math, entre otros.
- Efectos de sonido para músicos (EasyEffects y sus plugins).
- Los idiomas que no son el del equipo ni el inglés: Firefox, LibreOffice y diccionarios en otros 18 idiomas, y `locales-all` (todos los idiomas del mundo).
- Firmware de tarjetas de red de servidores y de celulares (nunca están en un portátil o PC).
- Los compiladores y archivos de programación, salvo que el wifi sea Broadcom con el controlador `wl`, que los necesita.

**Se queda:** IceWM, Firefox, LibreOffice (Writer, Calc, Impress y Draw), Evince para los PDF, Celluloid y mpv para videos y YouTube, XMMS para música, Mirage para fotos, Transmission, Xfburn para grabar discos, Synaptic, GParted, el Centro de Control de antiX, impresoras, escáner, wifi, bluetooth y el firmware de equipos comunes.

En la prueba con antiX Full de 32 bits se retiraron unos 250 paquetes y se liberaron **unos 2 GB**. Además:

- El menú queda sin accesos a programas que ya no existen, y el editor predeterminado pasa a ser Leafpad (el que se usaba era Geany).
- La ayuda de antiX (Preguntas frecuentes y botones de "Ayuda") se abre con Firefox, en lugar de un visor que ocupaba unos 150 MB.
- Retira los otros inits (solo queda runit) y aplica los [ajustes para equipos viejos](#ajustes-para-equipos-viejos), que antiX no trae. earlyoom solo se instala si hay internet, porque no viene en la ISO.

## Descargas más rápidas (espejos)

antiX 26 viene configurado para descargar los paquetes de Debian desde Alemania. Desde América Latina eso hace que bajar el escritorio y los programas (casi 2 GB) tarde horas.

Por eso, antes de instalar nada, el script busca el **espejo más rápido**. Un espejo es una copia idéntica del repositorio de paquetes, alojada en otro país:

1. Pregunta a la vez a varios espejos de Debian y de antiX, y descarta los que no responden o tardan mucho.
2. A los cuatro más rápidos les baja un pedazo de archivo y mide la velocidad real desde tu conexión.
3. Solo cambia si el nuevo es claramente más rápido (20 % o más) que el que ya tenías.

Toma menos de un minuto. Es seguro: apt revisa la firma de cada paquete, venga del espejo que venga. Si después del cambio algo falla, el script vuelve solo a la configuración anterior. Además, apt queda configurado para reintentar las descargas que se cortan, en vez de rendirse.

La lista de espejos de antiX sale de la que mantiene el propio antiX; para Debian prueba la red mundial `deb.debian.org`, el espejo que antiX sugiere para tu zona horaria y algunos grandes (Estados Unidos, Brasil, Chile, México, España...).

- Copia de las fuentes originales: `/var/backups/antix-desktop-espejos/original/`. Para volver a ellas, cópialas a `/etc/apt/sources.list.d/` y ejecuta `sudo apt-get update`.
- Para no buscar espejos: `--sin-espejos`.

Se puede volver a ejecutar sin problema; no duplica nada. Todo lo que hace queda anotado en `/var/log/antix-desktop-postinstall.log`.

## Ajustes para equipos viejos

Son los mismos ajustes que usa Lázaro Linux, adaptados a antiX. El script los aplica solo y quedan activos en cada arranque:

| Ajuste | Qué hace por el equipo |
| --- | --- |
| **zram** (memoria comprimida) | Una parte de la memoria se comprime y funciona como memoria extra. Con 1 o 2 GB se pueden abrir muchas más pestañas antes de que el equipo se ponga lento. En procesadores de un solo núcleo usa un método de compresión más liviano. |
| **earlyoom** | Si la memoria se acaba, cierra el programa que más usa en lugar de dejar el equipo congelado varios minutos. |
| **BFQ** (solo discos mecánicos) | El equipo sigue respondiendo mientras copia archivos grandes. |
| **Escritura en bloques pequeños** | Evita pausas largas al guardar en discos lentos o memorias USB. |
| **TRIM semanal** (solo discos SSD) | Evita que un SSD se vuelva lento con el tiempo. |
| **Páginas de memoria a pedido** (4 GB o menos) | Ahorra memoria. |

zram se activa **antes** de instalar el escritorio. En un equipo de 32 bits con poca memoria, apt-get se quedó sin memoria al calcular los ~650 paquetes de una sola vez y el sistema lo cerró. Por eso ahora también instala en cuatro tandas: base, escritorio, programas y YouTube.

Si no los quieres, usa `--sin-ajustes`. Para quitarlos después, borra `/etc/sysctl.d/90-antix-equipos-viejos.conf` y `/etc/runit/boot-run/S76-antix-equipos-viejos.stage1.sh`, y reinicia.

## Solo runit

antiX trae cinco "inits" para elegir al arrancar. El init es el primer programa que se ejecuta al encender el equipo, y el encargado de iniciar todo lo demás: la red, el sonido, la pantalla de inicio de sesión. antiX trae runit, sysVinit, dinit, s6-rc y s6-66. Este script configura todo para **runit** y **retira los otros cuatro**, así que el menú de arranque queda con una sola opción y nadie puede elegir por error un init en el que el escritorio no funciona.

Antes de retirar nada, el script simula la operación. Si apt fuera a borrar algo más que esos inits, no toca nada y lo avisa. Si prefieres conservarlos, usa `--conservar-inits`.

## 32 bits y procesadores viejos

El script funciona igual en 32 y 64 bits. Hay un límite que no depende del script: **Firefox, LibreOffice y LXQt necesitan un procesador con SSE2**. SSE2 es un conjunto de instrucciones que tienen casi todos los procesadores desde 2003 (Pentium 4, Pentium M, Celeron M, Athlon 64, Atom y posteriores). Los Pentium III y Athlon XP no lo tienen. El script lo revisa y avisa; en esos equipos no ofrece LXQt.

Para saber si tu procesador tiene SSE2:

```
grep -qw sse2 /proc/cpuinfo && echo "Tiene SSE2" || echo "NO tiene SSE2"
```

## Qué cambia en el sistema

- **Red:** NetworkManager reemplaza a dhcpcd y a connman. Solo se retiran cuando NetworkManager ya lleva 15 segundos funcionando, para que el equipo nunca quede sin internet. Si usabas wifi configurado con `ceni`, vuelve a conectarte desde el icono de red.
- **Sesiones y permisos:** usa ConsoleKit en lugar de elogind. Con elogind bajo runit, cada inicio de sesión esperaba 25 segundos de más.
- **Respaldos:** antes de modificar un archivo del sistema, guarda una copia con la fecha (`archivo.bak.AAAAMMDD_HHMMSS`).
- **Versión anterior:** si antes usaste el script viejo (`instalar_lxde_antix.sh`), este limpia lo que dejó mal: la sesión forzada a LXDE, el servicio roto de elogind, la consola de texto 1 desactivada y los iconos repetidos.

## Si algo sale mal

- **La pantalla parpadea o no aparece el inicio de sesión:** pulsa `Ctrl+Alt+F2`, entra con tu usuario y escribe `sudo rm /etc/service/lightdm` y luego `sudo reboot`. El equipo arrancará en modo texto. Revisa el registro y vuelve a intentarlo.
- **Un programa no se instaló:** el informe final lo dice. Vuelve a ejecutar el script con internet; solo instala lo que falta.
- **No hay red después de reiniciar:** el archivo original está respaldado en `/etc/network/interfaces.bak.*`.

## Prueba automática

En cada cambio, GitHub descarga antiX 26.1 Core de 32 y de 64 bits, retira los otros inits como lo hace el script e instala los programas en cada escritorio. Así comprueba que todos los paquetes existen y caben en ambas versiones. También descarga antiX 26.1 Full de 32 bits, lo configura en español de Colombia y hace la limpieza **sin red**. Luego comprueba que se quedó lo que debe quedar (IceWM, Firefox y LibreOffice en español, impresoras, wifi...), que se fue lo que sobra y que el menú no tiene accesos rotos. No arranca el escritorio: eso se prueba a mano en una máquina virtual.
