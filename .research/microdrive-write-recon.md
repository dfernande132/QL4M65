# Milestone 2 fase B — Escritura en microdrive: FASE 1, reconocimiento

**Fecha:** 2026-08-11
**Estado del proyecto:** fase A (lectura) cerrada y publicada. Última build `M2020`. La siguiente
es `M2021`.
**Alcance decidido con el usuario:** MVP = **`SAVE` sobre un cartucho ya formateado**. `FORMAT`
queda fuera (se documenta lo que necesitaría, §8). Persistencia = **caché de sectores sucios con
volcado diferido**.
**Este documento no propone arquitectura** — sólo establece hechos verificados. El diseño está en
`microdrive-write-design.md`.

---

## 0. Resumen de hallazgos

1. **No hay nada que adoptar de upstream.** `rtl/mdv.v` de `MiSTer-devel/QL_MiSTer` master,
   descargado y comparado hoy, es **idéntico byte a byte** al nuestro. Cero soporte de escritura.
2. **El formato de escritura ya está completamente caracterizado**, y `md/write.asm` confirma de
   forma independiente el mapa de sector que se dedujo en fase A a partir de `mdv.v` y de las
   imágenes reales. No queda ingeniería inversa por hacer (§3).
3. **Corrección importante al planteamiento previo**: `assign tx_empty = 1'b0` (`mdv.v:70`) **no**
   significa "nunca indica preparado". El bit 1 del registro de estado es `pc..txfl` = *transmit
   buffer **FULL***, y `wbyte` espera a que valga **0**. Hoy el bit vale siempre 0 = siempre
   preparado: **la CPU no se bloquea nunca, escribe a toda velocidad contra un registro que no
   existe** (§2).
4. **La CPU escribe más rápido que la cinta**: produce un byte cada **140-220 ciclos** y la cinta
   consume uno cada **296**. Eso sería un problema si la escritura se emulara "en tiempo real",
   pero **no lo es** con el diseño posicional de la fase 2: cada par de bytes se confirma
   inmediatamente en su dirección canónica, así que no hay ninguna ranura que perder y `txfl`
   resulta innecesario. Detalle y consecuencias en §4.
5. **El problema central de la fase B es de ALINEACIÓN, no de velocidad.** Si se deja correr la
   temporización tal cual, el primer byte escrito cae **~11 palabras dentro** de la región de
   datos en vez de al principio, y toda la estructura queda desplazada. En hardware real esto no
   importa (el lector se sincroniza con el preámbulo); en `mdv.v` sí, porque su modelo es
   **posicional** (`mdv_gap_cnt` decide qué es preámbulo y qué es dato). Cuantificado en §5.
6. **QDOS verifica todas las escrituras por sí solo**, releyendo el sector en la vuelta siguiente
   (`bt.aver` → `md_verin`). Un `SAVE` que termina y no se repite indefinidamente **es** la prueba
   de round-trip (§6).
7. **Sí existe un patrón de escritura a SD reutilizable en el framework** (`f32_fopen`/`f32_fseek`/
   `f32_fwrite`/`f32_fflush`/`f32_fclose` en el monitor QNICE, más `HANDLE_DRV_WR` y el volcado
   diferido de `shell.asm`). Y existe un precedente en este mismo core de una acción de menú que
   escribe en la SD: "Extract Back ROM" (§7).

---

## 1. Comprobación de upstream (paso 1 de la fase 1: cerrado)

`https://raw.githubusercontent.com/MiSTer-devel/QL_MiSTer/master/rtl/mdv.v`, descargado el
2026-08-11, es **idéntico** a `CORE/QL_MiSTer/rtl/mdv.v`: mismo módulo, mismos puertos, misma
máquina de estados, y el mismo `assign tx_empty = 1'b0;`. El repo local (`dfernande132/QL_MiSTer`)
importó el original pristino en `199bb0d` (2026-07-28).

**Conclusión: la escritura hay que diseñarla e implementarla. No hay versión upstream que traer.**

---

## 2. Qué falta hoy en el RTL, con precisión

