# QL4M65 — Plan de porting del Sinclair QL a MEGA65 vía MiSTer2MEGA65

Fecha: 2026-07-24
Fase: 3 — Montaje del framework M2M + estudio a fondo del core MiSTer del QL antes de tocar nada.

Este documento es el "dossier de Fase 0" que pide la Porting Guide de M2M
(`The-Ultimate-MiSTer2MEGA65-Porting-Guide.md`, sección 2.0), aplicado al
Sinclair QL. Es el punto de partida para las fases de implementación reales
(Fase 4 en adelante), que se harán con Claude Code.

**Importante:** en este hilo NO se ha modificado ni escrito código. Todo lo
de abajo es estudio y documentación. Lo único que se ha creado es la
estructura de carpetas (ver "Estado de la carpeta CoreQL" al final).

---

## 0. Estado actual del proyecto (actualizado: 2026-08-05, sesión M2011 — causa raíz real del bug de lectura encontrada y arreglada: `download` como pulso en vez de nivel; overlay de depuración retirado)

**Causa raíz real del bug de lectura intermitente de microdrive (M2004-M2010): `mdv1_download` era un pulso de un ciclo en vez de un nivel mantenido durante toda la carga**, a diferencia del original de MiSTer (`ioctl_download`). El bloque de `mdv.v` que avanza `mem_addr` no está condicionado por `sel` ni por si el buffer está completo - corre libre en cuanto hay `ce`. Con el pulso de un ciclo, `mem_addr` empezaba a correr sobre la misma BRAM que el cargador de QNICE seguía escribiendo: una carrera de lectura/escritura real. Como `mdv_sel` no tiene reset, si ya estaba en `'1'` de una sesión anterior, `mdv_present` se volvía verdad en cuanto llegaba la segunda palabra, exponiendo la carrera a QDOS. Explica todos los síntomas: primeras entradas del catálogo bien, corrupción progresiva, variabilidad entre recargas, fiabilidad total en una segunda lectura de la misma sesión.

Confirmado comparando con C64MEGA65 (sirve sectores bajo demanda, no precarga) y AExp (usa `avm_fifo`/Avalon-MM con backpressure real) - ninguno de los dos reproduce este patrón. **`M2011`: fix real** - `mdv1_download` ahora es un nivel derivado de `mdv1_req_status = C_CSR_REQ_LDNG` (la misma bandera que usa `shell.asm` internamente), traído de QNICE a `main.vhd` y sincronizado con un simple sincronizador de 2 FF. Se retira todo el overlay de depuración de M2007-M2010 (cumplió su función); el LED de actividad (M2008) se mantiene. Detalle completo en `DECISIONES.md`.

