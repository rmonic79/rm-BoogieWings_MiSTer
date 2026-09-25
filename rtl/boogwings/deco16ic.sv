//
// deco16ic.sv
// Data East tilemap chip (custom IC 55 / 56 / 74 / 141)
//
// Riferimento C++: reference/mame/deco16ic.cpp (Bryan McPhail / David Haywood)
// Riferimento BoogieWings: reference/mame/boogwing.cpp
//
// Sottoinsieme implementato (parziale, estendibile senza rewrite):
//   - 2 layer pf1/pf2 (pf2 = pipeline TODO; per ora output 0)
//   - VRAM 8KB per layer (4096 word) con scramble layout DECO_64x32
//   - 8 control word @ 0x00-0x0F (pf12_control[0..7])
//   - Pipeline pf1: 16x16 4bpp, no rowscroll, no flip, no 8x8 mode
//   - Tile code 12-bit + colour 4-bit (top nibble)
//   - Bank callback per pf1 e pf2 (bank_resp1/2)
//
// Memory map relativo (cpu_addr[15:0]):
//   0x0000-0x000F  pf_control_w (8 word)
//   0x4000-0x5FFF  pf1_data    (8KB = 4096 word, byte addr = 0x4000-0x5FFF)
//   0x6000-0x7FFF  pf2_data
//   0x8000-0x8FFF  pf1_rowscroll (4KB = 2048 word, byte addr = 0x8000-0x8FFF)
//   0xA000-0xAFFF  pf2_rowscroll
//
// In BoogieWings (main_map):
//   deco16ic[0] base = 0x260000 → cpu_addr[15:0] selezionato esternamente
//   deco16ic[1] base = 0x270000
//

module deco16ic
#(
	// Bank callback mode (boogwing.cpp:699-711):
	//   0 = identity (no callback, bank=0)
	//   1 = boogwing bank_callback:  offset = ((bank >> 4) & 7) << 12
	//   2 = boogwing bank_callback2: offset = bank_callback + (bank & 0xF == 0xA ? 0x800 : 0)
	parameter [1:0] BANK1_MODE = 2'd0,
	parameter [1:0] BANK2_MODE = 2'd0,
	// GFX bank base — placeholder, non più usato (il bridge usa region_id)
	parameter [23:0] GFX_8X8_BASE   = 24'h000000,
	parameter [23:0] GFX_16X16_BASE = 24'h000000,
	// Colour bank + mask (MAME boogwing.cpp:744-760):
	//   output_colour = (raw_colour & COL_MASK) + COL_BANK
	// BoogieWings:
	//   chip 0 pf1/pf2: COL_BANK=0,  COL_MASK=0x0F
	//   chip 1 pf1   :  COL_BANK=0,  COL_MASK=0x0F
	//   chip 1 pf2   :  COL_BANK=16, COL_MASK=0x0F
	parameter [4:0] PF1_COL_BANK = 5'd0,
	parameter [3:0] PF1_COL_MASK = 4'hF,
	parameter [4:0] PF2_COL_BANK = 5'd0,
	parameter [3:0] PF2_COL_MASK = 4'hF,
	// Tile size per layer: 16 = 16x16 (BG), 8 = 8x8 (text)
	// BoogieWings: chip 0 pf1 = 8 (text), tutti gli altri = 16
	parameter integer PF1_TILE_SIZE = 16,
	parameter integer PF2_TILE_SIZE = 16,
	// region_id passato al bridge (vedi sdram_bridge.sv RID_*)
	parameter [2:0] PF1_REGION_ID = 3'd2,   // RID_TILES2_LO default (BG1)
	parameter [2:0] PF2_REGION_ID = 3'd2
)
(
	input  wire        clk,
	input  wire        reset,

	// CPU bus (16-bit, big-endian byte enable: dsn[1]=UDS=hi, dsn[0]=LDS=lo)
	input  wire [15:0] cpu_addr,    // word offset relativo (bit 15:1 utili)
	input  wire        cpu_cs,
	input  wire        cpu_rd,
	input  wire        cpu_wr,
	input  wire [15:0] cpu_wdata,
	input  wire  [1:0] cpu_dsn,
	output wire [15:0] cpu_rdata,

	// Render (pixel clock domain via ce_pix)
	input  wire  [9:0] render_x,
	input  wire  [9:0] render_y,
	input  wire        ce_pix,
	output wire  [3:0] pf1_pix,
	output wire  [3:0] pf2_pix,
	output wire  [4:0] pf1_col,      // 5-bit per accomodare col_bank fino a 16
	output wire  [4:0] pf2_col,
	output wire        pf1_opaque,
	output wire        pf2_opaque,

	// Tile ROM fetch: 1 client per layer (pf1, pf2). Esternamente arbitrato.
	// region_id costante per layer (settato via parameter al compile time).
	output wire [23:0] pf1_rom_addr,
	output wire [2:0]  pf1_region_id,
	output wire        pf1_rom_req,
	input  wire [31:0] pf1_rom_data,
	input  wire        pf1_rom_valid,
	output wire [23:0] pf2_rom_addr,
	output wire [2:0]  pf2_region_id,
	output wire        pf2_rom_req,
	input  wire [31:0] pf2_rom_data,
	input  wire        pf2_rom_valid
);

