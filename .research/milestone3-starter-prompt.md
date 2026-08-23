# Prompt de arranque — QL4M65, Milestone 3 (velocidad + memoria)

Pega esto como primer mensaje en una conversación nueva de Claude Code
(directorio de trabajo: `E:\QL_MEGA65\Fase0\CoreQL\CORE`) para retomar el
proyecto sin tener que re-explicar nada.

---

## Qué es esto

QL4M65: port del **Sinclair QL** (core `QL_MiSTer` de MiSTer-devel) a la
**MEGA65** usando el framework **MiSTer2MEGA65 (M2M)**. Milestone 1 (CPU,
vídeo, teclado, 128k RAM) y Milestone 2 (dos microdrives con
carga/guardado) están cerrados, confirmados en hardware real y publicados
en GitHub. Toca **Milestone 3: velocidad completa de CPU + ampliación de
RAM (640k y 4096k), todo sobre HyperRAM**.

## Dónde está todo

- **Repo git**: `E:\QL_MEGA65\Fase0\CoreQL` (remoto: `github.com/dfernande132/QL4M65`).
- **`DECISIONES.md`**: `E:\QL_MEGA65\Fase0\DECISIONES.md` — **fuera del
  repo git** (un nivel por encima de `CoreQL/`), no versionado. Es el
  historial completo y detallado de cada build/decisión/bug del proyecto,
  en orden cronológico. Empieza a leerlo por el final (sección "Milestone
  2 — CIERRE") para el resumen de lo último hecho.
- **`.research/PORTING-PLAN.md`** (dentro del repo, en `CoreQL/.research/`):
  el plan de porting completo, con una sección "0. Estado actual del
  proyecto" al principio que resume dónde está cada milestone, y una
  sección `### Milestone 3 — Ampliación de memoria y velocidad` con el
  alcance ya esbozado.
- **`.research/`**: el resto de documentos de diseño específicos por
  tema (`microdrive-*.md`, `qlsd-*.md`, etc.) - no hace falta leerlos para
  Milestone 3 salvo que algo de RAM/HyperRAM remita a ellos.
- **RTL del core**: `CORE/vhdl/` (VHDL propio de QL4M65 - `main.vhd`,
  `mega65.vhd`, `globals.vhd`, `config.vhd`, etc.) y `CORE/QL_MiSTer/rtl/`
  (el core MiSTer original, Verilog/SystemVerilog, tocado lo mínimo
  posible - cada modificación real está documentada y justificada en
  `DECISIONES.md`).
- **Firmware QNICE**: `CORE/m2m-rom/m2m-rom.asm` (ensamblador del
  "sistema operativo" QNICE que corre el menú OSD, la carga de ficheros,
  etc. - no confundir con el firmware Minerva de la QL misma).
- **Proyectos Vivado**: `CORE/CORE-R6.xpr` (placa MEGA65 R6, la única que
  se compila en desarrollo) y `CORE/CORE-R3.xpr` (placa R3, solo se
  compila al publicar en GitHub). `CORE-R4.xpr`/`CORE-R5.xpr` existen pero
  están desactualizados desde hace tiempo — no se usan.
- **Herramientas de empaquetado**: `E:\QL_MEGA65\Mega65Tools\` —
  `bit2core.exe` (convierte `.bit` → `.cor`) y ahí mismo se guardan todos
  los `.cor` generados (`QL4M65-CoreQL-M<NNNN>_r<X>.cor`).

## Cómo se compila (para cuando toque)

1. `E:\QL_MEGA65\Fase0\CoreQL\CORE\build_core.tcl` (R6) / `build_core_r3.tcl`
   (R3) abren el `.xpr` correspondiente, añaden con `add_files` cualquier
   fichero fuente que el `.xpr` todavía no conozca (los ficheros ya
   trackeados por el `.xpr` NO hace falta volver a añadirlos), lanzan
   `synth_1` y luego `impl_1 -to_step write_bitstream`.
2. **Si se crea un fichero VHDL/Verilog nuevo**, hay que añadirlo a mano
   al `.xpr` (editar el XML, bloque `<File Path="$PPRDIR/...">` dentro de
   `sources_1`) — Vivado no descubre ficheros nuevos solo. Ver
   `CORE-R6.xpr`/`CORE-R3.xpr` para el formato exacto (buscar cualquier
   `<File Path=` existente como plantilla).
3. Invocación real (PowerShell, no bash — este entorno es Windows):
   ```
   Set-Location "E:\QL_MEGA65\Fase0\CoreQL\CORE"
   & "C:\Xilinx\Vivado\2022.2\bin\vivado.bat" -mode batch -source build_core.tcl -log build_<nombre>.log -journal build_<nombre>.jou
   ```
   Tarda varios minutos — lanzar en segundo plano y esperar a que
   termine (`Wait-Process`), no bloquear la conversación con un `sleep`.
4. El firmware QNICE (`m2m-rom.asm`) se ensambla automáticamente como
   paso previo a la síntesis (`synth_pre.tcl`) — no hace falta un paso
   manual aparte, aunque para una comprobación rápida de sintaxis ANTES
   de gastar una compilación completa de Vivado se puede ensamblar por
   WSL con `make_rom.sh` (visto usado en `M2026`, ver `DECISIONES.md`).
5. El bitstream resultante queda en
   `CORE\CORE-R6.runs\impl_1\mega65_r6.bit` (o el equivalente `_r3` para
   R3, en `CORE-R3.runs\impl_1\`).
6. Empaquetar a `.cor`:
   ```
   & "E:\QL_MEGA65\Mega65Tools\bit2core.exe" mega65r6 <ruta al .bit> "QL4M65-CoreQL" "M3001" "E:\QL_MEGA65\Mega65Tools\QL4M65-CoreQL-M3001_r6.cor"
   ```
   (target `mega65r3` para la placa R3). **La numeración de build arranca
   en `M3001` para este milestone** (mismo patrón que M1xxx/M2xxx antes).

## Reglas del proyecto ya establecidas (no re-descubrir)

- **Solo se compila R6 en desarrollo.** R3 (y, si algún día se
  actualizan, R4/R5) solo se compilan al publicar un release en GitHub.
- **Nunca hacer `git push` sin que el usuario lo pida explícitamente cada
  vez** (una aprobación no vale para las siguientes veces).
- **Cada build actualiza `DECISIONES.md` y `PORTING-PLAN.md` (y lo que
  haga falta) y se commitea localmente, sin pedir permiso** — el push a
  GitHub sí necesita petición explícita, el commit local no.
- **CDC (cruce de dominios de reloj): usar siempre primitivas
  `xpm_cdc_*`, nunca un sincronizador de 2 flip-flops a mano** — un
  sincronizador manual entre relojes no relacionados no lleva excepción
  de timing automática y produce un WNS negativo real (pasó en `M2011`).
- **Que `xsim` (simulación) pase no significa que sintetice** — una señal
  escrita desde dos procesos VHDL distintos simula bien (tipo resuelto)
  pero falla el DRC de múltiples drivers de Vivado en `opt_design`, un
  error que solo aparece al compilar de verdad (pasó en `M2031`).
- Antes de cualquier acción con riesgo real (fichero grande, sobrescribir
  algo, `git push`, borrar algo) - confirmar con el usuario primero.

## Qué se consiguió en Milestone 2 (para contexto, no hace falta releer nada más si esto basta)

Dos microdrives (`mdv1`, `mdv2`) completamente funcionales: carga manual
de imágenes `.mdv` desde el menú OSD, escritura desde la QL, volcado
automático a SD en segundo plano (sin bloquear), LED de actividad con
color según haya sectores sin guardar, zumbido de motor sintetizado en
las dos unidades. El buffer de cada microdrive vive en HyperRAM real (no
BRAM), a través de un `avm_cache` propio y un árbitro compartido
(`avm_arbit`) antes de la única HyperRAM física. El mecanismo QNICE↔core
de carga/lectura (`mdv_qnice_bridge.vhd`) es una entidad VHDL genérica sin
parámetros, instanciada dos veces - la primera vez que este proyecto
parametriza en vez de duplicar un bloque de lógica real.

**Errores reales encontrados y corregidos a lo largo del milestone**
(detalle completo de cada uno en `DECISIONES.md`, sección "Milestone 2 —
CIERRE" al final del documento):
1. `M2004`-`M2017`: una investigación larga sobre un supuesto bug de
   lectura resultó ser un falso positivo — las imágenes de prueba
   estaban corruptas de origen, no el RTL.
2. `M2006`: deadlock por calcular una señal de espera solo a partir de
   entradas vivas en vez de estado registrado.
3. `M2011`/`M2017`: una señal de control que necesitaba ser un NIVEL
   sostenido se implementó primero como pulso; y una FSM sin ningún
   camino de reset se quedaba atascada permanentemente tras un reset a
   mitad de un handshake.
4. `M2022`-`M2024`: protocolo de escritura nuevo con dos bugs de
   detección de flanco (mismo riesgo, dos sitios distintos) y un
   contador de 9 bits desbordando para una sesión de 538 bytes.
5. `M2027`: una señal de espera calculada solo de estado registrado no
   cubría el primer ciclo de una petición nueva - la CPU capturaba el
   dato de la petición anterior.
6. `M2030`-`M2032` (migración a HyperRAM): timing fijo calibrado para
   BRAM ya no válido con HyperRAM real; un bug de síntesis "multiple
   drivers" que la simulación no detectaba; pulso vs. nivel en el
   reconocimiento de un acierto de caché.
7. `M2035`: un descuido simple - se le olvidó el audio a la segunda
   unidad al duplicarla.

**Patrón que se repite y vale la pena tener presente para Milestone 3**:
casi todos los bugs reales de este milestone fueron de **cruce de
dominios de reloj o de timing entre BRAM/HyperRAM**, no de lógica
funcional - Milestone 3 va a tocar exactamente ese terreno otra vez
(ancho de banda de HyperRAM a velocidad "Full", 84 MHz de bus), así que
conviene ir con la misma disciplina de verificar en simulación antes de
compilar, y de no fiarse de que "`xsim` pasa" sea suficiente.

## Guía de M2M para portar cores (si hace falta consultarla)

Este repo NO tiene copiada localmente la guía "cómo portar un core de
MiSTer con M2M" del framework upstream - solo hay un par de assets en
`doc/wiki/assets/` (un PDF y una imagen), sin el contenido real de las
páginas. La guía real vive en GitHub, fuera de este repo: **"The Ultimate
MiSTer2MEGA65 Porting Guide"**,
<https://github.com/sy2002/MiSTer2MEGA65/wiki/The-Ultimate-MiSTer2MEGA65-Porting-Guide>
(enlace confirmado en el propio `README.md` de este repo). `VERSIONS.md`
(raíz del repo, doc del framework M2M en sí) también recomienda el código
del port de C64 (`C64MEGA65`, tag `M2M-V0.9`) como "manual de usuario" de
referencia cuando la wiki tiene huecos.

## Alcance de Milestone 3 (ya esbozado en `PORTING-PLAN.md`)

Los tres tamaños de RAM del requisito inicial (128k ya hecho en
Milestone 1/2 / 640k / 4096k, todos sobre HyperRAM) seleccionables desde
el menú OSD, más los modos de velocidad de CPU (16MHz / 24MHz / Full) -
todos ya presentes en el core MiSTer original como múltiplos del reloj
base, así que es principalmente exponer las opciones en `config.vhd` y
verificar que la HyperRAM aguanta el ancho de banda a la velocidad más
alta ("Full", bus a 84 MHz).

## Primer paso sugerido

Leer `.research/PORTING-PLAN.md` sección "### Milestone 3 — Ampliación de
memoria y velocidad" y la sección 3 (arriba en el mismo documento, sobre
los multiplicadores de reloj del core original) antes de tocar código, y
plantear un plan por escrito (como se hizo con
`.research/microdrive-second-unit-plan.md` en Milestone 2) antes de
implementar - el usuario prefiere revisar el plan primero, especialmente
cuando toca algo con riesgo real de timing como esto.
