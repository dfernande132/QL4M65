# Milestone 5 — RAM principal a SDRAM

Estado: **diseño, sin código todavía** (2026-09-11).

## Objetivo

Llevar la RAM principal del QL de BRAM a la SDRAM física de la MEGA65 R6
(64 MB, `IS42S16320F-6BL`, hoy sin usar y con todos sus pines atados a
inactivo en `top_mega65-r6.vhd:557-567`), para:

1. Recuperar el tier de **1024k** borrado en `M4010` por presión de BRAM.
2. Llegar hasta el tier de **4096k** del core original.
3. Liberar ~160 tiles de BRAM (la RAM principal es hoy 160 de los 254 usados).

## Por qué esto no es repetir el fracaso del Milestone 3

`M3001`/`M3002` movieron la RAM principal a **HyperRAM** y colgaron en
hardware real. La conclusión que se sacó entonces —"la RAM principal de una
CPU pertenece a BRAM en este framework"— se apoyaba en tres precedentes
(AExp, C64MEGA65 y el wiki de M2M) que **hablan todos de HyperRAM**.

El core original de MiSTer hace exactamente lo contrario con SDRAM
(`QL.sv:363-391, 627-631, 687`): **toda** la RAM del QL —la base y los tiers
de 512k/768k/4096k— vive en SDRAM, con `sdram_dtack` parando al 68008 hasta
que el dato está listo. Lo que este port eliminó al no tener controlador fue
precisamente ese `sdram_dtack` (anotado en su día en la auditoría de
`main.vhd`, punto 2).

Además, `M3001`/`M3002` no tenían handshake de espera de ningún tipo: la
CPU no se paraba nunca. Eso solo no explica el cuelgue, pero es una
diferencia estructural de peso frente a lo que se propone aquí.

## Decisión de arquitectura: el controlador a 84 MHz, sin CDC

**Punto clave del diseño.** Hay dos controladores candidatos y no se parecen:

| | `QL_MiSTer/rtl/sdram.sv` | `MJoergen` (M2M V2.1.0) |
|---|---|---|
| Reloj | `clk_sys`, el mismo que la CPU | generic `G_CLOCK_SPEED_MHZ` |
| Lectura | caché de fila, a menudo **0 esperas** | **12 ciclos**, sin ráfagas |
| Escritura | `dtack` inmediato (*posted write*) | 8 ciclos |
| DTACK | especulativo, 2 ciclos antes del dato | `waitrequest` / `readdatavalid` |
| Integración M2M | ninguna | nativa, con patrón `G_BOARD` |

El de referencia es un controlador hecho a medida para este QL; el de
MJoergen es genérico pero está bendecido por el framework, mantenido, y ya
probado en los alphas del C64.

**Se usa el de MJoergen, pero corriéndolo a 84 MHz en `main_clk`.** Sus
constantes de tiempo se derivan del generic
(`C_TIME_INIT_POWER_ON := 102 * G_CLOCK_SPEED_MHZ`,
`C_TIME_REFRESH := G_CLOCK_SPEED_MHZ * 1000 * 64 / 8192 - 12`), así que 84
es tan válido como los 100 que usa el C64. Esto **elimina el CDC por
completo** y recupera la propiedad más importante del diseño original: la
SDRAM síncrona con la CPU.

Presupuesto de latencia resultante:

- 12 ciclos a 84 MHz = **143 ns** por lectura, sin CDC.
- Con CDC (`avm_fifo`, como HyperRAM) habrían sido ~200 ns. Se evita.

Contra el ciclo de bus del 68008 a cada velocidad:

| Velocidad | Ciclo de bus | 143 ns caben? |
|---|---|---|
| QL nativa (~7,5 MHz) | ~533 ns | sí, holgado |
| 16 MHz | ~250 ns | sí |
| 24 MHz | ~167 ns | justo |
| Full (~42 MHz) | ~95 ns | **no** — la CPU se parará |

**Expectativa honesta: Full speed se ralentizará.** Con `sdram_dtack`
degrada suavemente (la CPU espera) en vez de romperse, pero Match Point a
Full no irá como ahora. Es el precio de los 4 MB.

Mitigación a evaluar **con medidas, no a priori**: tiers pequeños
(128k/640k) en BRAM y grandes (1024k/4096k) en SDRAM, dejando que el
usuario elija velocidad o capacidad. Duplica la fontanería de RAM, así que
no se hace salvo que las medidas lo justifiquen.

## El punto de riesgo real: el camino de DTACK

Hoy:

```vhdl
cpu_dtack <= qlsd_dtack when qlsd_sel = '1' else not ram_delay_dtack;
```

