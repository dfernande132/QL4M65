# Milestone 2, paso 5 — Segundo microdrive (mdv2): plan de arquitectura

**Fecha:** 2026-08-23
**Prerrequisito:** `mdv1` migrado a HyperRAM real y confirmado en hardware
(`M2030`-`M2032`, ver `DECISIONES.md`). Este documento asume ese estado como
punto de partida y no repite su contenido.
**Destinatario:** modelos de codificación que implementarán este paso.
**Decisión de secuenciación (acordada con el usuario, 2026-08-23):** NO
duplicar las FSM de CDC de QNICE para mdv2 y jubilarlas después — eso
implica implementar el mecanismo de acceso de QNICE dos veces (una vez
duplicado, otra vez genérico). Se hace una sola vez, en dos etapas
verificables por separado:

- **Etapa 1**: el camino en tiempo real de `mdv.v` (puerto A/B vía
  `avm_cache`) pasa de un maestro Avalon a dos, con un árbitro nuevo delante
  de `hr_core_*`. Riesgo aislado y verificable sin tocar el lado QNICE.
- **Etapa 2**: el lado QNICE (carga + volcado a SD) pasa de las 5 FSM de CDC
  específicas de mdv1 a un puente genérico (`qnice2hyperram.vhd`) que sirve
  a mdv1 y mdv2 por igual, mediante offset de dirección. Las FSM viejas de
  mdv1 se jubilan en este mismo paso, no antes.

---

## 0. Por qué esta secuencia y no otra

Duplicar primero (mdv1+mdv2 con FSM de CDC propias cada una) y jubilar
después significaría: implementar el mecanismo de acceso de QNICE para
mdv2 con el patrón viejo (5 primitivas de CDC + ~300 líneas de ensamblador
`MDV2_FLUSH_STEP`/`READ_MDV2_BYTE`, copia de las de mdv1), y luego, al
jubilar, **tirar también las de mdv1** (que hoy funcionan y están
confirmadas en hardware) para sustituir ambas por el mecanismo genérico.
Eso es implementar la arquitectura vieja una vez más, para después
implementar la arquitectura nueva de todas formas — no un atajo.

La única razón real para considerar duplicar sería aislar el riesgo de
"dos maestros reales compitiendo por `avm_cache`" del riesgo de "rediseñar
cómo QNICE accede al buffer" — pero ese aislamiento se consigue igual
separando el trabajo en las dos etapas de abajo, sin necesidad de
implementar (y luego tirar) el mecanismo de QNICE dos veces.

---

## 1. Etapa 1 — segundo maestro en tiempo real, con árbitro

### 1.1 Qué cambia

- **`zx8302.v`**: extender el mux existente (`mdv_sel[0] ? mdv1_*_i : ...`)
  para que también mire `mdv_sel[1]`, con un segundo juego de puertos
  (`mdv2_gap_i`, `mdv2_tx_empty_i`, `mdv2_rx_ready_i`, `mdv2_byte_i`) — el
  mismo patrón ya usado para mdv1 (ver cabecera del fichero, sección
  "Milestone 2 phase A"). El canal de escritura (`mdv_wr_data_o`/
  `mdv_wr_strobe_o`/`mdv_wr_en_o`) sigue siendo único (así es el hardware
  real del QL: solo la unidad seleccionada escribe) — no se toca aquí.
- **`main.vhd`**:
  - Nueva instancia `i_mdv2` (mismo patrón que `i_mdv1`), con `sel =>
    mdv_sel(1)`.
  - Enrutar `wr_en`/`wr_strobe`/`wr_data` hacia `i_mdv1` o `i_mdv2` según
    `mdv_sel` (gate, no duplicar la señal — solo una unidad "graba" a la
    vez, igual que el hardware real).
  - `i_mdv2`'s propio `mdv_dpram` (misma entidad que `mdv_dpram.vhd`, ya
    parametrizable) con su propia base `C_HMAP_MDV2` (`globals.vhd`).
