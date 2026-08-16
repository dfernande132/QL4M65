# Milestone 2 fase B — Escritura en microdrive: FASE 2, diseño de arquitectura

**Fecha:** 2026-08-11
**Prerrequisito:** leer antes `microdrive-write-recon.md` (fase 1). Este documento **da por
establecidos** todos los hechos de allí y no los repite.
**Destinatario:** modelos de codificación que implementarán la fase 3.
**Alcance:** `SAVE` sobre cartucho formateado. `FORMAT` fuera. Persistencia por sectores sucios
con volcado diferido.

---

## 1. Principio rector

> **La escritura es el espejo posicional de la lectura.**
>
> `md_write` deposita exactamente 538 bytes = 269 palabras, y esas 269 palabras se corresponden
> una a una con las palabras `gap_cnt` 0..268 de la región de datos que `mdv.v` ya recorre al leer.
> No hay que inventar un formato ni una temporización: hay que **colocar los bytes en las
> posiciones canónicas** de la región, ignorando cuándo llegan.

De ahí salen las tres decisiones estructurales del diseño:

| # | Decisión | Motivo (fase 1) |
|---|---|---|
| **D1** | La dirección de escritura se **ancla a la base de la región**, no al `mem_addr` instantáneo | §5: el primer byte llega ~11 palabras tarde |
| **D2** | **Sin control de flujo**: `tx_empty` sigue en `1'b0` (siempre listo) | §4.2: al ser posicional la escritura, que la CPU vaya por delante de la cinta no pierde nada; y un `txfl` como pulso reintroduciría el problema de margen de la fase A |
| **D3** | Toda la lógica de escritura vive **dentro de `mdv.v`** | Es donde están `mem_addr`, `gap_cnt`, `gap_state` y la instancia de la RAM; repartirla obligaría a exportar media máquina de estados |

---

## 2. Vista de conjunto

```
   ┌── dominio clk_main_i (84 MHz) ───────────────────────────────────────────┐
   │                                                                          │
   │  fx68k ── $18022 write ──► zx8302.v ── mdv_wr_data[7:0] ──►┐             │
   │           $18020 write ──►  (mctrl)  ── mdv_wr_en (bit 2) ─►│            │
   │                                      ── mdv_er_en (bit 3) ─►│            │
   │                                                             ▼            │
   │                                                     ┌───────────────┐    │
   │                                                     │    mdv.v      │    │
   │                                                     │  (MODIFICADO) │    │
   │  main.vhd ── dl_addr/dl_data/dl_wr ────────────────►│  puerto A RAM │    │
   │  main.vhd ◄── dl_q[15:0] ───────────────────────────│  (mux interno)│    │
   │  main.vhd ◄── sector[7:0], wr_commit ───────────────│               │    │
   │      │                                              └───────────────┘    │
   │      ▼                                                                   │
   │  dirty_bitmap[255:0]                                                     │
   │      │                                                                   │
   └──────┼───────────────────────────────────────────────────────────────────┘
          │  xpm_cdc_handshake  (x2 nuevos: peticion de lectura y respuesta)
   ┌──────▼───────── dominio qnice_clk_i (50 MHz) ────────────────────────────┐
   │  mega65.vhd  ── mapa de direcciones del dispositivo mdv1 ──► QNICE       │
   │  m2m-rom.asm ── item de menu "Save mdv1" ──► volcado con f32_fwrite      │
   └──────────────────────────────────────────────────────────────────────────┘
```

---

## 3. `mdv.v` — el corazón del diseño

**Ésta es la primera modificación de `rtl/mdv.v` desde que se importó el core pristino.**
Obligatorio documentarla en `doc/m2m/exceptions.md`.

### 3.1 Puertos nuevos

