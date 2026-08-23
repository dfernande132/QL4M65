# Milestone 2, paso 5 — Segundo microdrive (mdv2): plan de arquitectura

**Fecha:** 2026-08-23 (revisado el mismo día tras revisión del usuario contra
el código real — ver historial de cambios al final)
**Prerrequisito:** `mdv1` migrado a HyperRAM real y confirmado en hardware
(`M2030`-`M2032`, ver `DECISIONES.md`). Este documento asume ese estado como
punto de partida y no repite su contenido.
**Destinatario:** modelos de codificación que implementarán este paso.

**Decisión de secuenciación:** dos etapas verificables por separado.

- **Etapa 1**: el camino en tiempo real de `mdv.v` (puerto A/B vía
  `avm_cache`) pasa de un maestro Avalon a dos, con un árbitro nuevo. Riesgo
  aislado y verificable sin tocar el lado QNICE.
- **Etapa 2**: el mecanismo de acceso de QNICE (carga + volcado a SD) que
  hoy sirve a mdv1 se **parametriza y se instancia dos veces** — NO se
  sustituye por un protocolo nuevo (`qnice2hyperram.vhd`) en el mismo
  cambio. Esa sustitución, si algún día compensa, es una etapa 3 propia y
  opcional, evaluable con dos microdrives ya funcionando.

**Por qué esta secuencia (revisado):** los tres últimos hallazgos reales de
hardware de este proyecto (`M2027`: `wait_o` una petición por detrás;
`M2031`: latencia fija de 2 ciclos calibrada para BRAM; `M2032`: pulso en
vez de nivel) están **todos** en la fontanería QNICE↔core, y los tres eran
invisibles en simulación. Añadir una unidad y cambiar esa fontanería en la
misma build mezclaría dos fuentes de fallo — si algo se rompe, no se sabría
si es la unidad nueva o el protocolo nuevo. Reutilizar el mecanismo ya
probado tres veces contra bugs reales (parametrizado, no reescrito) separa
ese riesgo limpiamente.

---

## 1. Etapa 1 — segundo maestro en tiempo real, con árbitro

### 1.1 Dónde va el árbitro

**En `main_clk`, antes del FIFO de CDC**: `avm_arbit(mdv1, mdv2) →
avm_fifo → hr_core_*`. Un solo cruce de dominio, no dos. Los dos maestros
(`i_mdv1`, `i_mdv2`) ya viven en `clk_main_i` — el patrón de AExp (FIFO por
maestro, árbitro después en `hr_clk`) existe ahí porque sus dos maestros
viven en dominios de reloj distintos entre sí; no es el caso aquí. Menos
recursos, un único sitio donde razonar sobre el cruce de dominio.

`G_PREFER_SWAP` de `avm_arbit`: **da igual cuál se elija**, pero que quede
escrito por qué en vez de dejarlo al azar del valor por defecto — mdv1 y
mdv2 son igual de tiempo real entre sí, y los dos tienen el mismo margen
amplio (~592 ce ticks / ~7900 ciclos de `clk_main_i` entre cambios de
dirección reales, ya documentado en `dpram_avm.vhd`).

`mega65.vhd:372-373` documenta explícitamente el estado actual ("single
master, no avm_arbit needed") — ese comentario se actualiza en esta etapa.

### 1.2 Qué cambia

- **`main.vhd`**:
  - Nueva instancia `i_mdv2` (mismo patrón que `i_mdv1`), con `sel =>
    mdv_sel(1)`.
  - `wr_en`/`wr_strobe`/`wr_data` van **en difusión a las dos unidades, sin
    enrutar** (ver 1.3 — `mdv.v` se protege solo).
  - `i_mdv2`'s propio `mdv_dpram` (misma entidad que `mdv_dpram.vhd`, ya
    parametrizable) con su propia base `C_HMAP_MDV2` (`globals.vhd`).
- **`globals.vhd`**: mapa completo de las 8 unidades posibles, no solo
  mdv2 (ver 1.5).