**`M2008` probado en hardware: LED funciona, pero la velocidad x4 rompe la lectura por completo** (ni `tetris.mdv`, que leía bien a 1x, lee ya). Causa: el driver de microdrive de QDOS es tiempo real bit-a-bit a velocidad de CPU nativa - si el microdrive sirve datos más rápido que la CPU sin acelerar también la CPU, QDOS no llega a tiempo. Confirma por qué el modo turbo real de MiSTer (`QL.sv`'s `"O78,CPU speed"`) escala CPU+bus JUNTOS desde un único generador de reloj compartido, nunca el storage por separado - el vídeo que vio el usuario con `DIR` rápido casi seguro era MiSTer en modo turbo (no implementado aquí todavía, milestone futuro propio).

**`M2009`: revertido el x4** (`mdv1` vuelve a `ce_bus_p` nativo, sin código muerto), LED cambiado a rojo. **Bug abierto y prioritario ahora: `CHESS.MDV` da "bad or changed medium" en QDOS incluso a 1x**, mientras `tetris.mdv` (mismo tamaño) lee bien - confirmado que el dump es válido (funciona en otro emulador con la misma ROM). Es un error de contenido detectado por el checksum de QDOS, no un cuelgue - el overlay de depuración actual puede no bastar, puede hacer falta instrumentación nueva. Detalle completo en `DECISIONES.md`.

**`M2007` probado en hardware: `DIR mdv1_` ya funciona, `tetris.mdv` se
carga y se juega.** No se tocó ninguna lógica funcional entre `M2006` y
`M2007` (solo taps de depuración + overlay de vídeo) - la hipótesis es que
el place&route se reorganizó lo suficiente al añadir esas señales como
para despejar algún camino de timing marginal que fallaba en `M2006`. Hay
que volver a probar a fondo cuando se quite el overlay. `CHESS.MDV` ya no
cuelga, da `bad or changed medium` (mensaje real de QDOS, no un bug).

**`M2008`: LED de actividad del microdrive + velocidad x4.** El LED
(`zx8302.v`'s `led = mdv_sel[0]`, ya calculado pero descartado) ahora sale
por `main.vhd`→`mega65.vhd`→`main_drive_led_o`, igual que el LED de
disquete de AExp. La velocidad de lectura real se confirmó idéntica a la
del MiSTer original (mismo reloj 84MHz, misma `FRACT_BUS_QL`) - no era un
bug, es la velocidad real de un microdrive de 1984. Por decisión del
usuario, `mdv1` ahora usa su propio `ce_mdv1_fast` (~4x más rápido que
`ce_bus_p`) en vez de compartirlo, sin tocar `mdv.v`. Detalle completo en
`DECISIONES.md`.

**`M2006` probado en hardware: la carga del `.mdv` ya funciona bien** (se
vuelve limpiamente a BASIC). Pero `DIR mdv1_` con un `.mdv` cargado
**cuelga el sistema por completo** (ni teclado ni Ctrl+Espacio responden;
el IPC sigue sonando porque es independiente de la CPU principal). Sin
`.mdv` cargado, `DIR mdv1_` da "not found" correctamente - así que el
problema es específico de leer un microdrive ya presente, no del cargador
(que ya funciona desde `M2006`).

Comparación puerto a puerto contra el SoC original de MiSTer (`QL.sv`):
clk/ce/mdv_reverse/orden de bytes/pulso `dl_wr` por palabra (`WIDE=1`) -
todo coincide. Dos desviaciones reales encontradas: (1) `reset` en vez del
`reset_mdv` original (puerto muerto en `zx8302.v` desde M1, bajo riesgo);
(2) `mdv_download` es un pulso de un ciclo en vez del nivel mantenido
durante toda la carga que usa el original - evaluado y descartado como
causa de este cuelgue concreto (el driver aún no está seleccionado durante
la carga), documentado como pendiente. Ningún smoking gun tan claro como
el bug de `wait_o` de `M2006` - detalle completo en `DECISIONES.md`.

**`M2007`: en vez de seguir especulando, se añade un overlay visual en
pantalla** (6 cajas de color: SEL/LOADED/PRESENT/GAP/GAP_IRQ/RXRDY, mismo
patrón que el debug overlay de `cpu_addr` de M1016) para ver con datos
reales, en el momento exacto del cuelgue, qué señal no es la esperada.
Puertos de depuración aditivos en `zx8301.v` (`h_cnt_o`/`v_cnt_o`),
`mdv.v` (`mdv_present_o`/`mdv_loaded_o`) y `zx8302.v` (`gap_irq_o`) -
ninguno toca lógica existente. Pendiente de prueba en hardware.

**`M2004` probado en hardware: dos problemas.** ROMs dejaron de auto-cargar
desde `/ql4m65/rom/` (el revert de QL-SD se llevó por delante esa
reorganización, independiente de QL-SD). Cargar un `.mdv` colgaba el core en
la barra de progreso. Causa raíz aparente: mal uso de `xpm_cdc_handshake` -
`src_send`/`dest_ack` deben mantenerse en alto hasta ver la confirmación del
otro lado, no pulsarse un ciclo (confirmado leyendo el código fuente real de
la primitiva, no de memoria). **`M2005` arregla eso** (protocolo de 4 fases
correcto en `main.vhd`, rutas de ROM restauradas en `globals.vhd`) pero
**probado en hardware sigue colgándose exactamente igual** — ROM ya arranca
bien, pero el `.mdv` no.

**Segunda causa raíz (la real): `qnice_mdv1_wait_o` mezclaba estado
registrado con señales "en vivo" de la CPU QNICE.** La fórmula
`mdv1_ld_busy or (ce and we and addr(0))` nunca podía bajar a `'0'` mientras
la CPU mantuviera su escritura asertada — y la CPU (confirmado leyendo
`qnice_cpu.vhd`) solo retira `ce`/`we`/`addr` un ciclo *después* de ver
`wait='0'`, así que nunca lo veía: cuelgue permanente garantizado en la
primera palabra de cualquier carga. Encontrado comparando contra
`qnice2hyperram.vhd` (el mecanismo que sí carga `.win` con éxito), cuyo
`wait_o` depende solo de estado interno registrado, nunca de las señales
en vivo entrantes. Fix: `qnice_mdv1_wait_o <= mdv1_ld_busy;` (sin el término
extra). **`M2006`**: este fix + pantalla de bienvenida/`CORENAME` corregidos
a "Milestone 2" (misma regresión que las rutas de ROM, no reaplicada hasta
ahora). Detalle completo en `DECISIONES.md`.



**`M2004` (microdrive 1, solo lectura, BRAM) compila limpio: WNS=+0.282 ns,
WHS=+0.055 ns, 0 nets sin rutar. Pendiente de prueba en hardware.** Segunda
cirugía sobre `zx8302.v` (tras la de `ipc`): 5 puertos nuevos
(`mdv_sel_o`/`mdv1_gap_i`/`mdv1_tx_empty_i`/`mdv1_rx_ready_i`/
`mdv1_byte_i`), `mdv.v` reinstanciado sin modificar con un reemplazo
Vivado-limpio de su `dpram` interno (`mdv_dpram.vhd`, BRAM). Hallazgo de
diseño real: `mdv.v` ata los dos relojes de su RAM interna a una única
entrada `clk`, así que cargar el `.MDV` desde QNICE necesita un puente de
cruce de dominio de reloj de verdad (`xpm_cdc_handshake`) - a diferencia de
Main/Back ROM, cuya RAM de destino ya es de doble reloj sin necesitar
ninguna FSM. Detalle técnico completo en `DECISIONES.md`, sección
"Milestone 2 — microdrive fase A, M2004".



**Milestone 2 pasa de QL-SD a microdrive (decisión del usuario, 2026-08-04).**
QL-SD (`M2001`-`M2003`) quedó a medias: el mount llegaba a completarse (barra
de progreso, reset automático funcionando) pero el driver QL-SD seguía sin
detectar la tarjeta incluso después de arreglar un bug real de
direccionamiento HyperRAM (`C_HMAP_QLSD` apuntaba al límite físico del chip)
- queda al menos una causa más sin identificar. Antes de seguir depurando,
el usuario reevaluó la prioridad del milestone por dos motivos de peso:

1. Las imágenes QXL.WIN reales (~50MB) no caben ni en BRAM ni en los 8MB de
   HyperRAM del MEGA65 - el mecanismo de `vdrives.vhd`/el Shell QNICE exige
   la imagen completa en un buffer lineal (confirmado leyendo `shell.asm`).
   Soportar tamaños reales exigiría streaming real desde la SD, sin
   precedente en este ecosistema M2M.
2. El driver QL-SD ocupa el único slot de Back ROM (16KB) de forma
   permanente, dejando sin sitio a cualquier otra ROM de extensión que se
   quiera usar a la vez (caso real: la ROM de Prospero Pascal del usuario).
   El microdrive no tiene este problema - Minerva ya trae soporte de
   `mdv1_`/`mdv2_` de fábrica, sin necesitar ninguna Back ROM.

**Código de QL-SD revertido** (commit `248dbe5` en `CoreQL`, `7997bc5` en
`QL_MiSTer`) - `main.vhd`/`mega65.vhd`/`config.vhd`/`globals.vhd`/
`m2m-rom.asm`/`build_core.tcl`/`CORE-R6.xpr`/`exceptions.md` vueltos al
estado de cierre de Milestone 1 (`M1048`); `sd_card.sv` vuelto a su
`altsyncram` original. Los design docs (`.research/qlsd-design.md`,
`qlsd-driver.md`) y todo el historial de depuración se quedan como
referencia para cuando se retome - ver `DECISIONES.md`, sección "Milestone 2
— QL-SD pausado, pivote a microdrive".

**Plan para microdrive:** 2 unidades en BRAM, solo lectura primero; después
escritura; después migrar a HyperRAM; ampliar unidades si hace falta. Ver
sección 7 (milestones) y el desglose de tareas de la sesión en curso.
Próxima compilación: `M2004`.

## 0.3 Estado histórico (hasta el cierre de Milestone 1, sección sin tocar)

**MILESTONE 1 CERRADO, CONFIRMADO POR EL USUARIO Y PUBLICADO EN GITHUB**
(`https://github.com/dfernande132/QL4M65`, commits `2a67d6d` y `f71cc16`).
Tras el arranque end-to-end conseguido en `M1040` (resumen del tramo
`M1029`-`M1040` más abajo), la sesión `M1042`-`M1048` cerró el hito con una
tanda de pulido sustancial, probada a fondo en hardware real. Último
arreglo, `M1048`: la tecla `:` del MEGA65 seguía escribiendo `'` (resto sin
revisar de antes del rediseño de teclado) - corregido, y con eso el usuario
confirmó el cierre definitivo.

- **Causa raíz real del cuelgue "hay que hacer un hard reset al cambiar de
  ROM" encontrada y arreglada (`M1045`)**: no era la ROM vieja quedándose en
  la CPU, era que QNICE mismo se quedaba colgado de verdad (bucle infinito
  sin timeout) porque nuestro dispositivo de carga manual nunca implementó
  el protocolo CSR genérico del framework (`M2M/vhdl/qnice_csr.vhd`) que el
  firmware necesita para saber que un fichero terminó de cargarse. Bug
  presente desde que existe la carga manual de ROM, no introducido esta
  sesión - ver `DECISIONES.md` sección `M1042`-`M1047` para el detalle
  completo y la comparación con `AExp/CORE/vhdl/adf_mount_wrapper.vhd`, que
  sí lo implementa.
- **Main ROM (48K) + Back ROM (16K) como dos slots de tamaño fijo**
  (`C_DEV_QL_MAINROM`/`C_DEV_QL_BACKROM`), auto-carga desde
  `/ql4m65/main.rom`+`/ql4m65/back.rom`, acción "Extract Back ROM", y reset
  automático del core tras cualquier carga/extracción manual por menú -
  cierra por completo los items (a)/(b) pendientes de `M1041`.
- **Rediseño completo del mapeo de teclado** a "distribución MEGA65
  nativa" (lo que pone en la tecla del MEGA65 es lo que sale en la QL, no lo
  que tiene el QL real en esa combinación) - diseñado tecla a tecla con el
  usuario contrastando fotos reales de ambos teclados, documentado en
  `.research/keyboard-mapping-design.md`.
- El fichero de pre-síntesis de Vivado (`synth_pre.tcl`) nunca estuvo
  enganchado al proyecto - arreglado, ahora se reaplica en cada build desde
  `build_core.tcl` y ya no puede desaparecer silenciosamente otra vez.

Detalle técnico completo de las 7 compilaciones (`M1042`-`M1048`) en
`DECISIONES.md`. **Próxima compilación: `M2001`** - arranca Milestone 2, que
pasa a ser **microdrive virtual** en vez de ampliación de memoria/velocidad
(reordenado con el usuario al cierre de este hito: el microdrive permite
probar software real del QL sin ampliar cuanto antes, con menos riesgo
arquitectónico que migrar a HyperRAM; ver sección 7 para el detalle de la
reordenación). La numeración de builds pasa de `M1xxx` a `M2xxx` para
marcar el cambio de milestone.

## 0.2 Resumen histórico: cómo se llegó al arranque completo (`M1029`-`M1040`, cerrado 2026-08-01)

**HITO: el QL arranca por completo en el MEGA65 - Minerva y MGE llegan al
BASIC con teclado funcionando.** Tras la investigación `M1029`-`M1040`
(resumen abajo), el core pasa el chequeo de RAM, muestra el logo, llega a
la pantalla F1-F4, hace el timeout de 10s (o responde a F1/F2/F5) con
normalidad, y entra en SuperBASIC con el teclado respondiendo. Primer
arranque end-to-end de todo el proyecto. Detalle técnico completo en
`DECISIONES.md`, secciones `M1029` a `M1040`.

**Resumen del tramo `M1029`-`M1040` (el teclado/IPC, de raíz a resuelto):**
1. `M1029`/`M1030`: `keyboard.vhd` generaba `comctrl` como oscilador libre
   nunca sincronizado con la CPU - corrompía el primer comando real de
   cualquier ROM. Arreglado (reactivo, disparado por el bit de arranque
   real).
2. **Redirección clave del usuario**: en vez de seguir puliendo la FSM de
   protocolo hecha a mano, comparar cómo entrega MiSTer/MiST el teclado al
   IPC real - reveló que Minerva nunca llama al comando que sí
   implementamos (`9`, "keyrow") y siempre pide el comando `1` (estado)
   antes que nada, saltándose el teclado si su bit "hay datos pendientes"
   no está puesto (que nuestra FSM nunca ponía).
3. `M1031`: sustituido el `keyboard.vhd` hecho a mano por el 8049 real
   (núcleo T48, VHDL puro, sin modificar, del propio repo) ejecutando el
   firmware real (`ipc8049-hermes.hex`) - `ipc.vhd` nuevo, puerto
   estructural de `rtl/ipc.v`. `keyboard.vhd` se queda solo con la
   traducción MEGA65→matriz QL.
4. `M1032`-`M1034`: instrumentación (P1/P2 del 8049, luego traza de
   `cpu_addr`) para localizar por qué Minerva seguía sin arrancar -
   desensamblado real (con `capstone`, contra el `Minerva197_rom` de
   verdad) confirmó que la CPU estaba atrapada en el propio planificador
   de QDOS (`ss_reshd`/`ss_dljob`), sin encontrar nunca un trabajo listo.
5. `M1035`: confirmado que la causa era `ipl[1]` del 8049 real quedándose
   permanentemente asserted (nada en el sistema lo bajaba de nuevo) -
   forzar `ipc_ipl_i` a `"00"` desatascó el arranque por completo (se
   mantiene así; ver `zx8302.v`/`main.vhd`).
6. `M1036`/`M1037`: intento de arreglo más fino (`OR`→`AND` en `zx8302.v`
   con `ipc_ipl_i` real reconectado) - **regresión real**, revertido:
   `AND` bloquea `vsync_irq` casi siempre (el mismo bug de `M1001`-`M1005`
   reintroducido). Vuelta a la configuración de `M1035`.
7. `M1038`/`M1039`: implementada la interrupción "interface" (`intri`,
   bit1) que faltaba en `zx8302.v` desde el principio del proyecto -
   mejora real de fidelidad al hardware, pero no era la pieza que
   bloqueaba el teclado del BASIC.
8. **`M1040`, el arreglo real**: a petición del usuario, comparar qué
   implementa MiSTer que nosotros no - el microdrive. Confirmado, byte a
   byte contra el código fuente real de Minerva, que el arranque de
   SuperBASIC busca un fichero de arranque en `mdv1_` y se queda esperando
   para siempre una interrupción "gap" que `zx8302.v` nunca generaba
   (`mdv_gap` fijo a `0` desde `M1001`). Arreglado con un generador de
   pulso periódico de `mdv_gap` - no hace falta microdrive real, los
   propios timeouts de QDOS convergen solos a "sin soporte" en cuanto
   reciben el primer pulso.

**Limpieza post-hito (`M1041`)**: retirado el overlay de depuración
temporal (`M1016`-`M1039`, ya agotado - toda la información que podía dar
ya se usó), los puertos de depuración de `ipc.vhd`/`zx8301.v`, y
condensados los comentarios históricos en `zx8302.v` que quedaron
obsoletos tras encontrarse la causa real. Ver `doc/m2m/exceptions.md` para
el estado final de cada cambio respecto al MiSTer original.

## 0.1 Estado histórico (hasta M1001, sección original sin tocar)

**`M1001` conseguido.** `main.vhd` ya instancia el core QL real: `fx68k`
(CPU) + `zx8301` (vídeo) + `zx8302` (E/S, modificado para exponer el enlace
IPC) + `ql_timing` (wait-states) + RAM principal (128k, BRAM por ahora) +
VRAM (64k) + `keyboard.vhd` cableado de verdad. Síntesis + implementación +
bitstream sin errores (WNS=+0.130 ns, WHS=+0.051 ns, 0 nets sin rutar).
Detalle completo en `DECISIONES.md`, sección "M1001 conseguido".

**CAUSA REAL ENCONTRADA (2026-07-30): nunca se cargaba Minerva.** Toda la
investigación de "lentitud 100-1000x" de `M1001` a `M1012` resultó ser el
efecto de ejecutar una ROM en blanco (BRAM sin `INIT`, nunca cargada
manualmente por el menú OSD - el usuario asumía que Minerva venía incluida
en el `.cor`). Con Minerva 1.97 cargada de verdad por el menú "ROM:%s", el
core arranca **rápido, igual que un QL real**: chequeo de RAM en ~1 segundo
y aparece la pantalla de bienvenida de Minerva. Detalle completo,
razonamiento y verificación byte a byte contra el fichero real en
`DECISIONES.md` ("LA CAUSA REAL DEL CUELGUE/LENTITUD").

**Pendiente ahora:**
- Dejar avanzar Minerva más allá de la pantalla de bienvenida (teclado
  real, pantalla F1-F4, etc.) y ver hasta dónde llega con `keyboard.vhd`
  (aproximación parcial del protocolo IPC real).
- Nota aparte: `mge_rom` (una ROM original del QL, no Minerva) sí carga
  pero se queda negra/lentísima tras el chequeo de RAM - probable
  incompatibilidad con nuestro `keyboard.vhd` (protocolo IPC real no
  implementado del todo, ver Anexo B). Aparcado, no es el objetivo del
  Milestone 1.
- Limpiar el overlay de depuración temporal cuando ya no haga falta (ver
  `doc/m2m/exceptions.md` para la lista de reversiones pendientes).
- `zx8302.v` ya revertido de vuelta a la versión `OR` de `M1006` (correcta
  arquitectónicamente, y de hecho ya validada de forma indirecta: con
  Minerva real cargada y arrancando bien, el manejo de `vsync_irq` es
  necesario para que el sistema siga vivo más allá del arranque).
- Añadir los ficheros del core a los otros tres `.xpr` (R3/R4/R5) - solo se
  ha tocado `CORE-R6.xpr` hasta ahora.
- (Futuro, no urgente) Cargar Minerva automáticamente al arrancar, en vez
  del menú manual "ROM:%s" actual - mismo patrón que la Kickstart de AExp
  (`C_CRTROMTYPE_MANDATORY` + `C_CRTROMS_AUTO` en `globals.vhd`, fichero de
  nombre fijo tipo `/ql4m65/minerva.rom`, core en reset hasta que termina la
  carga).
- El recorte residual de ~1 carácter en el menú OSD: confirmado en otro
  monitor HDMI que se ve perfecto - es overscan del monitor de pruebas
  original, no un bug del core. Aparcado definitivamente, no se toca.
- `M1016`/`M1017`: **confirmado en hardware.** Faltaba invertir `cpu_ipl`
  antes de `IPL0n`/`IPL1n`/`IPL2n` en `main.vhd` (`fx68k` trata esos pines
  como activos a nivel bajo de verdad). Con el arreglo, Minerva llega por
  primera vez a la pantalla real F1/F2/F3/F4. Ver `DECISIONES.md` para el
  diagnóstico completo.
- **`M1018`-`M1028`: investigación del bloqueo en la pantalla F1-F4** (ni
  pulsación ni timeout de ~10s avanzan, en NINGUNA ROM). Descartado:
  teclas fantasma, basura de padding de ROM, codificación de la respuesta
  del comando 8, desajuste de temporización de `comctrl` frente al reloj
  real de 11MHz. Investigación del planificador de QDOS (`sv_pollm`,
  `ss_tlist`/`ss_reshd`) inconclusa (`M1027`/`M1028`).
- **`M1029`: causa encontrada y arreglo aplicado (pendiente de probar en
  hardware).** `comctrl_gen` en `keyboard.vhd` generaba `comctrl_o` como un
  oscilador libre, nunca sincronizado con las escrituras reales de la CPU
  a IPCWR - durante los silencios entre sondeos de teclado se colaban
  miles de flancos "fantasma" que la máquina de estados de comandos
  interpretaba como bits reales, corrompiendo el primer comando real de
  cualquier ROM. Arreglado: `comctrl_o` ahora es reactivo, solo genera sus
  2 flancos por bit al detectar el bit de arranque real de la CPU
  (`comdata_i` 1->0). Ver `DECISIONES.md` sección `M1029` para el análisis
  completo.
- Pasar la RAM principal de BRAM a HyperRAM de verdad (decisión explícita de
  esta sesión: BRAM primero para bajar el riesgo de esta compilación,
  HyperRAM después si el core arranca bien en hardware).
- Añadir los ficheros del core a los otros tres `.xpr` (R3/R4/R5) — solo se
  ha tocado `CORE-R6.xpr` hasta ahora.

**Fases del Milestone 1 cubiertas y pendientes:** ver la sección 9 (actualizada
fase a fase con el estado real, ya no todo "Pendiente").

**Convención de numeración de builds (corregida 2026-07-28):** a partir de
`M1001`, cada compilación que se sintetiza y se prueba en hardware
incrementa la secuencia (`M1002`, `M1003`, ...), sea cual sea el tamaño del
cambio — no solo los cambios "grandes". Ver `DECISIONES.md` para el
razonamiento completo.

**Registro de pruebas en hardware (MEGA65 R6 físico):**

| Build | Contenido | Resultado |
|---|---|---|
| `demo_r6` | Demo core M2M sin modificar (Fase 1, S25-S30) | Arranca correctamente |
| `DFSmega65_r6` | Prueba equivalente hecha por el usuario directamente en Vivado | Arranca correctamente |
| `QL4M65-CoreQL-batch1_r6` | `clk.vhd`+`mega65.vhd`+`config.vhd`+`globals.vhd`+`keyboard.vhd`, demo core aún dentro | Arranca; imagen con rayas y resolución aumentada (esperado, el demo sigue calculado para 54MHz con reloj ya a 84MHz); menú OSD vivo (Espacio/Help lo abren/cierran); sonido funciona |
| `M1001` | Core QL real (`fx68k`+`zx8301`+`zx8302`+`ql_timing`+RAM/VRAM+teclado) | Arranca; ruido de comprobación de RAM (¡CPU ejecutando Minerva de verdad!); menú de bienvenida M2M mal encuadrado (ver M1002); pantalla se pone en negro sólido (con señal) y se cuelga de forma reproducible; reset físico no recupera pero relanza el patrón - cuelgue determinista, no fallo de timing |
| `M1002` | Igual que M1001 + arreglo de `VGA_DX`/`VGA_DY` (512×256, sin duplicar) | Mejora parcial: el menú OSD se ve algo mejor pero sigue saliéndose por arriba y por la izquierda (TV reporta 720×576@50Hz, sin borde superior visible en el recuadro — recorte real, no solo overscan); mismo punto de cuelgue que M1001 |
| `M1003` | Igual que M1002 + `qnice_video_mode_o` forzado a `C_VIDEO_HDMI_640_60` (diagnóstico temporal, ver `DECISIONES.md`) | Recorte idéntico en 720×576 y 640×480 (ni más ni menos) — descarta la auto-detección de `ascal`; TV sin overscan en HDMI descarta también overscan de televisor; mismo punto de cuelgue |
| `M1004` | Arreglo real: reescalado proporcional del menú OSD para el camino HDMI (`vga_cfg_hscale_i`/`vscale_i` en `video_overlay.vhd`, ver `DECISIONES.md`) + revertido `qnice_video_mode_o` a `C_VIDEO_HDMI_4_3_50` | Peor en un sentido nuevo: el menú ocupa toda la pantalla con letras enormes (~2x el tamaño del core del Amiga) — el reescalado estira el menú en la misma proporción que `ascal` estira el vídeo del QL |
| `M1005` | Diagnóstico real (guía + comparación con AExp/C64MEGA65): `VGA_DX`/`VGA_DY` fijados a 720×576 (igual que Amiga, para que `hdmi_shift`=0) + revertido el mecanismo de `video_overlay.vhd`/`analog_pipeline.vhd`/`digital_pipeline.vhd` al original del framework (sin el reescalado de M1004) | Mejora grande: texto legible, tamaño razonable; queda un recorte residual de 1 carácter a la izquierda y el menú se ve ancho (~50% pantalla) por `OPTM_DX=23` (ver M1006); arranque: test de RAM y directo a negro, sin ver la pantalla verde de Minerva — refuerza la hipótesis de interrupciones sobre la de teclado |
| `M1006` | Arreglo del cuelgue: `zx8302.v` `ipl` cambiado de `AND`+"nada pendiente" a `OR`+"algo pendiente" (deja pasar `vsync_irq` propio del zx8302 al margen del IPC externo) + `OPTM_DX` 23→18 en `config.vhd` (menú más estrecho, con cabecera "Sinclair QL") | Menú reducido a ~40% como se esperaba. El cuelgue NO es tal: dejado varios minutos en negro, la pantalla se fue rellenando línea a línea desde abajo con el patrón de comprobación de memoria — avance real pero extremadamente lento, no parálisis total. Candidato: coste de reconocer `vsync_irq` (único emisor real entre los que tocamos; `xint`/`gap` atados a 0, `rtc`/`mdv_sel` fuera del rango que usa el `ipl`) |
| `M1007` | Mini-debug propio: overlay temporal con `cpu_addr` en hexadecimal (amarillo sobre negro, esquina superior izquierda), reutilizando la ROM de fuente del OSM; `zx8301.v` expone `h_cnt`/`v_cnt` como puertos nuevos para poder posicionar el overlay (temporal, ver `doc/m2m/exceptions.md` para revertir) | Confirma que la CPU está viva: se ven cifras moviéndose (demasiado rápido para leerlas), pero las dos primeras siempre "00" — la dirección se mantiene en `$00xxxx`, el rango de la ROM de Minerva. Bucle sin avanzar a otras zonas de memoria, no parálisis del bus |
| `M1008` | Overlay de `M1007` congelado a 1Hz (~50 pulsos de vsync) para poder leer la dirección con calma + `general.maxThreads 8` en `build_core.tcl` (Windows lo dejaba en 2 por defecto; tope duro de Vivado es 8 igualmente) | Dirección sigue moviéndose por un rango amplio de la ROM sin patrón repetido en 2 min — no es un bucle atascado, es la CPU ejecutando código real de Minerva mucho más lento de lo debido; candidato revisado: coste del sondeo de teclado (`keyboard.vhd`) en cada `vsync_irq`, protocolo con temporización nunca validada (ver `DECISIONES.md`) |
| `M1009` | Prueba temporal (no un arreglo): `ipc_comdata_kb2zx` forzado a `'1'` en `main.vhd`, simulando "ningún teclado/IPC conectado" — descarta la respuesta real de `keyboard.vhd` por completo. Motivación: en MiSTer real, sin teclado PS/2 conectado, igual se llega a la pantalla F1-F4 de Minerva | Comportamiento idéntico a M1008 (pantalla en negro, ROM saltando igual) — **descarta el teclado/IPC como causa de la lentitud**. El usuario recuerda además que este comportamiento probablemente ya estaba presente desde M1001 (nunca se dejó encendido el tiempo suficiente para verlo avanzar) - se descarta también `vsync_irq`/`M1006` como causa |
| `M1010` | Revertida la prueba de M1009 (teclado normal otra vez) + overlay ampliado a 12 dígitos: los 6 nuevos cuentan pulsos de `ce_bus_p` por segundo, para medir directamente si el reloj de bus de la CPU va a la velocidad correcta (~7.5MHz nativos del QL) | `0x723FDC`/`0x723FDB` (~7.487.452/seg) frente a ~7.499.450 esperados — solo ~0,16% de diferencia. **Descarta un problema de generación de reloj**; apunta a que cada transacción de bus individual consume muchos más ciclos (ya correctos) de los debidos |
| `M1011` | Overlay ampliado a 20 dígitos: los dígitos 6-11 pasan a contar cambios reales de `cpu_addr` por segundo (transacciones completadas, no solo pulsos de reloj); +4 dígitos de segundos desde el reset; +4 dígitos de segundos hasta el primer "interrupt acknowledge" (congelado la primera vez, `FFFF` si nunca ocurre) — para correlacionar el inicio de la lentitud con la fase de interrupciones | ~831.860 transacciones/seg (~9 ciclos/transacción, plausible con contención real); primer "interrupt acknowledge" a los **0 segundos** (casi instantáneo); cientos de millones de operaciones en total durante los minutos que tarda el arranque — apunta a que la rutina de interrupción de `vsync` de Minerva hace algo caro en cada uno de sus ~50 pasos/seg, no a que cada transacción individual sea lenta |
| `M1012` | Prueba temporal: revierte SOLO el arreglo del `ipl` de `M1006` (bloquea `vsync_irq` otra vez) manteniendo todos los contadores de `M1011`, para comparar la cifra EXACTA de transacciones/segundo con y sin esa interrupción llegando a la CPU | Prácticamente idéntico a `M1011`: ~831.860 transacciones/seg (mismo rango `0x0cb17b`/`0x0cb174`/`0x0cb16e`), mismo patrón de segundos. **Descarta la hipótesis de `vsync_irq`**: bloquear la interrupción por completo no cambia el tráfico de bus, así que el manejador de Minerva para esa interrupción no es el cuello de botella |
| `M1013` | Sin recompilar bitstream: binario 68000 mínimo (18 bytes, bucle de 2 instrucciones tocando solo RAM en `$030000`) cargado vía el menú "ROM:%s" ya existente, sobre el `M1012` ya flasheado | Dirección latcheada = `030000` (confirma el programa correcto). Transacciones/seg ≈ 9.363.973 (~11x más que Minerva) - pero se sospecha que el contador (sin antirrebote todavía) sobre-cuenta transitorios de un ciclo en saltos de dirección tan bruscos; ver `M1014` |
| `M1014` | Overlay de depuración: antirrebote (≥2 ciclos estables) en el contador de transacciones (dígitos 6-11) + dígitos 16-19 repurpuestos para mostrar la palabra baja del PC inicial leído de la ROM cargada (verificación de carga correcta, a petición del usuario) | Con `M1013` (binario mínimo): ~9.364.000/seg, prácticamente igual que sin antirrebote - **descarta que el 11x fuera un artefacto de medición, es una diferencia real**; PC inicial = `0008`, correcto. Con Minerva: ~831.868/seg, igual que sin antirrebote; pero PC inicial = **`0000`**, inesperado - pendiente verificar contra los bytes reales del fichero de ROM de Minerva usado (offset `$04`-`$07`) |

Detalle completo de cada prueba en `DECISIONES.md` (registro cronológico) y
sus Anexos A/B (memoria y teclado). Esta tabla no se mantuvo fila a fila
más allá de `M1014` (M1015-M1048 y el cierre de Milestone 1 están en
prosa en `DECISIONES.md`); tampoco se expande aquí para Milestone 2 -
`M2001` (compila limpio, WNS=+0.282 ns, WHS=+0.052 ns, pendiente de
hardware) está documentado en `DECISIONES.md`, sección "Milestone 2 —
implementación de QL-SD, M2001".

---

## 1. Núcleo MiSTer de referencia

- Repositorio elegido: **MiSTer-devel/QL_MiSTer** (oficial) — https://github.com/MiSTer-devel/QL_MiSTer
- Alternativa descartada por ahora: `MarcelKilgus/QL_MiSTer` (fork del mantenedor principal, puede tener commits más recientes sin fusionar).
- Es un port "muy avanzado" del QL de MiST (Till Harbaum, 2015) hecho por Sorgelig y otros para MiSTer. Cambios respecto al MiST original: CPU cambiada a un core `fx68k` "cycle-perfect", velocidades de CPU QL/16MHz/24MHz/42MHz, 896KB/4096KB de RAM, soporte de SMSQ/E vía un "GoldCard" virtual, soporte QL-SD (imágenes QXL.WIN), RTC.
- Copiado localmente (sin `.git` propio) en `CoreQL/CORE/QL_MiSTer/`, siguiendo el mismo criterio que se usó en la Fase 0 con C64MEGA65 y AExp: por ahora es solo una copia de trabajo, no un fork/submódulo git real. Eso se decidirá cuando toque implementar de verdad (ver "Decisiones pendientes").

## 2. Anatomía del core (capas rtl/ - sys/ - QL.sv)

Siguiendo el método de disección que propone la guía (sección 1.1 y 1.1.5):

### 2.1 El módulo `emu` — `QL.sv` (742 líneas)

Es el fichero raíz, la "glue" completa entre la máquina QL y el framework MiSTer.
Instancia, entre otras cosas:

- `pll` — un único PLL de 84 MHz a partir de los 50 MHz de referencia de MiSTer (`rtl/pll/pll_0002.v`).
- `hps_io` — el puente con el ARM (menú OSD, carga de ficheros, tarjeta SD, teclado/ratón PS/2, RTC).
- `sd_card` — emulador de tarjeta SD (para las imágenes QL-SD/QXL.WIN).
- `qlromext` — el hardware "QL-SD" que se mapea en la ROM del QL.
- `sdram` — controlador de memoria externa (toda la RAM del QL vive aquí).
- `mgc_rom` — ROM de arranque del "MiSTer Gold Card" (para SMSQ/E).
- `dpram` (x2) — la ROM de sistema QL (`ql_rom`) y la VRAM de pantalla (`vram`), ambas como wrappers de `altsyncram` (megafunción de Quartus, **no sintetiza en Vivado tal cual** — necesitará el mismo tratamiento que `dprom.vhd`/`spram.vhd` en el port del C64).
- `zx8301` — la ULA de vídeo.
- `zx8302` — el "microdrive/serial/red/RTC/interrupciones" chip (todo el I/O interno del QL salvo teclado/vídeo).
- `qimi` — interfaz de ratón (protocolo QL específico, no PS/2 directo).
- `ql_timing` — simulador del contended-memory timing original del QL (solo activo en modo "QL nativo", ver más abajo).
- `fx68k` — el core de CPU 68008 cycle-perfect (Verilog/SystemVerilog).

No hay ninguna instancia de `keyboard` directamente en `QL.sv`: el teclado se resuelve dentro de `ipc.v` (ver más abajo), un detalle importante que rompe la intuición de "buscar el teclado en el top".

### 2.2 CONF_STR — menú OSD actual del core

```
"QL;;",
"SC0,WIN,Mount HD image;",          -> S0: imagen de disco duro QL-SD (QXL.WIN), vdrive 0
"F2,MDV,Load MDV image;",           -> F2: carga de imagen de microdrive (.MDV)
"O2,MDV direction,normal,reverse;", -> status[2]
"F4,ROM,Load OS;",                  -> F4: carga de ROM de sistema operativo
"O3,Video mode,PAL,NTSC;",          -> status[3]
"OBC,Aspect ratio,...;",            -> status[12:11]
"O9A,Scandoubler Fx,...;",          -> status[10:9]
"ODE,Scale,...;",                   -> status[14:13]
"O78,CPU speed,QL,16 Mhz,24 Mhz,Full;", -> status[8:7]
"O45,RAM,128k,640k,896k,4096k;",    -> status[5:4]
"R0,Reset & unload MDV;"            -> status[0]
```

Traducción a decisiones de porting (columna "milestone 1" ver sección 5):

| Línea CONF_STR | Qué hace | Bits de status | Milestone 1 |
|---|---|---|---|
| `SC0,WIN` | Monta imagen de disco duro QL-SD | vdrive 0 | NO (fase posterior) |
| `F2,MDV` | Carga imagen de microdrive | ioctl index 2 | NO (milestone 2) |
| `O2` MDV direction | Sentido de la cinta microdrive | status[2] | NO |
| `F4,ROM` | Carga ROM de sistema operativo | ioctl index 4 | **SÍ — imprescindible para arrancar** |
| `O3` Video mode PAL/NTSC | Estándar de vídeo | status[3] | SÍ, fijo a PAL, sin opción de menú todavía |
| `OBC` Aspect ratio | Relación de aspecto HDMI | status[12:11] | Cableado a un valor fijo |
| `O9A` Scandoubler Fx | Filtros de vídeo (HQ2x, CRT) | status[10:9] | Cableado a "None" |
| `ODE` Scale | Escalado V/H-Integer | status[14:13] | Cableado a "Normal" |
| `O78` CPU speed | QL nativa / 16 / 24 / Full | status[8:7] | Fijo a "QL" (velocidad nativa) |
| `O45` RAM | 128k/640k/896k/4096k | status[5:4] | Fijo a "128k" |
| `R0` Reset | Reset + descarga MDV | status[0] | SÍ (reset básico) |

**Nota importante:** casi todo lo que no sea "cargar ROM de sistema" y "reset"
se puede cablear a un valor fijo por ahora, tal como recomienda la guía en la
regla de S6. No hay "S1..S3" adicionales ni joysticks obligatorios para
arrancar.

## 3. Reloj

Un único PLL de **84 MHz** (`rtl/pll/pll_0002.v`, `output_clock_frequency0 = 84.000000 MHz`,
referencia 50 MHz). A partir de ahí, **todos** los relojes derivados se generan
con acumuladores fraccionarios (clock enables), no con PLLs adicionales — exactamente
el patrón que la guía recomienda para M2M (menos dominios de reloj = menos CDC):

| Señal | Fracción sobre 84 MHz | Frecuencia resultante | Uso |
|---|---|---|---|
| `ce_bus_p`/`ce_bus_n` | `FRACT_BUS_QL = 11702/65536` | ~14.999 MHz (÷2 → reloj de bus real del 68008 a velocidad nativa QL) | Reloj de CPU (bus_p/bus_n, dos fases) |
| | `FRACT_BUS_16 = 24966/65536` | ~31.999 MHz | Modo "16 MHz" |
| | `FRACT_BUS_24 = 37449/65536` | ~48.000 MHz | Modo "24 MHz" |
| | `FRACT_BUS_FULL = 65536/65536` | 84 MHz | Modo "Full" |
| `ce_131k` | `84MHz / 640` | 131 250 Hz | Refresco de SDRAM + actualización de reloj (RTC) |
| `ce_vid` | `84MHz / 8` | 10.5 MHz | Reloj de píxel del ZX8301 |
| `ce_sd` | `FRACT_SD = 19505/65536` | ~25 MHz efectivos (SPI) | Tarjeta SD |
| `ce_11m` | `FRACT_11M = 8582/65536` | ~11 MHz | Reloj del IPC (8049) — igual que en el QL real |

**Para milestone 1** basta con generar (via MMCM Xilinx + clock-enables, igual que
en C64MEGA65/AExp): un reloj base (84 MHz o el que se decida tras ajustar la
aritmética a partir de los 100 MHz de la placa MEGA65) + los clock-enables de
arriba, fijando `cpu_speed = QL nativa`. Pendiente: NO se ha hecho aún la
aritmética exacta de MMCM para MEGA65 (100 MHz de entrada) — se hará en la
Fase 4 (clk.vhd), replicando el método visto en C64/Amiga (S7 de la guía).

No hay reconfiguración dinámica de PLL (no hay `pll_cfg`/`reconfig_to_pll` en
este core) — un problema menos que en el C64.

## 4. Memoria

- **SDRAM externa** (`rtl/sdram.sv`): toda la RAM principal del QL (128k/640k/896k/4096k según opción de menú) y también la "ROM shadow RAM" del modo GoldCard.
- **`ql_rom`** (`dpram` de 15 bits de dirección = 32K words = 64KB): la ROM de sistema operativo QL, cargada por `ioctl` (F4) — parte OS (48KB) + ROM de extensión (16KB, p.ej. TK2/QL-SD driver).
- **`vram`** (`dpram` de 15 bits = 64KB): framebuffer de pantalla, doble puerto (CPU escribe, ZX8301 lee para generar vídeo).
- **`gc_rom`** (`mgc_rom`, ROM de arranque GoldCard/SMSQE): ~512KB en fichero `.hex`, solo necesaria si se soporta el modo GoldCard (fuera de milestone 1).
- **`rtl/T48/`**: el core del microcontrolador Intel 8049 real (IPC — Inter Processor Communication), con su propia ROM interna (`ipc8049.hex`, hay también una variante `ipc8049-hermes.hex`).

**Decisión de dimensionamiento (revisada en este hilo, sustituye la propuesta inicial de BRAM):**
el requisito de partida del proyecto es soportar 128KB, 640KB **y 4096KB** de
RAM (los tres tamaños "grandes" del CONF_STR original, dejando aparte 896KB que
es un tamaño intermedio de la versión MiSTer sin equivalente claro de mercado).
4096KB no cabe en las ~1.4MB de BRAM disponibles en la Artix-7 (regla de la
guía, sección 1.4.2), así que **la RAM principal del QL se implementará sobre
HyperRAM desde el principio**, en vez de arrancar en BRAM y migrar más tarde.

Razón de la decisión: si el objetivo final incluye 4MB, diseñar primero sobre
BRAM y rehacer después el camino de memoria en `main.vhd`/`mega65.vhd` para
pasar a HyperRAM sería trabajo duplicado — mejor construir la arquitectura de
memoria correcta desde el milestone 1, aunque el primer arranque solo use una
fracción pequeña de la HyperRAM disponible (128KB). El framework M2M V2.0.1 ya
expone un maestro Avalon `hr_core_*` para el core (ver guía, sección 1.4.3),
así que no hace falta escribir un árbitro propio.

Consecuencias a tener en cuenta en Fase 6:
- Sustituir `rtl/sdram.sv` (controlador de SDRAM de Quartus, no aplica en MEGA65)
  por el interfaz Avalon `hr_core_*` del framework.
- La latencia de HyperRAM (5 ciclos a 100MHz, ~9 tras cruce de dominio de reloj)
  es mayor que la de BRAM. Hay que verificar que `ql_timing.sv` (los wait-states
  de `ram_delay_dtack`) siguen siendo compatibles, o si hace falta un pequeño
  buffer/cache intermedio para no penalizar el rendimiento en modo QL nativo
  (14.999 MHz) — a confirmar con pruebas reales en Fase 6/9.
- ROM de sistema (`ql_rom`, 64KB) y VRAM (`vram`, 64KB) sí pueden quedarse en
  BRAM interna sin problema (son pequeñas y de acceso muy frecuente/latencia
  crítica — la VRAM en particular la lee el ZX8301 en tiempo real para generar
  el vídeo, y no conviene meterla en HyperRAM compartido con el escalador).

`dpram.v` y `mgc_rom.v` son wrappers de la primitiva `altsyncram` de Quartus —
**no sintetizan en Vivado** tal cual; necesitarán la misma reescritura que
`dprom.vhd`/`spram.vhd` del port del C64 (patrón documentado en la guía, sección 3.A).

`ql_timing.sv` simula los estados de espera ("wait states") que el QL real
insertaba porque la RAM y el vídeo compartían el mismo bus físico (el ZX8301
"roba" ciclos de bus para generar la imagen). Es un simulador de *timing*
puramente lógico (cuenta chunks de línea de vídeo), no depende de qué
tecnología de memoria haya detrás — es compatible tanto con BRAM como con
HyperRAM sin cambios conceptuales. Solo está activo en modo "QL nativo"
(`ql_mode`), que es justo el modo elegido para milestone 1.

## 5. Periféricos — semántica exacta

- **Teclado — el detalle más importante y menos intuitivo del core.** El QL real
  no escanea el teclado con la CPU principal: hay un microcontrolador Intel 8049
  dedicado (el "IPC", Inter Processor Communication chip) que lee la matriz de
  teclado y se lo comunica a la CPU principal por un enlace serie de un solo
  hilo (`comdata`/`comctrl`) hacia el ZX8302. Este core de MiSTer **emula el
  8049 real, ejecutando su ROM original** (`rtl/T48/` + `rtl/ipc8049.hex`),
  en vez de atajar el problema con una matriz de teclado simple como hace el
  port del C64 con la CIA1. Dentro de `rtl/ipc.v`: se instancia `keyboard.v`
  (que sí convierte `ps2_key` en una matriz QL de 64 bits, exactamente igual
  de espíritu al `keyboard.vhd` del C64MEGA65) y luego un `t8049_notri` (el
  8049 real) que **lee esa matriz a través de sus puertos P1** como si fuera
  hardware físico, y la serializa. Consecuencia para el port: no basta con
  imitar `keyboard.v` — hay que decidir si se porta también el core T48 completo
  (más fiel, pero más RTL a portar) o si se sustituye todo el par
  `keyboard.v + ipc.v + T48` por un `keyboard.vhd` MEGA65 al estilo C64 que
  hable directamente el protocolo serie del ZX8302 sin pasar por un 8049
  emulado. **Decisión tomada (ver sección 8, punto 2):** se sigue el precedente
  de C64MEGA65 y AExp — se sustituye todo el conjunto `keyboard.v + ipc.v +
  rtl/T48/` por un `keyboard.vhd` MEGA65-nativo que hable directamente el
  protocolo `comdata`/`comctrl` del ZX8302, sin emular el 8049.
- **Ratón**: `qimi.v` — protocolo específico "QIMI" del QL (no PS/2 directo,
  aunque el propio `qimi.v` sí que consume `ps2_mouse` de `hps_io` y lo traduce).
  Fuera de milestone 1 (Workbench-equivalente no aplica al QL, el ratón no es
  imprescindible para arrancar).
- **Microdrive** (`mdv.v`): almacenamiento nativo del QL (equivalente al datasette/disco).
  Lee imágenes `.MDV` en formato QLAY (174 930 bytes exactos) cargadas por `ioctl`.
  Milestone 2, no milestone 1.
- **QL-SD** (`qlromext.v` + `sd_card` + PLL a 25MHz SPI): almacenamiento moderno
  vía tarjeta SD, mapeado como extensión de ROM. Fuera de milestone 1.
- **RTC**: `TIMESTAMP` (Unix time de 33 bits) entra directo desde `hps_io` al
  ZX8302 (`rtc_data`). En M2M habrá que ver qué fuente de tiempo real ofrece
  QNICE/Shell (a confirmar en Fase 7 — "Replace the HPS services").
- **Joysticks**: `js0`/`js1` de 5 bits cada uno, van directo al ZX8302 (el QL
  usa los puertos de joystick como entrada de teclado adicional/juegos). No
  imprescindible para milestone 1.

## 6. Lista de ficheros IN/OUT (borrador, según `files.qip` del core original)

Los 15 ficheros que Quartus compila realmente (`files.qip`) — este es el punto
de partida "IN" para la Fase 8 (proyecto Vivado):

```
rtl/T48/T8049.qip          (microcontrolador 8049 — OUT, ver decisión de teclado en sección 5/8)
rtl/fx68k/fx68k.qip        (CPU 68008 cycle-perfect — SystemVerilog) — SÍ, milestone 1
rtl/mgc_rom/mgc_rom.qip    (ROM GoldCard — FUERA de milestone 1)
rtl/rom_t49.vhd            (OUT, solo usado por T48)
rtl/sdram.sv               (controlador de SDRAM de Quartus — OUT, sustituido por HyperRAM/BRAM M2M)
rtl/dpram.v                (wrapper altsyncram — necesita reescritura Vivado-clean) — SÍ, milestone 1
rtl/qlromext.v             (QL-SD — FUERA de milestone 1, entra en milestone 3)
rtl/qimi.v                 (ratón — fuera de los 3 milestones definidos por ahora)
rtl/keyboard.v             (PS2 -> matriz QL — OUT tal cual; se reescribe como keyboard.vhd MEGA65-nativo, ver decisión de teclado)
rtl/ipc.v                  (integración keyboard.v + T48 — OUT, ver decisión de teclado)
rtl/mdv.v                  (microdrive — FUERA de milestone 1, entra en milestone 3)
rtl/zx8301.v               (vídeo — SÍ, milestone 1)
rtl/zx8302.v               (IO interno: microdrive/serie/RTC/interrupciones — SÍ, aunque de-featureando MDV/red hasta milestone 3)
rtl/ql_timing.sv           (timing de contended memory — SÍ, milestone 1; verificar compatibilidad con latencia de HyperRAM)
QL.sv                      (el emu — NO se porta tal cual, se reescribe como main.vhd)
```

Nuevo, no presente en el core original: `CORE/vhdl/keyboard.vhd` MEGA65-nativo
(sustituye a `keyboard.v + ipc.v + rtl/T48/`), siguiendo el patrón de
`C64MEGA65/CORE/vhdl/keyboard.vhd` y `AExp/CORE/vhdl/keyboard.vhd`.

Todo lo que está en `sys/` (framework MiSTer: `hps_io.sv`, `video_mixer.sv`,
`sdram` de MiSTer no confundir con `rtl/sdram.sv`, PLLs, scandoubler...) queda
**fuera** por definición — M2M ya tiene sus equivalentes.

## 7. Milestones (revisado en este hilo)

Se reestructuran en tres hitos, cada uno con un criterio de éxito verificable
en pantalla (S15 de la guía), de forma que memoria/velocidad y almacenamiento
no bloqueen el primer arranque:

### Milestone 1 — Arranque QL nativo sobre HyperRAM

**"El QL arranca en modo nativo (velocidad QL, PAL) hasta la pantalla/estado
inicial del sistema operativo cargado por SD, con salida de vídeo por HDMI y
teclado funcionando."** RAM principal ya implementada sobre HyperRAM (aunque
la configuración activa sea la más pequeña, 128KB, para simplificar el primer
bring-up). Sin microdrive, sin QL-SD, sin ratón, sin GoldCard/SMSQE, sin más
opciones de menú que reset y carga de ROM (F4). Se necesita elegir una ROM de
sistema operativo concreta para las pruebas (candidatas: JS-ROM, Minerva) —
pendiente de decisión (ver más abajo).

