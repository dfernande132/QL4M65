Empezamos Milestone 2 del proyecto QL4M65 (port del Sinclair QL a MEGA65
usando el framework MiSTer2MEGA65/M2M, a partir del core MiSTer-devel/
QL_MiSTer). Milestone 1 (arranque nativo QL, 128KB) está cerrado y probado
en hardware real. Milestone 2 es soporte QL-SD (imágenes .win/QXL.WIN como
disco duro virtual) — el diseño ya está escrito y revisado, toca
implementarlo.

## Dónde está todo (todo bajo E:\QL_MEGA65\)

- `Fase0\DECISIONES.md` — log de decisiones técnicas, fase a fase, es la
  fuente de verdad histórica del proyecto. Léetelo entero primero.
- `Fase0\CoreQL\.research\PORTING-PLAN.md` — el plan completo: arquitectura
  del core original, mapa de memoria, milestones, decisiones pendientes.
  Sección 0 tiene el snapshot de estado y el registro de builds probados en
  hardware; sección 7, la definición de milestones actual.
- `Fase0\CoreQL\.research\qlsd-design.md` — diseño técnico ya escrito de
  este milestone: qué módulos se instancian, cómo se cablean a
  `vdrives.vhd`, qué hay que tocar y qué se queda igual. Es el punto de
  partida real para escribir RTL.
- `Fase0\CoreQL\.research\qlsd-driver.md` — todo lo que sabemos del driver
  QL-SD (software QDOS, no RTL): por qué hace falta, qué ROM ya tenemos,
  qué falta decidir sobre su tamaño.
- `Fase0\CoreQL\.research\microdrive-read-design.md` — diseño del
  microdrive virtual, aparcado (ahora Milestone 4, no cancelado). No hace
  falta leerlo para este milestone salvo que quieras contexto de por qué se
  descartó como primera opción.
- `Fase0\MiSTer2MEGA65.wiki\The-Ultimate-MiSTer2MEGA65-Porting-Guide.md`
  (y su traducción al castellano en `Traducido\Parte1-4.md`) — la guía
  oficial del framework M2M para portar cores de MiSTer. Consúltala si algo
  en `vdrives.vhd` o en el mecanismo de menú/CSR no encaja con lo que dice
  `qlsd-design.md` — es la referencia de arquitectura del framework, no
  específica de este proyecto.
- `Fase0\CoreQL\doc\m2m\exceptions.md` — todas las desviaciones ya
  documentadas respecto al RTL original de `QL_MiSTer` (qué módulos se
  quitaron/modificaron y por qué). Revísalo antes de tocar `zx8302.v`, ya
  tiene cirugía previa (se le quitaron `ipc`/`mdv` internos).

Orden de lectura recomendado: `DECISIONES.md` completo → `PORTING-PLAN.md`
(secciones 0 y 7 primero, resto si hace falta detalle) → `qlsd-design.md` →
`qlsd-driver.md`. La guía del framework y `exceptions.md` son consulta, no
lectura obligatoria de entrada.

## Estructura del código (todo bajo `Fase0\CoreQL\`)

