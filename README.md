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
| **Fluxbox** | Muy viejo o con poca memoria (512 MB) | El más liviano. El menú aparece con clic derecho sobre el fondo de pantalla. |
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

En cada cambio, GitHub descarga antiX 26.1 Core de 32 y de 64 bits, retira los otros inits como lo hace el script e instala los programas en cada escritorio. Así comprueba que todos los paquetes existen y caben en ambas versiones. No arranca el escritorio: eso se prueba a mano en una máquina virtual.