- **`mega65.vhd`**:
  - Nueva instancia `avm_arbit` (2 esclavos → 1 maestro) entre
    `main_mdv1_avm_*`/`main_mdv2_avm_*` y el `avm_fifo` existente
    (`i_avm_fifo_mdv1` pasa a tomar la SALIDA del árbitro, no la salida
    directa de `i_mdv1` — renombrar en consecuencia).
  - `main_drive_led_o`/`main_drive_led_col_o` (M2029, hoy en
    `main_mdv1_led`/`main_mdv1_dirty`, líneas 973-974) deben mirar **las
    dos** unidades: `main_mdv1_led or main_mdv2_led` para el nivel, y el
    color azul si `main_mdv1_dirty or main_mdv2_dirty`.

### 1.3 `zx8302.v`: más muxes de los que parece, pero sin enrutado de escritura

**La escritura no necesita enrutado** — es difusión directa. `mdv.v` ya se
protege por construcción:
```verilog
wire mdv_present = sel && (mdv_end != 0);              // mdv.v:150
wire wr_session  = wr_en && mdv_present;                 // mdv.v:266
```
La unidad con `sel='0'` tiene `mdv_present='0'` → `wr_session='0'` →
`if(!wr_session) begin wr_byte_cnt<=0; wr_pending<=0; end` (mdv.v:301) se
ejecuta cada ciclo, así que nunca procesa un `wr_strobe` en un byte real.
Verificado leyendo el código; **confirmar igualmente en la simulación de
etapa 1** antes de darlo por sentado en hardware.

Lo que sí hay que tocar en `zx8302.v` (más de lo que parece a primera
vista - son 5 sitios, no 1): extender el mux `mdv_sel[0] ? mdv1_*_i : ...`
para que también mire `mdv_sel[1]`, en:
- `mdv_tx_empty` (zx8302.v:366)
- `mdv_rx_ready` (zx8302.v:367)
- `mdv_byte` (zx8302.v:368)
- `mdv_gap` (zx8302.v:440)
- `led` (zx8302.v:370) — pasa de `mdv_sel[0]` a `|mdv_sel[1:0]` (el LED de
  actividad real del QL se enciende si CUALQUIER unidad está seleccionada,
  no solo la 1).

Necesita un segundo juego de puertos de entrada (`mdv2_gap_i`,
`mdv2_tx_empty_i`, `mdv2_rx_ready_i`, `mdv2_byte_i`), mismo patrón ya usado
para mdv1.

### 1.4 Coherencia entre cachés: no hay problema, pero blíndalo

Cada `mdv_dpram` (mdv1 y mdv2) lleva su propio `avm_cache` — no comparten
instancia. Con `C_HMAP_MDV1`/`C_HMAP_MDV2` disjuntos no hay problema de
coherencia real entre ellas. Pero si algún día se solaparan por error de
cálculo, la corrupción sería silenciosa (cada caché vería solo su propio
tráfico, sin forma de detectar que otra caché está escribiendo el mismo
rango de HyperRAM por debajo). Añadir un `assert` en tiempo de elaboración
en `globals.vhd` o en el punto donde se instancian ambos `mdv_dpram`,
comprobando que los rangos `[C_HMAP_MDVn, C_HMAP_MDVn + 22)` no se solapan
— tres líneas, barato.

### 1.5 Mapa completo de HyperRAM, escrito ahora aunque solo se use la mitad

`globals.vhd` debe documentar el mapa completo de las 8 unidades posibles
(el protocolo real del QL, `mdv_sel` de 8 bits), no solo `C_HMAP_MDV2`:
22 bloques de 4kW por unidad × 8 unidades = 176 bloques (≈1,4MB de los
1024 bloques = 8MB del chip completo), aunque esta etapa solo instancie
`C_HMAP_MDV1`/`C_HMAP_MDV2` de verdad. Dejarlo escrito ahora evita que
Milestone 3 (RAM principal del QL sobre HyperRAM) tenga que averiguar qué
parte del mapa está reservada — la misma lección de `M2003`
(desbordamiento de `C_HMAP_QLSD`) aplicada por adelantado, y la
reconciliación pendiente que `M2030` ya dejó anotada.