- **`globals.vhd`**: `C_HMAP_MDV2`, offset dentro de los 4MB reservados
  para el QL — hay margen de sobra (cada buffer son ~176KB de 4MB
  disponibles; ver el propio comentario de `C_HMAP_MDV1` sobre el resto del
  mapa quedando para Milestone 3).
- **`mega65.vhd`**: **el cambio real de esta etapa.** Hoy
  `i_avm_fifo_mdv1`'s lado maestro conecta DIRECTAMENTE a `hr_core_*` (un
  solo maestro, sin árbitro — ver `M2030`). Con mdv2 hay dos: se necesita
  un `avm_arbit` (2 esclavos → 1 maestro, round-robin, mismo patrón que la
  documentación del framework y que el propio `avm_arbit_adf` de AExp)
  entre `i_avm_fifo_mdv1`/`i_avm_fifo_mdv2` y `hr_core_*`.

### 1.2 Riesgo específico a verificar

Dos maestros reales, cada uno con su propio `avm_cache` (uno POR
`mdv_dpram`, no compartido entre mdv1 y mdv2 — cada instancia de `dpram`
trae la suya propia), compitiendo por el mismo `hr_core_*` a través de un
árbitro nuevo. El camino de mdv1 ya se peleó tres veces con bugs reales de
hardware en solitario (`M2030`-`M2032`) — antes de fiarse de que "el
patrón ya funciona, solo hay que repetirlo", verificar en simulación
primero:

- Testbench con DOS instancias de `mdv.v` + `dpram_avm.vhd` compartiendo un
  `avm_arbit` delante de un backend de latencia variable (reutilizar
  `.research/hyperram-migration-sim/` como base, añadir un segundo `mdv`+
  `dpram` y el árbitro).
- Caso concreto a probar: mdv1 en sesión de escritura mientras mdv2 está en
  reproducción activa (el escenario real más exigente — el árbitro no debe
  dejar que uno mate de hambre al otro, ni introducir un retraso que rompa
  el margen de tiempo de `mdv.v` — ver el propio margen de ~592 ce ticks ya
  documentado en `dpram_avm.vhd`).

### 1.3 Criterio de cierre de esta etapa

Build real en Vivado, con mdv2 **presente en el hardware pero no cargable
todavía** (el lado QNICE sigue siendo el de la etapa 2, no toca todavía
mdv2) — regresión completa de mdv1 (`LOAD`/`DIR`/`SAVE`/apagar-encender)
para confirmar que añadir el segundo maestro/árbitro no rompe nada de lo
ya confirmado. Sin esto verificado, no tiene sentido pasar a la etapa 2.

---

## 2. Etapa 2 — acceso genérico de QNICE (jubila las FSM de mdv1)

### 2.1 Qué se jubila

En `main.vhd`: `i_mdv1_cdc`, `i_mdv1_loading_cdc`, `i_mdv1_clear_cdc`,
`i_mdv1_read_req_cdc`, `i_mdv1_read_resp_cdc`, y las FSM
`mdv1_loader_qnice`/`mdv1_loader_core`/`mdv1_reader_qnice`/
`mdv1_reader_core` que las rodean. En `m2m-rom.asm`:
`MDV1_FLUSH_STEP`/`READ_MDV1_BYTE` y su RAM (`MDV1_DIRTY_SNAP`/
`MDV1_LAST_DIRTY`/`MDV1_BM_TMP`/`MDV1_FL_*`/`MDV1_GATE_CNT`).

### 2.2 Qué las sustituye

- **`qnice2hyperram.vhd`** (ya en el árbol M2M, usado con éxito en el
  QL-SD revertido de este mismo proyecto): puente genérico QNICE↔HyperRAM
  por ventana de bytes, con su propio cruce de dominio interno. Un solo
  maestro para AMBAS unidades — la unidad concreta se elige por dirección
  (`C_HMAP_MDV1` vs `C_HMAP_MDV2`), no por FSM dedicada. Entra como tercer
  maestro en el árbitro de la etapa 1 (o en uno propio, a decidir según
  cómo de compartido esté ya `hr_core_*` con `ascal` en ese momento —
  hoy `ascal` no usa HyperRAM en este proyecto).