**Estado de las fases de Milestone 1 (actualizado 2026-07-28):** ver sección 0
(snapshot) y sección 9 (detalle fase a fase) — resumen: Fases 0-2 y 4 hechas,
Fase 3 parcial, Fases 5-7 en curso (bloqueante actual: instanciar
`fx68k`/`zx8301`/`zx8302` y la lógica de bus en `main.vhd`, la compilación
`M1001`), Fases 8-12 pendientes.

### Milestone 2 — Microdrive virtual (reordenado 2026-08-04, tercera vez: vuelve a ser microdrive)

**Historial de idas y venidas de este milestone** (para no perder el hilo):
memoria/velocidad → microdrive (cierre de M1) → QL-SD (2026-08-02, por coste
de implementación) → **microdrive de nuevo (2026-08-04, por dos problemas
reales encontrados implementando QL-SD)**. Ver `DECISIONES.md`, sección
"Milestone 2 — QL-SD pausado, pivote a microdrive", para el razonamiento
completo: las imágenes QXL.WIN reales (~50MB) no caben en la memoria
disponible (BRAM ni los 8MB de HyperRAM, compartidos con `ascal`) sin
streaming real desde la SD (sin precedente en este ecosistema M2M); y el
driver QL-SD ocupa la única Back ROM de forma permanente, sin dejar sitio a
otras ROMs de extensión (caso real: la ROM de Prospero Pascal del usuario).