### 2.1 `zx8302.v` — el registro de datos de escritura no está decodificado

El registro donde Minerva deposita cada byte a escribir es **`pc_tdata = $18022`**
(`Minerva-source/inc/pc:30`), alcanzado como `lea tdoff(a3),a2` con
`tdoff equ pc_tdata-pc_mctrl` = 2 (`md/write.asm:22,61`).

En `zx8302.v`, `$18022` decodifica a `zx8302_addr = {cpu_addr(5), cpu_addr(1)} = 2'b11`
(`main.vhd:445`). Y el bloque de escritura de la CPU (`zx8302.v:150-178`) sólo contempla:

```verilog
150:  if(cpu_sel && cpu_wr) begin
152:     if (cpu_uds) begin
154:        if(cpu_addr == 2'b10)  mctrl <= cpu_din[15:8];      // $18020 PC_MCTRL
159:     if (cpu_lds) begin
162:        if(cpu_addr == 2'b01)  comdata_reg <= cpu_din[3:0]; // $18003 PC_IPCWR
173:        if(cpu_addr == 2'b10)  irq_mask/irq_ack             // $18021 PC_INTR
```

**No hay ninguna rama para `2'b11`.** Las escrituras a `pc_tdata` se descartan en silencio.
`$18022` es par → UDS → el byte viaja en `cpu_din[15:8]`.

### 2.2 `zx8302.v` — los bits de control de escritura no salen del chip

`mctrl` (`zx8302.v:120`) se captura entero, pero sólo se usan los bits 0 y 1 (cadena de selección,
`zx8302.v:344-349`). Los bits que gobiernan la escritura no se exponen:

| bit | nombre (`inc/pc:108-111`) | uso |
|---|---|---|
| 3 | `pc..eras` | borrado activo |
| 2 | `pc..writ` | escritura activa |
| 1 | `pc..sclk` | reloj de la cadena de selección (ya usado) |
| 0 | `pc..sel` | dato de la cadena de selección (ya usado) |

Valores que usa el driver (`inc/pc:113-117`):

```
pc.read  = $02   sclk=1                      leer / reposo
pc.selec = $03   sclk=1, sel=1               seleccionar
pc.desel = $02   sclk=1                      deseleccionar
pc.erase = $0A   sclk=1, eras=1              borrado on, escritura off
pc.write = $0E   sclk=1, eras=1, writ=1      borrado y escritura on
```

Nótese que **todos mantienen `sclk`=1**, así que ninguna operación de escritura puede desplazar
accidentalmente la cadena de selección (ya verificado en la ronda 2 del análisis de lectura).

### 2.3 `mdv.v` — sin puerto de datos, sin `txfl` real, sin escritura en el buffer

`mdv.v` no tiene entrada de datos de CPU, su `dpram` tiene el puerto A dedicado al cargador QNICE
(`dl_addr`/`dl_data`/`dl_wr`, `mdv.v:49-60`) y el puerto B es sólo lectura (`a_q_o => open` en
`mdv_dpram.vhd:59`).

### 2.4 Nota: `pc_tctrl` ($18002) tampoco está decodificado

`md_slave` (`md/slave.asm:29-30`) hace `moveq #pc.mdvmd,d0` / `jsr ss_wser` para poner el registro
de control de transmisión en **modo microdrive** antes de arrancar el drive; `pc_tctrl` = `$18002`
(`inc/pc:26`) y `pc.mdvmd = %00010000` (`inc/pc:63`). En `zx8302.v` ese registro tampoco se
decodifica (sería `cpu_addr == 2'b01` con UDS). Para el MVP basta con condicionar la escritura a
`mctrl[2]`, pero conviene dejarlo anotado: si algún día se implementa el puerto serie, `pc_tdata`
tendrá dos destinos y hará falta `pc_tctrl` para desambiguar.

---

## 3. Qué escribe Minerva, byte a byte

Fuente: `Minerva-source/md/write.asm` completo.

### 3.1 Las dos rutinas