`ram_delay_dtack` **no es un mecanismo de espera de memoria**: es la
emulación de contención del ZX8301 (`ql_timing.sv`), y sólo está activa a
velocidad nativa (`ql_timing_enable <= '1' when cpu_speed_sel = "00"`). A
16/24/Full, DTACK se concede de inmediato. Es decir: **hoy no existe
ningún camino por el que la CPU pueda esperar a la memoria**, porque BRAM
siempre responde en un ciclo.

Meter SDRAM obliga a crear ese camino, y es exactamente donde hay que tener
cuidado:

- Hay que reintroducir el equivalente de `sdram_dtack` y combinarlo como el
  original: `cpu_ram ? sdram_dtack && !ram_delay_dtack`.
- `fx68k` es un core ciclo-a-ciclo; hay que confirmar en qué momento
  muestrea DTACK y que tolera una latencia variable.
- Verificar el caso de acceso de 16 bits (`extra_access` en `ql_timing.sv`),
  que ya añade estados de espera propios.

## Plan de builds — un cambio por build

### `M5001` — el controlador dentro, sin tocar la RAM principal

Traer `sdram.vhd` (copia de `C64MEGA65/develop`, `M2M/vhdl/controllers/SDRAM/`),
sacar los pines SDRAM en `top_mega65-r6.vhd` y `framework.vhd`, e instanciarlo
a 84 MHz. **Como carga de prueba se mueve el buffer de montaje de QL-SD de
HyperRAM a SDRAM**: ya es un maestro Avalon, es tolerante a latencia, y tiene
una prueba de extremo a extremo que ya funciona.

- **Criterio de aceptación**: `qlx.win` sigue montando, arrancando y
  escribiendo igual que en `M4011b`. Si eso funciona, el controlador, los
  pines, el reloj y el arbitraje están bien.
- Riesgo bajo, y de paso libera 1 MB de HyperRAM.

### `M5002` — RAM principal en SDRAM, mismos tamaños

Mover `i_main_ram_lo`/`i_main_ram_hi` a SDRAM detrás del handshake de DTACK
nuevo, **manteniendo sólo 128k/640k**. Nada de tiers nuevos todavía.

- **Criterio de aceptación**: regresión completa contra `M4011b` — arranque
  de Minerva, microdrives (`LOAD`/`SAVE`), QL-SD, y las cuatro velocidades.
  Medir tiempos de carga reales a Full para cuantificar la pérdida.

### `M5003` — tiers de 1024k y 4096k

Ampliar `cpu_addr` de 21 a 22 bits (hoy `x"1FFFFF"`), añadir las entradas de
menú y la decodificación. `OPTM_SIZE`/`OPTM_DY` suben juntos, y `m2mcfg` hay
que regenerarlo — el bug histórico `M1046`/`M1047`.

- **Criterio de aceptación**: Minerva detecta el tamaño correcto en cada
  tier; un programa que necesite >640k (p.ej. `MyLISP`) funciona.

### `M5004` — fallback de R3

R3 no tiene SDRAM. Patrón `G_BOARD` del C64: R3 se queda con BRAM y
128k/640k, R6 usa SDRAM con hasta 4096k. Implica que el menú de RAM difiere
por placa.

## Cuestiones abiertas

1. ¿Corre el controlador de MJoergen correctamente a 84 MHz? Las constantes
   se derivan del generic, pero **sólo está probado a 100** (C64) y 166
   (banco de pruebas propio). Preguntar a MJoergen.
2. En R4/R5/R6 el framework de V2.1.0 le da la SDRAM al ascaler. ¿Cuánto
   queda? Aquí se parte de V2.0.1 (sin ascaler en SDRAM), así que de momento
   está toda libre, pero conviene saberlo antes de subir a V2.1.0.
3. ¿Merece la pena el híbrido BRAM/SDRAM por tier? Decidir con las medidas
   de `M5002`, no antes.
4. Este port no usa `rom_shadow` (el original mete la ROM en SDRAM al
   arrancar). No hace falta replicarlo, pero conviene tenerlo presente al
   leer `QL.sv`.

## Reglas de trabajo aplicables

- Sólo R6 en desarrollo; R3 sólo al publicar (o en `M5004`, que es
  específico de R3).
- Cada build real actualiza `DECISIONES.md`/`PORTING-PLAN.md` y se commitea
  en local; el push se pide aparte.
- CDC con primitivas `xpm_cdc_*` — aunque la gracia de este diseño es no
  necesitar ninguno en el camino de la RAM.
- Que simule no garantiza que sintetice ni que funcione en hardware.
- Test de aceptación permanente de `M4009`: cualquier `[Synth 8-3848]` sobre
  un net del módulo nuevo significa que no está conectado.