**Por qué microdrive no tiene ninguno de esos dos problemas:**
- Cada imagen `.MDV` (formato QLAY) son 174930 bytes exactos (~171KB) — un
  par de unidades caben de sobra hasta en BRAM, sin tocar HyperRAM para
  nada al principio.
- Minerva trae soporte de `mdv1_`/`mdv2_` integrado en la propia ROM de
  sistema (confirmado en `M1040`) — no necesita ninguna Back ROM, así que
  no compite por ese slot con Prospero Pascal, TK2, ni nada más.

**Coste de implementación (recordatorio de la comparación original,
2026-08-02):** `mdv.v` no tiene interfaz LBA/direccionable — es un replay
continuo de un buffer entero a 200kbit/s, no encaja con `vdrives.vhd`. Hace
falta: soporte de escritura (no existe en el RTL original de `mdv.v`), un
`dpram` propio (BRAM primero, HyperRAM después), y una FSM de carga QNICE
nueva — sin poder reusar `vdrives.vhd` tal cual (a diferencia de QL-SD). El
patrón de escritura de AExp (`adf_mount_wrapper.vhd`+`adf_track_engine.vhd`:
HyperRAM + bitmap de pistas sucias + `HANDLE_CORE_IO`) es la referencia a
seguir para la parte de escritura, una vez la lectura funcione.