```verilog
module mdv
(
   input        clk,
   input        ce,
   input        reset,
   input        reverse,
   input        sel,

   output       gap,
   output       tx_empty,
   output       rx_ready,
   output [7:0] dout,

   // ---- QL4M65 fase B: canal de escritura desde la CPU ----
   input        wr_en,        // nivel: mctrl[2] (pc..writ) ya sincronizado al dominio del core
   input        wr_strobe,    // pulso de 1 ciclo de clk por cada byte que la CPU escribe en $18022
   input  [7:0] wr_data,      // el byte
   output [7:0] sector,       // indice del sector bajo el cabezal, 0..254
   output       wr_commit,    // pulso de 1 ciclo de clk por cada PALABRA confirmada en la RAM

   // ram interface to read image
   input        download,
   input [16:0] dl_addr,
   input [15:0] dl_data,
   input        dl_wr,
   output [15:0] dl_q         // ---- QL4M65 fase B: lectura del buffer para el volcado ----
);
```

`tx_empty` **no cambia**: sigue siendo `assign tx_empty = 1'b0;`. Ver D2 y §3.7.

### 3.2 Anclaje de la región (D1)

`mem_addr` no avanza durante los huecos (`mdv.v:141-149` sólo incrementa en la rama
`else`, `:151`). Por tanto, durante todo un hueco `mem_addr` **es ya la dirección de la primera
palabra de la región que viene**. Basta con capturarla continuamente mientras dure el hueco:

```verilog
reg [16:0] region_base;
reg        region_state;      // copia de mdv_gap_state al empezar la region

// dentro del  if(ce) ... if(!mdv_clk_cnt) ... if(mdv_bit_cnt == 15)  ya existente,
// junto al resto de la logica de gap:
if (mdv_gap_active) begin
    region_base  <= mem_addr;        // constante durante todo el hueco
    region_state <= !mdv_gap_state;  // el estado que tendra la region que viene
end
```

Cuando el hueco termina, `region_base` queda congelado con la dirección correcta durante toda la
región. Sin restas, sin divisiones, sin condiciones de carrera.

> **Nota sobre `region_state`**: en el instante del `gap_cnt == 34` el RTL hace
> `mdv_gap_state <= !mdv_gap_state` (`mdv.v:147`), así que el estado de la región entrante es el
> **complemento** del valor actual. `region_state = 0` → región de cabecera (14 palabras);
> `region_state = 1` → región de datos (329 palabras). El MVP sólo necesita la de datos, pero
> registrar el estado sale gratis y deja `FORMAT` a un paso.

### 3.3 Contador de sector

```verilog
reg [7:0] mdv_sector;

// en el mismo bloque, junto a las dos ramas ya existentes:
if (mem_addr > mdv_end)                              mdv_sector <= 8'd0;   // wrap de cinta
else if (!mdv_gap_active && mdv_gap_state && mdv_gap_cnt == 328)
                                                     mdv_sector <= mdv_sector + 8'd1;

assign sector = mdv_sector;
```

Comprobación de fase: tras `download`, `mdv_gap_state = 1` y `mdv_gap_active = 1`; al acabar ese
primer hueco `mdv_gap_state` pasa a 0, así que **la primera región es la de cabecera del sector 0**
y `mdv_sector` debe valer 0 ahí. ✓

### 3.4 Acumulador de bytes y confirmación

```verilog
// CORREGIDO tras M2023 (ver microdrive-write-bug-analysis.md): la version
// original de este documento decia "[8:0] ... 9 bits sobran" - FALSO,
// 2^9 = 512 < 538: el contador daba la vuelta en el byte 512 de cada
// sesion y reescribia las palabras 0..12 de la region (cabecera de bloque
// incluida) con la cola del bloque de datos. 0..537 necesita 10 bits.
reg  [9:0] wr_byte_cnt;   // 0..537 en una sesion completa; 10 bits (¡no 9!)
reg  [7:0] wr_byte_hi;    // primer byte del par
reg        wr_pending;    // hay medio par acumulado
reg        wr_do;         // pulso: hay una palabra que confirmar
reg [16:0] wr_addr;
reg [15:0] wr_word;

wire wr_session = wr_en && mdv_present;   // nunca escribir sin cartucho ni sin unidad seleccionada
wire [9:0] wr_word_idx = wr_byte_cnt[9:1];
wire wr_in_range = region_state
                 ? (wr_word_idx < 10'd329)     // region de datos
                 : (wr_word_idx < 10'd14);     // region de cabecera (solo FORMAT)

always @(posedge clk) begin
    wr_do <= 1'b0;

    if (!wr_session) begin
        wr_byte_cnt <= 10'd0;     // cada sesion empieza de cero
        wr_pending  <= 1'b0;
    end
    else if (wr_strobe) begin
        wr_byte_cnt <= wr_byte_cnt + 10'd1;
        if (!wr_pending) begin
            wr_byte_hi <= wr_data;         // byte alto: el primero del par (mdv.v:88)
            wr_pending <= 1'b1;
        end
        else begin
            wr_pending <= 1'b0;
            if (wr_in_range) begin
                wr_addr <= region_base + {7'd0, wr_word_idx};
                wr_word <= {wr_byte_hi, wr_data};
                wr_do   <= 1'b1;
            end
        end
    end
end

assign wr_commit = wr_do;
```