| rutina | escribe | usada por |
|---|---|---|
| `md_wblok` (`:48`) | sólo preámbulo + cabecera de bloque + checksum | `FORMAT` (`md/formt.asm:147,150`) |
| `md_write` (`:24`) | preámbulo + cabecera de bloque + checksum, **y a continuación** preámbulo + 512 datos + checksum | `md_serve` (`md/serve.asm:222`) y `FORMAT` (`formt.asm:242`) |

### 3.2 Secuencia exacta de `md_write`

```
:25   move.b #pc.erase,(a3)     mctrl = $0A   borrado on
:26   delay  (3600-40)          3560 us  = 26.700 ciclos
:28   lea    4(sp),a1           a1 -> la palabra (fichero, bloque) apilada por md_serve
:29   moveq  #2-1,d1            ... de 2 bytes
      --- wr_init ---
:57   moveq  #pc.write,d0       mctrl = $0E   borrado + escritura on
:58   move.b d0,(a3)            (escrito DOS veces, :58 y :59)
:60   moveq  #pc..txfl,d6       d6 = 1  -> bit de estado a sondear
:61   lea    tdoff(a3),a2       a2 = $18022  registro de datos
:63   moveq  #9,d5              -> 10 bytes de cero
:64-69 wr_pream                 escribe d5+1 bytes de $00
:70-72                          escribe 2 bytes de $FF
:74   move.w #$0f0f,d3          inicializa el checksum
:76-80 wr_loop                  escribe d1+1 bytes desde (a1)+, acumulando en d3
:82-85                          escribe el checksum: LSB primero, luego MSB
      --- wr_rec (vuelve por a4) ---
:35   move.w #$1ff,d1           512 bytes
:36   moveq  #6-1,d5            -> 6 bytes de cero  (+2 de $FF)
      ... mismo wr_inpre/wr_loop con el buffer real ...
      --- end_wr ---
:41   moveq  #pc.read,d4        mctrl = $02
:44   delay  120                120 us = 900 ciclos
:45   move.b d4,(a3)            borrado y escritura off
```

`md_wblok` es igual pero termina en `end_wb` (`:52-54`), dejando `mctrl = pc.erase` en vez de
`pc.read`.

### 3.3 El mapa resultante, y por qué encaja exactamente con el que ya conocíamos

| escrito por | bytes | contenido |
|---|---|---|
| `wr_init` preámbulo | 12 | 10 × `$00` + 2 × `$FF` |
| `md_write` cabecera | 2 | nº fichero, nº bloque (de `md_map[sector]`) |
| checksum | 2 | `$0F0F` + suma, **LSB primero** |
| `wr_rec` preámbulo | 8 | 6 × `$00` + 2 × `$FF` |
| datos | 512 | el bloque |
| checksum | 2 | `$0F0F` + suma, LSB primero |
| **total** | **538** | = **269 palabras** |

Contrástese con el mapa de sector de 686 bytes deducido en fase A a partir de `mdv.v` y verificado
sobre imágenes reales (`Fase0/tools/README.md`):

```
[ 28.. 39]  12 B  preambulo   <- wr_init, "00 x10 ff ff"     ✓ coincide byte a byte
[ 40.. 41]   2 B  cab.bloque  <- md_write                     ✓
[ 42.. 43]   2 B  checksum    <- md_write                     ✓
[ 44.. 51]   8 B  "hueco PLL" <- wr_rec, "00 x6 ff ff"        ✓ NO es un hueco: es el preambulo del registro
[ 52..563] 512 B  datos       <- wr_rec                       ✓
[564..565]   2 B  checksum    <- wr_rec                       ✓
[566..685] 120 B  cola        <- NO se escribe nunca          ✓
```

**538 bytes escritos = exactamente `[28..565]`.** Y los 120 bytes de cola son justo lo que sobra:
la región de datos de `mdv.v` sirve 317 palabras y QDOS sólo lee 257 (`317-257 = 60` palabras
= 120 bytes). Todo cuadra. El "hueco de reset del PLL" que se nombró así en fase A queda
correctamente reidentificado como el preámbulo de 8 bytes de `wr_rec`.

