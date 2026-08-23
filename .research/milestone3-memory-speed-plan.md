# Milestone 3 — plan: RAM ampliada + velocidad de CPU sobre HyperRAM

Fecha: 2026-08-23 (arranque de sesión). Estado: **propuesta para revisión del
usuario, nada implementado todavía** — mismo protocolo que
`.research/microdrive-second-unit-plan.md` en Milestone 2.

## 0. Alcance

Tres piezas, del `CONF_STR` original de `QL_MiSTer` (`PORTING-PLAN.md`
sección 2.2/3):

- `O45,RAM,128k,640k,896k,4096k` → aquí sin `896k` (sin equivalente de
  mercado claro, ya descartado en `PORTING-PLAN.md` sección 4) y con el
  tope bajado de 4096k a 2048k (decisión del usuario, ver más abajo):
  **128k / 640k / 2048k**, todas sobre HyperRAM.
- `O78,CPU speed,QL,16 Mhz,24 Mhz,Full` → **QL nativa / 16MHz / 24MHz /
  Full (84MHz de bus)**.

Orden de trabajo acordado con el usuario: primero migrar los 128k actuales
de BRAM a HyperRAM (arquitectura correcta, mismo tamaño, regresión
completa) y **solo después** ampliar tamaño/velocidad, que a partir de ahí
es "trivial" en sus palabras — este plan confirma que la parte de tamaño sí
lo es, pero identifica un punto real que hay que decidir antes de tocar
`globals.vhd` (sección 3.3).

**Decisión del usuario (2026-08-23): el tope de RAM se baja de 4096k a
2048k** — el requisito pasa a ser **128k / 640k / 2048k**, no 4096k. Esto
resuelve por completo el conflicto de presupuesto de la sección 3 sin tocar
nada del framework ni de la reserva de microdrives (ver aritmética
actualizada ahí) — el usuario confirmó explícitamente que el límite de
4096k no le preocupa y prefiere esta simplificación a investigar/recortar
la reserva `C_HMAP_M2M`/de microdrives.

## 1. Estado actual (verificado leyendo el RTL, no de memoria)

- **RAM principal**: 128k en BRAM pura (`dualport_2clk_ram_byteenable`,
  `main.vhd` ~L672, "milestone 1, 128k, BRAM for now"), 16 bits de
  dirección, acceso síncrono de 1 ciclo. `cpu_dtack <= not ram_delay_dtack`
  — el único wait-state es el modelo de contención de `ql_timing.sv`, no
  hace falta ningún wait-state adicional de controlador de memoria porque
  la BRAM responde en el mismo ciclo.
- **VRAM** (64k, pantalla): BRAM aparte, sin cambios en este milestone —
  sigue así (ver `PORTING-PLAN.md` sección 4: acceso de tiempo real del
  ZX8301, no conviene meterla en HyperRAM compartida).
- **Reloj de bus (`ce_bus_p`/`ce_bus_n`)**: un único acumulador fraccionario
  fijo a `FRACT_BUS_QL` (11702/65536 sobre 84MHz ≈ 14.999MHz). Las otras
  tres constantes del original (`FRACT_BUS_16`/`FRACT_BUS_24`/
  `FRACT_BUS_FULL`) existen en `QL.sv` pero **no están portadas aquí
  todavía** — hay que traerlas.
- **`ql_timing.sv` (contención de bus tipo QL real)**: en el original, su
  entrada `enable` está atada a `ql_mode = (cpu_speed == 0)` — es decir,
  **el modelo de contención SOLO se aplica en velocidad nativa**; en 16MHz/
  24MHz/Full el core original corre sin ningún wait-state de contención,
  solo el reloj de bus más rápido. Confirmado leyendo `QL.sv` línea ~198-201.
  Aquí no está portado ese `enable` todavía (siempre activo, porque solo
  existe el modo nativo) — habrá que añadirlo a la vez que se añaden los
  otros `FRACT_BUS_*`.