assign pf1_region_id = PF1_REGION_ID;
assign pf2_region_id = PF2_REGION_ID;

// =====================================================================
// VRAM (pf1+pf2 8KB ciascuno = 4096 word × 16-bit)
// =====================================================================
// Address decode (relativo a cpu_addr base modulo, byte addressing):
//   pf1_data:  0x4000-0x5FFF  → cpu_addr[15:13] == 3'b010
//   pf2_data:  0x6000-0x7FFF  → cpu_addr[15:13] == 3'b011
//   pf1_rs:    0x8000-0x8FFF  → cpu_addr[15:12] == 4'h8
//   pf2_rs:    0xA000-0xAFFF  → cpu_addr[15:12] == 4'hA
//   ctrl:      0x0000-0x000F  → cpu_addr[15:4]  == 12'd0
wire is_pf1_data = cpu_cs & (cpu_addr[15:13] == 3'b010);
wire is_pf2_data = cpu_cs & (cpu_addr[15:13] == 3'b011);
wire is_pf1_rs   = cpu_cs & (cpu_addr[15:12] == 4'h8);
wire is_pf2_rs   = cpu_cs & (cpu_addr[15:12] == 4'hA);
wire is_ctrl     = cpu_cs & (cpu_addr[15:4]  == 12'd0);

wire [11:0] cpu_pf_idx = cpu_addr[12:1];   // 12-bit index (4096 word)
wire [10:0] cpu_rs_idx = cpu_addr[11:1];   // 11-bit (2048 word)

// VRAM 4096 word × 16-bit. Quartus inferisce M10K solo se la BRAM ha pattern
// chiaro "1 write port + 1 read port". 8-bit lane split: 2 BRAM da 4096×8 cad.
(* ramstyle = "M10K" *) reg [7:0] pf1_vram_lo [0:4095];
(* ramstyle = "M10K" *) reg [7:0] pf1_vram_hi [0:4095];
(* ramstyle = "M10K" *) reg [7:0] pf2_vram_lo [0:4095];
(* ramstyle = "M10K" *) reg [7:0] pf2_vram_hi [0:4095];
(* ramstyle = "M10K" *) reg [7:0] pf1_rs_lo [0:2047];
(* ramstyle = "M10K" *) reg [7:0] pf1_rs_hi [0:2047];
(* ramstyle = "M10K" *) reg [7:0] pf2_rs_lo [0:2047];
(* ramstyle = "M10K" *) reg [7:0] pf2_rs_hi [0:2047];

wire pf1_we_lo = is_pf1_data & cpu_wr & ~cpu_dsn[0];
wire pf1_we_hi = is_pf1_data & cpu_wr & ~cpu_dsn[1];
wire pf2_we_lo = is_pf2_data & cpu_wr & ~cpu_dsn[0];
wire pf2_we_hi = is_pf2_data & cpu_wr & ~cpu_dsn[1];
wire pf1rs_we_lo = is_pf1_rs & cpu_wr & ~cpu_dsn[0];
wire pf1rs_we_hi = is_pf1_rs & cpu_wr & ~cpu_dsn[1];
wire pf2rs_we_lo = is_pf2_rs & cpu_wr & ~cpu_dsn[0];
wire pf2rs_we_hi = is_pf2_rs & cpu_wr & ~cpu_dsn[1];

always @(posedge clk) if (pf1_we_lo)   pf1_vram_lo[cpu_pf_idx] <= cpu_wdata[ 7:0];
always @(posedge clk) if (pf1_we_hi)   pf1_vram_hi[cpu_pf_idx] <= cpu_wdata[15:8];
always @(posedge clk) if (pf2_we_lo)   pf2_vram_lo[cpu_pf_idx] <= cpu_wdata[ 7:0];
always @(posedge clk) if (pf2_we_hi)   pf2_vram_hi[cpu_pf_idx] <= cpu_wdata[15:8];
always @(posedge clk) if (pf1rs_we_lo) pf1_rs_lo[cpu_rs_idx]   <= cpu_wdata[ 7:0];
always @(posedge clk) if (pf1rs_we_hi) pf1_rs_hi[cpu_rs_idx]   <= cpu_wdata[15:8];
always @(posedge clk) if (pf2rs_we_lo) pf2_rs_lo[cpu_rs_idx]   <= cpu_wdata[ 7:0];
always @(posedge clk) if (pf2rs_we_hi) pf2_rs_hi[cpu_rs_idx]   <= cpu_wdata[15:8];

// =====================================================================
// Control registers (8 word @ 0x00-0x0F)
// Layout (deco16ic.cpp:94-134):
//   [0] bit 7  = flip screen, bit 6:0 = ?
//   [1] = pf2 scroll X
//   [2] = pf2 scroll Y
//   [3] = pf1 scroll X
//   [4] = pf1 scroll Y
//   [5] = enables + rowscroll/colscroll style
//   [6] = mode bits (8x8 vs 16x16, rowscroll en, colscroll en, flip behavior)
//   [7] = bank hi: [15:8] = pf1 gfx bank, [7:0] = pf2 gfx bank
// NOTA: in MAME word index = byte_offset/2, quindi pf_control[0] = byte 0,
// pf_control[1] = byte 2, ecc.
// =====================================================================
reg [15:0] pf12_control [0:7];
wire [2:0] ctrl_idx = cpu_addr[3:1];

always @(posedge clk) begin
	if (is_ctrl & cpu_wr) begin
		if (~cpu_dsn[0]) pf12_control[ctrl_idx][ 7:0] <= cpu_wdata[ 7:0];
		if (~cpu_dsn[1]) pf12_control[ctrl_idx][15:8] <= cpu_wdata[15:8];
	end
end

wire [15:0] pf1_scroll_x = pf12_control[3];
wire [15:0] pf1_scroll_y = pf12_control[4];
wire [15:0] pf2_scroll_x = pf12_control[1];
wire [15:0] pf2_scroll_y = pf12_control[2];
// TODO control[5] enable bits, control[6] mode bits

// =====================================================================
// Bank callback (deco16ic.cpp:903-931)
//   bank1_cb input  = pf12_control[7] & 0xff   (byte basso)
//   bank2_cb input  = pf12_control[7] >> 8     (byte alto)
//   Output = m_pf1_bank / m_pf2_bank, sommato a tile_code in rendering
//
//   BoogieWings (boogwing.cpp:699-711):
//     bank_callback:  offset = ((bank >> 4) & 7) * 0x1000           → max 0x7000
//     bank_callback2: bank_callback + ((bank & 0xF) == 0xA ? 0x800) → max 0x7800
//   Quindi tile_code dopo bank = 12-bit raw + max 0x7800 = max 0x8FFF = 15-bit
// =====================================================================
wire [7:0] bank1_in = pf12_control[7][7:0];
wire [7:0] bank2_in = pf12_control[7][15:8];

function [14:0] bank_calc(input [1:0] mode, input [7:0] bank);
	reg [14:0] base;
	begin
		// ((bank >> 4) & 7) << 12 = bit [6:4] in posizione [14:12]
		base = {bank[6:4], 12'd0};
		case (mode)
			2'd1: bank_calc = base;
			2'd2: bank_calc = base + ((bank[3:0] == 4'hA) ? 15'h0800 : 15'd0);
			default: bank_calc = 15'd0;
		endcase
	end
endfunction

wire [14:0] pf1_bank = bank_calc(BANK1_MODE, bank1_in);
wire [14:0] pf2_bank = bank_calc(BANK2_MODE, bank2_in);

// =====================================================================
// CPU read-back (mux interno)
// =====================================================================
// Rowscroll + ctrl read (CPU side). VRAM CPU readback ritorna 0 (MAME raramente
// rilegge VRAM tile; sopprimere il read port libera la 2a porta del M10K).
reg [7:0] rs_pf1_lo, rs_pf1_hi, rs_pf2_lo, rs_pf2_hi;
reg [15:0] ctrl_rd;
always @(posedge clk) rs_pf1_lo <= pf1_rs_lo[cpu_rs_idx];
always @(posedge clk) rs_pf1_hi <= pf1_rs_hi[cpu_rs_idx];
always @(posedge clk) rs_pf2_lo <= pf2_rs_lo[cpu_rs_idx];
always @(posedge clk) rs_pf2_hi <= pf2_rs_hi[cpu_rs_idx];
always @(posedge clk) ctrl_rd   <= pf12_control[ctrl_idx];
wire [15:0] rs_pf1_rd = {rs_pf1_hi, rs_pf1_lo};
wire [15:0] rs_pf2_rd = {rs_pf2_hi, rs_pf2_lo};

// Latch del cpu_cs target ciclo precedente (1 reg [4:0])
reg [4:0] is_d;
always @(posedge clk) is_d <= {is_pf1_data, is_pf2_data, is_pf1_rs, is_pf2_rs, is_ctrl};

// CPU readback VRAM tile data ritorna 0 (port BRAM dedicato al pixel pipeline).
assign cpu_rdata = is_d[2] ? rs_pf1_rd :
                   is_d[1] ? rs_pf2_rd :
                   is_d[0] ? ctrl_rd   :
                             16'h0000;

// =====================================================================
// PIPELINE pf1 — 16x16 4bpp, no flip, no rowscroll, no 8x8
// =====================================================================
// VRAM layout 64x32 (deco16ic.cpp:291):
//   tile_index = (col & 0x1F) + ((row & 0x1F) << 5)
//              + ((col & 0x20) << 5) + ((row & 0x20) << 6)
// Cioè blocchi 32x32 disposti in 2x1 (col[5] e row[5] selezionano blocco).
//
// Layout 16x16 4bpp (boogwing.cpp tile_16x16_layout):
//   32 byte per riga (16 px × 2 byte plane = 32 byte = 8 word ROM)
//   No, ricalcolo:
//     16x16 4bpp = 16*16*4 / 8 = 128 byte per tile = 32 word 32-bit (4 byte)
//   In gfx_layout:
//     plane_offset = { 1/2+8, 1/2+0, 0/2+8, 0/2+0 } → 4 bitplane
//     x_offset = STEP8(16*8*2,1), STEP8(0,1)       → 16 pixel x usando 2 byte
//     y_offset = STEP16(0, 8*2)                     → 16 righe × 16 byte
//     totalbits = 32*16 = 512 bit = 64 byte per tile (interleaved)
//
// In pratica per RTL: ogni tile 16x16 4bpp occupa 64 byte = 16 word 32-bit.
// Layout: 2 word 32-bit per riga (8 pixel low + 8 pixel high), 16 righe.

// Scroll registrato per spezzare path lungo cpu_addr→ctrl→scroll→render
reg [9:0] src_x, src_y;
reg [9:0] src2_x, src2_y;
always @(posedge clk) begin
	src_x  <= render_x + pf1_scroll_x[9:0];
	src_y  <= render_y + pf1_scroll_y[9:0];
	src2_x <= render_x + pf2_scroll_x[9:0];
	src2_y <= render_y + pf2_scroll_y[9:0];
end

// Coordinate tile e pixel-in-tile dipendenti dalla tile size del layer.
// 16x16: col=src_x[9:4], pix_x=src_x[3:0]
// 8x8:   col=src_x[9:3], pix_x=src_x[2:0]
// Stessa logica per row/pix_y. Per VRAM 64×32 mantengo col 6-bit, row 5-bit.
wire [5:0] col;
wire [4:0] row;
wire [3:0] pix_x, pix_y;
generate
	if (PF1_TILE_SIZE == 8) begin : pf1_8x8_coords
		assign col   = src_x[9:3];          // 7-bit src tile col, troncato a 6
		assign row   = src_y[7:3];
		assign pix_x = {1'b0, src_x[2:0]};  // pix_x[3] sempre 0 per 8x8
		assign pix_y = {1'b0, src_y[2:0]};
	end else begin : pf1_16x16_coords
		assign col   = src_x[9:4];
		assign row   = src_y[8:4];
		assign pix_x = src_x[3:0];
		assign pix_y = src_y[3:0];
	end
endgenerate

// VRAM swizzle layout DECO_64x32 (deco16ic.cpp:291)
//   tile_index = (col & 0x1F) + ((row & 0x1F) << 5) + ((col & 0x20) << 5) + ((row & 0x20) << 6)
// Per 64×32: row 5-bit (max 0x1F), col 6-bit (max 0x3F) →
//   bit [11]    = row[5] (= 0 sempre per 32 row)
//   bit [10]    = col[5]
//   bit [9:5]   = row[4:0]
//   bit [4:0]   = col[4:0]
wire [11:0] vram_idx = {1'b0, col[5], row[4:0], col[4:0]};

// VRAM read port pixel pipeline (lane lo+hi separate per inferire 2 M10K)
reg [7:0] tile_word_lo, tile_word_hi;
always @(posedge clk) tile_word_lo <= pf1_vram_lo[vram_idx];
always @(posedge clk) tile_word_hi <= pf1_vram_hi[vram_idx];
wire [15:0] tile_word_r = {tile_word_hi, tile_word_lo};

// Tile decode (deco16ic.cpp:294-352, pf1 usa control[6] byte basso)
wire [11:0] tile_code_raw = tile_word_r[11:0];
wire [3:0]  tile_colour_raw = tile_word_r[15:12];
// Flip: bit 15 del tile word + control[6] mode bits.
//   if (tile & 0x8000) {
//       if (control[6] & 0x01) FLIPX, colour &= 0x7
//       if (control[6] & 0x02) FLIPY, colour &= 0x7
//   }
wire [7:0]  pf1_mode  = pf12_control[6][7:0];
wire        pf1_has_flip = tile_word_r[15];
wire        pf1_flip_x   = pf1_has_flip & pf1_mode[0];
wire        pf1_flip_y   = pf1_has_flip & pf1_mode[1];
wire        pf1_colour_mask_low = pf1_has_flip & (pf1_mode[0] | pf1_mode[1]);
wire [3:0]  tile_colour = pf1_colour_mask_low ? (tile_colour_raw & 4'h7) : tile_colour_raw;
wire [3:0]  pix_x_eff   = pf1_flip_x ? (4'd15 - pix_x) : pix_x;
wire [3:0]  pix_y_eff   = pf1_flip_y ? (4'd15 - pix_y) : pix_y;

// Bank callback: tile_code remappato = raw + pf1_bank
wire [14:0] tile_code = {3'd0, tile_code_raw} + pf1_bank;

// ROM addressing 16x16 4bpp PLANAR (MAME gfx tile_16x16_layout):
//   Per metà-riga (8 pixel) servono 2 fetch 16-bit del bridge:
//     fetch 1: planeLo region → word con plane0+plane1 (8 pixel × 2 plane)
//     fetch 2: planeHi region → word con plane2+plane3
//   Il bridge gestisce internamente la coppia lo/hi e ritorna 32-bit
//   tile_data = {plane_hi_word, plane_lo_word}.
//
//   Byte address dentro la region (offset planeLo, il bridge calcola planeHi):
//     byte_offset = tile_code × 32 + 2*pix_y + (pix_x[3] ? 32 : 0)
//   Allineamento word (byte 0 = 0):
//     byte_addr = {tile_code, pix_x[3], pix_y[3:0], 1'b0}
//   tile_code 15-bit + xhalf 1-bit + pix_y 4-bit + bit0=0 = 21-bit byte addr
//
//   GFX_16X16_BASE non più sommato: il bridge applica la base region dato
//   il region_id (passato dal top via tile_rom_arbiter).
// Byte address dentro la region (planeLo), il bridge calcola planeHi automaticamente.
// 16x16 4bpp: 128 byte/tile (16x16 px * 4 bpp / 8 = 128).
//   Per ciascuna metà-riga 8 pixel: 4 byte * 2 plane region = 8 byte.
//   Per riga: 16 byte. Per 16 righe: 256? NO: 16x16 4bpp = 1024 bit = 128 byte.
//   Byte/riga = 128/16 = 8. Per metà-riga 8 pixel = 4 byte (2 word).
//   byte = tile_code*128 + xhalf*64 + 8*y? NO! formula MAME:
//     16x16 4bpp planar 2 region: tile=64 byte/region * 2 region = 128 byte
//     Region = 64 byte/tile (2 plane * 16x16 / 8 = 64 byte). Spacing in 1 region = 64.
//   Quindi se leggiamo PER REGION (= 1 fetch a region = 64 byte/tile spacing):
//     byte_offset_in_region = tile_code*64 + xhalf*32 + pix_y*2 — OK formula attuale.
//     {3'd0, tile_code, xhalf, pix_y[3:0], 1'b0} = 24 bit.
// MA il bridge fa 2 fetch (HI+LO region), quindi offset DENTRO ogni region è
// effettivamente tile_code*64. Tile spacing in SDRAM globale = 128 byte
// (perché HI+LO region adiacenti somma 128 totale). FORMULA È CORRETTA.
// 16x16: byte_per_region = tile_code*64 + xhalf*32 + 2*y → {tile_code, xhalf, pix_y[3:0], 1'b0}
//  8x8 : byte_per_region = tile_code*16 + 2*y          → {tile_code, pix_y[2:0], 1'b0}
// MAME tile_16x16_layout x_offsets:
//   STEP8(16*8*2,1) per pixel 0..7   → bit 256 = byte 32
//   STEP8(0,1)      per pixel 8..15  → bit 0
// → pix_x[3]=0 (pix 0..7) richiede byte_offset 32 nel ROM (xhalf logico=1)
// → pix_x[3]=1 (pix 8..15) richiede byte_offset 0 (xhalf logico=0)
// Quindi nel concat usa ~pix_x_eff[3] come bit xhalf.
wire [23:0] pf1_local_addr;
generate
	if (PF1_TILE_SIZE == 8) begin : pf1_addr_8x8
		assign pf1_local_addr = {5'd0, tile_code, pix_y_eff[2:0], 1'b0};
	end else begin : pf1_addr_16x16
		assign pf1_local_addr = {3'd0, tile_code, ~pix_x_eff[3], pix_y_eff[3:0], 1'b0};
	end
endgenerate
assign pf1_rom_addr = pf1_local_addr;

// Toggle request: l'arbiter usa rising/toggle detection su r0_req. Se teniamo
// pf1_rom_req=1 fisso, dopo il primo ciclo NON si verifica più rising edge e
// nessun fetch successivo viene fatto → tutta la schermata mostra lo stesso
// tile/pixel. Toggle quando l'addr cambia.
reg [23:0] pf1_addr_prev;
reg        pf1_req_tgl;
always @(posedge clk) begin
	if (reset) begin
		pf1_addr_prev <= 24'd0;
		pf1_req_tgl   <= 1'b0;
	end else if (pf1_rom_addr != pf1_addr_prev) begin
		pf1_addr_prev <= pf1_rom_addr;
		pf1_req_tgl   <= ~pf1_req_tgl;
	end
end

// rom_data 32-bit PLANAR (MAME gfx tile_16x16_layout):
//   tile_data[15:0]  = plane_lo_word = {plane1_byte, plane0_byte} (8 pixel × 2 plane)
//   tile_data[31:16] = plane_hi_word = {plane3_byte, plane2_byte}
//   pixel i (0..7) bit_pos = 7 - i (MSB first)
//   pixel_4bit = {plane3[bp], plane2[bp], plane1[bp], plane0[bp]}
//             = {tile_data[24+bp], tile_data[16+bp], tile_data[8+bp], tile_data[bp]}

// Latch rom_data + pixel select dinamico
reg [31:0] pf1_rom_latch;
always @(posedge clk) if (pf1_rom_valid) pf1_rom_latch <= pf1_rom_data;

// Mux 8:1 sui 4 plane per estrarre il pixel(pix_x[2:0]).
// MAME convention: pixel 0 (leftmost) = MSB del byte plane (bit 7),
// pixel 7 (rightmost) = LSB (bit 0). Verificato offline via render tile_code=0x10
// (atteso un "+" centrato; mode msb_first produce "+" plausibile, lsb_first no).
wire [4:0] pf1_bit_pos = 5'd7 - {2'd0, pix_x_eff[2:0]};
reg  [3:0] pf1_pix_r;
reg  [4:0] pf1_col_r;
always @(posedge clk) begin
	pf1_pix_r <= {
		pf1_rom_latch[5'd24 + pf1_bit_pos],   // plane 3 (MSB)
		pf1_rom_latch[5'd16 + pf1_bit_pos],   // plane 2
		pf1_rom_latch[5'd8  + pf1_bit_pos],   // plane 1
		pf1_rom_latch[       pf1_bit_pos]     // plane 0 (LSB)
	};
	// MAME: output_colour = (raw & col_mask) + col_bank
	pf1_col_r <= {1'b0, tile_colour & PF1_COL_MASK} + PF1_COL_BANK;
end

assign pf1_pix    = pf1_pix_r;
assign pf1_col    = pf1_col_r;
assign pf1_opaque = |pf1_pix_r;

assign pf1_rom_req = pf1_req_tgl;

// =====================================================================
// PIPELINE pf2 — gemellare pf1
// =====================================================================
wire [5:0]  col2;
wire [4:0]  row2;
wire [3:0]  pix2_x, pix2_y;
generate
	if (PF2_TILE_SIZE == 8) begin : pf2_8x8_coords
		assign col2   = src2_x[9:3];
		assign row2   = src2_y[7:3];
		assign pix2_x = {1'b0, src2_x[2:0]};
		assign pix2_y = {1'b0, src2_y[2:0]};
	end else begin : pf2_16x16_coords
		assign col2   = src2_x[9:4];
		assign row2   = src2_y[8:4];
		assign pix2_x = src2_x[3:0];
		assign pix2_y = src2_y[3:0];
	end
endgenerate
wire [11:0] vram2_idx = {1'b0, col2[5], row2[4:0], col2[4:0]};

reg [7:0] tile2_word_lo, tile2_word_hi;
always @(posedge clk) tile2_word_lo <= pf2_vram_lo[vram2_idx];
always @(posedge clk) tile2_word_hi <= pf2_vram_hi[vram2_idx];
wire [15:0] tile2_word_r = {tile2_word_hi, tile2_word_lo};

wire [11:0] tile2_code_raw    = tile2_word_r[11:0];
wire [3:0]  tile2_colour_raw  = tile2_word_r[15:12];
wire [7:0]  pf2_mode          = pf12_control[6][15:8];
wire        pf2_has_flip      = tile2_word_r[15];
wire        pf2_flip_x        = pf2_has_flip & pf2_mode[0];
wire        pf2_flip_y        = pf2_has_flip & pf2_mode[1];
wire        pf2_colour_mask_low = pf2_has_flip & (pf2_mode[0] | pf2_mode[1]);
wire [3:0]  tile2_colour      = pf2_colour_mask_low ? (tile2_colour_raw & 4'h7) : tile2_colour_raw;
wire [3:0]  pix2_x_eff        = pf2_flip_x ? (4'd15 - pix2_x) : pix2_x;
wire [3:0]  pix2_y_eff        = pf2_flip_y ? (4'd15 - pix2_y) : pix2_y;

wire [14:0] tile2_code     = {3'd0, tile2_code_raw} + pf2_bank;

wire [23:0] pf2_local_addr;
generate
	if (PF2_TILE_SIZE == 8) begin : pf2_addr_8x8
		assign pf2_local_addr = {5'd0, tile2_code, pix2_y_eff[2:0], 1'b0};
	end else begin : pf2_addr_16x16
		assign pf2_local_addr = {3'd0, tile2_code, ~pix2_x_eff[3], pix2_y_eff[3:0], 1'b0};
	end
endgenerate
assign pf2_rom_addr = pf2_local_addr;

reg [23:0] pf2_addr_prev;
reg        pf2_req_tgl;
always @(posedge clk) begin
	if (reset) begin
		pf2_addr_prev <= 24'd0;
		pf2_req_tgl   <= 1'b0;
	end else if (pf2_rom_addr != pf2_addr_prev) begin
		pf2_addr_prev <= pf2_rom_addr;
		pf2_req_tgl   <= ~pf2_req_tgl;
	end
end
assign pf2_rom_req = pf2_req_tgl;

reg [31:0] pf2_rom_latch;
always @(posedge clk) if (pf2_rom_valid) pf2_rom_latch <= pf2_rom_data;

wire [4:0] pf2_bit_pos = 5'd7 - {2'd0, pix2_x_eff[2:0]};   // MSB-first vedi pf1
reg  [3:0] pf2_pix_r;
reg  [4:0] pf2_col_r;
always @(posedge clk) begin
	pf2_pix_r <= {
		pf2_rom_latch[5'd24 + pf2_bit_pos],   // plane 3
		pf2_rom_latch[5'd16 + pf2_bit_pos],   // plane 2
		pf2_rom_latch[5'd8  + pf2_bit_pos],   // plane 1
		pf2_rom_latch[       pf2_bit_pos]     // plane 0
	};
	pf2_col_r <= {1'b0, tile2_colour & PF2_COL_MASK} + PF2_COL_BANK;
end

assign pf2_pix    = pf2_pix_r;
assign pf2_col    = pf2_col_r;
assign pf2_opaque = |pf2_pix_r;

endmodule