**La cabecera de sector de 14 bytes (`[12..25]`) y su preámbulo (`[0..11]`) no se tocan nunca en
una escritura normal** — sólo `FORMAT` las escribe. Ésa es la razón estructural por la que sacar
`FORMAT` del MVP simplifica tanto el problema.

### 3.4 Correspondencia con la región de datos de `mdv.v`

Región de datos = `mdv_gap_cnt` 0..328 (329 palabras), con `mem_addr` avanzando una por palabra:

| `gap_cnt` | palabras | servido en lectura | escrito por `md_write` |
|---|---|---|---|
| 0..5 | 6 | no | preámbulo `wr_init` (12 B) |
| 6..7 | 2 | **sí** | cabecera de bloque + checksum (4 B) |
| 8..11 | 4 | no | preámbulo `wr_rec` (8 B) |
| 12..268 | 257 | sí | 512 datos + checksum (514 B) |
| 269..328 | 60 | sí (ignorado) | nada |

**El flujo de escritura es el espejo exacto del de lectura, palabra a palabra, empezando en
`gap_cnt = 0`.** Ésta es la propiedad que hace viable toda la fase B.

---

## 4. Presupuesto de tiempo real de la escritura

### 4.1 El bucle de sondeo

```
md/write.asm:
90  wbyte
91          btst    d6,(a3)      12+08   ¿listo para un byte?   (bit pc..txfl de $18020)
92          bne.s   wbyte        12/18   repite mientras el bit valga 1
93          move.b  d4,(a2)      12(08)  deposita el byte en $18022
94          rts                  32+32
```

- **Bucle de espera = 20 + 18 = 38 ciclos.**
- Minerva anota: un byte completo con el `bsr` cuesta **102-172 ciclos**, y el bucle `wr_loop`
  entero **140-220 ciclos (18.7-29.3 µs)** por byte (`:79-80`).
- La cinta consume un byte cada **8 bits × 37 ciclos = 296 ciclos = 39.5 µs**.

### 4.2 Por qué el desfase de ritmo NO se traduce en bytes perdidos

Sería un problema si el RTL emulara la escritura "al ritmo de la cinta": la CPU ofrecería ~2 bytes
por cada ranura y habría que descartar uno, o frenarla con `txfl`.

Pero el diseño de la fase 2 no pacea nada: cada par de bytes se escribe **en su dirección
canónica** (`region_base + índice_de_palabra`) en cuanto llega. Que la CPU vaya por delante de
`mem_addr` es irrelevante — las palabras acaban en su sitio igualmente. La única protección
necesaria es un límite de rango para no desbordar al sector siguiente.

Los 538 bytes se sueltan en 10-16 ms y la región de datos dura 26 ms: cabe con holgura en
cualquier caso.

### 4.3 La diferencia clave con el lado de lectura

En lectura, `rx_ready` es un **pulso de anchura fija** (37 ciclos) que la CPU tiene que cazar con
un bucle de 30 — de ahí el margen de 7 ciclos que costó tres rondas de investigación.

En escritura, `txfl` es un **nivel que la propia CPU limpia** al escribir el byte. No hay ventana
que perder: si el RTL pone "listo" y lo mantiene hasta que llegue el byte, la CPU no puede
fallarlo por tarde que llegue.

> **Regla de diseño que se deriva de esto: `txfl` debe implementarse como NIVEL, nunca como pulso.**
> Con nivel, los 38 ciclos del bucle son irrelevantes. Con pulso, harían falta ≥38 ciclos de
> anchura y volveríamos a tener un problema de margen igual que el de lectura.

### 4.4 Duración total de una sesión de escritura

- 538 bytes.
- Ritmo máximo de la CPU: 538 × 140 = **75.320 ciclos = 10.0 ms**.
- Ritmo mínimo de la CPU: 538 × 220 = **118.360 ciclos = 15.8 ms**.
- Si se pacea al ritmo de la cinta: 538 × 148 = **79.624 ciclos = 10.6 ms**
  (269 palabras × 78.9 µs = 21.2 ms de tiempo de cinta).