- **Rutina de ensamblador genérica** (`MDV_FLUSH_STEP` en vez de
  `MDV1_FLUSH_STEP`/`MDV2_FLUSH_STEP` por separado), parametrizada por
  registro con: dirección base HyperRAM del buffer, dirección del bitmap
  de sucios, índice de manejo de fichero SD (`MDV1_MAN_IDX`/`MDV2_MAN_IDX`
  pasan a ser argumentos, no constantes fijas). La RAM de estado
  (`MDV_DIRTY_SNAP` etc.) se duplica por unidad (eso sí es barato — son
  bloques de datos, no lógica) o se pasa un puntero base; a decidir en
  implementación según presupuesto de RAM de QNICE (ver `AGENTS.md` de
  AExp para el estilo de cálculo de presupuesto de heap que ya se usa en
  este ecosistema, aunque QL4M65 no lo haya necesitado hasta ahora).

### 2.3 El punto que no es trivial: el bitmap de sucios

El bitmap de 256 bits vive hoy en registros de `clk_main_i` dentro de
`main.vhd` (`mdv1_dirty`), no en HyperRAM — es estado del core (qué
sectores escribió la CPU), no datos del buffer. `qnice2hyperram` es un
puente de MEMORIA, no puede leer registros del core directamente.

**Opción a evaluar en implementación:** que el core mismo escriba su
bitmap a una dirección reservada de HyperRAM (dentro de la región de cada
unidad, p. ej. justo después del buffer de 174930 bytes, mismo sitio
donde vive hoy conceptualmente `C_MDV1_DIRTY_BASE` en el espacio de
direcciones de QNICE) cada vez que cambia, usando el mismo `avm_cache` que
ya usa para sus propias escrituras — así QNICE lo lee con el mismo
`qnice2hyperram` genérico, sin mecanismo aparte. Necesita diseño propio
antes de implementar (cuándo escribir el bitmap sin pisar tráfico en
tiempo real, si hace falta un write especial de "solo bitmap" separado
del de datos). **No asumir la solución obvia sin comprobarla contra el
RTL real** — mismo principio que todo lo demás en este proyecto.

### 2.4 Criterio de cierre de esta etapa (y del paso 5 completo)

`LOAD mdv1`, `LOAD mdv2`, `DIR` de ambos, `SAVE` en ambos, apagar/encender,
releer ambos — de forma independiente (que escribir en uno no afecte al
otro). Regresión completa, no solo "compila".

---

## 3. Riesgos/abiertos a llevar a la implementación

1. El árbitro de la etapa 1 introduce latencia extra en el camino de mdv1
   (ahora comparte turno con mdv2) - repetir el razonamiento de margen ya
   documentado en `dpram_avm.vhd` (¿el margen de ~592 ce ticks sigue siendo
   cómodo con un árbitro de por medio?) antes de dar la etapa 1 por buena,
   no solo confiar en que "ya pasó con un maestro".
2. `C_HMAP_MDV2`: mismo cuidado que se documentó para `C_HMAP_MDV1` sobre
   la unidad de las constantes (bloques de 4kW, no bytes ni palabras
   directamente) - error de la misma familia que `M2003` si se pasa por
   alto.
3. El diseño del bitmap en HyperRAM (sección 2.3) es el mayor riesgo de
   diseño nuevo de todo este plan - dedicarle su propio documento/sesión
   de diseño antes de tocar RTL, no improvisarlo sobre la marcha.
4. Presupuesto de RAM/ROM de QNICE para el segundo slot de menú
   (`OPTM_G_MDV2`) y la rutina genérica - comprobar antes de implementar,
   no después (ver el estilo de verificación de heap que usa AExp para
   `OPTM_SIZE`, referenciado arriba).