**Orden de bytes**: `mdv.v:88` sirve `mdv_data[15:8]` primero, así que el **primer** byte de cada
par es el **alto**. Idéntico al criterio del cargador QNICE
(`main.vhd`: `mdv1_ld_word_data <= mdv1_ld_byte0 & data(7 downto 0)`).

**Paridad**: Minerva siempre escribe un número par de bytes por sesión (12+2+2 = 16 y 8+512+2 = 522;
`md_wblok` escribe 16). Si al terminar la sesión quedara un byte suelto, **se descarta**. No hacer
nada más: es un caso que no ocurre y silenciarlo evita escribir basura.

### 3.5 Multiplexor del puerto A de la RAM

`mdv.v` instancia la RAM (`mdv.v:49-60`). El puerto A hoy es del cargador. Ahora tiene tres
usuarios; se resuelve con un mux de prioridad dentro de `mdv.v`:

```verilog
wire [16:0] pa_addr = wr_do ? wr_addr : dl_addr;
wire [15:0] pa_data = wr_do ? wr_word : dl_data;
wire        pa_wren = wr_do | dl_wr;

dpram #(17, 88000) vram
(
    .wrclock(clk),
    .wraddress(pa_addr),
    .wren(pa_wren),
    .byteena_a(2'b11),
    .data(pa_data),
    .q_a(dl_q),            // <-- NUEVO: lectura del puerto A para el volcado
    .rdclock(clk),
    .rdaddress(mem_addr),
    .q(mdv_din)
);
```

Prioridad: **confirmación de escritura > cargador/volcado**. Nunca coinciden en la práctica
(cargar y reproducir son excluyentes), pero un volcado sí puede solaparse con escrituras del QL, y
en ese caso es preferible perder un ciclo de volcado (que QNICE reintenta, está en espera) que
perder un dato escrito.

`mdv_dpram.vhd` necesita exponer `q_a` (hoy `a_q_o => open`, `mdv_dpram.vhd:59`) y añadir el puerto
`q_a` a la entidad `dpram`. **La instancia Verilog conecta por nombre**, así que el orden no
importa, pero la entidad VHDL y la instancia deben coincidir en nombres.

### 3.6 `mdv_end` y `mdv_present`

`mdv_end` **no se toca**: una escritura normal nunca cambia el tamaño del cartucho. `wr_session`
ya exige `mdv_present` (`mdv.v:91` = `sel && mdv_end != 0`), así que sin cartucho no se escribe
nada.

### 3.7 Por qué NO se implementa `txfl` de verdad (D2)

Con este diseño el RTL acepta bytes al ritmo que sea: no hay cola, cada par se confirma en el ciclo
siguiente. `tx_empty = 1'b0` (bit `pc..txfl` = 0 = "no lleno" = listo) es, por tanto, **la respuesta
correcta**, no un valor provisional. El bucle `wbyte` (`md/write.asm:90-94`) nunca gira: la CPU
tarda 10-16 ms en soltar sus 538 bytes y la región dura 26 ms (fase 1 §4.2, §4.4).

Que el flujo vaya más rápido que la cinta **no importa**, porque las direcciones son posicionales:
las palabras acaban en su sitio aunque `mem_addr` ya haya pasado por ahí. La única protección
necesaria es `wr_in_range`, que impide desbordar al sector siguiente.