- Región de datos disponible: 329 palabras = **25.96 ms**.

**Cabe en los dos regímenes**, con holgura. La escritura no está limitada por el tiempo.

### 4.5 Contra `ql_timing`

`main.vhd:458` es `cpu_dtack <= not ram_delay_dtack;` y la instancia lleva desde `M2018`
`cpu_rom => cpu_rom or ql_io` (`main.vhd:613`, con `enable => '1'` en `:590`), que exime **toda** la E/S de `zx8302`
(`$018000-$01BFFF`) de esperar a la ventana de chunk de vídeo. Eso cubre por igual los sondeos
de `btst d6,(a3)` ($18020) y las escrituras `move.b d4,(a2)` ($18022).

**Verificado, no asumido: el arreglo de M2018 cubre el lado de escritura sin cambios.** Y como
además no hay ventana que cazar (§4.2, §4.3), el margen deja de ser un factor crítico.

---

## 5. El problema de la alineación (el hallazgo central de esta fase)

### 5.1 Cronología real, en microsegundos

Tomando como origen el instante en que empieza el hueco A (que es cuando salta la interrupción de
gap y arranca `md_serve`):

| t (µs) | evento | fuente |
|---|---|---|
| 0 | empieza hueco A (35 palabras) | `mdv.v:144` |
| 2760 | fin del hueco A, empieza la región de cabecera | 35 × 78.9 |
| ~2957 | `md_endgp` retorna (~197 µs tras el fin del hueco) | `md/endgp.asm:41-42` |
| 3233 | primer `rx_ready` de la cabecera (`gap_cnt` 6) | 6 × 78.9 |
| 3865 | `md_sectr` termina de leer sus 16 bytes | 8 × 78.9 |
| ~3965 | `md_serve` llega a la rama `write` | ~100 µs de trabajo |
| 3865 | fin de la región de cabecera, empieza el hueco B | 14 × 78.9 |
| ~3965 | `mctrl = pc.erase`, arranca `delay 3560` | `md/write.asm:25-26` |
| 6625 | fin del hueco B, **empieza la región de datos** | 3865 + 2760 |
| ~7525 | termina el `delay`, **se escribe el primer byte** | 3965 + 3560 |

> **El primer byte llega ≈ 900 µs = ~11.4 palabras DESPUÉS del inicio de la región de datos.**

### 5.2 Por qué esto no rompe el hardware real y sí rompería a `mdv.v`

En un microdrive de verdad el cabezal de borrado va físicamente por delante del de escritura; el
`delay 3560` compensa esa distancia. El lector se resincroniza con el **patrón** de preámbulo
(10 ceros + 2×$FF), no con una posición absoluta: la cinta es analógica y no tiene "índice".

`mdv.v`, en cambio, es **puramente posicional**: `mdv_gap_cnt` decide qué palabra es preámbulo,
cuál es cabecera y cuál es dato (`mdv.v:127`). Si los bytes se depositan 11 palabras tarde, la
cabecera de bloque cae en `gap_cnt` 17-18 en vez de 6-7 y el bloque de 512 empieza en 23 en vez
de 12 — y el camino de lectura, que sí es posicional, devolvería basura.

> **Conclusión obligatoria para la fase 2: la posición de escritura NO puede derivarse del momento
> en que llega cada byte. Hay que anclarla a la estructura.** Está desarrollado en
> `microdrive-write-design.md` §3.

### 5.3 Margen de la estimación

Los 900 µs son una estimación con ±200 µs de incertidumbre (el trabajo de `md_serve` entre
`md_sectr` y `md_write` no está anotado en ciclos). Da igual: **cualquier desalineación distinta
de cero rompe el modelo posicional**, así que la conclusión no depende de la precisión del número.
Nótese además que `mdv.v` modela los dos huecos con la misma duración (35 palabras) mientras que
su propio comentario (`mdv.v:86`) dice que en la realidad son de 2800 y 3400 µs — una razón más
para no fiarse de la temporización.

---

## 6. QDOS verifica sus propias escrituras