**Plan de implementación por fases (acordado 2026-08-04):**
1. Preparar el milestone: revisar/actualizar `.research/microdrive-read-design.md`
   con las lecciones de la sesión de QL-SD (sobre todo la aritmética de
   direcciones de HyperRAM, aunque no aplica hasta la fase 4 de este plan).
2. Un microdrive, solo lectura, en BRAM.
3. Driver de escritura (ahora que ya se lee).
4. Migrar el microdrive a HyperRAM.
5. Ampliar a 2, 3 o 4 unidades.

Diseño completo de la lectura en `.research/microdrive-read-design.md`
(pendiente de revisión antes de implementar, ver paso 1 arriba).

### Milestone 3 — Ampliación de memoria y velocidad

Los tres tamaños de RAM del requisito inicial (128k/640k/4096k, todos sobre
HyperRAM) seleccionables desde el menú OSD, más los modos de velocidad de CPU
(16MHz/24MHz/Full) — todos ellos ya presentes en el core original como
múltiplos del reloj base (sección 3), así que es principalmente exponer las
opciones de `config.vhd` y verificar que la HyperRAM aguanta el ancho de banda
a la velocidad más alta ("Full", 84 MHz de bus).

### Milestone 4 — QL-SD / QXL.WIN (pausado 2026-08-04, no cancelado)

