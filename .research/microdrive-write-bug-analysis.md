# Fase B — Análisis del fallo de escritura de `M2023`: causa raíz encontrada

**Fecha:** 2026-08-15
**Veredicto:** una sola causa, determinista, reproducida en simulación, con arreglo de tres líneas.
**Y una admisión previa: el bug nació en el documento de diseño, no en la implementación.**
`microdrive-write-design.md` §3.4 declara `reg [8:0] wr_byte_cnt` con el comentario *"0..537 en una
sesion completa; 9 bits sobran"*. **Es falso: 2⁹ = 512 < 538.** Quien implementó copió fielmente
esa línea, comentario incluido. El error de aritmética es del diseño (mío); la implementación es
correcta respecto a lo que se le pidió.

---

## 1. La causa raíz

`rtl/mdv.v` (estado `M2023`):

```
235:  reg  [8:0]  wr_byte_cnt; // 0..537 en una sesion completa; 9 bits sobran   <-- FALSO
230:  wire [8:0]  wr_word_idx = wr_byte_cnt[8:1];
262:  wr_byte_cnt <= wr_byte_cnt + 9'd1;
270:  wr_addr <= region_base + {8'd0, wr_word_idx};
```

Una sesión `md_write` son **538 bytes** (16 de bloque-cabecera + 522 de registro, fase 1 §3.3).
Un contador de 9 bits cuenta 0..511 y **se desborda en el byte 512**:

| bytes del flujo | `wr_byte_cnt` | palabra escrita | debería ser |
|---|---|---|---|
| 0..511 | 0..511 | región 0..255 | región 0..255 ✓ |
| **512..537** (los 26 últimos) | **0..25 (wrap)** | **región 0..12 (¡otra vez!)** | región 256..268 |

Dos daños simultáneos, en **cada** sesión de escritura:

1. **Las palabras 0..12 de la región se sobrescriben** con la cola del bloque de datos — incluidas
   la **cabecera de bloque (palabra 6)** y su **checksum (palabra 7)**.
2. **Las palabras 256..268 nunca reciben su contenido** (los últimos 24 bytes de datos y el
   checksum del bloque) — conservan lo que hubiera antes.

Daño colateral que explica por qué ningún guardarraíl saltó: `wr_word_idx = wr_byte_cnt[8:1]` son
**8 bits efectivos** (máximo 255), así que `wr_in_range` (`idx < 329`) es **siempre verdadero** —
la protección contra desbordamiento quedó estructuralmente inerte por la misma anchura corta.

## 2. Reproducido en simulación (no es una conjetura)

Transcribí el acumulador de `mdv.v:229-276` **tal cual está en `M2023`** a Python
(`Fase0/tools/wrsim.py`), le alimenté el flujo exacto de 538 bytes de `md_write` (con los
checksums LSB-primero de `md/write.asm:82-85`) sobre la región de datos de un sector libre de
`empty1`, y le apliqué encima la validación de lectura de Minerva:

```
CNT_BITS=9:   cab.bloque MAL (leida: f4 f5, deberia 80 00)   datos MAL
              palabras mal colocadas: [0..12, 256..267]
              palabras 256..268 con contenido viejo: True
CNT_BITS=10:  cab.bloque OK   datos OK
```

**Con 9 bits, cada escritura corrompe el sector. Con 10, el round-trip es limpio.** La palabra 6
(cabecera de bloque) acaba conteniendo dos bytes de la cola del bloque de datos — basura
determinista, distinta según el contenido, imposible de verificar.

## 3. Por qué esto explica todos los síntomas de `M2023`, uno a uno

Antes, las dos respuestas de Minerva que pedía el handoff (preguntas 2 y 3):

- **"El sector de mapa"** es el **sector 0**: su región de datos contiene el mapa del cartucho
  (`md_map`, 255 palabras + `md_lsect` = 512 bytes exactos, `inc/md:16-17`), escrito como fichero
  de bloque-cabecera `$80`/`$F8`. Cuando hay medio nuevo, `md_serve` hace `tst.b d7; bne anrts` y
  sólo con **sector 0** llama a `go_read` para cargar el mapa (`md/serve.asm:117-121`) — y ese es
  el camino protegido por `maxfail=7` (`:135-140`).
- **Un `SAVE` sobre cartucho vacío escribe al menos TRES cosas**: los bloques de datos del fichero,
  el **directorio** (fichero 0 — otro bloque de datos normal), y el **MAPA**
  (`dd/mdvbu.asm:269`: `move.w #-1,md_pendg` → `md/serve.asm:154-160`:
  `move.w #mapfile<<8+0,-(sp); jsr md_write` **sobre la región de datos del sector 0**).