`md/serve.asm:221-227`:

```
write
        tst.b   d2                     ¿el drive sigue arrancando?
        bmi.s   anrts
        move.w  md_map(a5),-(sp)       apila (fichero, bloque) del mapa
        jsr     md_write(pc)
        addq.l  #2,sp
        moveq   #bt.aver,d0            estado -> "awaiting verify"
```

y en la vuelta siguiente, con `bt..rdvr` puesto, `md_serve` toma la rama `verify`
(`md/serve.asm:205-218`) → `md_verin` → `vblock`, que **relee el sector y compara byte a byte**;
si falla, `bt.updt` → se vuelve a escribir.

Consecuencias prácticas, muy útiles:

1. **El round-trip está integrado.** Si nuestro RTL escribe algo que el camino de lectura no
   devuelve idéntico, QDOS entrará en un bucle escribir→verificar→fallar→escribir **sin límite de
   reintentos** (recuérdese: `maxfail = 7` sólo aplica al sector de mapa, `md/serve.asm:135-140`).
   Un `SAVE` que se cuelga girando es la señal de "la escritura no cuadra con la lectura".
2. **Un `SAVE` que termina limpio es prueba de que el round-trip funciona**, sin necesidad de
   instrumentación adicional.
3. `md_map[sector]` es la fuente de la cabecera de bloque escrita — coincide con lo comprobado en
   fase A sobre imágenes reales (221/222 sectores de `quill` tenían la cabecera de bloque igual a
   su entrada de mapa).

---

## 7. Lo que ya existe para persistir en la SD

**Corrección al planteamiento previo**: sí hay patrón reutilizable, y hasta un precedente en este
mismo core.

### 7.1 Llamadas al sistema disponibles (monitor QNICE, `QNICE/monitor/qmon.asm:103-116`)

```
f32_fopen    -> FAT32$FILE_OPEN
f32_fread    -> FAT32$FILE_RB     leer un byte
f32_fseek    -> FAT32$FILE_SEEK   posicion de 32 bits; rechaza pasarse del EOF
f32_fwrite   -> FAT32$FILE_WB     escribir un byte en la posicion actual
f32_fflush   -> FAT32$FLUSH
f32_fclose   -> FAT32$CLOSE
```

`FAT32$FILE_RWB` (`fat32_library.asm:1119-1128`) documenta que lee/escribe **en la posición interna
actual** y avanza. Combinado con `f32_fseek`, permite **sobrescribir en el sitio** — exactamente lo
que necesita un volcado por sectores sucios. Como el `.mdv` ya existe y no cambia de tamaño, nunca
hay que extender el fichero.

### 7.2 Precedentes en el framework y en este core

- **`HANDLE_DRV_WR`** (`M2M/rom/shell.asm:1077`) y su volcado diferido (`_FC_FL`, `~:1275-1300`,
  que llama a `f32_fwrite` byte a byte) — el mecanismo con el que C64MEGA65 escribe en sus D64.
  El comentario de `shell.asm:1070-1076` describe literalmente la arquitectura elegida: caché en
  RAM y escritura física posterior.
- **"Extract Back ROM"** (`CORE/m2m-rom/m2m-rom.asm:177-243`) — un ítem de menú momentáneo
  (`OPTM_G_SINGLESEL`) tratado en el callback `OSM_SEL_POST`, con su `CLEAR_BACK_ROM` (`:216-241`)
  mostrando cómo QNICE accede a un dispositivo del core por la ventana de 4K
  (`M2M$RAMROM_DEV` / `M2M$RAMROM_4KWIN` / `M2M$RAMROM_DATA`). **Es la plantilla exacta para un
  ítem "Save mdv1".**
- Este repo llegó a cablear `vdrives.vhd` en `M2001` (revertido al pivotar de QL-SD a microdrive),
  así que hay precedente propio si se quisiera ir por esa vía.

### 7.3 Punto abierto para la fase 3