### 1.6 Tráfico de sobrecarga: mdv2 corre siempre, esté seleccionada o no

`mem_addr` avanza incondicionalmente con `ce` en `mdv.v`, esté la unidad
seleccionada o no — es toda la historia de `M2011`. Así que `i_mdv2`
generará tráfico de HyperRAM (lectura de puerto B + su propio refresco
periódico de `dpram_avm`) aunque nadie la esté usando. El tráfico útil es
pequeño (~12,7 kpalabras/s por unidad), pero el refresco periódico dobla,
y cada refresco puede ser un fallo de caché con ráfaga de 8 palabras -
sobrecarga pura que escala linealmente si algún día se llega a más
unidades. **Medir en la simulación de esta etapa y dejarlo anotado.** Si
sale alto, gatear el refresco por `sel` es trivial - con cuidado de no
romper el caso de recarga de imagen, que es precisamente cuando hace
falta el refresco (ver el razonamiento ya documentado en `dpram_avm.vhd`
sobre por qué existe el refresco de puerto B).

### 1.7 Verificación

- **Simulación (HECHA, 2026-08-23):** `tb_mdv_dual.vhd` en
  `.research/hyperram-migration-sim/` - dos instancias reales de `mdv.v`,
  cada una con su propio `dpram_avm.vhd`/`avm_cache`, compartiendo un
  `avm_arbit` delante de un backend único de latencia variable (10-200
  ciclos). Escenario probado: mdv1 en sesión de escritura completa
  mientras mdv2 reproduce activamente en paralelo (el caso más exigente).
  Resultado: **las cuatro comprobaciones pasan limpio**:
  1. `TEST_DUAL_MDV1_WRITE_SURVIVES: PASS` - la escritura de mdv1
     sobrevive a la contención real de mdv2, sin inanición ni timeout.
  2. Flujo servido de mdv2 (`dout_trace_mdv2.txt`, muestreado durante TODA
     la ejecución, incluida la ventana de escritura de mdv1): **1831/1831
     bytes exactos** contra el modelo de referencia sin modificar - la
     contención no corrompe ni bloquea la reproducción de mdv2.
  3. `TEST_DUAL_WRITE_BROADCAST_SAFE: PASS` (riesgo #3 de la sección 4,
     verificado en simulación real, no solo por lectura de código):
     desseleccionada mdv2 (`sel='0'`), difundidos los mismos
     `wr_en`/`wr_strobe`/`wr_data` a las dos unidades a la vez (igual que
     hará `main.vhd` de verdad) - la palabra 0 de mdv2 sigue siendo
     exactamente la de la imagen cargada, la escritura no se filtró.
  4. Tráfico de sobrecarga medido (sección 1.6): **2246 transacciones
     aceptadas de mdv1** (carga + sesión de escritura + su propio
     refresco de puerto B) frente a **1982 de mdv2** (carga + refresco de
     puerto B puro, sin selección real de CPU en este test - mem_addr
     avanza igual, ver M2011) a lo largo de ~4,02M ciclos de `clk_main_i`
     - aproximadamente una transacción cada ~2000 ciclos por unidad
     inactiva, coherente con `C_REFRESH_PERIOD=2000`. No se considera alto
     - no hace falta gatear el refresco por `sel` de momento.

  **Hallazgo real durante la implementación, no anticipado en la versión
  anterior de este plan:** `mdv_dpram.vhd` guardaba `C_HMAP_MDV1` como una
  referencia directa al paquete `globals`, no como parámetro - las dos
  instancias habrían compartido la MISMA dirección base de HyperRAM en
  silencio, corrompiéndose mutuamente, si se hubiera compilado tal cual.
  Arreglado añadiendo un generic `G_HMAP_BASE` a la entidad `dpram`
  (por defecto `C_HMAP_MDV1`, preservando el comportamiento de `M2030`-
  `M2032` sin cambios para `i_mdv1`) y un nuevo parámetro `HMAP_BASE` en
  `mdv.v` que lo pasa por nombre a su propia instancia interna de `dpram`
  - `main.vhd` pasa `C_HMAP_MDV1`/`C_HMAP_MDV2` explícitamente a
  `i_mdv1`/`i_mdv2` vía `generic map`. Confirmado en simulación que Vivado
  sí soporta pasar un generic VHDL a un parámetro Verilog en ambos
  sentidos de la instanciación mixta (`entity work.mdv generic map (...)`
  desde VHDL hacia el `parameter` de `mdv.v`) - sin precedente previo en
  este proyecto, verificado antes de confiar en ello para hardware real
  (la elaboración mostró explícitamente `work.mdv(HMAP_BASE=16'b0)` y
  `work.mdv(HMAP_BASE=16'b010110)` como dos parametrizaciones distintas).
  El `assert` de no-solape de la sección 1.4 vive junto a las dos
  instanciaciones en `main.vhd`.