*Refinamiento opcional, fuera del MVP:* si algún día se quiere fidelidad de ritmo (o soportar
software que no sea QDOS), `tx_empty` pasaría a ser un **nivel** que sube al aceptar un byte y baja
al llegar la siguiente ranura de byte de la cinta. **Nunca un pulso** — sería reintroducir
exactamente el problema de margen de la fase A.

---

## 4. `zx8302.v` — decodificación del registro de datos

### 4.1 Puertos nuevos

```verilog
    output [7:0]   mdv_wr_data_o,   // byte escrito en pc_tdata ($18022)
    output         mdv_wr_strobe_o, // 1 tick de cen por escritura
    output         mdv_wr_en_o,     // mctrl[2]  pc..writ
    output         mdv_er_en_o,     // mctrl[3]  pc..eras  (por ahora solo observabilidad)
```

### 4.2 Captura del byte

Dentro del bloque `else if(cen)` que ya existe (`zx8302.v:145-179`), en la rama `if (cpu_uds)`
(`$18022` es par → UDS → dato en `cpu_din[15:8]`):

```verilog
    if (cpu_uds) begin
        if(cpu_addr == 2'b10)
            mctrl <= cpu_din[15:8];
        // QL4M65 fase B: pc_tdata ($18022) - registro de transmision.
        if(cpu_addr == 2'b11) begin
            mdv_wr_data  <= cpu_din[15:8];
            mdv_wr_pulse <= 1'b1;
        end
    end
```

`mdv_wr_pulse` debe volver a `0` en el siguiente `cen`; con `mdv_wr_pulse <= 1'b0;` al principio
del bloque `else if(cen)` basta.

> **Trampa de un ciclo de bus**: el bloque está gateado por `cen`, pero un ciclo de bus del 68000
> abarca **varios** ticks de `cen` con `cpu_sel`/`cpu_wr` estables. Tal cual, un solo `move.b`
> generaría **varios** pulsos y se escribirían bytes duplicados.
>
> **Obligatorio: detectar el flanco.** Registrar `prev_wr_sel <= cpu_sel && cpu_wr && cpu_uds &&
> (cpu_addr == 2'b11)` en `cen` y pulsar sólo en el flanco de subida. Éste es el error más
> probable de toda la fase 3; si aparecen bytes duplicados en el `.mdv`, mirar aquí primero.

### 4.3 Salidas de control

```verilog
assign mdv_wr_en_o     = mctrl[2];   // pc..writ
assign mdv_er_en_o     = mctrl[3];   // pc..eras
assign mdv_wr_data_o   = mdv_wr_data;
assign mdv_wr_strobe_o = mdv_wr_pulse;
```

`mctrl` no tiene reset (igual que en el original). No pasa nada: los FF arrancan a 0 por `INIT`, y
`mctrl[2] = 0` significa "no escribir", que es el estado seguro.

### 4.4 Sobre `pc_tctrl` ($18002)

Fuera de alcance (fase 1 §2.4). Si en el futuro se implementa el puerto serie, `pc_tdata` tendrá
dos destinos y habrá que decodificar `pc_tctrl` para desambiguar. Anotarlo en `exceptions.md`.

---

## 5. `main.vhd` — cableado y bitmap de sucios

### 5.1 Cableado

```vhdl
   i_zx8302 : entity work.zx8302
      port map (
         ...
         mdv_wr_data_o   => mdv1_wr_data,
         mdv_wr_strobe_o => mdv1_wr_strobe,
         mdv_wr_en_o     => mdv1_wr_en,
         mdv_er_en_o     => mdv1_er_en,
      );

   i_mdv1 : entity work.mdv
      port map (
         ...
         wr_en      => mdv1_wr_en,
         wr_strobe  => mdv1_wr_strobe,
         wr_data    => mdv1_wr_data,
         sector     => mdv1_sector,
         wr_commit  => mdv1_wr_commit,
         dl_q       => mdv1_dl_q
      );
```

Los cuatro caminos son intra-dominio (`clk_main_i`): **no hay CDC aquí**.