**¿Recuerda el Shell la ruta completa del `.mdv` cargado?** `CRTROM_MAN_LDF`
(`shell.asm:381`, `crts-and-roms.asm:33,481,512,565`) es un array de banderas "cargado/no cargado",
no la ruta. El **nombre mostrado** vive en `OPTM_HEAP` (`shell.asm:412-418`), pero es la etiqueta
del menú y puede venir recortada.

No lo doy por resuelto. Las dos salidas posibles, por orden de preferencia:

1. Localizar dónde `crts-and-roms.asm` abre el fichero y comprobar si conserva ruta+nombre
   completos en algún sitio reutilizable.
2. Si no, **capturarlo nosotros**: guardar la ruta en una variable propia de `m2m-rom.asm` en el
   momento de la carga (el callback `OSM_SEL_PRE`/`OSM_SEL_POST` ya se ejecuta ahí). Es unas pocas
   líneas y no depende de detalles internos del framework.

---

## 8. Alcance: qué entra y qué no

### Dentro del MVP

- `SAVE` (y cualquier otra operación de QDOS que acabe en `md_write`) sobre un cartucho **ya
  formateado y con sectores libres**.
- Escritura de la cabecera de bloque + los 512 bytes de datos + sus dos checksums, en la región de
  datos del sector que toque.
- El ciclo de verificación que hace QDOS solo.
- Marcado de sectores sucios y volcado al `.mdv` de la SD.

### Fuera del MVP (documentado para después)

- **`FORMAT`** (`md/formt.asm`). Necesitaría, además de todo lo anterior:
  - escribir las **cabeceras de sector** de 14 bytes con su preámbulo (`md_wblok`, llamado en
    `formt.asm:147,150`), es decir, escritura también en la región de cabecera (`gap_state = 0`);
  - `md_veril` (`md/read.asm:127-137`), la verificación de bloque largo de
    `2+2+8+512+86 = 610` bytes que usa el formateo;
  - generar el nombre de medio y el identificador aleatorio, y construir el mapa;
  - decidir qué significa "formatear" cuando el cartucho es un fichero de tamaño fijo en la SD.
  El diseño de la fase 2 deja el camino abierto (la escritura en la región de cabecera sale casi
  gratis si se generaliza el anclaje), pero **no se implementa ni se prueba**.
- **Escritura en `mdv2_`..`mdv8_`** (sigue habiendo una sola unidad).
- **El buffer en HyperRAM** (la antigua fase C). Se mantiene en BRAM.

---

## 9. Inventario de ficheros que tocará la fase 3

| fichero | repo | cambio previsto |
|---|---|---|
| `CORE/QL_MiSTer/rtl/zx8302.v` | QL_MiSTer | decodificar `$18022`, exponer `mctrl[3:2]` y el byte |
| `CORE/QL_MiSTer/rtl/mdv.v` | QL_MiSTer | **primera modificación de este fichero**: puerto de datos, `txfl`, escritura |
| `CORE/vhdl/main.vhd` | CoreQL | cableado, FSM de escritura, bitmap de sucios, lectura QNICE |
| `CORE/vhdl/mega65.vhd` | CoreQL | mapa de direcciones del dispositivo mdv1, CSR de volcado |
| `CORE/vhdl/globals.vhd` | CoreQL | constantes nuevas |
| `CORE/vhdl/config.vhd` | CoreQL | ítem de menú "Save mdv1" (`OPTM_SIZE` cambia) |
| `CORE/m2m-rom/m2m-rom.asm` | CoreQL | callback del ítem y rutina de volcado |
| `CORE/vhdl/mdv_dpram.vhd` | CoreQL | posiblemente, si se necesita otro puerto |
| `doc/m2m/exceptions.md` | CoreQL | **obligatorio**: documentar la desviación en `mdv.v` |
| `Fase0/tools/mdvcheck.py` | (fuera) | sin cambios; se usa tal cual para validar el `.mdv` volcado |

> Recordatorio del proyecto: `config.vhd`'s `OPTM_SIZE` cambia al añadir un ítem de menú, y eso
> invalida el fichero de configuración guardado en `/ql4m65/m2mcfg` (ya pasó en `M2001`).