- **Hardware**: build real con mdv2 presente en el silicio pero **aún no
  cargable desde el menú** (el lado QNICE es el de la etapa 2, sin tocar
  todavía) - regresión completa de mdv1 (`LOAD`/`DIR`/`SAVE`/apagar-
  encender) para confirmar que el árbitro nuevo no rompe nada de lo ya
  confirmado. Sin esto verificado, no tiene sentido pasar a la etapa 2.

---

## 2. Etapa 2 — segunda unidad accesible desde QNICE (parametrizar, no sustituir)

### 2.1 Qué se hace

Sacar la FSM de QNICE que hoy sirve a mdv1 (`mdv1_loader_qnice`/
`mdv1_loader_core`/`mdv1_reader_qnice`/`mdv1_reader_core` y las 5
primitivas de CDC que las rodean: `i_mdv1_cdc`, `i_mdv1_loading_cdc`,
`i_mdv1_clear_cdc`, `i_mdv1_read_req_cdc`, `i_mdv1_read_resp_cdc`) a un
componente propio parametrizado (p. ej. `mdv_qnice_bridge.vhd`), con
genéricos para: el ID de dispositivo QNICE, la base de dirección del
buffer, y cualquier otra constante hoy fija que necesite variar por
unidad. Instanciarlo dos veces (`i_mdv1_bridge`, `i_mdv2_bridge`).

**Es la misma lógica ya probada en hardware real tres veces contra bugs
reales** (`M2027`/`M2031`/`M2032`), sin duplicar código fuente y sin
protocolo nuevo que verificar desde cero.

### 2.2 El bitmap de sucios: se queda donde está

**Revisión respecto a la versión anterior de este plan**: el bitmap de
sucios NO se mueve a HyperRAM. Sigue en registros de `clk_main_i`
(`main.vhd:327`, `mdv1_dirty`, un bloque de 256 flip-flops por unidad) y
se lee por el mismo camino que hoy (`main.vhd:1469`), simplemente
instanciado dos veces dentro del componente parametrizado de 2.1.

Meterlo en HyperRAM (la propuesta original de este documento) habría sido
un error: obligaría al core a hacer lectura-modificación-escritura sobre
HyperRAM en cada confirmación de escritura de sector, introduciendo una
carrera nueva contra el propio `avm_cache` - todo para ahorrar 256
flip-flops que ya son baratos en la FPGA. No compensa.

### 2.3 Rutina de ensamblador: duplicada, no parametrizada (revisión 2026-08-23)

**Revisión respecto a la versión anterior de esta sección**: la propuesta
original pedía una única `MDV_FLUSH_STEP` parametrizada por registro
(índice de manejo de fichero SD, ID de dispositivo QNICE), sustituyendo a
`MDV1_FLUSH_STEP` para ambas unidades. Implementada la etapa 2 completa
(2026-08-23), se decidió NO hacerlo así: parametrizar de verdad esta
rutina en concreto exige que 3 valores por unidad (ID de dispositivo,
índice de fichero SD, puntero al bloque de estado de 100 palabras)
sobrevivan correctamente a través de ~260 líneas de ensamblador QNICE con
más de 25 puntos de uso, ramas y llamadas RSUB/SYSCALL anidadas - sin
ningún simulador de ensamblador QNICE disponible en este entorno para
verificarlo antes de hardware real. Esta rutina concreta ya lleva tres
bugs reales encontrados y corregidos contra hardware (`M2027`, `M2031`,
`M2032`) - el riesgo de una reescritura no verificable localmente pesa más
que el ahorro de ~130 líneas duplicadas.