Con eso, la cadena completa:

| Síntoma observado | Explicación |
|---|---|
| `SAVE` termina con *"bad or changed medium"* a los ~30-50 s | Todas las escrituras fallan la verificación (palabra 6/7 corruptas) → reintento sin límite. Pero **cada vuelta de cinta pasa por el sector 0 con operaciones pendientes**, y ahí `md_fail` incrementa (`md/serve.asm:137`); sólo se limpia cuando una operación pendiente **triunfa** (`:212`), cosa que nunca ocurre → a las ~7 vueltas (~8.3 s/vuelta con los huecos), `err_fe` → error. **Tu hipótesis del `maxfail=7` era correcta, con este mecanismo debajo.** |
| `DIR` falla **después** del `SAVE` | El `SAVE` incluyó la escritura del **mapa** → la región de datos del **sector 0** quedó corrupta en el buffer → el reconocimiento de medio (`go_read` del mapa) falla → `maxfail=7` → mismo error, misma ventana temporal. |
| Recargar la imagen restaura `DIR` | La recarga restaura el mapa pristino del fichero. |
| El siguiente `SAVE` vuelve a fallar | El wrap es determinista: pasa en el byte 512 de **cada** sesión. |
| `DIR` sobre chess funciona entre medias | La lectura no está tocada; sólo corrompe quien escribe. |
| 100% reproducible | No hay ningún elemento probabilístico en el mecanismo. |

También cierra la **pregunta 1** del handoff (¿puede `region_base` anclar al sector equivocado?):
no hace falta — el ancla es correcta; es el **índice** el que da la vuelta y reescribe el principio
de la región correcta. Y la **pregunta 4** (¿algo específico del primer `SAVE` a un cartucho
vacío?): no; fallaría igual en uno poblado. Lo que el cartucho vacío hace es garantizar que el
mapa se escribe (asignación de sectores nuevos) y que el fallo de `DIR` posterior sea visible.

Nota sobre `M2022` vs `M2023`: en `M2022` el bug del strobe (11 pulsos/byte) desbordaba el
contador ~11 veces más rápido y de forma más caótica — de ahí el cuelgue eterno sin llegar nunca
al patrón limpio de `maxfail`. El arreglo de `M2023` fue real y necesario; simplemente destapó
esta segunda avería, más abajo.

## 4. El arreglo (`M2024`)

`rtl/mdv.v`, tres líneas:

```verilog
// linea 235 - un bit mas: 0..537 necesita 10 bits (2^9=512 < 538)
reg  [9:0]  wr_byte_cnt;

// linea 230 - el indice de palabra, con la anchura nueva: 0..268
wire [9:0]  wr_word_idx = wr_byte_cnt[9:1];

// linea 231-233 - las comparaciones pasan a 10 bits (y ahora SI protegen algo)
wire        wr_in_range = region_state
                        ? (wr_word_idx < 10'd329)
                        : (wr_word_idx < 10'd14);

// linea 262 - el incremento, a juego
wr_byte_cnt <= wr_byte_cnt + 10'd1;

// linea 270 - la suma, a juego
wr_addr <= region_base + {7'd0, wr_word_idx};
```

Con 10 bits el contador llega a 1023 sin dar la vuelta, `wr_word_idx` cubre 0..511, y
`wr_in_range` se convierte por primera vez en una protección real (una sesión anómala de más de
658 bytes se descartaría en vez de envolver).

**Verificación previa a la build, sin hardware:** `python3 Fase0/tools/wrsim.py` — debe decir
`CNT_BITS=10: cab.bloque OK / datos OK`. Ya lo dice.

**Criterio de aceptación en hardware:** el mismo de la etapa 1 (diseño §8): `SAVE mdv1_prueba`
termina, `DIR` lo ve, `LOAD mdv1_prueba` carga, y la regresión de lectura de fase A pasa.

## 5. Corrección aplicada al documento de diseño

`microdrive-write-design.md` §3.4 queda corregido (anchura 10 bits y comentario arreglado) para
que nadie vuelva a copiar el error. La lección para el registro de riesgos, si se quiere anotar:
*los comentarios de anchura de contadores en un documento de diseño son código — se copian tal
cual, así que hay que verificarlos con la misma seriedad que el RTL*.

## 6. Estado de las demás verificaciones del handoff

Todo lo que el implementador re-verificó a mano (orden de bytes, anclaje D1, `region_state`,
atomicidad del mux, cobertura de `wr_in_range` "en operación normal") **era correcto** — lo
confirmo de forma independiente y la simulación lo respalda: con el contador ancho, la sesión
completa aterriza perfecta. El único fallo era la anchura. La detección de flanco de `M2023`
también es correcta y debe quedarse.