**Cuidado con `mdv1_output_reg`** (`main.vhd:1047`, registro extra de M2015): registra
`gap/tx_empty/rx_ready/byte` en la dirección mdv1→zx8302. Las señales nuevas van en la dirección
**contraria** (zx8302→mdv1) y **no deben pasar por ese registro**. Si el timing lo pidiera, añadir
un registro propio, simétrico, y anotarlo.

### 5.2 Bitmap de sectores sucios

```vhdl
signal mdv1_dirty : std_logic_vector(255 downto 0) := (others => '0');

   p_dirty : process (clk_main_i)
   begin
      if rising_edge(clk_main_i) then
         if mdv1_dirty_clear = '1' then            -- desde el dominio QNICE, ver 6.2
            mdv1_dirty <= (others => '0');
         elsif mdv1_wr_commit = '1' then
            mdv1_dirty(to_integer(unsigned(mdv1_sector))) <= '1';
         end if;
      end if;
   end process;
```

256 flip-flops y un decodificador. Marcar por **palabra confirmada** en vez de por sesión es más
simple y estrictamente correcto (marca de más sólo si hubiera una sesión a caballo entre dos
sectores, que no puede ocurrir porque `wr_in_range` lo impide).

`mdv1_dirty_clear` cruza de QNICE al core: **`xpm_cdc_single`** (regla del proyecto; ver
`DECISIONES.md` M2011/M2012 y la memoria `feedback_cdc_use_xpm_primitives.md`).

---

## 6. El camino de vuelta a QNICE

### 6.1 Mapa de direcciones del dispositivo `C_DEV_QL_MDV1` (`x"0103"`)

| rango de dirección de byte QNICE | acceso | significado |
|---|---|---|
| `0x0000000..0x002AB11` | escritura | carga de la imagen (**existente, sin cambios**) |
| `0x0000000..0x002AB11` | **lectura** | **NUEVO**: leer un byte del buffer, para el volcado |
| `0x0030000..0x003001F` | lectura | **NUEVO**: bitmap de sucios, 32 bytes. Byte *m*, bit *n* = sector *m*·8+*n* |
| `0x0030020` | escritura | **NUEVO**: escribir cualquier valor limpia el bitmap entero |
| `0xFFFF000..0xFFFFFFF` | ambos | CSR del framework (**existente**, `qnice_csr.vhd`) |

La ventana de 4K del framework (`M2M$RAMROM_4KWIN`) hace que `0x30000` sea la ventana 48. El rango
del bitmap está muy por encima de `C_MDV1_MAX_BYTES` (174930 = `0x2AB12`) y muy por debajo del CSR:
no hay solape posible.

### 6.2 Extensión del proceso `mdv1_loader_qnice`

Hoy `main.vhd` sólo maneja escrituras. Hay que añadir la rama de lectura, con la **misma disciplina
que ya funciona**:

- `qnice_mdv1_wait_o <= mdv1_ld_busy;` — se mantiene, y ahora `mdv1_ld_busy` también cubre la
  lectura. **Nunca meter `qnice_mdv1_ce_i`/`we_i`/`addr_i` "en vivo" en la fórmula del wait**
  (M2006: cuelgue permanente garantizado).
- Dos `xpm_cdc_handshake` nuevos:
  1. **petición** (QNICE → core): 17 bits de dirección de palabra.
  2. **respuesta** (core → QNICE): 16 bits del dato leído.
- En el lado del core, un proceso pequeño: al recibir la petición, poner `mdv1_dl_addr` (con
  `dl_wr = '0'`), esperar **2 ciclos** de `clk_main_i` (la RAM tiene la dirección registrada y la
  lectura es combinacional: 1 ciclo basta, pero 2 da margen y es gratis), capturar `mdv1_dl_q` y
  devolverlo.
- El byte concreto se selecciona en el dominio QNICE con `qnice_mdv1_addr_i(0)`:
  `'0'` → byte alto, `'1'` → byte bajo (mismo criterio que la carga).
- El bitmap de sucios se lee sin CDC de datos: son 256 bits estables en el dominio del core; basta
  con sincronizar la palabra seleccionada con `xpm_cdc_array_single` o, más simple, reutilizar el
  mismo mecanismo de petición/respuesta cambiando la fuente del dato.