En su lugar: `MDV2_FLUSH_STEP`/`READ_MDV2_BYTE` son copias mecánicas
literales de `MDV1_FLUSH_STEP`/`READ_MDV1_BYTE` (mismo cuerpo, solo
renombradas las etiquetas `_MFS_*`→`_MFS2_*` y las referencias a
`MDV1_*`→`MDV2_*`/`C_DEV_QL_MDV1`→`C_DEV_QL_MDV2`), cada una con su propio
bloque de estado en RAM. `MDV1_ADDR2WIN` (matemática de dirección pura,
sin ID de dispositivo) sí se reutiliza sin duplicar - es la única parte
del mecanismo genuinamente independiente de la unidad. Decisión confirmada
explícitamente con el usuario (ver AskUserQuestion en la sesión del
2026-08-23) tras señalar la contradicción con esta sección tal y como
estaba escrita originalmente.

Este es el lado del componente parametrizado de VHDL (`mdv_qnice_bridge.vhd`,
sección 2.1) el que sigue siendo la pieza que de verdad importaba
parametrizar - ese sí que se hizo tal y como pedía el plan, sin duplicar.

**Nota del usuario para el futuro (2026-08-23):** si algún día hay una
tercera unidad, ahí sí toca parametrizar de verdad `MDV_FLUSH_STEP`/
`READ_MDV_BYTE`. Con dos copias, duplicar sigue siendo más barato que
abstraer; con tres deja de serlo. Y para entonces se tendrán dos versiones
funcionando (mdv1 y mdv2, ambas probadas en hardware real) de las que
derivar la rutina genérica con confianza, en vez de una sola - la misma
lógica que ya se aplicó en la sección 2.1 para el puente QNICE en VHDL
(`mdv_qnice_bridge.vhd` se escribió DESPUÉS de tener mdv1 funcionando, no
antes).

La RAM de estado (`MDV_DIRTY_SNAP`/`MDV_LAST_DIRTY`/`MDV_BM_TMP`/
`MDV_FL_*`/`MDV_GATE_CNT`, ~100 palabras) se duplica por unidad - eso es
barato (bloques de datos, no lógica ni riesgo de protocolo). Comprobar
presupuesto de RAM/ROM de QNICE antes de implementar el segundo slot de
menú (`OPTM_G_MDV2`) y la RAM duplicada, no después - mismo estilo de
cálculo de presupuesto de heap que ya usa este ecosistema (ver `AGENTS.md`
de AExp para el patrón, aunque QL4M65 no lo haya necesitado hasta ahora).

### 2.4 Criterio de cierre de esta etapa (y del paso 5 completo)

`LOAD mdv1`, `LOAD mdv2`, `DIR` de ambos, `SAVE` en ambos, apagar/encender,
releer ambos - de forma independiente (que escribir en uno no afecte al
otro). Regresión completa, no solo "compila".

**Estado (2026-08-23): compila y sintetiza limpio (R6, `M2034`, `WNS=+0.203 ns`,
`WHS=+0.050 ns`, `RESULT=BUILD_OK`), pendiente de probar en hardware real.**
`mdv_qnice_bridge.vhd` (entidad nueva, sin genéricos, copia verbatim de la
lógica de `main.vhd` ya probada) instanciada dos veces en `main.vhd`
(`i_mdv1_bridge`, `i_mdv2_bridge`); `mega65.vhd` con `i_mdv2_csr`/
`p_mdv2_size_check` (4ª instancia de `qnice_csr`) y despacho
`C_DEV_QL_MDV2` en `core_specific_devices`; `globals.vhd` con
`C_DEV_QL_MDV2` y `C_CRTROMS_MAN_NUM=4`; `config.vhd` con la línea de menú
"mdv2:%s" (`OPTM_SIZE`/`OPTM_DY` 11→12); `m2m-rom.asm` con
`MDV2_FLUSH_STEP`/`READ_MDV2_BYTE` (ver 2.3 para por qué son copias, no una
rutina parametrizada) y su propio bloque de estado en RAM. Ningún byte de
esto se ha compilado ni probado todavía - siguiente paso: build R6 +
regresión completa en hardware real.