Implementación real ya empezada y luego pausada (`M2001`-`M2003`, código
revertido) — ver `DECISIONES.md` para el razonamiento completo y todo lo
aprendido (incluida la causa raíz de direccionamiento HyperRAM encontrada en
`M2003`, y el problema sin resolver que quedó pendiente tras arreglarla).
Diseño completo en `.research/qlsd-design.md`/`qlsd-driver.md`, siguen
vigentes. Para retomarlo con imágenes de tamaño realista (~20-50MB, el
estándar del mundo QL) hace falta además resolver el streaming real desde
la SD (fase 2 del propio diseño, nunca empezada) — sin eso, solo sirven
imágenes de prueba pequeñas (unos pocos MB).

(GoldCard/SMSQE, el ratón, y el soporte de disquetera vía imágenes `.img`
DSDD de 720KB tipo Trump Card quedan sin hito asignado todavía —
investigado el 2026-08-04: el core `QL_MiSTer` no tiene absolutamente
ningún soporte de disquetera, ni siquiera como fichero sin usar - el propio
`readme.md` del core confirma que ni el driver de floppy de SMSQ/E está
implementado. Sería el hito más grande de los tres pendientes, ya que
habría que diseñar un controlador FDC completo y no hay ningún driver QDOS
conocido para reutilizar/portar - se revisará cuando los milestones
anteriores estén cerrados.)