- **Camino HyperRAM ya existente (mdv1/mdv2)**: cada `mdv.v` tiene su propio
  `dpram` (`mdv_dpram.vhd`) con un `avm_cache` propio; sus dos maestros
  Avalon se combinan con `avm_arbit` (2 vías, fijo) en `mega65.vhd`
  (`i_avm_arbit_mdv`) antes de un único `avm_fifo` (CDC `main_clk`→`hr_clk`)
  que llega a `hr_core_*` (el framework M2M). Mapa de direcciones en
  `globals.vhd`: `C_HMAP_M2M` (framework, 512 bloques de 4kW = 4MB) +
  `C_HMAP_QL` (reservado para el core QL, otros 512 bloques = otros 4MB —
  el chip HyperRAM de la MEGA65 son 8MB en total, confirmado en comentarios
  existentes de `mdv_dpram.vhd`/`globals.vhd`). Dentro de `C_HMAP_QL`, ya
  hay un mapa dibujado (no todo instanciado) para hasta 8 microdrives (22
  bloques cada uno = 176 bloques = 1.375MB), dejando "336 bloques = 2.625MB
  libres... para Milestone 3" según el propio comentario de `globals.vhd`
  (escrito en `M2033`, anticipando este milestone).
- **`avm_cache`** (usado dentro de `mdv_dpram.vhd`) es genérico y reutilizable
  tal cual. **`avm_arbit_general`** (`M2M/vhdl/memory/avm_arbit_general.vhd`,
  framework, sin modificar, nunca usado aquí todavía) arbitra 3 o 4 maestros
  componiendo instancias de `avm_arbit` en árbol — existe ya en el
  repositorio, solo hace falta instanciarlo.
- **Menú OSD** (`config.vhd`, `OPTM_ITEMS`): mecanismo de opciones del propio
  M2M (no el `CONF_STR` literal de MiSTer). Ya tiene secciones tipo
  "ROM"/"Microdrive" con items seleccionables — añadir "RAM"/"Speed" es el
  mismo patrón, sin sorpresas de diseño.

## 2. El punto que NO es trivial: `mdv_dpram.vhd` no es la plantilla correcta para la RAM principal