- `CORE\` — proyecto Vivado. `CORE-R6.xpr` es el activo (hay R3/R4/R5
  también, de revisiones de placa MEGA65 anteriores, no se usan).
  `CORE\vhdl\` tiene nuestro RTL M2M propio: `main.vhd` (instancia el core
  QL + toda la lógica de bus), `mega65.vhd` (wrapper de nivel superior,
  carga de ROMs vía QNICE, HyperRAM, etc.), `globals.vhd` (constantes de
  configuración: mapa de HyperRAM, ROMs cargables, drives virtuales),
  `config.vhd` (definición del menú OSD), `clk.vhd` (generación de relojes).
- `CORE\QL_MiSTer\` — copia de trabajo del core MiSTer original, git local
  propio (sin remoto). `rtl\*.v` y `sys\*.sv` son Verilog/SystemVerilog del
  core original, instanciados tal cual desde `main.vhd` cuando es posible
  (política del proyecto: no reescribir RTL original salvo necesidad
  probada, ver `exceptions.md`). `QL.sv` es el top-level original — **no se
  porta**, lo sustituye `main.vhd` por completo. `releases\` tiene ROMs e
  imágenes de ejemplo que vienen del propio repo upstream (incluye
  `minerva+qlsd_ql.rom`, relevante para este milestone).
- `M2M\` — el framework MiSTer2MEGA65 en sí (plantilla, sin tocar salvo
  necesidad). `M2M\vhdl\vdrives.vhd` es la pieza central de este milestone
  (bridge QNICE/FAT32 ↔ protocolo "SD" de MiSTer). `M2M\QNICE\tools\` tiene
  `bit2core` (empaquetado del bitstream final).
- `CORE\build_core.tcl` — script Tcl que abre `CORE-R6.xpr`, añade las
  fuentes necesarias (incluye la lista completa de ficheros del core QL +
  T48 del IPC) y lanza síntesis/implementación.

## Qué se consiguió en Milestone 1 (cerrado en `M1048`, tag y commits en
git local de `CoreQL\`)

- El QL arranca de verdad sobre Minerva: pantalla de test de RAM → pantalla
  verde F1/F2/F3/F4 de identificación de Minerva → responde a la pulsación
  de tecla.
- Teclado real y funcional: matriz MEGA65→QL completa + protocolo IPC
  comdata/comctrl implementado con el 8049 real emulado ciclo a ciclo (core
  T48 + ROM `ipc8049.hex` original, integrado en `M1031` tras descartar un
  sustituto simplificado que no bastaba).
- 128KB de RAM, sobre BRAM interna (no HyperRAM todavía — decisión
  explícita de Milestone 1, ver `DECISIONES.md` Fase 3).
- Carga de ROM: partición Main (48KB, `$000000-$00BFFF`)/Back (16KB
  extensión, `$00C000-$00FFFF`) vía QNICE, con menú manual y auto-carga
  desde SD (`/ql4m65/main.rom`, `/ql4m65/back.rom`) — infraestructura que
  este milestone reutiliza directamente para el driver QL-SD.
- Pipeline de vídeo/OSD corregido (encuadre del menú, escalado HDMI 4:3
  576p).
- Sin microdrive, sin QL-SD, sin ratón, sin GoldCard/SMSQE, sin ampliación
  de memoria/velocidad — todo eso queda para milestones posteriores.
- Probado en hardware real (MEGA65 R6 físico), confirmado cerrado por el
  usuario.

## Numeración de builds

Las compilaciones de Milestone 1 fueron `M1001`-`M1048`. **La próxima
compilación de este milestone es `M2001`**, y la secuencia sigue
incrementando con cada build que se sintetiza y se prueba en hardware
(`M2002`, `M2003`...), sea cual sea el tamaño del cambio — no solo los
cambios grandes. Cada build se empaqueta como
`QL4M65-CoreQL-M2xxx_r6.cor` y se etiqueta en git (`git tag M2xxx`) sobre el
commit exacto que la generó. Cada build probada en hardware se registra en
la tabla de `PORTING-PLAN.md` sección 0 y se documenta en prosa en
`DECISIONES.md`.

## Cómo se compila

1. Vivado 2022.2 nativo de Windows abre `CORE\CORE-R6.xpr`, o se ejecuta
   `build_core.tcl` (que abre el proyecto, añade las fuentes que aún no
   están en el `.xpr` — como los ficheros del T48 o `qnice_csr.vhd` — y
   fija las propiedades necesarias, incluido `general.maxThreads 8`).
2. Síntesis + implementación + generación de bitstream (`.bit`) desde
   Vivado, mismo flujo estándar de cualquier proyecto Vivado.
3. Empaquetado a `.cor` con `Mega65Tools\bit2core.exe` (herramienta nativa
   de Windows, ya en el proyecto — no hace falta WSL para esto, se abandonó
   ese camino en `M1004`).
4. El `.cor` resultante se prueba en el MEGA65 R6 físico del usuario vía SD.
5. Comprobar siempre WNS/WHS en el log de Vivado antes de dar un build por
   bueno — el script de build no aborta automáticamente si el timing no se
   cumple (lección de `M1004`: un build "sintéticamente OK" con WNS muy
   negativo llegó a generarse sin que nada lo marcara como fallo).

## Qué toca hacer ahora

Seguir el plan de `qlsd-design.md`: instanciar `qlromext.v` y `sd_card.sv`
sin modificar, reemplazar el `altsyncram` interno de `sd_card.sv` por un
`dualport_2clk_ram` (patrón ya usado 2 veces en este proyecto), decodificar
la dirección QL-SD en `main.vhd` (`qlsd_en <= cpu_rom and cpu_rd`, más
simple que el original al no tener GoldCard/rom_shadow), instanciar
`vdrives.vhd` con `VDNUM => 1`, añadir la entrada de menú "Mount HD image",
y resolver primero la pregunta abierta del tamaño del Back ROM (ver
`qlsd-driver.md`) antes de cablear el chequeo de tamaño. Las preguntas
abiertas de `qlsd-design.md` (sección final) son el punto de partida para
decidir con el usuario antes de escribir RTL de verdad.