**Los procesos nuevos deben llevar reset desde el primer día** (`qnice_rst_i` en el lado QNICE,
`reset` en el lado del core) — es el bug de `M2017`, no repetirlo.

Latencia estimada: ~400 ns por byte. Volcado completo (174930 bytes) ≈ 70 ms. Un solo sector
(686 bytes) ≈ 0.3 ms. Irrelevante.

### 6.3 Alternativa arquitectónica (documentada, NO para el MVP)

Sacar la RAM de `mdv.v` e instanciarla en `main.vhd` como RAM de **doble reloj de verdad**
(`dualport_2clk_ram_byteenable` ya lo soporta): puerto A en `qnice_clk_i` (carga y volcado
**sin ningún CDC**), puerto B en `clk_main_i` (lectura y escritura de `mdv.v`). Es el patrón
"exponer puertos en el original e instanciar fuera" que ya se usó para `ipc` y para el propio
`mdv1`.

Ventajas: **elimina por completo el `xpm_cdc_handshake` del cargador** — justo la maquinaria
responsable de los bugs `M2004`/`M2005`/`M2006`/`M2017` — y el volcado pasa a ser un acceso
directo. Inconveniente: toca el camino de carga que hoy funciona, y el puerto B tendría que
alternar lectura y escritura (resoluble: `mdv.v` sólo necesita el dato leído en el tick de palabra,
una vez cada ~6600 ciclos de `clk`, así que cualquier otro ciclo está libre para escribir).

**Recomendación: hacerlo cuando el buffer migre a HyperRAM** (la antigua fase C), que va a forzar
este refactor de todas formas. No mezclarlo con la fase B.

---

## 7. `mega65.vhd`, `globals.vhd`, `config.vhd`, `m2m-rom.asm`

### 7.1 `mega65.vhd`

En `core_specific_devices`, rama `when C_DEV_QL_MDV1` (hoy `mega65.vhd:612-621`): añadir el decodificador de
los tres rangos de §6.1 y devolver `qnice_dev_data_o` en las lecturas. La rama CSR
(`mdv1_csr_active`) se queda como está.

### 7.2 `globals.vhd`

```vhdl
constant C_MDV1_DIRTY_BASE  : natural := 16#30000#;  -- bitmap de sucios, 32 bytes
constant C_MDV1_DIRTY_CLR   : natural := 16#30020#;  -- escribir aqui = limpiar
```

### 7.3 `config.vhd` — el ítem de menú

Añadir bajo "Microdrive", junto a `mdv1:%s`:

```
   " Save mdv1\n"           &    -- accion momentanea
```

con grupo `OPTM_G_MDV1_SAVE + OPTM_G_SINGLESEL`, exactamente el patrón de
"Extract Back ROM" (`config.vhd:357`). **`OPTM_SIZE` pasa de 11 a 12** y `OPTM_DY` con él.

> **Aviso ya conocido (M2001)**: al cambiar `OPTM_SIZE`, el fichero de configuración guardado en
> `/ql4m65/m2mcfg` queda con el tamaño antiguo. Hay que regenerarlo o dejar que el Shell lo
> descarte la primera vez.

### 7.4 `m2m-rom.asm` — el volcado

Plantilla: `OSM_SEL_POST` + `CLEAR_BACK_ROM` (`m2m-rom.asm:177-243` (`CLEAR_BACK_ROM` en `:216`)), que ya demuestra cómo
alcanzar un dispositivo del core desde QNICE (`M2M$RAMROM_DEV` / `M2M$RAMROM_4KWIN` /
`M2M$RAMROM_DATA`) y cómo se engancha una acción momentánea.

```
FLUSH_MDV1:
  1. leer los 32 bytes del bitmap en 0x30000
  2. si todo es cero -> mensaje "nothing to save" y salir
  3. f32_fopen sobre la ruta del .mdv cargado          (ver 7.5)
  4. para cada sector S con el bit puesto:
        f32_fseek(S * 686)
        para i en 0..685:
            leer el byte del dispositivo mdv1 en S*686 + i
            f32_fwrite
  5. f32_fflush ; f32_fclose
  6. escribir en 0x30020 para limpiar el bitmap
  7. repintar el menu (M2M$FORCE_MENU / OPTM_SHOW / OPTM_SELECT), igual que hace
     "Extract Back ROM", para que el item no se quede con la marca "=" puesta
```