`mdv_dpram.vhd` (el wrapper que hoy conecta `mdv.v` a HyperRAM) está
diseñado a propósito para un patrón de acceso **lento y de baja frecuencia**:
`mdv.v` cambia de dirección una vez cada ~592 ciclos de `ce` (~79µs reales),
y tolera servir un dato "un poco viejo" mientras se resuelve una petición de
verdad (de ahí el diseño de "hold register + contador de settle + refresco
periódico" documentado extensamente en la cabecera de ese fichero).

La CPU principal (`fx68k`) es justo lo contrario: accede a RAM en
**prácticamente cada ciclo de bus**, y el protocolo 68000 real (`DTACKn`)
exige que cada acceso se resuelva de verdad (no vale servir un valor viejo
"probablemente correcto") — cualquier lectura debe devolver el dato real de
esa dirección, cualquier escritura debe completarse antes de que la CPU siga.
Copiar el patrón de `mdv_dpram.vhd` sería incorrecto aquí, no solo
subóptimo.

**Diseño propuesto (nueva entidad, ej. `qram_avm.vhd`)**: mucho más simple
que `mdv_dpram.vhd` porque solo hay UN solicitante (la CPU, no dos puertos
que arbitrar):

1. Interfaz sencilla hacia `main.vhd`: dirección, `wr`/`rd`, `byteenable`,
   `data_i`/`data_o`, y una señal `ram_ready_o` (nivel, no pulso — misma
   lección que `q_a_valid_o` de `M2030`-`M2032`).
2. Un `avm_cache` propio (igual que hace `mdv_dpram.vhd`), pero el
   traductor delante es un master Avalon-MM directo: pide, mantiene la
   petición, y sube `ram_ready_o` en el ciclo exacto en que
   `s_avm_readdatavalid_o` (lectura) o la aceptación (`waitrequest`
   bajando en una escritura) confirma que el dato es real — sin hold
   register, sin settle counter, sin refresco periódico (nada de eso tiene
   sentido cuando cada acceso es genuinamente nuevo).
3. `cpu_dtack` pasa a ser `(not ram_delay_dtack) and (ram_ready or not
   cpu_ram)` — el término de contención de `ql_timing` se mantiene (sigue
   aplicando en modo nativo, ver sección 1) y se le añade el nuevo término
   de HyperRAM, solo relevante cuando la CPU está tocando de verdad el rango
   de RAM.
4. El acierto de caché de `avm_cache` (localidad espacial de accesos a
   programa/pila) debería servir la mayoría de accesos en pocos ciclos; un
   fallo de caché paga el viaje completo a HyperRAM real (decenas de ciclos
   de `hr_clk`, más el cruce de dominio por `avm_fifo`). Esto es
   **correcto siempre** (el protocolo `DTACKn` no tiene límite superior, la
   CPU simplemente espera lo que haga falta) pero **more lento que la BRAM
   actual** en el peor caso — impacto real de rendimiento a medir en
   simulación antes de dar por bueno el diseño, no algo que se pueda
   descartar de antemano.

## 3. Presupuesto de direcciones HyperRAM — RESUELTO (2026-08-23)

Aritmética real: el chip son 8MB. La mitad (`C_HMAP_M2M`, 4MB) está
reservada para el framework. La otra mitad (`C_HMAP_QL`, 4MB = 512 bloques
de 4kW) es todo lo que tiene el core QL para RAM principal + microdrives +
lo que venga después.

Con el tope de RAM bajado a **2048k** (decisión del usuario, sección 0):
2048k = 256 bloques. Sumando los 176 bloques ya reservados (aunque no todos
instanciados) para hasta 8 microdrives, quedan 512-256-176 = 80 bloques
(625KB) libres de margen dentro de `C_HMAP_QL`, sin tocar ni recortar nada
del framework ni de la reserva de microdrives existente. **No hace falta
ninguna de las opciones (A)-(D) originalmente planteadas** — el problema
desaparece con el nuevo tope.

Colocación acordada dentro de `C_HMAP_QL` (a fijar en `globals.vhd` cuando
toque la Fase 2): la ventana de RAM principal (hasta 256 bloques al tope de
2048k) va justo después del rango completo de 176 bloques ya reservado para
microdrives, es decir en `C_HMAP_QL + 176`, dejando a mdv1-mdv8 su hueco
íntegro tal y como quedó dibujado en `M2033`, sin reordenar nada existente.

## 4. Velocidad de CPU — riesgo de ancho de banda a "Full" (84MHz)

Como la contención de `ql_timing` se desactiva fuera de modo nativo (sección
1), a velocidad "Full" la CPU golpea el bus mucho más agresivamente y con
mucho menos margen entre accesos que en modo nativo — justo el escenario
donde un fallo de caché de HyperRAM (decenas de ciclos) más duele. Igual que
ya anticipó el usuario: el resultado correcto y aceptable puede ser que
"Full" real (84MHz) no sea alcanzable con buen rendimiento y haya que topar
el máximo soportado (66MHz, o lo que aguante la Fase 3 verificará esto con
datos, no antes) más bajo, dejando el menú con las opciones que de verdad
funcionen bien. Esto no es un riesgo de corrección (el protocolo `DTACKn`
sigue siendo válido a cualquier velocidad, nunca corrompe datos) sino de
rendimiento/sensación real en hardware — a medir, no a asumir.

## 5. Fases de implementación (staged, con hardware real como cierre de cada una — mismo patrón que microdrive)

### Fase 1 — 128k RAM: BRAM → HyperRAM (arquitectura correcta, mismo tamaño)

**Pasos 1-4 hechos (2026-08-23).**

1. **Diseño de `CORE/vhdl/qram_avm.vhd`** — hecho. No es una copia de
   `mdv_dpram.vhd` (sección 2 de este documento explica por qué): un único
   solicitante (la CPU), sin arbitraje interno de puertos, FSM propia
   (`IDLE`→`DISPATCH`→`WAIT_READ`/`DONE`) sobre un `avm_cache` privado.
2. **Simulación aislada** (`.research/qram-avm-sim/`, mismo patrón que
   `.research/hyperram-migration-sim/` de mdv1: `fake_avm_backend.vhd`
   reutilizado tal cual, memoria real + 10-200 ciclos de latencia
   inyectada) — **encontró un bug real de protocolo antes de tocar
   hardware**: la primera versión de la FSM asumía aceptación inmediata de
   `avm_cache` con un pulso de un ciclo, sin comprobar `waitrequest` de
   verdad — si `avm_cache` seguía ocupado drenando una escritura anterior,
   la siguiente se perdía en silencio. Arreglado (estado `DISPATCH` que
   sostiene la petición hasta ver `waitrequest='0'` de verdad, protocolo
   Avalon-MM estándar). Resultado final: `635/635` accesos correctos, sin
   *timeouts* — barrido secuencial, escrituras parciales por byte,
   peticiones sin ningún hueco entre ellas, y 500 accesos aleatorios con
   duración de sujeción de bus de 1 a 20 ciclos. Detalle completo en
   `.research/qram-avm-sim/RESUMEN.md`.
3. **`avm_arbit_general`** (`G_NUM_SLAVES=3`, framework M2M, sin modificar,
   ya estaba en `CORE-R6.xpr` sin usar) sustituye a `avm_arbit` (2 vías) en
   `mega65.vhd` — mdv1=índice 0, mdv2=índice 1, RAM principal=índice 2,
   mismo `avm_fifo`/`hr_core_*` compartido de siempre.
4. **Dirección HyperRAM**: `C_HMAP_QRAM` (`globals.vhd`) = `C_HMAP_QL` +
   176 bloques (justo después de la reserva completa de 8 microdrives),
   256 bloques reservados (tope de 2048k, sección 3) — Fase 1 solo
   instancia 16 de esos 256 (128k, `qram_avm`'s `G_ADDR_WIDTH=16`).
   `main.vhd`: `i_main_ram` (BRAM) sustituida por `i_qram`; `cpu_dtack`
   ahora también depende de `qram_ready` cuando `cpu_ram='1'`.
   `CORE-R6.xpr` actualizado con el fichero nuevo.
5. **Build R6: hecho (`M3001`).** `RESULT=BUILD_OK`, `WNS=+0.090 ns`,
   `WHS=+0.011 ns`, 0 errores, 0 *critical warnings*. `.cor` empaquetado
   como `QL4M65-CoreQL-M3001_r6.cor`. **Probado en hardware real: FALLA**
   — arranca, lee mdv1, a veces guarda, se cuelga al poco (una vez incluso
   con el menú OSD abierto). Diagnóstico completo en `DECISIONES.md`,
   sección "Milestone 3, Fase 1 — M3001 falla en hardware real": margen de
   *hold* al límite en el dominio `hr_rwds` (`WHS=+0.011 ns`, el más
   ajustado del diseño desde `M2025`, nunca antes exigido de verdad —
   `qram_avm` es la primera carga de trabajo que genera tráfico denso hacia
   HyperRAM). **`M3002`: mismo RTL, estrategia de implementación
   `Performance_ExplorePostRoutePhysOpt` (fijada como nuevo valor por
   defecto en `build_core.tcl`/`build_core_r3.tcl`) — `hr_rwds` sube a
   `WHS=+0.213 ns` (~19×), global `WNS=+0.191 ns`/`WHS=+0.051 ns`.** `.cor`
   empaquetado como `QL4M65-CoreQL-M3002_r6.cor`. **Pendiente de
   confirmación en hardware real** (misma regresión completa que `M3001`
   no pudo pasar).

### Fase 2 — Tamaño de RAM seleccionable (640k / 2048k)

Ya no bloqueada por presupuesto de direcciones (sección 3, resuelta).

1. `config.vhd`: opción de menú "RAM" (128k/640k/2048k), mismo mecanismo
   que las demás opciones multi-select del framework.
2. `main.vhd`: la máscara de dirección de `cpu_ram`/`cpu_addr` deja de ser
   fija a `x"03FFFF"` (128k) y pasa a depender de la opción elegida —
   probablemente vía un registro leído una vez al reset (el tamaño de RAM
   es una decisión de arranque, no cambia en caliente, igual que en el
   `CONF_STR` original).
3. `qram_avm.vhd`/`globals.vhd`: la ventana HyperRAM de la RAM principal
   crece según el tamaño elegido (hasta 256 bloques para 2048k).
4. Regresión completa en cada tamaño — probar software real que realmente
   use la RAM ampliada, no solo arrancar.

### Fase 3 — Velocidad de CPU (16MHz / 24MHz / Full)

1. Portar `FRACT_BUS_16`/`FRACT_BUS_24`/`FRACT_BUS_FULL` a `main.vhd`
   (constantes ya conocidas, ver sección 1) + opción de menú "Speed".
2. `ce_bus_p`/`ce_bus_n` seleccionan la fracción activa; **igual que
   `QL.sv`, este único reloj de bus alimenta CPU + `zx8302` + `mdv.v` a la
   vez** — no repetir el error de `M2008` (acelerar mdv1 solo, por su
   cuenta, rompió el driver de QDOS).
3. `ql_timing`'s `enable` pasa a depender de `cpu_speed = nativo` (hoy
   siempre activo porque solo existe el modo nativo).
4. Verificación de ancho de banda HyperRAM a cada velocidad, de menor a
   mayor (16MHz primero, Full al final) — parar en la velocidad más alta
   que de verdad funcione limpia en hardware real (sección 4), documentando
   cualquier techo encontrado.

## 6. Próximo paso propuesto

Empezar por la Fase 1, paso 1-2 (diseño de `qram_avm.vhd` + simulación
aislada) — no toca `globals.vhd`/menú todavía, así que no depende de
resolver la sección 3. Pendiente de OK del usuario para arrancar.