---

## 3. Etapa 3 (opcional, futura) — `qnice2hyperram.vhd` genérico

Si con dos (o más) unidades funcionando el componente parametrizado de la
etapa 2 empieza a sentirse pesado de mantener o de escalar, migrar el
lado QNICE a un puente genérico único (`qnice2hyperram.vhd`, ya usado con
éxito en el QL-SD revertido de este proyecto) sigue siendo una opción
válida - pero como su propia etapa, evaluable con calma, con dos
microdrives reales ya funcionando como red de seguridad, no como camino
crítico para tener mdv2. El bitmap de sucios seguiría en registros del
core en cualquier caso (2.2) - solo cambiaría cómo QNICE llega al
contenido del buffer en sí, no cómo se rastrea qué está sucio.

---

## 4. Riesgos/abiertos a llevar a la implementación

1. El árbitro de la etapa 1 introduce latencia extra en el camino de mdv1
   (ahora comparte turno con mdv2) - repetir el razonamiento de margen ya
   documentado en `dpram_avm.vhd` (¿el margen de ~592 ce ticks / ~7900
   ciclos sigue siendo cómodo con un árbitro de por medio?) antes de dar
   la etapa 1 por buena, no solo confiar en que "ya pasó con un maestro".
2. `C_HMAP_MDV2` y el resto del mapa de 8 unidades: mismo cuidado que se
   documentó para `C_HMAP_MDV1` sobre la unidad de las constantes
   (bloques de 4kW, no bytes ni palabras directamente) - error de la
   misma familia que `M2003` si se pasa por alto.
3. **[HECHO, 2026-08-23]** Confirmado en simulación (`TEST_DUAL_WRITE_BROADCAST_SAFE`,
   sección 1.7) que la difusión de `wr_en`/`wr_strobe`/`wr_data` a las dos
   unidades es segura - mdv2 desseleccionada no recibe nada aunque reciba
   los mismos strobes que mdv1.
4. **[HECHO, 2026-08-23]** Tráfico de sobrecarga medido (sección 1.7):
   ~1982 transacciones de mdv2 en ~4,02M ciclos, no se considera alto - no
   hace falta gatear el refresco por `sel` de momento.
5. Presupuesto de RAM/ROM de QNICE para el segundo slot de menú
   (`OPTM_G_MDV2`) y la RAM duplicada del componente parametrizado (2.3) -
   comprobar antes de implementar, no después.

---

## Historial de revisiones

- **2026-08-23 (primera versión)**: propuesta inicial - etapa 1 (árbitro)
  + etapa 2 (jubilar las FSM de mdv1 en favor de `qnice2hyperram.vhd` de
  una vez, con el bitmap de sucios movido a HyperRAM).
- **2026-08-23 (esta versión)**: revisión del usuario contra el código
  real. Etapa 1 aprobada con precisiones (ubicación del árbitro en
  `main_clk`, difusión de escritura sin enrutar, lista completa de muxes
  de `zx8302.v`, mapa de 8 unidades escrito ahora, medición de tráfico de
  sobrecarga). Etapa 2 reordenada de raíz: parametrizar el mecanismo ya
  probado tres veces en hardware, en vez de sustituirlo por
  `qnice2hyperram.vhd` en la misma build que añade la unidad - esa
  sustitución pasa a ser una etapa 3 opcional y futura. El bitmap de
  sucios se queda en registros del core, no se mueve a HyperRAM.