`f32_fseek` (`fat32_library.asm:1222`) rechaza posiciones más allá del EOF, lo que es exactamente
la protección que queremos: el `.mdv` ya existe y no cambia de tamaño, así que toda escritura es
in situ.

**Disparador automático adicional**: antes de cargar un `.mdv` nuevo, si el bitmap no está vacío,
avisar o volcar. Engancharlo en `OSM_SEL_PRE` para el ítem `mdv1:%s`.

### 7.5 Punto abierto: la ruta del fichero

Fase 1 §7.3. Resolver así, por orden:

1. Comprobar si `crts-and-roms.asm` conserva ruta+nombre completos en algún sitio reutilizable
   (mirar alrededor de `:481-565` y de `CRTROM_MAN_LDF`).
2. Si no, **guardarla nosotros** en una variable de `m2m-rom.asm` durante la carga. Es la opción
   robusta y no depende de detalles internos del framework.

---

## 8. Plan de implementación por etapas

Cada etapa es una build compilable y probable en hardware por separado. **No saltar a la siguiente
sin pasar el criterio de aceptación de la anterior.**

### Etapa 1 — `M2021`: camino RTL de escritura (sin persistencia)

**Cambios:** `zx8302.v` (§4), `mdv.v` (§3), cableado en `main.vhd` (§5.1). Nada de QNICE.

**Criterio de aceptación, en la propia QL, en una sola sesión:**
```
LOAD  mdv1_<algo>        (comprobar que la lectura no ha sufrido regresion)
SAVE  mdv1_prueba        -> debe TERMINAR, no quedarse girando
DIR   mdv1_              -> debe aparecer "prueba"
LOAD  mdv1_prueba        -> debe cargar sin error
```

**Por qué esto ya demuestra mucho:** QDOS releé y verifica cada sector escrito en la vuelta
siguiente (fase 1 §6) y **no tiene límite de reintentos** para bloques de datos. Si el `SAVE`
termina, el round-trip escritura→lectura es correcto por construcción. Si se queda girando para
siempre, la verificación está fallando: mirar primero el flanco del strobe (§4.2), luego el
anclaje (§3.2).

**Regresión obligatoria:** la batería de fase A con imágenes verificadas
(`tetris`, `spaceinvaders`, `empty1`, `OPascal`, `CHESS_fix`).

### Etapa 2 — `M2022`: bitmap de sucios y lectura desde QNICE

**Cambios:** bitmap (§5.2), extensión del loader a lector (§6.2), mapa de direcciones (§6.1, §7.1).

**Criterio de aceptación:** sin cambio funcional visible en la QL (repetir la batería de la etapa 1
sin regresión). Verificación del camino nuevo: leer desde QNICE unos cuantos bytes conocidos del
buffer y el bitmap, con un volcado temporal por pantalla o por el mecanismo de depuración que se
prefiera.

**Prueba puntual muy barata:** tras un `SAVE`, el bitmap debe tener puestos exactamente los bits de
los sectores que QDOS haya tocado (típicamente unos pocos, más el sector de mapa).

### Etapa 3 — `M2023`: ítem de menú y volcado a la SD

**Cambios:** `config.vhd`, `m2m-rom.asm`, `globals.vhd` (§7).

**Criterio de aceptación:**
```
1. cargar empty1.mdv
2. SAVE mdv1_prueba
3. menu -> "Save mdv1"
4. APAGAR Y ENCENDER  (no un reset: hay que descartar que sobreviva en BRAM)
5. cargar el mismo fichero .mdv
6. DIR mdv1_   ->  "prueba" debe seguir ahi
7. en el PC:  python mdvcheck.py <ese .mdv>   ->  0 fallos de 765 checksums
```

El paso 7 es innegociable: comprueba con el algoritmo real de Minerva que lo que hemos escrito en
la SD es un microdrive válido, no sólo algo que nuestra propia lectura sabe interpretar.