## 8. Decisiones pendientes (para el usuario o para el arranque de Fase 4/5 en Claude Code)

1. **Fork real vs copia local — RESUELTA por ahora:** se sigue en local, sin fork
   público en GitHub. Recomendación aplicada: inicializar `git` LOCAL (sin
   remoto) tanto en `CoreQL/` como en `CoreQL/CORE/QL_MiSTer/` — dos repos
   separados, como pide la arquitectura M2M — antes de que Claude Code empiece
   a tocar RTL, para tener red de seguridad (commits pequeños, poder deshacer)
   desde el principio (S32/S34 de la guía). El fork público
   (`QL_MiSTerMEGA65`) queda pospuesto hasta que se quiera publicar, compartir,
   o traer arreglos del upstream (`git fetch upstream`) — añadir el remoto más
   adelante no obliga a rehacer el historial local.
2. **Teclado — RESUELTA:** se sustituye `keyboard.v + ipc.v + rtl/T48/` por un
   `keyboard.vhd` MEGA65-nativo que hable directamente el protocolo serie
   `comdata`/`comctrl` que espera el ZX8302, sin emular el microcontrolador
   Intel 8049. Justificación: es el mismo patrón que ya usaron tanto el port
   del C64 (ataca directamente la matriz de la CIA1, sin PS/2) como el del
   Amiga (`AExp/CORE/vhdl/keyboard.vhd`: sintetiza directamente el protocolo
   `kbd_mouse_data`/`kbd_mouse_type`/`kms_level` que la CIA-A espera, con
   handshake de flow-control, sin emular el microcontrolador de teclado real
   del Amiga). Ahorra portar todo `rtl/T48/` (un procesador completo en VHDL)
   a cambio de perder la fidelidad cycle-accurate del 8049 real, que no debería
   afectar al uso normal del teclado.