### Etapa 4 — `M2024`: endurecimiento

- Volcado automático (o aviso) al cambiar de imagen con cambios pendientes.
- Mensajes al usuario (`CUSTOM_MSG`, `m2m-rom.asm:265`).
- Revisar WNS/WHS y hacer `report_timing` sobre las celdas nuevas de `mdv.v`, igual que en fase A.
- Actualizar `doc/m2m/exceptions.md`, `DECISIONES.md` y `PORTING-PLAN.md` §0.

---

## 9. Registro de riesgos

| # | Riesgo | Probabilidad | Detección | Mitigación |
|---|---|---|---|---|
| R1 | **Strobe múltiple por ciclo de bus** → bytes duplicados | **alta** | El `SAVE` gira sin terminar; el `.mdv` volcado falla `mdvcheck.py` | Detección de flanco obligatoria (§4.2). Es el primer sitio donde mirar |
| R2 | Anclaje mal calculado → datos desplazados | media | Igual que R1 | Verificar que `region_base` se captura sólo con `mdv_gap_active` y en el tick de palabra |
| R3 | Orden de bytes invertido | media | El `.mdv` volcado falla los checksums de forma sistemática | El primer byte es el **alto** (`mdv.v:88`) |
| R4 | Colisión lectura/escritura en la BRAM | baja | Vivado emitirá ahora avisos `SYNTH-16` también para `mdv1` (hoy sólo los da para `ql_rom`) | Es inocuo: puerto B sólo lee, y un dato de lectura indefinido en un ciclo suelto no lo consume nadie. **Documentar el aviso nuevo para que no se confunda con un bug** |
| R5 | Escritura desbordando al sector siguiente | baja | Sectores adyacentes corrompidos | `wr_in_range` (§3.4) |
| R6 | El proceso nuevo de QNICE se queda colgado | media | "Sólo se arregla apagando y encendiendo" | Reset desde el primer día en **ambos** lados (lección de `M2017`) |
| R7 | Regresión en la lectura | media | Batería de fase A | Ejecutarla en **todas** las etapas, no sólo al final |
| R8 | Ruta del fichero no disponible para el volcado | media | Se descubre al implementar la etapa 3 | §7.5, con plan B propio |

---

## 10. Lo que NO hay que hacer

- **No implementar `txfl` como pulso.** Ver D2 y fase 1 §4.3.
- **No derivar la dirección de escritura de `mem_addr`** en el instante en que llega el byte.
  Ver D1 y fase 1 §5.
- **No meter señales "en vivo" del bus QNICE en `qnice_mdv1_wait_o`.** Cuelgue garantizado (M2006).
- **No usar sincronizadores hechos a mano** entre `qnice_clk_i` y `clk_main_i`. Sólo `xpm_cdc_*`
  (M2011 → M2012).
- **No dejar procesos nuevos sin reset** (M2017).
- **No probar con una imagen `.mdv` sin pasarle antes `mdvcheck.py`.** Costó tres rondas de
  investigación aprenderlo (M2004-M2017).
- **No tocar `mdv_end`** en el camino de escritura.
- **No intentar `FORMAT`** en esta fase, aunque el diseño deje la puerta entreabierta (§3.2
  registra `region_state`, y `md_wblok` funcionaría ya con este mismo mecanismo).

---

## 11. Resumen para quien implemente

Lo esencial cabe en cinco frases:

1. Cuando `mctrl[2]` está a 1, cada byte que la CPU escribe en `$18022` se acumula de dos en dos.
2. Cada palabra se guarda en `region_base + índice_de_palabra`, donde `region_base` es la dirección
   que tenía `mem_addr` durante el último hueco — **no** la que tiene ahora.
3. El primer byte de cada par es el alto.
4. Cada palabra confirmada marca como sucio el sector `mdv_sector`.
5. Un ítem de menú vuelca los sectores sucios al `.mdv` de la SD con `f32_fseek` + `f32_fwrite`.

Y el criterio de éxito: **`SAVE` termina, `DIR` lo ve, y `mdvcheck.py` da 0 fallos sobre el fichero
volcado.**