3. **ROM de sistema operativo para las pruebas — RESUELTA:** se usará **Minerva**
   como ROM de referencia para el bring-up de milestone 1.
4. **Revisión de placa MEGA65 — RESUELTA:** **R6**, confirmada físicamente por
   el usuario (sustituye la marca "provisional" de la Fase 0).
5. **Nombre definitivo del proyecto/repo** cuando se cree de verdad en GitHub
   (el proyecto ya se viene llamando "QL4M65" en `DECISIONES.md`).
6. **Compatibilidad de `ql_timing.sv` con la latencia de HyperRAM.** A verificar
   en Fase 6/9: si los wait-states que simula (`ram_delay_dtack`) siguen dando
   un timing correcto con la latencia real de HyperRAM, o si hace falta ajustar
   el modelo o añadir un pequeño buffer intermedio.

## 9. Fases de la Porting Guide aplicadas a QL4M65 (resumen ejecutivo)

Basado en la Parte II de `The-Ultimate-MiSTer2MEGA65-Porting-Guide.md`. Estado
actualizado el 2026-07-28 (ver sección 0 para el snapshot rápido y
`DECISIONES.md` para el detalle cronológico completo):

- **Fase 0 — Estudiar el core. HECHA.** Este mismo documento es el entregable.
  Catálogo de features, CONF_STR, reloj, memoria, periféricos y milestone 1
  ya están definidos arriba.
- **Fase 1 — Proyecto desde la plantilla. HECHA.** Bitstream del demo core de
  M2M sin modificar, sintetizado *dentro de `CoreQL/` concretamente* (no
  reutilizado de otra carpeta) y probado en hardware real (MEGA65 R6): arranca
  correctamente. Ver registro de pruebas en la sección 0.
- **Fase 2 — Fork del core y curación de la lista de ficheros. HECHA en parte.**
  El core está copiado en `CORE/QL_MiSTer/`, con su propio repo git local
  (commit `199bb0d`, snapshot íntegro de upstream sin modificar). La tabla
  IN/OUT preliminar está en la sección 6 de este documento. Sigue pendiente el
  fork público en GitHub (decisión pendiente #1, sin fecha todavía).
- **Fase 3 — Dejar el RTL "Vivado-clean". PARCIAL.** `rtl/dpram.v` no se ha
  reescrito línea a línea (no hace falta: `ql_rom`/`vram` no viven ahí, viven
  en `QL.sv`, que no se porta) — en su lugar, `ql_rom` ya está resuelto con el
  módulo `dualport_2clk_ram` del propio framework M2M (ver Anexo A de
  `DECISIONES.md`). `rtl/mgc_rom/mgc_rom.v` (GoldCard) sigue sin tocar, fuera
  de alcance de milestone 1. Falta barrer el resto de ficheros IN de la
  sección 6 en busca de más Quartus-ismos cuando se instancien de verdad
  (Fase 5).
- **Fase 4 — Relojes (`clk.vhd`). HECHA.** MMCM retargeteado a 84.000000 MHz
  exactos desde los 100 MHz de la placa (0 ppm de error, commit `9f0ba92`).
  Clock-enables internos (`ce_bus_p/n`, `ce_131k`, `ce_vid`, `ce_sd`, `ce_11m`)
  también hechos, portados literalmente del generador de `QL.sv` (commit
  `ce97f0c`).
- **Fase 5 — Cablear `main.vhd`. HECHA (M1001 conseguido).** `fx68k` + `zx8301`
  + `zx8302` (modificado para exponer el enlace IPC, ver Anexo B de
  `DECISIONES.md`) + `ql_timing` instanciados, con la lógica de bus/decodificación
  de direcciones de `QL.sv` traducida (simplificada al alcance de M1: sin
  GoldCard/QL-SD/microdrive/ratón). `keyboard.vhd` cableado de verdad al enlace
  IPC. Commit `389c8f0`. Pendiente: validar el protocolo IPC contra
  hardware/simulación real (sigue basado en desensamblado propio no
  contrastado externamente).
- **Fase 6 — Memorias (BRAM/QNICE/HyperRAM). CASI HECHA (BRAM, no HyperRAM
  todavía).** `ql_rom` (64KB, Minerva) y `vram` (64KB) instanciados y
  funcionando; RAM principal (128KB) también en BRAM por decisión explícita
  de esta sesión (bajar el riesgo de `M1001`, ver Anexo A de `DECISIONES.md`).
  HyperRAM de verdad para la RAM principal: pendiente, siguiente paso tras
  confirmar `M1001` en hardware (el maestro Avalon `hr_core_*` sigue atado a
  cero en `mega65.vhd`).
- **Fase 7 — Sustituir los servicios HPS. EN CURSO.** Carga de ROM (F4)
  resuelta vía el mecanismo de carga manual de QNICE (`C_DEV_QL_MINERVA`).
  RTC atado a cero por ahora (sin fuente de tiempo real todavía, no bloquea
  el arranque - ver sección 0). vdrives (QL-SD/MDV, milestone 3) sigue sin
  diseñar.
- **Fase 8 — Ficheros de proyecto Vivado. PARCIAL.** `fx68k`/`zx8301`/`zx8302`/
  `ql_timing.sv` añadidos a `CORE-R6.xpr` únicamente — los otros tres
  (R3/R4/R5) siguen sin tocar.
- **Fase 9-12 — Síntesis, timing, bring-up en hardware, release. EN CURSO.**
  Síntesis limpia conseguida (`M1001`: 0 errores, WNS=+0.130 ns, WHS=+0.051 ns).
  Falta el bring-up real en hardware (pendiente de que el usuario pruebe
  `QL4M65-CoreQL-M1001_r6.cor`). Milestone 2 añadirá las configs de
  640k/4096k y los modos de velocidad; milestone 3 añade microdrive y QL-SD.

---

## Estado de la carpeta `CoreQL/` (creada en este hilo, sin código modificado)

```
CoreQL/
 ├─ .research/
 │   └─ PORTING-PLAN.md          <- este documento
 ├─ CORE/
 │   ├─ QL_MiSTer/                <- copia de trabajo del core MiSTer-devel/QL_MiSTer (sin .git propio)
 │   ├─ vhdl/                     <- todavía son los ficheros de la plantilla M2M (democore); SIN TOCAR
 │   ├─ m2m-rom/                  <- firmware QNICE de la plantilla, sin adaptar aún al QL
 │   └─ CORE-R3/R4/R5/R6.xpr      <- proyectos Vivado de la plantilla, sin modificar
 ├─ M2M/                          <- framework M2M completo (QNICE incluido), sin tocar
 ├─ doc/                          <- plantillas de documentación de M2M (exceptions.md, file-headers.md, etc.)
 ├─ AUTHORS, README.md, VERSIONS.md, LICENSE  <- todavía con el texto de plantilla ("YOUR PROJECT NAME...")
 └─ .gitmodules                   <- apunta a QNICE-FPGA (framework), sin cambios
```

Nada de esto es todavía un repositorio git propio (no hay `.git` en `CoreQL/`).
Es una copia de trabajo local, tal como se decidió en este hilo.

---

## 10. Referencias externas

Documentación externa relevante para el hardware original del QL, a consultar
cuando haga falta el detalle de bajo nivel (registros exactos, esquemas,
matriz de teclado, temporización de microdrives, etc.) que no viene en el
código fuente del core MiSTer:

- **QL Service Manual (Manual de Servicio del QL)** — Thorn (EMI) Datatech
  Ltd. para Sinclair Research Ltd., octubre de 1985. Versión HTML en
  castellano: https://sinclairql.speccy.org/manuales/qlsm/
  Contenido relevante para este proyecto: descripción del sistema (CPU
  MC68008, IPC Intel 8049, organización de memoria, control de periféricos
  ZX8301/ZX8302/IC28, microdrives), diagramas de bloques, esquema del circuito
  (Issue 5 e Issue 6), diagrama de la matriz del teclado y detección de fallos
  en microdrives. Especialmente útil para contrastar el comportamiento real
  del IPC 8049 y de la matriz de teclado contra lo que asumimos al escribir
  `keyboard.vhd` (sección 5 y decisión 2 de este documento), y para el mapa de
  memoria y la semántica exacta de ZX8301/ZX8302 si el código del core deja
  dudas.
