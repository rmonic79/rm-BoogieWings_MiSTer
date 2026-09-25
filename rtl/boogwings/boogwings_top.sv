//
// boogwings_top.sv
// Scheletro top BoogieWings (Data East, 1992)
//
// Hardware MAME (boogwing.cpp):
//   Main CPU:    M68000 @ 14 MHz (28/2)         — DE102 encrypted opcodes
//   Sound CPU:   H6280  @ 8.055 MHz (32.22/4)
//   Tilemap:     DECO16IC × 2  (4 BG layer totali)
//   Sprite:      DECO_SPRITE × 2 (alpha-blend)
//   Palette:     DECO_ACE (palette + alpha)
//   I/O+protect: DECO104PROT
//   Audio:       YM2151 @ 3.58 MHz + OKIM6295 × 2 (1 MHz e 2 MHz)
//
// Memory map main (boogwing.cpp:504):
//   0x000000-0x0FFFFF  ROM (1MB, encrypted)
//   0x200000-0x20FFFF  work RAM (64KB)
//   0x220000           priority_w
//   0x240000/0x244000  spriteram DMA trigger
//   0x242000/0x246000  spriteram1/2 (2KB ciascuno)
//   0x24E000-0x24EFFF  DECO104 protection RAM + I/O
//   0x260000-0x267FFF  deco16ic[0] control + pf1 + pf2
//   0x268000-0x26AFFF  rowscroll pf1/pf2
//   0x270000-0x277FFF  deco16ic[1] control + pf1 + pf2
//   0x278000-0x27AFFF  rowscroll pf3/pf4
//   0x282008           palette DMA trigger
//   0x284000-0x285FFF  palette RAM (8KB)
//   0x3C0000-0x3C004F  deco_ace control (ACE alpha)
//
// Memory map audio H6280 (boogwing.cpp:547):
//   0x000000-0x00FFFF  ROM (64KB)
//   0x110000           YM2151 r/w
//   0x120000           OKI1 r/w
//   0x130000           OKI2 r/w
//   0x140000           sound latch read
//   0x1F0000-0x1F1FFF  work RAM (8KB)
//
// IRQ:
//   Main IRQ6 = VBLANK (irq6_line_hold)
//   H6280 IRQ0 = sound latch (DECO104 soundlatch_irq_cb)
//   H6280 IRQ2 = YM2151 IRQ
//

module boogwings_top
(
	input  wire        clk,
	input  wire        reset,
	input  wire        pause,

	// Savestate trigger (da savestate_ui nel sys)
	input  wire        ss_save,
	input  wire        ss_load,
	input  wire [4:0]  ss_slot,   // 32 slot: [4:3]=regione (file .ss1-.ss4), [2:0]=sotto-slot

	// Inputs MAME-mapping BoogieWings (vedi docs/99_discovery_log.md):
	//   inputs_port = INPUTS (16-bit, P1+P2 joy+button+start, active LOW)
	//   system_port = SYSTEM (16-bit, coin+service+vblank, active LOW eccetto vblank)
	//   dsw_port    = DSW    (16-bit DIP switches)
	input  wire [15:0] inputs_port,
	input  wire [15:0] system_port,
	input  wire [15:0] dsw_port,

	// SDRAM ROM interface (via sdram_bridge)
	// TODO: porte main/tile/sub (sub non c'è in boogwings — solo main+tile)
	output wire [23:0] main_rom_addr,
	output wire        main_rom_is_opcode,   // dual-view fetch (bypass decrypt)
	output wire        main_rom_req,
	input  wire [15:0] main_rom_rdata,
	input  wire        main_rom_ready,

	output wire [23:0] tilerom_addr,
	output wire [2:0]  tilerom_region_id,  // RID_* selettore region planar
	output wire        tilerom_req,
	input  wire [31:0] tilerom_data,
	input  wire        tilerom_valid,

	// Tile ROM PORT B (chip1 BG2): port 3 SDRAM dedicata (legacy, lasciata cablata)
	output wire [23:0] tilerom2_addr,
	output wire [2:0]  tilerom2_region_id,
	output wire        tilerom2_req,
	input  wire [31:0] tilerom2_data,
	input  wire        tilerom2_valid,

	// Tile ROM FG0 (chip1.pf1) — ba0 jtframe diretto, no arbiter
	output wire [23:0] tilerom_fg0_addr,
	output wire [2:0]  tilerom_fg0_region_id,
	output wire        tilerom_fg0_req,
	input  wire [31:0] tilerom_fg0_data,
	input  wire        tilerom_fg0_valid,

	// Tile ROM FG1 (chip1.pf2) — ba1 jtframe diretto, no arbiter
	output wire [23:0] tilerom_fg1_addr,
	output wire [2:0]  tilerom_fg1_region_id,
	output wire        tilerom_fg1_req,
	input  wire [31:0] tilerom_fg1_data,
	input  wire        tilerom_fg1_valid,

	// Tile ROM BG1 (chip0.pf2 5bpp) — ba3 SDRAM dedicato (4 plane base + P4 dedicato)
	output wire [23:0] tilerom_bg1_addr,
	output wire        tilerom_bg1_req,
	input  wire [31:0] tilerom_bg1_data,
	input  wire        tilerom_bg1_valid,
	output wire        tilerom_bg1_p4_req,
	input  wire  [7:0] tilerom_bg1_p4_data,
	input  wire        tilerom_bg1_p4_valid,

	// ioctl (ROM download)
	input  wire        ioctl_download,
	input  wire        ioctl_wr,
	input  wire [26:0] ioctl_addr,
	input  wire [15:0] ioctl_dout,
	input  wire [15:0] ioctl_index,
	output wire        ioctl_wait,

	// Video pixel interface
	input  wire [9:0]  render_x,
	input  wire [9:0]  render_y,
	input  wire        hblank_in,
	input  wire        vblank_in,
	input  wire        ce_pix,
	input  wire        ce_audio,    // ~8 MHz, per H6280 audio CPU
	input  wire        ce_ym,       // ~3.58 MHz, per YM2151
	input  wire        ce_ym_p1,    // ~1.79 MHz, half rate per jt51
	input  wire        ce_oki0,     // ~1.01 MHz, per OKI #0
	input  wire        ce_oki1,     // ~2.00 MHz, per OKI #1
	// Savestate fase contatori ce (da/verso Template): in = save, out + load_wr = restore.
	input  wire [3:0]  ce_audio_cnt_in,
	input  wire [4:0]  ce_ym_cnt_in,
	input  wire        ce_ym_toggle_in,
	input  wire [6:0]  ce_oki0_cnt_in,
	input  wire [5:0]  ce_oki1_cnt_in,
	output wire [3:0]  ce_audio_cnt_load,
	output wire [4:0]  ce_ym_cnt_load,
	output wire        ce_ym_toggle_load,
	output wire [6:0]  ce_oki0_cnt_load,
	output wire [5:0]  ce_oki1_cnt_load,
	output wire        ce_cnt_load_wr,
	// OSD audio sel (4 bit each) — Default/MAME hardcoded dentro boogwings_audio
	input  wire [3:0]  osd_sel_fm,
	input  wire [3:0]  osd_sel_oki0,
	input  wire [3:0]  osd_sel_oki1,
	input  wire [1:0]  osd_presence,   // shelving alti sul mix: 0 Off, 1 +3, 2 +6, 3 +9 dB
	output wire [23:0] rgb_out,

	// Audio
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,
	output wire        paused_safe,    // gating frame-aligned per i contatori ce in Template.sv

	// DDRAM HPS pins (per audio ROM, OKI samples, sprite ROM)
	input  wire        DDRAM_CLK,
	input  wire        DDRAM_BUSY,
	output wire  [7:0] DDRAM_BURSTCNT,
	output wire [28:0] DDRAM_ADDR,
	input  wire [63:0] DDRAM_DOUT,
	input  wire        DDRAM_DOUT_READY,
	output wire        DDRAM_RD,
	output wire [63:0] DDRAM_DIN,
	output wire  [7:0] DDRAM_BE,
	output wire        DDRAM_WE,

	// === Layer enable OSD (runtime mask) ===
	input  wire        layer_bg0_en,   // chip0 pf1 (text)
	input  wire        layer_bg1_en,   // chip0 pf2 (BG1)
	input  wire        layer_spr_en,   // sprite
	input  wire        layer_fg0_en,   // chip1 pf1+pf2 (BG2)

	// === Layer FG1 (chip1.pf2 separato da FG0) ===
	input  wire        layer_fg1_en,

	// Tile permutation toggles (16 = 4 perm × 4 layer bg0/bg1/fg0/fg1) + sprite
	input  wire        osd_bg0_swap_hl,
	input  wire        osd_bg0_brev8,
	input  wire        osd_bg0_nibsw,
	input  wire        osd_bg0_bs_ab,
	input  wire        osd_bg1_swap_hl,
	input  wire        osd_bg1_brev8,
	input  wire        osd_bg1_nibsw,
	input  wire        osd_bg1_bs_ab,
	input  wire        osd_fg0_swap_hl,
	input  wire        osd_fg0_brev8,
	input  wire        osd_fg0_nibsw,
	input  wire        osd_fg0_bs_ab,
	input  wire        osd_fg1_swap_hl,
	input  wire        osd_fg1_brev8,
	input  wire        osd_fg1_nibsw,
	input  wire        osd_fg1_bs_ab,
	input  wire        osd_spr_swap_hl,
	input  wire        osd_spr_brev8,
	input  wire        osd_spr_nibsw,
	input  wire        osd_spr_bs_ab,
	input  wire        osd_spr_msb_first,
	input  wire        osd_spr_half_inv,
	input  wire        osd_spr_half_eff_inv,
	input  wire        osd_spr_row_inv,
	input  wire        osd_spr_plane_inv,
	input  wire [1:0]  osd_spr_p0_src,
	input  wire [1:0]  osd_spr_p1_src,
	input  wire [1:0]  osd_spr_p2_src,
	input  wire [1:0]  osd_spr_p3_src,
	input  wire [1:0]  osd_spr_chip_filter,  // 00=both, 01=chip0, 10=chip1, 11=none
	input  wire        osd_spr_w_swap_pos,          // w-mode: scambia posizione 1°/2° blocco
	input  wire        osd_spr_w_offset_first,      // w-mode: applica offset al 1° blocco (debug X assoluta)
	input  wire        osd_spr_w_code_swap,         // w-mode: swap code primo/secondo
	input  wire signed [3:0] osd_spr_w_offset,      // w-mode: offset X signed (step 16)

	// BG1 p4 (plane 4 mbd-02) permutation toggles
	input  wire [1:0]  osd_bg1_p4_byte_pos,
	input  wire        osd_bg1_p4_brev8,
	input  wire        osd_bg1_p4_bit_shift
);

// GFX debug permutazioni RIMOSSE 2026-05-21: hardcoded ai valori di default.
wire [4:0] osd_tile_decode_mode = 5'd0;
wire       osd_pixel_bit_msb    = 1'b0;
wire       osd_plane_rev32      = 1'b0;
wire       osd_nibble_swap      = 1'b0;
wire       osd_byte_swap_ab     = 1'b0;
wire       osd_region_lohi_swap = 1'b0;
wire       osd_xhalf_inv        = 1'b0;
wire       osd_tile_hi_rev      = 1'b0;
wire [1:0] osd_vram_swizzle     = 2'd0;

// =====================================================================
// MAIN CPU M68000 @ 14 MHz (target, MAME = 28MHz/2)
// Pattern: jtframe_68kdtack_cen genera cpu_cen/cpu_cenb con cycle recovery
// quando bus è busy (es. SDRAM in attesa). Pause = cen gating, mai reset.
// =====================================================================

// Clock divider: clk_sys 96 MHz × 7/48 = 14.000 MHz esatti
// MAME M68K main = 28 MHz / 2 = 14.000 MHz (boogwing.cpp:715,719)
// Prima era 1/7 ≈ 13.71 MHz = -2% troppo lento
localparam [6:0] CPU_NUM = 7'd7;
localparam [7:0] CPU_DEN = 8'd48;

wire        cpu_cen, cpu_cenb;
wire        cpu_dtackn;
wire [23:0] cpu_addr;
wire        cpu_rd, cpu_wr;
wire [15:0] cpu_wdata;
wire [1:0]  cpu_dsn;
wire [15:0] cpu_rdata;
wire        cpu_iack;
wire [2:0]  cpu_fc;
wire        cpu_fx_asn;
wire [1:0]  cpu_fx_dsn;

// Address decoder forward declarations (per ModelSim 10.5b senza forward ref)
wire is_rom, is_ram, is_prio, is_spr1, is_spr2, is_sprdma1, is_sprdma2;
wire is_prot, is_pf0, is_pf1, is_paldma, is_pal, is_ace;
// Mirror DECO16IC chip 0 control (range 0x24C000-0x24CFFF, scoperto da
// disassembly main 0xA94: scrive ctrl regs via $24C100..$24C600 stride 0x100).
// Il chip 0 decodifica parzialmente: cpu_addr[10:8] = ctrl index.
wire is_pf0_mirror;
// Noprw range MAME (boogwing.cpp:510, 534, 535) — devono produrre DTACK ma
// scrittura/lettura senza effetti (read=FFFF, write=ignorata).
wire is_noprw;

// bus_cs = la CPU sta accedendo a uno spazio mappato.
// bus_busy = il target non è ancora pronto. Per ROM: ~main_rom_ready (cache).
//            Per RAM/palette/sprite/deco16ic/ace (= BRAM read): 1 ck wait per
//            far stabilizzare l'output BRAM (1-ck latency). Implemento questo
//            generando bus_busy=1 nel ciclo IN CUI il request è nuovo, poi 0
//            nel ciclo successivo (= dato pronto).
//
// NOTE: 0x24XXXX mirror (range generico DECO104) catturato da is_prot per
// 0x24E000-0x24EFFF; gli altri sub-range del 0x24 mirror sono ridondanti.
wire is_io_mirror = (cpu_addr[23:16] == 8'h24) && !is_spr1 && !is_spr2
                    && !is_sprdma1 && !is_sprdma2 && !is_prot && !is_pf0_mirror;
wire bus_cs   = is_rom | is_ram | is_pf0 | is_pf0_mirror | is_pf1 | is_pal | is_ace |
                 is_spr1 | is_spr2 | is_sprdma1 | is_sprdma2 | is_prio | is_prot |
                 is_paldma | is_io_mirror | is_noprw;

// jtframe_68kdtack_cen ha già un proprio wait1 interno che dà 1 ciclo extra
// dopo AS falling, quindi NON serve bram_wait. ram_dout_r (BRAM 1-ck read
// latency) è pronto al cpu_cen che jtframe usa per sample bus_busy.
// DECO104 read latency: pipeline registrato 1 ck. Aggiungiamo 1 ck di
// bus_busy per dare tempo alla read di propagare a prot_cpu_rd.
reg prot_busy_r;
always @(posedge clk) begin
	if (reset) prot_busy_r <= 1'b0;
	else       prot_busy_r <= is_prot & cpu_rd & ~prot_busy_r;
end

// VRAM tile pf0/pf1: 1 ck wait per garantire che la write CPU si propaghi alla
// BRAM prima che la CPU passi al prossimo bus cycle. Senza wait, sotto stress
// (= scritture VRAM consecutive a ritmo CPU) alcune scritture possono saltare
// silenziosamente per timing race (= bug "pf0/pf1 VRAM non popolati").
// Pattern copiato da WarriorBlade darius2_dual68k_top.sv:442-463 (vram_dtack_cnt).
reg pf_busy_r;
wire pf_wr_active = (is_pf0 | is_pf0_mirror | is_pf1) & cpu_wr;
always @(posedge clk) begin
	if (reset) pf_busy_r <= 1'b0;
	else       pf_busy_r <= pf_wr_active & ~pf_busy_r;
end

wire bus_busy = (is_rom & cpu_rd & ~main_rom_ready) | (is_prot & cpu_rd & ~prot_busy_r) | (pf_wr_active & ~pf_busy_r);

jtframe_68kdtack_cen #(.W(8), .RECOVERY(1)) u_dtack (
	.rst      (reset),
	.clk      (clk),
	.cpu_cen  (cpu_cen),
	.cpu_cenb (cpu_cenb),
	.bus_cs   (bus_cs),
	.bus_busy (bus_busy),
	.bus_legit(1'b0),
	.bus_ack  (1'b0),
	.ASn      (cpu_fx_asn),
	.DSn      (cpu_fx_dsn),
	.num      (CPU_NUM),
	.den      (CPU_DEN),
	.wait2    (1'b0),
	.wait3    (1'b0),
	.DTACKn   (cpu_dtackn),
	.fave     (),
	.fworst   ()
);

// === VBlank-synced pause (frame-aligned, pattern Ninja Warriors / F2 obj_paused) ===
// pause raw asincrono (commuta sul tasto a meta' frame) → paused_safe registrato che
// cambia SOLO al rising edge vblank (frame boundary). Evita race a meta' bus-cycle /
// scanline / DDR3. Usato su CPU (cen) + audio (YM/OKI cen + HUC via RDY). Lo sprite
// si congela da solo: il renderer disegna il buffer, e il DMA copia la live RAM ferma
// (la CPU che la scrive e' in pausa) -> immagine sprite statica.
reg vblank_pp_d;
reg paused_safe_r;
always @(posedge clk) begin
	if (reset) begin
		vblank_pp_d   <= 1'b0;
		paused_safe_r <= 1'b0;
	end else begin
		vblank_pp_d <= vblank_in;
		// paused_safe_r = pausa REALE frame-aligned (= obj_paused di F2). UNA sola assegnazione, chiara:
		//   - SALITA: solo al rising vblank, se (pause | ss_pause) -> il SAVE cattura a confine frame,
		//     mai a meta' (video/audio puliti).
		//   - MANTENIMENTO durante SS: se ss_pause e' alto e paused_safe_r e' gia' alto, RESTA alto
		//     (non aspetta il prossimo vblank). FIX RACE: senza, se un confine vblank cade mentre
		//     memory_stream scrive i chip audio (idx 20-25, ultimi), i ce_ym/ce_oki ripartirebbero a
		//     META' scatter -> chip riceve registri mentre il contatore gira -> a volte muta a volte
		//     glitcha (fase casuale = non deterministico, subito al restore). F2 usa obj_paused continuo.
		//   - DISCESA: durante SS scende SUBITO quando ss_pause cade (restore finito) -> HuC+68k+chip
		//     ripartono nello STESSO ciclo (come F2 obj_paused). Pausa utente: discesa al vblank.
		// Trasparente a SS spento (ss_pause=0): si comporta come l'originale (salita/discesa al vblank).
		if (ss_pause & paused_safe_r)
			paused_safe_r <= 1'b1;                          // mantieni alto per tutta la durata del SS
		else if (vblank_in & ~vblank_pp_d)
			paused_safe_r <= pause | ss_pause;              // SALITA frame-aligned su pause|ss_pause (= F2);
			                                               // DISCESA: a SS off ss_pause=0 -> torna a pause

	end
end
// Pausa effettiva = SOLO il safe-pause REGISTRATO al vblank (paused_safe_r). Sia pausa utente
// che savestate passano per il campionamento frame-aligned (riga 321: paused_safe_r campiona
// pause|ss_pause al rising vblank). NIENTE OR con ss_pause combinatorio: quello faceva fermare
// il savestate a META' FRAME (bypassando il vblank) -> VRAM/palette/sprite/audio catturati a
// meta' transizione -> sfondi/palette corrotti, audio glitch. Ora TUTTO si ferma SOLO al vblank,
// uguale alla pausa utente (che gia' freeza pulito). Come F2 obj_paused (frame-aligned).
// paused_safe e' un output port (gata i contatori ce in Template.sv, gating dentro il contatore
// come F2 .cen_in, non AND esterno sul pulse).
assign paused_safe = paused_safe_r;

// Pause: gating cen (NON reset). Durante il SS la CPU DEVE girare per eseguire il mini-handler
// (ss_cpu_exec), quindi NON la fermiamo in quel caso anche se paused.
wire cpu_run    = ~paused_safe | ss_cpu_exec;
wire cpu_cen_g  = cpu_cen  & cpu_run;
wire cpu_cenb_g = cpu_cenb & cpu_run;

// IRQ: VBLANK rising edge → IRQ6 hold finché la CPU non lo acknowledgia (iack).
// MAME: irq6_line_hold = mantieni IRQ6 alto, MAME lo abbassa quando CPU fa IACK.
// Durante il SAVE il modulo SS forza IRQ7 (ss_irq) per far prendere l'eccezione alla CPU.
reg vblank_d;
reg irq6_pending;
always @(posedge clk) begin
	vblank_d <= vblank_in;
	if (reset) irq6_pending <= 1'b0;
	else if (vblank_in & ~vblank_d) irq6_pending <= 1'b1;  // rising edge VBLANK
	else if (cpu_iack)              irq6_pending <= 1'b0;
	else if (misc_ss_wr)            irq6_pending <= misc_irq6_load;   // restore (trasparente)
end
wire [2:0] cpu_irq_level = ss_irq        ? 3'd7 :
                           irq6_pending  ? 3'd6 : 3'd0;

// cpu_din: durante il SS il modulo inietta handler/vettore al posto del bus normale.
wire [15:0] cpu_din_eff = ss_din_en ? ss_din_data : cpu_rdata;

cpu68000_wrapper u_maincpu (
	.clk        (clk),
	.reset      (reset | ss_reset),
	.ce_cpu     (cpu_cen_g),
	.ce_cpub    (cpu_cenb_g),
	.bus_rdata  (cpu_din_eff),
	.bus_dtackn (cpu_dtackn),
	.irq_level  (cpu_irq_level),
	.active     (dbg_cpu_active),
	.cycles     (dbg_cpu_cycles),
	.bus_addr   (cpu_addr),
	.bus_rd     (cpu_rd),
	.bus_wr     (cpu_wr),
	.bus_wdata  (cpu_wdata),
	.bus_dsn_out(cpu_dsn),
	.fx_asn     (cpu_fx_asn),
	.fx_dsn     (cpu_fx_dsn),
	.last_read  (),
	.dbg_pc     (dbg_cpu_pc),
	.iack       (cpu_iack),
	.fc         (cpu_fc)
);

// Opcode fetch: 68K FC=2 (user prog) o FC=6 (supervisor prog)
wire cpu_is_opcode = (cpu_fc == 3'd2) || (cpu_fc == 3'd6);

// Debug probe pulses (1 ck width)
assign dbg_vblank_irq  = vblank_in & ~vblank_d;
assign dbg_prot_access = is_prot & (cpu_rd | cpu_wr);

// =====================================================================
// DE102 decryption (DECO102 chip) — selettore via `BYPASS_DECRYPT`
//   address scramble: i_logical → i_physical (ROM offset)
//   data decrypt:     din × addr × select_xor → plain
// Parametri boogwing.cpp:1027:
//   address_xor=0x42BA, data_select_xor=0x00, opcode_select_xor=0x18
// =====================================================================
wire [19:0] scrambled_addr;
wire [15:0] rom_plain;

`ifdef BYPASS_DECRYPT
// ROM pre-decrittata: nessuno scramble né decrypt runtime.
assign scrambled_addr = cpu_addr[19:0];
assign rom_plain      = main_rom_rdata;
`else
wire [19:0] cpu_word_idx = {1'b0, cpu_addr[19:1]};
wire [19:0] scrambled_word_idx;
deco102_addr_scramble #(.ADDRESS_XOR(16'h42BA)) u_addr_scr (
	.i_logical (cpu_word_idx),
	.i_physical(scrambled_word_idx)
);
assign scrambled_addr = {scrambled_word_idx[18:0], 1'b0};

deco102_decrypt #(
	.DATA_SELECT_XOR  (16'h0000),
	.OPCODE_SELECT_XOR(16'h0018)
) u_decrypt (
	.addr     (cpu_addr[19:0]),
	.din      (main_rom_rdata),
	.is_opcode(cpu_is_opcode),
	.dout     (rom_plain)
);
`endif

// =====================================================================
// MAIN address decoder (boogwing.cpp:504)
// =====================================================================
// 0x000000-0x0FFFFF  ROM (SDRAM)
// 0x200000-0x20FFFF  work RAM 64KB
// 0x220000           priority_w
// 0x240000-0x247FFF  sprite RAM + DMA
// 0x24E000-0x24EFFF  DECO104 protection
// 0x260000-0x26AFFF  DECO16IC[0] tilemap + rowscroll
// 0x270000-0x27AFFF  DECO16IC[1] tilemap + rowscroll
// 0x282008           palette DMA
// 0x284000-0x285FFF  palette RAM
// 0x3C0000-0x3C004F  DECO_ACE control
assign is_rom    = (cpu_addr[23:20] == 4'h0);                    // 0x000000-0x0FFFFF
assign is_ram    = (cpu_addr[23:16] == 8'h20);                   // 0x200000-0x20FFFF
assign is_prio   = (cpu_addr[23:16] == 8'h22) && (cpu_addr[15:1] == 15'd0);
// MAME: 0x242000-0x2427FF (2 KB = 0x800 byte). 4× più stretto del nostro vecchio.
assign is_spr1   = (cpu_addr[23:11] == 13'h484);                 // 0x242000-0x2427FF
assign is_spr2   = (cpu_addr[23:11] == 13'h48C);                 // 0x246000-0x2467FF
assign is_sprdma1= (cpu_addr[23:1] == {16'h2400, 7'd0});         // 0x240000
assign is_sprdma2= (cpu_addr[23:1] == {16'h2440, 7'd0});         // 0x244000
assign is_prot   = (cpu_addr[23:12] == 12'h24E);                 // 0x24E000-0x24EFFF
assign is_pf0    = (cpu_addr[23:14] == 10'h098) || (cpu_addr[23:14] == 10'h099) ||  // 0x260000-0x267FFF
                    (cpu_addr[23:14] == 10'h09A) || (cpu_addr[23:14] == 10'h09B);
assign is_pf1    = (cpu_addr[23:14] == 10'h09C) || (cpu_addr[23:14] == 10'h09D) ||  // 0x270000-0x27AFFF
                    (cpu_addr[23:14] == 10'h09E) || (cpu_addr[23:14] == 10'h09F);
assign is_paldma = (cpu_addr[23:4] == 20'h28200) && (cpu_addr[3:1] == 3'd4);  // 0x282008
assign is_pal    = (cpu_addr[23:13] == 11'h142);                 // 0x284000-0x285FFF
assign is_ace    = (cpu_addr[23:7] == 17'h7800);                 // 0x3C0000-0x3C004F (approx)

// Mirror DECO16IC chip 0: la ROM main (disasm 0xA94..0xABC) scrive control
// regs a $24C100, $24C200, ..., $24C600. Il chip 0 ha decode parziale e
// risponde anche qui. cpu_addr[10:8] = ctrl word index (1..6 = scroll+mode).
assign is_pf0_mirror = (cpu_addr[23:12] == 12'h24C);

// Noprw ranges (MAME boogwing.cpp:510, 534, 535):
//   0x220002-0x22FFFF : after priority_w
//   0x280000-0x28000F : palette setup (eccetto 0x282008 = paldma)
//   0x282000-0x282001 : palette setup
wire is_noprw_220 = (cpu_addr[23:16] == 8'h22) && !is_prio;
wire is_noprw_280 = (cpu_addr[23:4] == 20'h28000);
wire is_noprw_282 = (cpu_addr[23:1] == {16'h2820, 7'd0}) && !is_paldma;
assign is_noprw   = is_noprw_220 | is_noprw_280 | is_noprw_282;

// ROM bridge addressing usa indirizzo SCRAMBLED. Registro per evitare path
// combinatorio lungo cpu_addr → scramble → main_rom_addr (esce dal modulo).
reg [23:0] main_rom_addr_r;
reg        main_rom_req_r;
reg        main_rom_is_opcode_r;
always @(posedge clk) begin
	main_rom_addr_r      <= {4'd0, scrambled_addr};
	main_rom_req_r       <= is_rom & cpu_rd;
	main_rom_is_opcode_r <= cpu_is_opcode;
end
assign main_rom_addr       = main_rom_addr_r;
assign main_rom_req        = main_rom_req_r;
assign main_rom_is_opcode  = main_rom_is_opcode_r;

// === SAVESTATE — dichiarazioni bus (devono precedere il primo adaptor) ===
// SS_IDX_* = indice univoco di ogni blocco di stato. SS_NSLAVES = numero di slave.
localparam SS_IDX_WORKRAM    = 0;
localparam SS_IDX_SPR1       = 1;
localparam SS_IDX_SPR2       = 2;
localparam SS_IDX_PAL_CPU    = 3;
localparam SS_IDX_C1_PF1_MIR = 4;
localparam SS_IDX_C1_PF2_MIR = 5;
// chip0 (u_deco16_0): VRAM pf1/pf2, rowscroll pf1/pf2, control
localparam SS_IDX_C0_VRAM_PF1 = 6;
localparam SS_IDX_C0_VRAM_PF2 = 7;
localparam SS_IDX_C0_RS_PF1   = 8;
localparam SS_IDX_C0_RS_PF2   = 9;
localparam SS_IDX_C0_CTRL     = 10;
// chip1 (u_deco16_1): VRAM pf1/pf2, rowscroll pf1/pf2, control
localparam SS_IDX_C1_VRAM_PF1 = 11;
localparam SS_IDX_C1_VRAM_PF2 = 12;
localparam SS_IDX_C1_RS_PF1   = 13;
localparam SS_IDX_C1_RS_PF2   = 14;
localparam SS_IDX_C1_CTRL     = 15;
localparam SS_IDX_HUC_RAM     = 16;
localparam SS_IDX_GLOBAL      = 17;   // SSP del 68000 (modulo ss_m68k)
// chip0 VRAM shadow mirror (readback CPU pf1/pf2) — vedi blocco mirror chip0 sotto
localparam SS_IDX_C0_PF1_MIR  = 18;
localparam SS_IDX_C0_PF2_MIR  = 19;
localparam SS_IDX_HUC_CPU     = 20;   // stato interno HUC6280 (auto_ss, 246 bit)
localparam SS_IDX_OKI0        = 21;   // stato interno OKI #0 (jt6295, auto_ss 359 bit)
localparam SS_IDX_OKI1        = 22;   // stato interno OKI #1 (jt6295, auto_ss 359 bit)
localparam SS_IDX_YM          = 23;   // stato interno YM2151 (jt51, auto_ss 2774 bit)
localparam SS_IDX_ACE         = 24;   // DECO ACE register file (blend/alpha/fade, 64x16)
localparam SS_IDX_AUDIO_BUS   = 25;   // stato persistente wrapper audio (FIFO sndlatch + YM/OKI ctrl, 161 bit)
localparam SS_IDX_MISC        = 26;   // sprite DMA + palette DMA + priority_reg + irq6_pending (74 bit)
localparam SS_IDX_DECO104     = 27;   // DECO104 reg protezione (xor/nand/bank/latch/soundlatch, 70 bit)
localparam SS_IDX_DC_RB0      = 28;   // DECO104 rambank0 (RAM protezione 128x16)
localparam SS_IDX_DC_RB1      = 29;   // DECO104 rambank1 (RAM protezione 128x16)
localparam SS_NSLAVES         = 30;
// memory_stream COUNT (>= SS_NSLAVES, potenza di 2). Con SS_NSLAVES>16 serve COUNT>=32.
localparam SS_MS_COUNT        = 32;
ssbus_if ssbus();
ssbus_if ssb[SS_NSLAVES]();

// Work RAM 64KB (32K × 16-bit, byte enable). Solo accesso CPU.
// Forzo M10K per evitare LUT-RAM su 64KB (sarebbe ~500k LUT!!).
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_lo [0:32767];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_hi [0:32767];
// Causa root: write+read in 1 always inferisce 32K FF. Split = M10K safe.
reg [7:0] ram_dout_hi_r, ram_dout_lo_r;
wire [15:0] ram_dout_r = {ram_dout_hi_r, ram_dout_lo_r};
wire [14:0] ram_idx_cpu = cpu_addr[15:1];
wire we_lo_cpu = is_ram & cpu_wr & ~cpu_dsn[0];
wire we_hi_cpu = is_ram & cpu_wr & ~cpu_dsn[1];

// Savestate adaptor in serie sulla porta CPU (ZERO BRAM aggiunta): a SS idle passa i
// segnali del gioco; durante SS dirotta la porta verso il bus savestate (SS_IDX_WORKRAM).
wire [14:0] ram_idx;
wire        we_lo, we_hi;
wire [15:0] ram_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(15), .SS_IDX(SS_IDX_WORKRAM)) workram_ss (
	.clk      (clk),
	.we_lo_in (we_lo_cpu),
	.we_hi_in (we_hi_cpu),
	.addr_in  (ram_idx_cpu),
	.wdata_in (cpu_wdata),
	.we_lo_out(we_lo),
	.we_hi_out(we_hi),
	.addr_out (ram_idx),
	.wdata_out(ram_wdata_eff),
	.q_in     (ram_dout_r),
	.ssbus    (ssb[SS_IDX_WORKRAM])
);

always @(posedge clk) if (we_hi) ram_hi[ram_idx] <= ram_wdata_eff[15:8];
always @(posedge clk) if (we_lo) ram_lo[ram_idx] <= ram_wdata_eff[7:0];
always @(posedge clk) ram_dout_hi_r <= ram_hi[ram_idx];
always @(posedge clk) ram_dout_lo_r <= ram_lo[ram_idx];
wire [15:0] ram_dout = ram_dout_r;

// === DEBUG yes/no: cattura $208000, $208002, $208003 (flag player IN GIOCO). ===
// $208002 bit7 / $208003 bit7 = player p1/p2 in gioco. Se 0 nella scena CONTINUE
// ("Ready to listen?"), il blitter 0x5158 scrive SPAZI -> risposte invisibili.
// word idx = byte_addr>>1. $208000->0x4000, $208002->0x4001, $208003 = byte alto di idx 0x4001.
// $208000/$208002 sono byte: cattura il valore alla scrittura CPU.
reg [15:0] dbg_ram_8000, dbg_ram_8002;
always @(posedge clk) begin
	if (we_lo && ram_idx == 15'h4000) dbg_ram_8000[7:0]  <= ram_wdata_eff[7:0];   // $208000
	if (we_hi && ram_idx == 15'h4000) dbg_ram_8000[15:8] <= ram_wdata_eff[15:8];  // $208001
	if (we_lo && ram_idx == 15'h4001) dbg_ram_8002[7:0]  <= ram_wdata_eff[7:0];   // $208002
	if (we_hi && ram_idx == 15'h4001) dbg_ram_8002[15:8] <= ram_wdata_eff[15:8];  // $208003
end

// ROM bus: usa rom_plain (decrittato) invece di main_rom_rdata raw
// Forward decl per ModelSim 10.5b
wire [15:0] spr1_cpu_rd, spr2_cpu_rd, ace_cpu_rd, d16_0_cpu_rdata, d16_1_cpu_rdata;
wire [15:0] prot_cpu_rd;

// =====================================================================
// Chip1 VRAM shadow mirror (pattern Darius2 NinjaWarriors).
// MAME boogwing.cpp:529-530: chip1 pf1/pf2 mappati con `.ram().w(deco16ic)`.
// = scrittura va sia a RAM shadow CPU sia al deco16ic interno.
// CPU readback DEVE leggere lo shadow (non il deco16ic shared con scan).
// Senza mirror: CPU read torna 0/FFFF → bug logica gioco (AI, path, collision).
// Range:
//   $274000-$275FFF (pf1, 8 KB = 4096 word)
//   $276000-$277FFF (pf2, 8 KB = 4096 word)
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf1_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf1_mirror_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf2_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c1_pf2_mirror_hi [0:4095];
integer ii_c1m;
initial begin
	for (ii_c1m = 0; ii_c1m < 4096; ii_c1m = ii_c1m + 1) begin
		c1_pf1_mirror_lo[ii_c1m] = 8'd0; c1_pf1_mirror_hi[ii_c1m] = 8'd0;
		c1_pf2_mirror_lo[ii_c1m] = 8'd0; c1_pf2_mirror_hi[ii_c1m] = 8'd0;
	end
end
// is_pf1 = chip1 range. Bit [13] distingue pf1 (0) vs pf2 (1) — vedi
// is_pf1_data/is_pf2_data nel deco16ic_jt (cpu_addr[15:13] == 010 / 011).
wire c1_is_pf1_data = is_pf1 && (cpu_addr[15:13] == 3'b010);
wire c1_is_pf2_data = is_pf1 && (cpu_addr[15:13] == 3'b011);
wire [11:0] c1_mirror_idx = cpu_addr[12:1];

// Savestate adaptor in serie sui mirror chip1 (ZERO BRAM aggiunta).
wire c1m1_we_lo_cpu = c1_is_pf1_data && cpu_wr && ~cpu_dsn[0];
wire c1m1_we_hi_cpu = c1_is_pf1_data && cpu_wr && ~cpu_dsn[1];
wire c1m2_we_lo_cpu = c1_is_pf2_data && cpu_wr && ~cpu_dsn[0];
wire c1m2_we_hi_cpu = c1_is_pf2_data && cpu_wr && ~cpu_dsn[1];
wire c1m1_we_lo, c1m1_we_hi, c1m2_we_lo, c1m2_we_hi;
wire [11:0] c1m1_idx, c1m2_idx;
wire [15:0] c1m1_wdata_eff, c1m2_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C1_PF1_MIR)) c1m1_ss (
	.clk(clk),
	.we_lo_in(c1m1_we_lo_cpu), .we_hi_in(c1m1_we_hi_cpu), .addr_in(c1_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c1m1_we_lo), .we_hi_out(c1m1_we_hi), .addr_out(c1m1_idx), .wdata_out(c1m1_wdata_eff),
	.q_in(c1_pf1_mirror_rd), .ssbus(ssb[SS_IDX_C1_PF1_MIR])
);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C1_PF2_MIR)) c1m2_ss (
	.clk(clk),
	.we_lo_in(c1m2_we_lo_cpu), .we_hi_in(c1m2_we_hi_cpu), .addr_in(c1_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c1m2_we_lo), .we_hi_out(c1m2_we_hi), .addr_out(c1m2_idx), .wdata_out(c1m2_wdata_eff),
	.q_in(c1_pf2_mirror_rd), .ssbus(ssb[SS_IDX_C1_PF2_MIR])
);
always @(posedge clk) if (c1m1_we_lo) c1_pf1_mirror_lo[c1m1_idx] <= c1m1_wdata_eff[ 7:0];
always @(posedge clk) if (c1m1_we_hi) c1_pf1_mirror_hi[c1m1_idx] <= c1m1_wdata_eff[15:8];
always @(posedge clk) if (c1m2_we_lo) c1_pf2_mirror_lo[c1m2_idx] <= c1m2_wdata_eff[ 7:0];
always @(posedge clk) if (c1m2_we_hi) c1_pf2_mirror_hi[c1m2_idx] <= c1m2_wdata_eff[15:8];
reg [7:0] c1_pf1_mr_lo_r, c1_pf1_mr_hi_r, c1_pf2_mr_lo_r, c1_pf2_mr_hi_r;
always @(posedge clk) c1_pf1_mr_lo_r <= c1_pf1_mirror_lo[c1m1_idx];
always @(posedge clk) c1_pf1_mr_hi_r <= c1_pf1_mirror_hi[c1m1_idx];
always @(posedge clk) c1_pf2_mr_lo_r <= c1_pf2_mirror_lo[c1m2_idx];
always @(posedge clk) c1_pf2_mr_hi_r <= c1_pf2_mirror_hi[c1m2_idx];
reg c1_pf1_rd_d, c1_pf2_rd_d;
always @(posedge clk) begin
	c1_pf1_rd_d <= c1_is_pf1_data;
	c1_pf2_rd_d <= c1_is_pf2_data;
end
wire [15:0] c1_pf1_mirror_rd = {c1_pf1_mr_hi_r, c1_pf1_mr_lo_r};
wire [15:0] c1_pf2_mirror_rd = {c1_pf2_mr_hi_r, c1_pf2_mr_lo_r};
wire [15:0] c1_mirror_rdata  = c1_pf2_rd_d ? c1_pf2_mirror_rd :
                                c1_pf1_rd_d ? c1_pf1_mirror_rd :
                                d16_1_cpu_rdata;

// =====================================================================
// Chip0 VRAM shadow mirror (stesso pattern chip1 sopra, FUNZIONANTE su HW).
// CAUSA bug YES/NO: deco16ic_jt mux cpu_rdata (460-463) NON serve is_pf1_data/
// is_pf2_data -> le letture VRAM dati del chip0 ($264000/$266000) tornano 0x0000.
// La routine 0x16AFC fa read-modify-write sui glifi YES/NO (BG0): legge 0 ->
// azzera i tile-code -> testo invisibile. "1P" sopravvive (riscritto plain).
// Range: $264000-$265FFF (pf1, [15:13]==010) / $266000-$267FFF (pf2, ==011).
// Gating su is_pf0 (NON is_pf0_mirror=$24Cxxx, che e' ctrl remap).
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf1_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf1_mirror_hi [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf2_mirror_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] c0_pf2_mirror_hi [0:4095];
integer ii_c0m;
initial begin
	for (ii_c0m = 0; ii_c0m < 4096; ii_c0m = ii_c0m + 1) begin
		c0_pf1_mirror_lo[ii_c0m] = 8'd0; c0_pf1_mirror_hi[ii_c0m] = 8'd0;
		c0_pf2_mirror_lo[ii_c0m] = 8'd0; c0_pf2_mirror_hi[ii_c0m] = 8'd0;
	end
end
wire c0_is_pf1_data = is_pf0 && (cpu_addr[15:13] == 3'b010);
wire c0_is_pf2_data = is_pf0 && (cpu_addr[15:13] == 3'b011);
wire [11:0] c0_mirror_idx = cpu_addr[12:1];
wire c0m1_we_lo_cpu = c0_is_pf1_data && cpu_wr && ~cpu_dsn[0];
wire c0m1_we_hi_cpu = c0_is_pf1_data && cpu_wr && ~cpu_dsn[1];
wire c0m2_we_lo_cpu = c0_is_pf2_data && cpu_wr && ~cpu_dsn[0];
wire c0m2_we_hi_cpu = c0_is_pf2_data && cpu_wr && ~cpu_dsn[1];
wire c0m1_we_lo, c0m1_we_hi, c0m2_we_lo, c0m2_we_hi;
wire [11:0] c0m1_idx, c0m2_idx;
wire [15:0] c0m1_wdata_eff, c0m2_wdata_eff;
wire [15:0] c0_pf1_mirror_rd, c0_pf2_mirror_rd;
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C0_PF1_MIR)) c0m1_ss (
	.clk(clk),
	.we_lo_in(c0m1_we_lo_cpu), .we_hi_in(c0m1_we_hi_cpu), .addr_in(c0_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c0m1_we_lo), .we_hi_out(c0m1_we_hi), .addr_out(c0m1_idx), .wdata_out(c0m1_wdata_eff),
	.q_in(c0_pf1_mirror_rd), .ssbus(ssb[SS_IDX_C0_PF1_MIR])
);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_C0_PF2_MIR)) c0m2_ss (
	.clk(clk),
	.we_lo_in(c0m2_we_lo_cpu), .we_hi_in(c0m2_we_hi_cpu), .addr_in(c0_mirror_idx), .wdata_in(cpu_wdata),
	.we_lo_out(c0m2_we_lo), .we_hi_out(c0m2_we_hi), .addr_out(c0m2_idx), .wdata_out(c0m2_wdata_eff),
	.q_in(c0_pf2_mirror_rd), .ssbus(ssb[SS_IDX_C0_PF2_MIR])
);
always @(posedge clk) if (c0m1_we_lo) c0_pf1_mirror_lo[c0m1_idx] <= c0m1_wdata_eff[ 7:0];
always @(posedge clk) if (c0m1_we_hi) c0_pf1_mirror_hi[c0m1_idx] <= c0m1_wdata_eff[15:8];
always @(posedge clk) if (c0m2_we_lo) c0_pf2_mirror_lo[c0m2_idx] <= c0m2_wdata_eff[ 7:0];
always @(posedge clk) if (c0m2_we_hi) c0_pf2_mirror_hi[c0m2_idx] <= c0m2_wdata_eff[15:8];
reg [7:0] c0_pf1_mr_lo_r, c0_pf1_mr_hi_r, c0_pf2_mr_lo_r, c0_pf2_mr_hi_r;
always @(posedge clk) c0_pf1_mr_lo_r <= c0_pf1_mirror_lo[c0m1_idx];
always @(posedge clk) c0_pf1_mr_hi_r <= c0_pf1_mirror_hi[c0m1_idx];
always @(posedge clk) c0_pf2_mr_lo_r <= c0_pf2_mirror_lo[c0m2_idx];
always @(posedge clk) c0_pf2_mr_hi_r <= c0_pf2_mirror_hi[c0m2_idx];
reg c0_pf1_rd_d, c0_pf2_rd_d;
always @(posedge clk) begin
	c0_pf1_rd_d <= c0_is_pf1_data;
	c0_pf2_rd_d <= c0_is_pf2_data;
end
assign c0_pf1_mirror_rd = {c0_pf1_mr_hi_r, c0_pf1_mr_lo_r};
assign c0_pf2_mirror_rd = {c0_pf2_mr_hi_r, c0_pf2_mr_lo_r};
wire [15:0] c0_mirror_rdata  = c0_pf2_rd_d ? c0_pf2_mirror_rd :
                                c0_pf1_rd_d ? c0_pf1_mirror_rd :
                                d16_0_cpu_rdata;

// pal CPU readback ritorna 0 (palette write-only dal lato CPU 68K)
assign cpu_rdata = is_rom         ? rom_plain       :
                    is_ram         ? ram_dout       :
                    is_spr1        ? spr1_cpu_rd    :
                    is_spr2        ? spr2_cpu_rd    :
                    is_ace         ? ace_cpu_rd     :
                    is_pf0         ? c0_mirror_rdata:
                    is_pf0_mirror  ? d16_0_cpu_rdata:
                    is_pf1         ? c1_mirror_rdata:
                    is_prot        ? prot_cpu_rd    :
                    16'hFFFF;
// cpu_dtackn ora generato da jtframe_68kdtack_cen via bus_cs/bus_busy

// =====================================================================
// DECO104 protection / IO mux (stub minimale — vedi rtl/common/deco104.sv)
// =====================================================================
// Stub minimale che mappa i 4 indirizzi noti del main (da disassembly):
//   $24E138 → SYSTEM     (system_port)
//   $24E150 → soundlatch write (→ H6280 IRQ0 quando audio sarà istanziato)
//   $24E344 → INPUTS     (inputs_port)
//   $24E6C0 → DSW        (dsw_port)
// Tutti gli altri offset ritornano FFFF (sufficiente per il boot, no
// check di magic value protezione attivi ai primi cicli).

wire  [7:0] sndlatch_data;
wire        sndlatch_irq_main_pulse;   // pulse main scrive nuovo latch
// Savestate DECO104: adaptor sui 70 bit di reg protezione (xor/nand/bank/latch/soundlatch).
wire [68:0] dc_ss_out, dc_ss_in;
wire        dc_ss_wr;
auto_save_adaptor #(.N_BITS(69), .SS_IDX(SS_IDX_DECO104)) u_deco104_ss_adaptor (
	.clk(clk), .ssbus(ssb[SS_IDX_DECO104]),
	.bits_in(dc_ss_out), .bits_out(dc_ss_in), .bits_wr(dc_ss_wr)
);
deco104 #(.SS_RB0_IDX(SS_IDX_DC_RB0), .SS_RB1_IDX(SS_IDX_DC_RB1)) u_prot (
	.clk             (clk),
	.reset           (reset),
	.cpu_addr        (cpu_addr[11:0]),  // offset relativo a $24E000
	.cpu_cs          (is_prot),
	.cpu_rd          (cpu_rd),
	.cpu_wr          (cpu_wr),
	.cpu_wdata       (cpu_wdata),
	.cpu_dsn         (cpu_dsn),
	.cpu_rdata       (prot_cpu_rd),
	.port_a          (inputs_port),
	.port_b          (system_port),
	.port_c          (dsw_port),
	.soundlatch_data (sndlatch_data),
	.soundlatch_irq  (sndlatch_irq_main_pulse),
	.soundlatch_rd   (1'b0),             // H6280 non istanziata → mai legge
	.soundlatch_dout (),
	.dc_ss_in        (dc_ss_in),
	.dc_ss_out       (dc_ss_out),
	.dc_ss_wr        (dc_ss_wr),
	.ss_rb0          (ssb[SS_IDX_DC_RB0]),
	.ss_rb1          (ssb[SS_IDX_DC_RB1])
);

// =====================================================================
// Savestate: sprite DMA FSM + palette DMA FSM + priority_reg + irq6_pending (74 bit)
// =====================================================================
localparam integer MISC_SS_BITS = 74;
wire [MISC_SS_BITS-1:0] misc_ss_out, misc_ss_in;
wire                   misc_ss_wr;
auto_save_adaptor #(.N_BITS(MISC_SS_BITS), .SS_IDX(SS_IDX_MISC)) u_misc_ss_adaptor (
	.clk     (clk),
	.ssbus   (ssb[SS_IDX_MISC]),
	.bits_in (misc_ss_out),
	.bits_out(misc_ss_in),
	.bits_wr (misc_ss_wr)
);
// SAVE: concatena in ordine (save = restore ordine identico)
//  [73:58] priority_reg  [57] irq6_pending  [56:46] dma_rd_idx  [45:36] dma_wr_idx  [35] dma_which
//  [34] dma2_active  [33] dma1_active  [32] pal_dma_active  [31:19] pal_dma_rd_idx  [18:8] pal_dma_wr_idx
//  [7:0] pal_dma_b_lat
assign misc_ss_out = {priority_reg, irq6_pending, dma_rd_idx, dma_wr_idx, dma_which, dma2_active, dma1_active,
                      pal_dma_active, pal_dma_rd_idx, pal_dma_wr_idx, pal_dma_b_lat};
// RESTORE: estrai con lo stesso ordine (endianness identica al save)
wire [15:0] misc_priority_load        = misc_ss_in[73:58];
wire        misc_irq6_load            = misc_ss_in[57];
wire [10:0] misc_dma_rd_idx_load      = misc_ss_in[56:46];
wire [9:0]  misc_dma_wr_idx_load      = misc_ss_in[45:36];
wire        misc_dma_which_load       = misc_ss_in[35];
wire        misc_dma2_load            = misc_ss_in[34];
wire        misc_dma1_load            = misc_ss_in[33];
wire        misc_pal_dma_active_load  = misc_ss_in[32];
wire [12:0] misc_pal_dma_rd_idx_load  = misc_ss_in[31:19];
wire [10:0] misc_pal_dma_wr_idx_load  = misc_ss_in[18:8];
wire [7:0]  misc_pal_dma_b_lat_load   = misc_ss_in[7:0];

// =====================================================================
// Priority register (0x220000) — write da CPU, usato dal video mixer (TODO)
// =====================================================================
reg [15:0] priority_reg;
always @(posedge clk) begin
	if (reset) priority_reg <= 16'd0;
	else if (is_prio & cpu_wr) begin
		if (~cpu_dsn[0]) priority_reg[7:0]  <= cpu_wdata[7:0];
		if (~cpu_dsn[1]) priority_reg[15:8] <= cpu_wdata[15:8];
	end
	else if (misc_ss_wr) priority_reg <= misc_priority_load;   // restore (trasparente a SS spento)
end

// === DEBUG: latch dei control regs di chip1 dal bus CPU (no touch al renderer) ===
// chip1 control = is_pf1 & cpu_addr[15:4]==0 (0x270000-0x27000F), index = cpu_addr[3:1].
// ctrl[1]=pf1_scroll_x, [2]=pf1_scroll_y, [3]=pf2_scroll_x, [4]=pf2_scroll_y, [5]=style, [6]=enable.
wire c1_is_ctrl = is_pf1 & (cpu_addr[15:4] == 12'd0);
reg [15:0] dbg_c1_ctrl1, dbg_c1_ctrl2, dbg_c1_ctrl3, dbg_c1_ctrl4, dbg_c1_ctrl5, dbg_c1_ctrl6, dbg_c1_ctrl7;
always @(posedge clk) begin
	if (c1_is_ctrl & cpu_wr) begin
		case (cpu_addr[3:1])
			3'd1: dbg_c1_ctrl1 <= cpu_wdata;
			3'd2: dbg_c1_ctrl2 <= cpu_wdata;
			3'd3: dbg_c1_ctrl3 <= cpu_wdata;
			3'd4: dbg_c1_ctrl4 <= cpu_wdata;
			3'd5: dbg_c1_ctrl5 <= cpu_wdata;
			3'd6: dbg_c1_ctrl6 <= cpu_wdata;
			3'd7: dbg_c1_ctrl7 <= cpu_wdata;
			default: ;
		endcase
	end
end

// === DEBUG: latch control regs di CHIP0 (BG0/BG1) = il valore RUNTIME reale. ===
// chip0 control = is_pf0 & cpu_addr[15:4]==0 ($260000-$26000F). ctrl5=enable, ctrl6=8x8/flip, ctrl7=bank.
// Serve per il bug yes/no: vedere se ctrl5 chip0 bit7 (pf1/text enable) e' davvero 1 nella scena.
wire c0_is_ctrl = is_pf0 & (cpu_addr[15:4] == 12'd0);
reg [15:0] dbg_c0_ctrl2, dbg_c0_ctrl5, dbg_c0_ctrl6, dbg_c0_ctrl7;
always @(posedge clk) begin
	if (c0_is_ctrl & cpu_wr) begin
		case (cpu_addr[3:1])
			3'd2: dbg_c0_ctrl2 <= cpu_wdata;   // pf1 scroll_y
			3'd5: dbg_c0_ctrl5 <= cpu_wdata;   // enable (bit7=pf1/text, bit15=pf2/BG1)
			3'd6: dbg_c0_ctrl6 <= cpu_wdata;   // 8x8/flip
			3'd7: dbg_c0_ctrl7 <= cpu_wdata;   // bank
			default: ;
		endcase
	end
end

// =====================================================================
// SOUND CPU H6280 @ 8.055 MHz (32.22/4)
// =====================================================================
// TODO: istanziare HUC6280 + memory map audio BoogieWings
//   - ROM da DDRAM (64KB)
//   - YM2151 @ 0x110000
//   - OKIM6295 #1 @ 0x120000
//   - OKIM6295 #2 @ 0x130000
//   - soundlatch @ 0x140000 (read da DECO104)
//   - IRQ0 = soundlatch_irq_cb, IRQ2 = YM2151 IRQ
//   - RAM 8KB @ 0x1F0000

// =====================================================================
// DECO16IC × 2 (tilemap engine, 4 BG layer totali)
// =====================================================================
// Tilegen[0]: pf1+pf2 (BG 1+2), CS @ 0x260000-0x26AFFF
// Tilegen[1]: pf1+pf2 (BG 3+4), CS @ 0x270000-0x27AFFF
// Tile ROM da SDRAM: tilerom_req via tile_rom_arbiter (TODO)
wire [3:0]  d16_0_pf1_pix;
wire [4:0]  d16_0_pf2_pix;     // 5-bit per BG1 5bpp (BoogieWings)
wire [4:0]  d16_0_pf1_col,  d16_0_pf2_col;
wire        d16_0_pf1_opq,  d16_0_pf2_opq;
wire        flip_screen;        // chip0 ctrl[0] bit 7 (MAME boogwing.cpp:419)
// Render x/y flippati quando flip_screen=1 (MAME flip_screen_set). Solo per i
// TILEGEN: gli sprite ricevono le coordinate grezze e si ribaltano da soli.
// Schermo BoogieWings: hcnt 0..441 attivo 0..319 → x flip = 319-x.
// Template.sv: render_x=hcnt (= x di MAME), render_y=vcnt+1 (tutta l'immagine
// alzata di 1 px). In MAME l'asse dello specchio verticale e' 255; nello spazio
// alzato di 1 diventa 255+2*1 = 257, non 255. Misurato: col flip gli sprite,
// che dentro usano le costanti di MAME (240-y, 304-x), cadono esattamente
// sull'asse 257 (banco NsSprites_Flip_Bench, 0 differenze su 76160 confronti).
wire [9:0] render_x_flip = flip_screen ? (10'd319 - render_x) : render_x;
wire [9:0] render_y_flip = flip_screen ? (10'd257 - render_y) : render_y;
wire [3:0]  d16_1_pf1_pix;
wire [4:0]  d16_1_pf2_pix;     // 5-bit interfaccia ma 4bpp (bit 4 sempre 0)
wire [4:0]  d16_1_pf1_col,  d16_1_pf2_col;
wire        d16_1_pf1_opq,  d16_1_pf2_opq;
wire [23:0] d16_0_pf1_rom_addr, d16_0_pf2_rom_addr;
wire [2:0]  d16_0_pf1_rid, d16_0_pf2_rid;
wire        d16_0_pf1_rom_req,  d16_0_pf2_rom_req;
wire [31:0] d16_0_pf1_rom_data, d16_0_pf2_rom_data;
wire        d16_0_pf1_rom_valid,d16_0_pf2_rom_valid;
wire        d16_0_pf2_p4_req;
wire  [7:0] d16_0_pf2_p4_data;
wire        d16_0_pf2_p4_valid;
wire [23:0] d16_1_pf1_rom_addr, d16_1_pf2_rom_addr;
wire [2:0]  d16_1_pf1_rid, d16_1_pf2_rid;
wire        d16_1_pf1_rom_req,  d16_1_pf2_rom_req;
wire [31:0] d16_1_pf1_rom_data, d16_1_pf2_rom_data;
wire        d16_1_pf1_rom_valid,d16_1_pf2_rom_valid;
// d16_0_cpu_rdata/d16_1_cpu_rdata già forward-declarate sopra

// BoogieWings bank callbacks (boogwing.cpp:749, 761):
//   tilegen[0]: bank1=none, bank2=bank_callback (mode 1)
//   tilegen[1]: bank1=bank_callback2, bank2=bank_callback2 (mode 2)
// GFX base address SDRAM (tile_byte_addr relativo a TILE_BASE):
//   tiles1 (text)  @ 0x000000  (128KB)
//   tiles2 (BG1)   @ 0x020000  (3MB)
//   tiles3 (BG2)   @ 0x320000  (2MB)
// Mirror $24Cxxx: rimappa l'offset come accesso ctrl regs (0x0000-0x000F)
// usando cpu_addr[10:8] come ctrl index. La ROM main (disasm 0xA94..0xABC)
// scrive a $24C100,$24C200,$24C300,$24C400,$24C500,$24C600 = ctrl[0..6].
// Sintetizziamo un cpu_addr "virtuale" che passi al chip come word ctrl.
wire [15:0] d16_0_cpu_addr_eff = is_pf0_mirror
    ? {12'd0, cpu_addr[10:8], 1'b0}  // mappa a 0x0000-0x000E (8 ctrl word)
    : cpu_addr[15:0];

// Chip 0: pf1 = text 8x8 (tiles1), pf2 = BG1 16x16 (tiles2)
// Modulo: deco16ic_jt (scanline-based, ispirato Jotego BAC06).
// Vecchio deco16ic istanza COMMENTATA — file vecchio resta nel qsf.
deco16ic_jt #(
	.BANK1_MODE(2'd0),
	.BANK2_MODE(2'd1),
	.PF1_COL_BANK(5'd0), .PF1_COL_MASK(4'hF),
	.PF2_COL_BANK(5'd0), .PF2_COL_MASK(4'hF),
	.PF1_TILE_SIZE(8),   .PF2_TILE_SIZE(16),
	.PF1_REGION_ID(3'd0),
	.PF2_REGION_ID(3'd2),
	// BG1 5bpp: chip0.pf2 fetcha anche plane 4 da TILES2_HI (= mbd-02).
	.PF2_HAS_5BPP(1),
	.PF2_REGION_ID_P4(3'd4),  // RID_TILES2_HI
	.SS_VRAM_PF1_IDX(SS_IDX_C0_VRAM_PF1),
	.SS_VRAM_PF2_IDX(SS_IDX_C0_VRAM_PF2),
	.SS_RS_PF1_IDX(SS_IDX_C0_RS_PF1),
	.SS_RS_PF2_IDX(SS_IDX_C0_RS_PF2),
	.SS_CTRL_IDX(SS_IDX_C0_CTRL)
) u_deco16_0 (
	.clk(clk), .reset(reset),
	.cpu_addr(d16_0_cpu_addr_eff),
	.cpu_cs(is_pf0 | is_pf0_mirror),
	.cpu_rd(cpu_rd), .cpu_wr(cpu_wr),
	.cpu_wdata(cpu_wdata), .cpu_dsn(cpu_dsn),
	.cpu_rdata(d16_0_cpu_rdata),
	.render_x(render_x_flip), .render_y(render_y_flip),
	.hblank_in(hblank_in), .vblank_in(vblank_in), .ce_pix(ce_pix),
	.pf1_pix(d16_0_pf1_pix), .pf2_pix(d16_0_pf2_pix),
	.pf1_col(d16_0_pf1_col), .pf2_col(d16_0_pf2_col),
	.pf1_opaque(d16_0_pf1_opq), .pf2_opaque(d16_0_pf2_opq),
	.flip_screen(flip_screen),
	.pf1_rom_addr(d16_0_pf1_rom_addr), .pf1_region_id(d16_0_pf1_rid),
	.pf1_rom_req(d16_0_pf1_rom_req),
	.pf1_rom_data(d16_0_pf1_rom_data), .pf1_rom_valid(d16_0_pf1_rom_valid),
	.pf2_rom_addr(d16_0_pf2_rom_addr), .pf2_region_id(d16_0_pf2_rid),
	.pf2_rom_req(d16_0_pf2_rom_req),
	.pf2_rom_data(d16_0_pf2_rom_data), .pf2_rom_valid(d16_0_pf2_rom_valid),
	.pf2_p4_req  (d16_0_pf2_p4_req),
	.pf2_p4_data (d16_0_pf2_p4_data),
	.pf2_p4_valid(d16_0_pf2_p4_valid),
	.osd_tile_decode_mode(osd_tile_decode_mode),
	.osd_pixel_bit_msb(osd_pixel_bit_msb),
	.osd_plane_rev32(osd_plane_rev32),
	.osd_nibble_swap(osd_nibble_swap),
	.osd_byte_swap_ab(osd_byte_swap_ab),
	.osd_xhalf_inv(osd_xhalf_inv),
	.osd_tile_hi_rev(osd_tile_hi_rev),
	.osd_vram_swizzle(osd_vram_swizzle),
	.osd_p4_byte_pos (osd_bg1_p4_byte_pos),
	.osd_p4_brev8    (osd_bg1_p4_brev8),
	.osd_p4_bit_shift(osd_bg1_p4_bit_shift),
	.combine_mode    (1'b0),
	.ss_vram_pf1(ssb[SS_IDX_C0_VRAM_PF1]),
	.ss_vram_pf2(ssb[SS_IDX_C0_VRAM_PF2]),
	.ss_rs_pf1  (ssb[SS_IDX_C0_RS_PF1]),
	.ss_rs_pf2  (ssb[SS_IDX_C0_RS_PF2]),
	.ss_ctrl    (ssb[SS_IDX_C0_CTRL])
);

// Chip 1: pf1 + pf2 entrambi BG2 16x16 (tiles3). pf2 col_bank=16.
deco16ic_jt #(
	.BANK1_MODE(2'd2),
	.BANK2_MODE(2'd2),
	.PF1_COL_BANK(5'd0),  .PF1_COL_MASK(4'hF),
	.PF2_COL_BANK(5'd16), .PF2_COL_MASK(4'hF),
	.PF1_TILE_SIZE(16),   .PF2_TILE_SIZE(16),
	.PF1_REGION_ID(3'd5),
	.PF2_REGION_ID(3'd5),
	.SS_VRAM_PF1_IDX(SS_IDX_C1_VRAM_PF1),
	.SS_VRAM_PF2_IDX(SS_IDX_C1_VRAM_PF2),
	.SS_RS_PF1_IDX(SS_IDX_C1_RS_PF1),
	.SS_RS_PF2_IDX(SS_IDX_C1_RS_PF2),
	.SS_CTRL_IDX(SS_IDX_C1_CTRL)
) u_deco16_1 (
	.clk(clk), .reset(reset),
	.cpu_addr(cpu_addr[15:0]),
	.cpu_cs(is_pf1),
	.cpu_rd(cpu_rd), .cpu_wr(cpu_wr),
	.cpu_wdata(cpu_wdata), .cpu_dsn(cpu_dsn),
	.cpu_rdata(d16_1_cpu_rdata),
	.render_x(render_x_flip), .render_y(render_y_flip),
	.hblank_in(hblank_in), .vblank_in(vblank_in), .ce_pix(ce_pix),
	.pf1_pix(d16_1_pf1_pix), .pf2_pix(d16_1_pf2_pix),
	.pf1_col(d16_1_pf1_col), .pf2_col(d16_1_pf2_col),
	.pf1_opaque(d16_1_pf1_opq), .pf2_opaque(d16_1_pf2_opq),
	.flip_screen(),
	.pf1_rom_addr(d16_1_pf1_rom_addr), .pf1_region_id(d16_1_pf1_rid),
	.pf1_rom_req(d16_1_pf1_rom_req),
	.pf1_rom_data(d16_1_pf1_rom_data), .pf1_rom_valid(d16_1_pf1_rom_valid),
	.pf2_rom_addr(d16_1_pf2_rom_addr), .pf2_region_id(d16_1_pf2_rid),
	.pf2_rom_req(d16_1_pf2_rom_req),
	.pf2_rom_data(d16_1_pf2_rom_data), .pf2_rom_valid(d16_1_pf2_rom_valid),
	.pf2_p4_req  (),       // chip1 no 5bpp
	.pf2_p4_data (8'd0),
	.pf2_p4_valid(1'b0),
	.osd_tile_decode_mode(osd_tile_decode_mode),
	.osd_pixel_bit_msb(osd_pixel_bit_msb),
	.osd_plane_rev32(osd_plane_rev32),
	.osd_nibble_swap(osd_nibble_swap),
	.osd_byte_swap_ab(osd_byte_swap_ab),
	.osd_xhalf_inv(osd_xhalf_inv),
	.osd_tile_hi_rev(osd_tile_hi_rev),
	.osd_vram_swizzle(osd_vram_swizzle),
	.osd_p4_byte_pos (2'd0),
	.osd_p4_brev8    (1'b0),
	.osd_p4_bit_shift(1'b0),
	.combine_mode    ((priority_reg[2:0] == 3'd4) || (priority_reg[2:0] == 3'd5)),
	.ss_vram_pf1(ssb[SS_IDX_C1_VRAM_PF1]),
	.ss_vram_pf2(ssb[SS_IDX_C1_VRAM_PF2]),
	.ss_rs_pf1  (ssb[SS_IDX_C1_RS_PF1]),
	.ss_rs_pf2  (ssb[SS_IDX_C1_RS_PF2]),
	.ss_ctrl    (ssb[SS_IDX_C1_CTRL])
);

// TODO: tile ROM arbiter tra deco16_0, deco16_1, (text)
// Per ora collego deco16_0 al SDRAM tile bridge (priorità singola)
// Riferimento Verilog: reference/jt/cop/hdl/jtcop_bac06.v

// =====================================================================
// DECO_SPRITE × 2 (sprite engine)
// =====================================================================
// Sprite RAM 2KB ciascuno (0x242000-0x2427FF, 0x246000-0x2467FF)
// Doppio buffer: CPU scrive in sprite_ram_cpu[N], DMA trigger su 0x240000/
// 0x244000 copia in sprite_ram_buf[N] che alimenta il renderer.
// Sprite RAM 2KB. Doppio buffer: cpu (CPU rw + DMA read) → buf (renderer read).
// 2 BRAM ognuna, 2 porte ognuna. DMA pipelinato:
//   - rd_idx: legge da cpu (via mux con spr_idx CPU)
//   - 1 ck dopo: scrive in buf con index = rd_idx-1
//   - dma_active resta su 1025 cicli (1024 read + 1 drain)
// Sprite RAM 2KB (1024×16) ciascuna. 8-bit lane split per inferenza M10K
// pulita (1 write port CPU + 1 read port CPU readback).
// CPU-side RAM (CPU rw + DMA read source)
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_hi [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_hi [0:1023];
// Buffer side (DMA write dest + renderer read source) — buffered_spriteram MAME-style
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_buf_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr1_buf_hi [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_buf_lo [0:1023];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] spr2_buf_hi [0:1023];
integer ii_spr;
initial for (ii_spr=0; ii_spr<1024; ii_spr=ii_spr+1) begin
	spr1_lo[ii_spr] = 8'd0; spr1_hi[ii_spr] = 8'd0;
	spr2_lo[ii_spr] = 8'd0; spr2_hi[ii_spr] = 8'd0;
	spr1_buf_lo[ii_spr] = 8'd0; spr1_buf_hi[ii_spr] = 8'd0;
	spr2_buf_lo[ii_spr] = 8'd0; spr2_buf_hi[ii_spr] = 8'd0;
end
wire [9:0] spr_idx = cpu_addr[10:1];

reg dma1_active, dma2_active;
reg [10:0] dma_rd_idx;          // 0..1024 (FSM kept for future decospr)
wire dma_active = dma1_active | dma2_active;

// Glitch fix: CPU 68K non deve scrivere sram durante DMA copy → corrompeva
// buffer mid-frame con mix vecchio/nuovo state.
wire spr1_we_lo_cpu = is_spr1 & cpu_wr & ~cpu_dsn[0] & ~dma_active;
wire spr1_we_hi_cpu = is_spr1 & cpu_wr & ~cpu_dsn[1] & ~dma_active;
wire spr2_we_lo_cpu = is_spr2 & cpu_wr & ~cpu_dsn[0] & ~dma_active;
wire spr2_we_hi_cpu = is_spr2 & cpu_wr & ~cpu_dsn[1] & ~dma_active;

// Savestate adaptor in serie sulla porta CPU sprite (ZERO BRAM aggiunta).
wire spr1_we_lo, spr1_we_hi, spr2_we_lo, spr2_we_hi;
wire [9:0]  spr1_idx, spr2_idx;
wire [15:0] spr1_wdata_eff, spr2_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(10), .SS_IDX(SS_IDX_SPR1)) spr1_ss (
	.clk(clk),
	.we_lo_in(spr1_we_lo_cpu), .we_hi_in(spr1_we_hi_cpu), .addr_in(spr_idx), .wdata_in(cpu_wdata),
	.we_lo_out(spr1_we_lo), .we_hi_out(spr1_we_hi), .addr_out(spr1_idx), .wdata_out(spr1_wdata_eff),
	.q_in(spr1_cpu_rd), .ssbus(ssb[SS_IDX_SPR1])
);
ss_ram16_adaptor #(.WIDTHAD(10), .SS_IDX(SS_IDX_SPR2)) spr2_ss (
	.clk(clk),
	.we_lo_in(spr2_we_lo_cpu), .we_hi_in(spr2_we_hi_cpu), .addr_in(spr_idx), .wdata_in(cpu_wdata),
	.we_lo_out(spr2_we_lo), .we_hi_out(spr2_we_hi), .addr_out(spr2_idx), .wdata_out(spr2_wdata_eff),
	.q_in(spr2_cpu_rd), .ssbus(ssb[SS_IDX_SPR2])
);

always @(posedge clk) if (spr1_we_lo) spr1_lo[spr1_idx] <= spr1_wdata_eff[ 7:0];
always @(posedge clk) if (spr1_we_hi) spr1_hi[spr1_idx] <= spr1_wdata_eff[15:8];
always @(posedge clk) if (spr2_we_lo) spr2_lo[spr2_idx] <= spr2_wdata_eff[ 7:0];
always @(posedge clk) if (spr2_we_hi) spr2_hi[spr2_idx] <= spr2_wdata_eff[15:8];

reg [7:0] spr1_rd_lo, spr1_rd_hi, spr2_rd_lo, spr2_rd_hi;
always @(posedge clk) spr1_rd_lo <= spr1_lo[spr1_idx];
always @(posedge clk) spr1_rd_hi <= spr1_hi[spr1_idx];
always @(posedge clk) spr2_rd_lo <= spr2_lo[spr2_idx];
always @(posedge clk) spr2_rd_hi <= spr2_hi[spr2_idx];
assign spr1_cpu_rd = {spr1_rd_hi, spr1_rd_lo};
assign spr2_cpu_rd = {spr2_rd_hi, spr2_rd_lo};

// Sprite renderer read port — legge dal BUFFER (= snapshot dopo DMA).
// Prima leggeva dalla RAM CPU diretta -> coordinate Y/X cambiate sotto il render -> sprite saltellanti.
wire [9:0]  spr_render_addr;
reg  [7:0]  spr1_rd_render_lo, spr1_rd_render_hi;
always @(posedge clk) spr1_rd_render_lo <= spr1_buf_lo[spr_render_addr];
always @(posedge clk) spr1_rd_render_hi <= spr1_buf_hi[spr_render_addr];
wire [15:0] spr_render_data = {spr1_rd_render_hi, spr1_rd_render_lo};

// Sprite chip1 (sprites2) renderer read port — buffer.
wire [9:0]  spr2_render_addr;
reg  [7:0]  spr2_rd_render_lo, spr2_rd_render_hi;
always @(posedge clk) spr2_rd_render_lo <= spr2_buf_lo[spr2_render_addr];
always @(posedge clk) spr2_rd_render_hi <= spr2_buf_hi[spr2_render_addr];
wire [15:0] spr2_render_data = {spr2_rd_render_hi, spr2_rd_render_lo};

// DMA controller: copy LIVE -> BUFFER al VBlank rise, entrambi i chip in sequenza.
reg [9:0] dma_wr_idx;
reg dma_wr_en;
reg dma_which;
reg vblank_in_d;
always @(posedge clk) vblank_in_d <= vblank_in;
wire vblank_rise = vblank_in & ~vblank_in_d;

always @(posedge clk) begin
	if (reset) begin
		dma1_active <= 1'b0;
		dma2_active <= 1'b0;
		dma_rd_idx  <= 11'd0;
		dma_wr_idx  <= 10'd0;
		dma_wr_en   <= 1'b0;
		dma_which   <= 1'b0;
	end else if (misc_ss_wr) begin   // restore DMA sprite FSM (trasparente a SS spento)
		dma1_active <= misc_dma1_load;
		dma2_active <= misc_dma2_load;
		dma_rd_idx  <= misc_dma_rd_idx_load;
		dma_wr_idx  <= misc_dma_wr_idx_load;
		dma_which   <= misc_dma_which_load;
	end else if (vblank_rise & ~paused_safe) begin
		// MAME buffered_spriteram16: copy LIVE -> BUFFER a VBlank rise (bufsprite.h).
		// Trigger qui (NON cpu_wr a 0x240000 che e' la prima word della live RAM).
		// Gated da ~paused_safe: durante pausa/SS il DMA NON gira (buffer sprite coerente,
		// niente copia a meta' transizione). Al restore riparte al 1o vblank -> ricostruisce.
		dma1_active <= 1'b1;
		dma2_active <= 1'b1;
		dma_rd_idx  <= 11'd0;
		dma_wr_en   <= 1'b0;
		dma_which   <= 1'b0;
	end else if (dma_active) begin
		// FIX OFFSET-1 confermato matematicamente:
		//   - dma1_rd_lo_r in ck Y = spr1_lo[rd_idx_at_ck_(Y-1)]
		//   - write event a posedge Y+1 usa valori di ck Y.
		//   - Per scrivere buf[K]<=spr1_lo[K] serve: rd_idx_Y-1=K (perche' dma1_rd_lo_r_Y=spr1_lo[K])
		//     AND wr_idx_Y=K. Quindi wr_idx = rd_idx[K_prev] = K = (rd_idx_Y - 1 - 1)+1 = rd_idx_Y-1...
		//   - Equivalente: wr_idx setting "wr_idx <= rd_idx_current" da' wr_idx_(Y+1)=rd_idx_Y.
		//   - Per K: serve wr_idx in ck Y = K, dma1_rd_lo_r in ck Y = spr1_lo[K] (rd_idx_Y-1=K, rd_idx_Y=K+1).
		//   - wr_idx_Y = (assegnato a posedge Y) = (rd_idx in ck Y-1) = K (perche' rd_idx_Y-1 = K).
		//   - Quindi formula: wr_idx <= rd_idx[9:0]  (NO -1). Funziona per rd_idx 0..1023 (writes K=0..1023).
		// Loop fino a 1025: rd_idx 0,1,...,1024,1025. Write usa rd_idx 0..1023 -> wr_idx_Y registered 1..1024(=0 overflow ignorato).
		if (dma_rd_idx == 11'd1025 && dma_which == 1'b1) begin
			dma1_active <= 1'b0;
			dma2_active <= 1'b0;
			dma_wr_en   <= 1'b0;
		end else if (dma_rd_idx == 11'd1025 && dma_which == 1'b0) begin
			dma_rd_idx  <= 11'd0;
			dma_which   <= 1'b1;
			dma_wr_en   <= 1'b0;
		end else begin
			dma_wr_en  <= (dma_rd_idx <= 11'd1023);
			dma_wr_idx <= dma_rd_idx[9:0];
			dma_rd_idx <= dma_rd_idx + 11'd1;
		end
	end else begin
		dma_wr_en <= 1'b0;
	end
end

// DMA read port: durante dma_active, la CPU readback NON e' usata, quindi spr_idx
// e' libera di puntare a dma_rd_idx per leggere il source RAM. Mux il bus.
// 1 ck latency: dato letto al ck successivo al cambio addr -> dma_wr_idx = dma_rd_idx-1.
wire [9:0] dma_rd_addr = dma_rd_idx[9:0];
reg [7:0] dma1_rd_lo_r, dma1_rd_hi_r, dma2_rd_lo_r, dma2_rd_hi_r;
always @(posedge clk) dma1_rd_lo_r <= spr1_lo[dma_rd_addr];
always @(posedge clk) dma1_rd_hi_r <= spr1_hi[dma_rd_addr];
always @(posedge clk) dma2_rd_lo_r <= spr2_lo[dma_rd_addr];
always @(posedge clk) dma2_rd_hi_r <= spr2_hi[dma_rd_addr];

// DMA write port: scrive nel buffer all'indice dma_wr_idx quando dma_wr_en
always @(posedge clk) if (dma_wr_en && dma_which == 1'b0) spr1_buf_lo[dma_wr_idx] <= dma1_rd_lo_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b0) spr1_buf_hi[dma_wr_idx] <= dma1_rd_hi_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b1) spr2_buf_lo[dma_wr_idx] <= dma2_rd_lo_r;
always @(posedge clk) if (dma_wr_en && dma_which == 1'b1) spr2_buf_hi[dma_wr_idx] <= dma2_rd_hi_r;

// TODO: 2 istanze decospr renderer che leggono sprite_ram_buf1/2 + sprite ROM
// Riferimento Verilog: reference/jt/cop/hdl/jtcop_obj{,_buffer,_draw}.v

// =====================================================================
// DECO_ACE (palette + alpha blend mixer)
// =====================================================================
// Palette RAM 8KB = 4096 colori × 16-bit. Doppio buffer (buffered_palette16):
// CPU scrive in pal_cpu, DMA su 0x282008 copia in pal_buf usato dal mixer.
// ACE control register file: 0x3C0000-0x3C004F = 80 byte (40 word) di
// configurazione alpha/blend.
// Palette RAM 4096×16. pal_cpu (CPU rw + DMA read) → pal_buf (renderer read).
// 2 BRAM, 2 porte ognuna. DMA pipelinato a 2 stadi (BRAM lat 1).
// Palette RAM 4096×16. 8-bit lane split. CPU readback NON serve (write-only
// dal punto di vista di MAME boogwing: il chip è palette device, leggere è
// debug). DMA legge sempre, write CPU non collide.
// Init esplicito BRAM palette: senza init alcune M10K partono con garbage
// che il CPU non riesce mai a clearare se non scrive TUTTA la palette al boot.
// Pattern ActFancer "palette non inizializzata = monnezza" → fix preventivo.
// Palette DECO_ACE 24-bit RGB888 (MAME deco_ace.cpp):
//   m_paletteram[2048] è uint32: bits 23:16 = B byte, 15:8 = G byte, 7:0 = R byte.
//   CPU word16 access: offset even → uint32[31:16] (= 0x00BB), odd → uint32[15:0] (= 0xGGRR).
//   $284000-$285FFF (8KB) = 4096 word16 = 2048 entries.
// Il vecchio decoder (xBGR_444) era SBAGLIATO → colori storti per livello (ogni livello
// scrive byte diversi che venivano interpretati come nibble → palette wrong).
// no_rw_check: durante CPU write + DMA read concorrenti su pal_cpu_*, e durante
// DMA write + renderer read concorrenti su pal_buf, M10K mixed_port deve
// tornare valore vecchio (no glitch). Senza l'attributo Quartus infer NEW_DATA
// = output X transitorio = impurità flicker sui pixel renderizzati durante DMA.
(* ramstyle = "M10K", no_rw_check *) reg [7:0]  pal_cpu_lo [0:4095];
(* ramstyle = "M10K", no_rw_check *) reg [7:0]  pal_cpu_hi [0:4095];
// pal_buf duplicato: pal_buf_top per lookup top_pal_idx, pal_buf_bot per bot_pal_idx.
// Permette 2 read paralleli senza conflitto port M10K (max 2 porte: 1 write DMA + 1 read).
// DMA scrive in entrambi in parallelo → contenuto identico, niente coerenza problema.
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_buf_top [0:2047];   // {B,G,R} 8-bit
(* ramstyle = "M10K", no_rw_check *) reg [23:0] pal_buf_bot [0:2047];
integer init_i;
initial begin
	for (init_i = 0; init_i < 4096; init_i = init_i + 1) begin
		pal_cpu_lo[init_i] = 8'd0;
		pal_cpu_hi[init_i] = 8'd0;
	end
	for (init_i = 0; init_i < 2048; init_i = init_i + 1) begin
		pal_buf_top[init_i] = 24'd0;
		pal_buf_bot[init_i] = 24'd0;
	end
end
wire [11:0] pal_idx = cpu_addr[12:1];

reg pal_dma_active;
reg [12:0] pal_dma_rd_idx;     // 0..4096 (legge 4096 word CPU = 2048 entries × 2)
reg [10:0] pal_dma_wr_idx;     // 0..2047 entry idx
reg        pal_dma_wr_en;
reg [7:0]  pal_dma_b_lat;      // byte B catturato da word even
reg [23:0] pal_dma_wr_data;    // dato da scrivere (latched 1 ck prima per matchare wr_en)

wire pal_we_lo_cpu = is_pal & cpu_wr & ~cpu_dsn[0];
wire pal_we_hi_cpu = is_pal & cpu_wr & ~cpu_dsn[1];

// Savestate adaptor sulla porta WRITE palette (ZERO BRAM aggiunta). Durante SS il
// gioco e' in pausa (DMA fermo): il read SS usa la porta DMA (pal_dma_rd_idx dirottato
// a ssbus.addr) e q_in = pal_cpu_rd. A SS idle: trasparente (pal_we=cpu, idx=pal_idx).
wire pal_we_lo, pal_we_hi;
wire [11:0] pal_idx_w;
wire [15:0] pal_wdata_eff;
wire        pal_ss_sel = ssb[SS_IDX_PAL_CPU].access(SS_IDX_PAL_CPU);
ss_ram16_adaptor #(.WIDTHAD(12), .SS_IDX(SS_IDX_PAL_CPU)) pal_ss (
	.clk(clk),
	.we_lo_in(pal_we_lo_cpu), .we_hi_in(pal_we_hi_cpu), .addr_in(pal_idx), .wdata_in(cpu_wdata),
	.we_lo_out(pal_we_lo), .we_hi_out(pal_we_hi), .addr_out(pal_idx_w), .wdata_out(pal_wdata_eff),
	.q_in(pal_cpu_rd), .ssbus(ssb[SS_IDX_PAL_CPU])
);
always @(posedge clk) if (pal_we_lo) pal_cpu_lo[pal_idx_w] <= pal_wdata_eff[ 7:0];
always @(posedge clk) if (pal_we_hi) pal_cpu_hi[pal_idx_w] <= pal_wdata_eff[15:8];

// DMA read port (BRAM lat=1). Durante SS il read indirizza ssbus.addr (DMA fermo in pausa).
wire [11:0] pal_rd_idx = pal_ss_sel ? ssb[SS_IDX_PAL_CPU].addr[11:0] : pal_dma_rd_idx[11:0];
reg [7:0] pal_dma_rd_lo, pal_dma_rd_hi;
always @(posedge clk) pal_dma_rd_lo <= pal_cpu_lo[pal_rd_idx];
always @(posedge clk) pal_dma_rd_hi <= pal_cpu_hi[pal_rd_idx];
wire [15:0] pal_cpu_rd = {pal_dma_rd_hi, pal_dma_rd_lo};

// FSM DMA:
//   rd_idx avanza 0..4095 (legge tutte le word CPU). Latency 1 ck.
//   Quando arriva dato (rd_idx+1 prev), se prev rd_idx[0]=0 → word even → byte B = pal_cpu_rd[7:0] in latch.
//   Quando arriva dato e prev rd_idx[0]=1 → word odd → G=rd[15:8], R=rd[7:0] → compose + write.
//   pal_dma_wr_idx = (rd_idx_prev) >> 1.
reg pal_dma_rd_d0;   // bit 0 di rd_idx ritardato 1 ck (= identifica B vs GR all'arrivo)
reg pal_dma_rd_valid_d;  // c'era una read in corso al ck precedente
always @(posedge clk) begin
	if (reset) begin
		pal_dma_active   <= 1'b0;
		pal_dma_rd_idx   <= 13'd0;
		pal_dma_wr_idx   <= 11'd0;
		pal_dma_wr_en    <= 1'b0;
		pal_dma_b_lat    <= 8'd0;
		pal_dma_wr_data  <= 24'd0;
		pal_dma_rd_d0    <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end else if (misc_ss_wr) begin   // restore palette DMA FSM (trasparente a SS spento)
		pal_dma_active <= misc_pal_dma_active_load;
		pal_dma_rd_idx <= misc_pal_dma_rd_idx_load;
		pal_dma_wr_idx <= misc_pal_dma_wr_idx_load;
		pal_dma_b_lat  <= misc_pal_dma_b_lat_load;
	end else if ((is_paldma & cpu_wr) | ss_restore_done) begin
		// Trigger DMA palette: comando gioco OPPURE restore appena finito (ricostruisce pal_buf
		// da pal_cpu gia' ricaricato -> palette coerente senza salvare pal_buf nel SS).
		pal_dma_active   <= 1'b1;
		pal_dma_rd_idx   <= 13'd0;
		pal_dma_wr_en    <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end else if (pal_dma_active) begin
		// Default: no write this ck
		pal_dma_wr_en <= 1'b0;
		// Latch bit 0 + valid del ciclo di lettura corrente (per uso al ck+1)
		pal_dma_rd_d0 <= pal_dma_rd_idx[0];
		pal_dma_rd_valid_d <= (pal_dma_rd_idx < 13'd4096);
		// All'arrivo del dato (= read ck precedente)
		if (pal_dma_rd_valid_d) begin
			if (!pal_dma_rd_d0) begin
				// word even = high uint32 = byte B
				pal_dma_b_lat <= pal_cpu_rd[7:0];
			end else begin
				// word odd = low uint32 = {G,R}. Compone subito e latcha:
				// la wr_en + wr_data sono assertati al ck successivo, ma a quel
				// punto pal_cpu_rd è del word_idx successivo (read pipelined).
				// Fix: cattura wr_data ORA (insieme a wr_en).
				pal_dma_wr_en   <= 1'b1;
				pal_dma_wr_data <= {pal_dma_b_lat, pal_cpu_rd[15:8], pal_cpu_rd[7:0]};
				pal_dma_wr_idx  <= pal_dma_rd_idx[11:1] - 11'd1;
			end
		end
		// Avanza rd_idx finché non finito
		if (pal_dma_rd_idx == 13'd4096) begin
			pal_dma_active <= 1'b0;
		end else begin
			pal_dma_rd_idx <= pal_dma_rd_idx + 13'd1;
		end
	end else begin
		pal_dma_wr_en <= 1'b0;
		pal_dma_rd_valid_d <= 1'b0;
	end
end

// Pattern M10K saving: 1 always block per array, scritto separatamente.
always @(posedge clk) if (pal_dma_wr_en) pal_buf_top[pal_dma_wr_idx] <= pal_dma_wr_data;
always @(posedge clk) if (pal_dma_wr_en) pal_buf_bot[pal_dma_wr_idx] <= pal_dma_wr_data;

// ACE control register file (0x3C0000-0x3C004F = 40 word). MLAB inferito.
(* ramstyle = "MLAB" *) reg [15:0] ace_regs [0:63];
wire [5:0] ace_idx = cpu_addr[6:1];

// Savestate adaptor su ace_regs (blend/alpha/fade). Byte-split lo/hi via dsn, come la palette.
// Durante SS (gioco in pausa) la porta write e' dirottata al ssbus; a SS idle: trasparente.
wire        ace_we_lo_cpu = is_ace & cpu_wr & ~cpu_dsn[0];
wire        ace_we_hi_cpu = is_ace & cpu_wr & ~cpu_dsn[1];
wire        ace_we_lo, ace_we_hi;
wire [5:0]  ace_idx_w;
wire [15:0] ace_wdata_eff;
ss_ram16_adaptor #(.WIDTHAD(6), .SS_IDX(SS_IDX_ACE)) ace_ss (
	.clk(clk),
	.we_lo_in(ace_we_lo_cpu), .we_hi_in(ace_we_hi_cpu), .addr_in(ace_idx), .wdata_in(cpu_wdata),
	.we_lo_out(ace_we_lo), .we_hi_out(ace_we_hi), .addr_out(ace_idx_w), .wdata_out(ace_wdata_eff),
	.q_in(ace_cpu_rd), .ssbus(ssb[SS_IDX_ACE])
);
always @(posedge clk) begin
	if (ace_we_lo) ace_regs[ace_idx_w][7:0]  <= ace_wdata_eff[7:0];
	if (ace_we_hi) ace_regs[ace_idx_w][15:8] <= ace_wdata_eff[15:8];
end
reg [15:0] ace_cpu_rd_r;
// La read SS usa la porta di lettura: durante SS il renderer e' fermo, l'idx e' dirottato.
wire [5:0] ace_rd_idx = ssb[SS_IDX_ACE].access(SS_IDX_ACE) ? ssb[SS_IDX_ACE].addr[5:0] : ace_idx;
always @(posedge clk) ace_cpu_rd_r <= ace_regs[ace_rd_idx];
assign ace_cpu_rd = ace_cpu_rd_r;

// Pixel mixer alpha-blend DECO_ACE implementato sotto (~riga 1100+).

// =====================================================================
// DECO104PROT (I/O + protection MCU simulato)
// =====================================================================
// TODO: deco104 protection device
//   - Port A: INPUTS (p1+p2)
//   - Port B: SYSTEM (coin+start)
//   - Port C: DSW
//   - soundlatch_irq_cb → H6280 IRQ0
//   - interface_scramble_reverse + magic_read_address_xor
// Riferimento Verilog: reference/jt/cop/hdl/jtcop_prot.v (deco104 simile)

// =====================================================================
// YM2151 @ 3.58 MHz (32.22/9)
// =====================================================================
// TODO: jt51 istanza (rtl/jt51/jt51.v)
//   - IRQ → H6280 IRQ2
//   - port_write → sound bankswitch
//   - mix 32% nel master volume

// =====================================================================
// OKIM6295 × 2
// =====================================================================
// TODO: 2 istanze jt6295 (rtl/jt6295/jt6295.v)
//   - OKI1 @ 1.007 MHz (32.22/32) PIN7_HIGH → mix 56%
//   - OKI2 @ 2.014 MHz (32.22/16) PIN7_HIGH → mix 12%
//   - Sample ROM da DDRAM (port read audio)

// =====================================================================
// VIDEO MIXER — 4 tile layer, sprite TODO
// =====================================================================
// Priority semplice: primo layer opaque vince. Vero priorità BoogieWings ha
// priority_w (0x220000) che determina ordine layer. Per ora ordine fisso:
//   sprite > deco16_1 pf1 > deco16_1 pf2 > deco16_0 pf1 > deco16_0 pf2 > bg
// (sprite non implementato → salta direttamente ai tile)
//
// Palette index base (boogwing.cpp:gfx_boogwing entries):
//   tiles1 (text 8×8)   = palette base 0x800
//   tiles2 (deco16_0)   = palette base 0x100
//   tiles3 (deco16_1)   = palette base 0x300
//
// Per ora pf1/pf2 di ogni chip usano stessa base (l'col_bank è applicato esterno):
//   deco16_0 pf*: base 0x100
//   deco16_1 pf*: base 0x300 / 0x300+16*16 per col_bank=16 (pf2)
//
// pen 4-bit + colour 4-bit (top) → 8-bit index nella palette banca

// Priority mixer: priority encoder + 8-bit pen index registrati.
// Layer base palette: deco16_0 = 0x100, deco16_1 pf1 = 0x300, pf2 = 0x400.
// Palette index per layer (MAME gfx_boogwing boogwing.cpp:671):
//   tiles1 (text)  → base 0x800, 16 set × 16 col (4bpp)
//   tiles2 (BG1)   → base 0x100, 16 set × 32 col (5bpp → ora 4bpp,
//                                upper half vuota finché plane 4 non impl)
//   tiles3 (BG2)   → base 0x300, 32 set × 16 col (4bpp)
// Formula: pal_idx = base + (set * Ncol) + pix
//   tiles1: pal_idx = 0x800 + col * 16 + pix
//   tiles2: pal_idx = 0x100 + col * 32 + pix
//   tiles3: pal_idx = 0x300 + col * 16 + pix
// Priority: top → bottom (default MAME boogwing.cpp:467-472 else case):
//   1. text       (chip0 pf1, palette 0x800)         ← TOP
//   2. BG1        (chip0 pf2, palette 0x100, tiles2)
//   3. BG2 alpha  (chip1 pf1, palette 0x300, tiles3)
//   4. BG2 base   (chip1 pf2, palette 0x300+16, tiles3, col_bank=16)
//   5. background pen 0
//
// La logica MAME ha 5 modi diversi via priority_reg[2:0] (vedi screen_update);
// per ora implemento solo l'ordine default. priority_reg salvato ma non usato.
// (col_bank di chip1 pf2 è già dentro d16_1_pf2_col → non sommato qui)
// Palette base per layer — MAME GFXDECODE (boogwing.cpp:672-674):
//   tiles1 text = 0x800, tiles2 BG1 = 0x100, tiles3 BG2 = 0x300.
// Hardcoded ai default verificati HW (OSD override rimosso 2026-05-21).
wire [11:0] pal_bg0_base = 12'h800;
wire [11:0] pal_bg1_base = 12'h100;
wire [11:0] pal_bg2_base = 12'h300;
wire [11:0] pal_bg3_base = 12'h300;

// =====================================================================
// Layer mixer con priority register MAME-compliant (5 modi).
// Riferimento: boogwing.cpp:417-477 screen_update.
// =====================================================================
//
// Componenti pixel:
//   text  = chip0.pf1 (sempre TOP, drawn dopo mix sprite)
//   bg1   = chip0.pf2
//   bg2a  = chip1.pf1 (BG2 alpha)
//   bg2b  = chip1.pf2 (BG2 base)
//   bg2c  = combine 8bpp di chip1 (pf1 nibble basso + pf2 nibble alto)
//
// Modi priority[2:0]:
//   0/6/7 (default): bg2b (BOT) | bg2a (mid) | bg1 (top)        | text
//   1, 2           : bg2b (BOT) | bg1 (mid)  | bg2a (top)       | text
//   3              : come 1/2 (alpha shadow non implementato)  | text
//   4              : bg2c (BOT, combine)     | bg1 (top)        | text
//   5              : bg1  (BOT)              | bg2c (top combine)| text

wire [2:0] pri = priority_reg[2:0];
wire mode_combine = (pri == 3'd4) || (pri == 3'd5);
wire mode_bg2a_top = (pri == 3'd1) || (pri == 3'd2) || (pri == 3'd3);

wire mode_5       = (pri == 3'd5);

// Combine BG2 (per modi 4/5). chip1 e' 4bpp: prendo solo [3:0] di pf2_pix.
wire [3:0]  bg2c_pen_lo = d16_1_pf1_opq ? d16_1_pf1_pix : 4'd0;
wire [3:0]  bg2c_pen_hi = d16_1_pf2_opq ? d16_1_pf2_pix[3:0] : 4'd0;
wire        bg2c_opq    = d16_1_pf1_opq | d16_1_pf2_opq;
wire [11:0] bg2c_pal_pre = pal_bg2_base + {3'd0, d16_1_pf1_col, d16_1_pf1_pix};
wire [11:0] bg2c_pal_idx = {bg2c_pal_pre[11:8], bg2c_pal_pre[7:4] | bg2c_pen_hi, bg2c_pal_pre[3:0]};

// Pal_idx singoli (per modi separati)
wire [11:0] bg1_pal_idx  = pal_bg1_base + {2'd0, d16_0_pf2_col, 5'd0} + {8'd0, d16_0_pf2_pix};
wire [11:0] bg2a_pal_idx = pal_bg2_base + {3'd0, d16_1_pf1_col, d16_1_pf1_pix};
// chip1.pf2 e' 4bpp (pen[3:0]). pf2_pix arriva 5-bit ma bit 4 sempre 0.
// MAME formula: pal_idx = base + col_5b * 16 + pen[3:0].
wire [11:0] bg2b_pal_idx = pal_bg3_base + {3'd0, d16_1_pf2_col, d16_1_pf2_pix[3:0]};
wire [11:0] text_pal_idx = pal_bg0_base + {3'd0, d16_0_pf1_col, d16_0_pf1_pix};

// Forward decl per ModelSim 10.5b (Quartus accetta inline forward use).
// Definizione effettiva dei segnali sotto vicino a u_sprites.
wire [11:0] sprite_pxl;
// Chip1 esce dal renderer su DUE strati: opaco e trasparente (fumo/esplosioni).
// Tenerli separati serve perche' il pixel trasparente non cancelli nel buffer
// quello opaco che copre: cosi' la fusione ha sotto l'oggetto vero e non lo
// sfondo. Vedi il commento su linebuf_spr1_a in bw_sprites.sv.
wire [11:0] sprite2_opq_pxl;
wire [11:0] sprite2_alp_pxl;
wire        spr2_alp_present = (sprite2_alp_pxl[3:0] != 4'd0);
// Il pixel di chip1 che il mixer considera: il trasparente se c'e', se no l'opaco.
wire [11:0] sprite2_pxl = spr2_alp_present ? sprite2_alp_pxl : sprite2_opq_pxl;
// Pixel opaco dello STESSO chip che sta sotto a quello trasparente.
wire        spr2_under_opq = spr2_alp_present && (sprite2_opq_pxl[3:0] != 4'd0);
wire [11:0] spr2_under_pal_idx = 12'h700 + {3'd0, sprite2_opq_pxl[7:4], sprite2_opq_pxl[3:0]};

// Sprite chip0 (sprites1): MAME GFXDECODE 0x500, 32 banks x 16 colors.
// MAME mixer: pal_idx = 0x500 + (pix1 & 0x1ff) dove pix1 = {color[7:0], pen[3:0]}
// → pal_idx = 0x500 + {color[4:0], pen[3:0]} (= 5 bit color = 32 banks)
// Bug fix: era color[3:0] (= solo 16 banks), ora color[4:0] (= 32 banks MAME-corretto).
wire [3:0]  spr_pen   = sprite_pxl[3:0];
wire [7:0]  spr_color = sprite_pxl[11:4];
// chip filter: 00=both, 01=chip0, 10=chip1, 11=none
wire chip0_visible = (osd_spr_chip_filter == 2'b00) || (osd_spr_chip_filter == 2'b01);
wire chip1_visible = (osd_spr_chip_filter == 2'b00) || (osd_spr_chip_filter == 2'b10);
wire        spr_opq   = (spr_pen != 4'd0);
wire [11:0] spr_pal_idx = 12'h500 + {2'd0, spr_color[4:0], spr_pen};

// Sprite chip1 (sprites2): MAME 0x700, 16 banks x 16 colors.
// pal_idx = 0x700 + {color[3:0], pen[3:0]} (= 4 bit color = 16 banks).
// Bug fix: era color[2:0] (= solo 8 banks), ora color[3:0].
wire [3:0]  spr2_pen   = sprite2_pxl[3:0];
wire [7:0]  spr2_color = sprite2_pxl[11:4];
wire        spr2_opq   = (spr2_pen != 4'd0);
wire [11:0] spr2_pal_idx = 12'h700 + {3'd0, spr2_color[3:0], spr2_pen};

// MAME boogwing.cpp mix() priorità sprite vs sprite dinamica (pixel-by-pixel).
// pri bits = bit 9,10 del raw pixel = mio color[5], color[6] (= x_word[14], x_word[15]).
// MAME (priority_reg & 0x7) default case → spri1 = 2/8/32, spri2 = 4/16/64.
// pri_bits = {color[6], color[5]} = {x_bit15, x_bit14}
// MAME spri1: 0x600=0b11 → 2 ; 0x400=0b10 → 8 ; else → 32
// MAME spri2: 0x600=0b11 → 4 ; (0x400 OR 0x200)=non-zero → 16 ; else → 64
wire [1:0] spr_pri  = {spr_color[6],  spr_color[5]};   // chip0 pri bits
wire [1:0] spr2_pri = {spr2_color[6], spr2_color[5]};  // chip1 pri bits

// MAME spri1 (boogwing.cpp:240-262) ha un CASE su priority:
//   case 0x00: (pix1&0x600)==0x600 -> 2 ; ==0x400 -> 8 ; else -> 32
//   default (priority!=0): (pix1&0x400) -> 8 ; else -> 32   (MAI 2!)
// Il core usava SEMPRE lo schema 0x00 (2/8/32). In priority 4 (cutscene pre-boss, il testo
// e' uno sprite chip0) questo dava spri1=2 quando spr_pri=2'b11, mentre MAME da' spri1=8.
// Con spri1 sottostimato, chip1_over_chip0=(spri2>spri1) scattava e il testo (chip0) veniva
// coperto da chip1 -> testo cutscene invisibile. Fix: rispettare il case priority come MAME.
reg [6:0] spri1, spri2;
always @(*) begin
	if (pri == 3'd0) begin
		case (spr_pri)
			2'b11:   spri1 = 7'd2;
			2'b10:   spri1 = 7'd8;
			default: spri1 = 7'd32;
		endcase
	end else begin
		spri1 = spr_pri[1] ? 7'd8 : 7'd32;   // MAME default: (pix1 & 0x400) ? 8 : 32
	end
	case (spr2_pri)
		2'b11:                spri2 = 7'd4;
		2'b10, 2'b01:         spri2 = 7'd16;
		default:              spri2 = 7'd64;
	endcase
end

// chip1 sopra chip0 se spri2 > spri1 (MAME default).
//
// ECCEZIONE dalla PROM di priorita' della scheda (kj-00.15n, blocco del modo 0;
// il gioco usa ANCHE altri modi e il bit 3 - fine livello, boss - quindi questa
// eccezione vale solo quando priority_reg[2:0] == 0).
// Con entrambi gli sprite davanti (bit10 = 0 su tutti e due) la tabella dice
// "si vedono entrambi", TRANNE quando pix1 bit9 = 0 e pix2 bit9 = 1.
// MAME invece calcola spri1 = 32 (perche' p1 in {0,1} finisce nel ramo else) e
// spri2 = 16 (perche' p2 = 1 entra in "else if (pix2 & 0x600)"): con bit9 = 1 su
// entrambi la condizione spri2 > spri1 e' falsa e il pixel del chip 1 viene
// buttato via. Sulla scheda quel pixel si vede.
// Decodifica e prove: docs/50_prom_priorita_kj00.md.
wire prom0_both_front  = (pri == 3'd0) && !spr_pri[1] && !spr2_pri[1];
wire prom0_chip0_alone = ~spr_pri[0] & spr2_pri[0];
wire chip1_over_chip0  = prom0_both_front ? ~prom0_chip0_alone : (spri2 > spri1);

// === MAME priority bitmap (bg_pri) per sprite vs playfield ===
// MAME boogwing.cpp:437-471: dopo screen.priority().fill(0), ogni tilemap_draw
// passa un priority_value che viene scritto nella priority bitmap per i pixel
// opachi disegnati. Poi mix() confronta pri1/pri2 (sprite) > bgpri per decidere.
//
// MAME draw sequence (pri_reg & 0x7):
//   case 0x5: PF2[0] OPAQUE=0, combine[1] pri=32
//   case 0x4: combine[1] OPAQUE=0, PF2[0] pri=32
//   case 0x1/0x2: PF2[1] OPAQUE=0, PF2[0] pri=8, PF1[1] pri=32
//   case 0x3: PF2[1] OPAQUE=0, PF2[0] pri=8, PF1[1] alpha (NO priority write)
//   default (0,6,7): PF2[1] OPAQUE=0, PF1[1] pri=8, PF2[0] pri=32
//
// Mapping nomi RTL:
//   PF2[0] = d16_0_pf2 = BG1
//   PF1[1] = d16_1_pf1 = FG0 (BG2 alpha tmap)
//   PF2[1] = d16_1_pf2 = FG1 (BG2 base)
//   combine[1] = bg2c (= FG0|FG1 combined)
//
// bg_pri viene aggiornato in ordine: l'ultimo layer opaque disegnato sovrascrive.
// Equivalente: scorro reverso, prendo il primo opaque.
reg [6:0] bg_pri;
always @(*) begin
	bg_pri = 7'd0;
	case (pri)
		3'd5: begin
			if      (bg2c_opq)         bg_pri = 7'd32;  // combine (ultimo)
			else if (d16_0_pf2_opq)    bg_pri = 7'd0;   // BG1 opaque
		end
		3'd4: begin
			if      (d16_0_pf2_opq)    bg_pri = 7'd32;  // BG1 (ultimo)
			else if (bg2c_opq)         bg_pri = 7'd0;   // combine opaque
		end
		3'd1, 3'd2: begin
			if      (d16_1_pf1_opq)    bg_pri = 7'd32;  // FG0 (ultimo)
			else if (d16_0_pf2_opq)    bg_pri = 7'd8;   // BG1
			else if (d16_1_pf2_opq)    bg_pri = 7'd0;   // FG1 opaque
		end
		3'd3: begin
			// FG0 in mode 3 = alpha tmap, NO priority write
			if      (d16_0_pf2_opq)    bg_pri = 7'd8;   // BG1
			else if (d16_1_pf2_opq)    bg_pri = 7'd0;   // FG1 opaque
		end
		default: begin // 0, 6, 7
			if      (d16_0_pf2_opq)    bg_pri = 7'd32;  // BG1 (ultimo)
			else if (d16_1_pf1_opq)    bg_pri = 7'd8;   // FG0
			else if (d16_1_pf2_opq)    bg_pri = 7'd0;   // FG1 opaque
		end
	endcase
end

// pri1 = sprite chip0 priority vs playfield (MAME boogwing.cpp:264-295)
// pri2 = sprite chip1 priority vs playfield (MAME boogwing.cpp:316-338)
// IMPORTANTE: MAME checks tipo "(pix & 0x400) == 0x400" testano SOLO il bit 10
// (= spr_pri[1]), NON l'esatto pattern 2'b10. Quindi spr_pri=2'b11 soddisfa pure.
reg [6:0] pri1, pri2;
always @(*) begin
	// pri1
	case (pri)
		3'd1: pri1 = (spr_pri != 2'b00)       ? 7'd16 : 7'd64;
		3'd0: pri1 = spr_pri[1]               ? 7'd16 : 7'd64;
		default: begin
			if      (spr_pri == 2'b11)        pri1 = 7'd4;
			else if (spr_pri[1])              pri1 = 7'd16;
			else                              pri1 = 7'd64;
		end
	endcase
	// pri2
	case (pri)
		3'd2: begin
			if      (spr2_pri == 2'b11)       pri2 = 7'd4;
			else if (spr2_pri[1])             pri2 = 7'd16;
			else                              pri2 = 7'd64;
		end
		3'd3:    pri2 = spr2_pri[1]            ? 7'd16 : 7'd64;
		default: pri2 = spr2_pri[1]            ? 7'd16 : 7'd64;
	endcase
end

// Sprite-vs-playfield: visible solo se pri > bg_pri (MAME mix() linee 359/371)
wire spr0_above_bg  = (pri1 > bg_pri);
wire spr1_above_bg  = (pri2 > bg_pri);

// drawnpixe1 flags MAME (mix() line 357-387): pixel sprite EFFETTIVAMENTE disegnato
wire chip0_drawn = layer_spr_en && chip0_visible && spr_opq && spr0_above_bg;
wire chip1_drawn = layer_spr_en && chip1_visible && spr2_opq && spr1_above_bg
                   && (chip1_over_chip0 || !chip0_drawn);

// MODE 3 shadow apply (MAME line 396-411):
//   pri3 = 32. condizione: bg2_drawed (= bgpri==8 && nessun sprite) OR
//   (sprite_drawn && pri_sprite <= pri3=32).
//   E poi filtro: ((pix2 & 0x900) != 0x900) || ((spri2 <= spri1) && sprite1_drawed)
//   pix2 bit 11 = spr2_color[7], bit 8 = spr2_color[4]. & 0x900 == 0x900 → entrambi.
wire mode3_bg2_drawed = (bg_pri == 7'd8) && !chip0_drawn && !chip1_drawn;
wire mode3_sprite1_drawed = chip0_drawn && (pri1 <= 7'd32);
wire mode3_sprite2_drawed = chip1_drawn && (pri2 <= 7'd32);
wire mode3_pix2_900       = spr2_color[7] && spr2_color[4];  // pix2 & 0x900 == 0x900
wire mode3_filter_pass    = !mode3_pix2_900 || ((spri2 <= spri1) && mode3_sprite1_drawed);
wire mode3_shadow_apply   = (pri == 3'd3) && layer_fg0_en && d16_1_pf1_opq
                          && (mode3_bg2_drawed
                              || (mode3_sprite1_drawed && !(chip1_drawn))
                              || (mode3_sprite2_drawed && !(chip0_drawn))
                              || (mode3_sprite1_drawed && mode3_sprite2_drawed))
                          && mode3_filter_pass;

// tmap_pal_idx = pixel del BG layer più alto opaque al pixel corrente.
// MAME mix() linea 369: dstline[x] = paldata[tmappix] (= ultimo tilemap drawn).
// Usato come "sotto" quando sprite chip1 alpha-blend per vederci attraverso il BG.
// BACKDROP: dove tutti i layer sono trasparenti, MAME mostra pen 0x400 (boogwing.cpp:435
// bitmap.fill(pen(0x400))), NON pen 0 (nero). Senza backdrop, il blend sopra il cielo
// aperto mischia con nero -> MACCHIE NERE. Fallback = backdrop, non 12'd0.
localparam [11:0] PAL_BACKDROP = 12'h400;
reg [11:0] tmap_pal_idx;
always @(*) begin
	case (pri)
		3'd5: begin
			if      (bg2c_opq)         tmap_pal_idx = bg2c_pal_idx;     // combine ultimo
			else if (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		3'd4: begin
			if      (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1 ultimo
			else if (bg2c_opq)         tmap_pal_idx = bg2c_pal_idx;
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		3'd1, 3'd2: begin
			if      (d16_1_pf1_opq)    tmap_pal_idx = bg2a_pal_idx;     // FG0 ultimo
			else if (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1
			else if (d16_1_pf2_opq)    tmap_pal_idx = bg2b_pal_idx;     // FG1
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		3'd3: begin
			if      (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;
			else if (d16_1_pf2_opq)    tmap_pal_idx = bg2b_pal_idx;
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
		default: begin // 0, 6, 7
			if      (d16_0_pf2_opq)    tmap_pal_idx = bg1_pal_idx;      // BG1 ultimo
			else if (d16_1_pf1_opq)    tmap_pal_idx = bg2a_pal_idx;
			else if (d16_1_pf2_opq)    tmap_pal_idx = bg2b_pal_idx;
			else                       tmap_pal_idx = PAL_BACKDROP;
		end
	endcase
end

// === Sprite chip1 alpha-blend (MAME boogwing.cpp:305-314) ===
// pix2 = (colour << 4) | pen → mapping al mio sistema:
//   pix2[3:0]   = spr2_pen[3:0]
//   pix2[7:4]   = spr2_color[3:0]  (= 4 bit colour LSB visibili nel pal_idx)
//   pix2[8]     = spr2_color[4]    (= x_word bit 13)
//   pix2[11]    = spr2_color[7]    (= y_word bit 15)
//   pix2 & 0x80 = spr2_color[3]    (= colour bit 3 = x_word bit 12)
//   pix2 & 8    = spr2_pen[3]      (= pen MSB)
//
// MAME alpha2 logic:
//   default: alpha2 = get_alpha((pix2 >> 4) & 0xf)  = get_alpha(spr2_color[3:0])
//   if pix2[8]:
//      if pix2[11]: alpha2 = (pix2&8) ? 0xff : get_alpha(0x14 + ((pix2-1) & 0x7))
//      else:        alpha2 = get_alpha(0x10 + (pix2[7] ? 1 : 0))
//   else if pix2[11]: alpha2 = get_alpha(0x12 + (pix2[7] ? 1 : 0))
//
// MAME get_alpha(N): regval = ace_regs[N][7:0];
//   if regval > 0x20: return 0x80 (special)
//   else: return clamp_unsigned(255 - (regval << 3))
//
// Quando alpha2 < 0xff → blend sprite con strato sotto.
function [7:0] ace_alpha_of(input [7:0] regval);
	reg [10:0] sh, sub;
	begin
		sh  = {3'd0, regval} << 3;
		sub = 11'd255 - sh;
		ace_alpha_of = (regval > 8'h20) ? 8'h80
		             : (sub[10] ? 8'd0 : sub[7:0]);
	end
endfunction

wire pix2_bit8  = spr2_color[4];
wire pix2_bit11 = spr2_color[7];
wire pix2_bit7  = spr2_color[3];
wire pix2_bit3  = spr2_pen[3];
// pix2[2:0] = pen[2:0] → "(pix2 - 1) & 0x7" su 8 bit, ma usato solo in LUT 0x14..0x1b
wire [2:0] pix2_minus1_low3 = {spr2_pen[2:0]} - 3'd1;

reg [5:0] alpha_idx_r;
reg       alpha_is_const_ff;
always @(*) begin
	alpha_is_const_ff = 1'b0;
	alpha_idx_r = {2'd0, spr2_color[3:0]};   // default: get_alpha(pix2>>4 & 0xf)
	if (pix2_bit8) begin
		if (pix2_bit11) begin
			// PROVATO A TOGLIERLA E RIMESSA (2026-09-23): boogwing.cpp:309 dichiara
			// opaco il pixel col bit 3 del pen acceso senza leggere la LUT dell'ACE.
			// Sembrava una semplificazione dell'emulatore da scavalcare, ma il
			// confronto a schermo con MAME dice il contrario: senza, le esplosioni
			// diventano brunastre e trasparenti dove in MAME sono piene e brillanti.
			// Resta com'e'. La sparizione di bandiera/power-up sotto il fumo NON
			// viene da qui: e' priorita' fra i due chip sprite, non alpha.
			if (pix2_bit3) begin
				alpha_is_const_ff = 1'b1;     // alpha2 = 0xff (opaque)
			end else begin
				alpha_idx_r = 6'h14 + {3'd0, pix2_minus1_low3};
			end
		end else begin
			alpha_idx_r = 6'h10 + {5'd0, pix2_bit7};
		end
	end else if (pix2_bit11) begin
		alpha_idx_r = 6'h12 + {5'd0, pix2_bit7};
	end
end

wire [7:0] spr2_alpha = alpha_is_const_ff ? 8'hff
                      : ace_alpha_of(ace_regs[alpha_idx_r][7:0]);
wire       spr2_blend = (spr2_alpha < 8'hff);

// layer_fg0_en = chip1.pf1 (BG2 alpha), layer_fg1_en = chip1.pf2 (BG2 base).
// Priority: text > sprite > BG/FG layers.
//
// DECO_ACE alpha-blend (MAME deco_ace.cpp + boogwing.cpp mix()):
//   Quando priority_reg[2:0]==3 e FG0 (chip1.pf1) ha pen != 0 → blend FG0 con
//   strato sotto (di solito BG1 o FG1). Alpha = 255 - (ace_regs[0x1f][4:0] << 3).
//   In tutti gli altri casi rendering opaque normale.
//
// Pipeline a 2 indici: top (pixel "src") + bot (pixel "dst"). Lookup BRAM separato
// per ciascuno, poi blend stadio successivo.
reg [11:0] top_pal_idx_r;
reg [11:0] bot_pal_idx_r;
reg        blend_en_r;       // 1 = blend top+bot, 0 = output top diretto
reg        sub_blend_r;      // 1 = sub_blend (dst-src*alpha), 0 = alpha_blend lerp
reg [7:0]  pixel_alpha_r;    // alpha factor per il pixel corrente (sprite chip1 o tmap)
always @(posedge clk) begin
	// default: no blend, alpha = tilemap default (= ace_regs[0x1f])
	blend_en_r    <= 1'b0;
	sub_blend_r   <= 1'b0;
	bot_pal_idx_r <= PAL_BACKDROP;   // dst default = backdrop (non nero) per blend sul cielo
	pixel_alpha_r <= ace_alpha;

	// Text TOP sempre (drawn dopo mix sprite in MAME).
	if (layer_bg0_en && d16_0_pf1_opq) begin
		top_pal_idx_r <= text_pal_idx;
	// Sprite priority DINAMICA pixel-by-pixel (MAME mix() spri1 vs spri2 + pri vs bg).
	// Sprite visibile solo se pri_sprite > bg_pri (sprite vs playfield).
	// Se entrambi opaque: chip1 sopra chip0 se chip1_over_chip0 (= spri2 > spri1).
	// Quando chip1 vince E ha alpha2 < 0xff → blend chip1 con strato sotto (= chip0 se
	// opaque AND chip0_above_bg, altrimenti BG che verrà selezionato sotto in else).
	end else if (chip1_drawn) begin
		top_pal_idx_r <= spr2_pal_idx;
		if (spr2_blend) begin
			blend_en_r    <= 1'b1;
			// "Sotto" = nell'ordine: il pixel OPACO dello stesso chip1 se c'e'
			// (il power-up/l'elefante coperti dal fumo), poi chip0 se visibile,
			// infine il tmap layer (= vedi BG attraverso).
			bot_pal_idx_r <= spr2_under_opq ? spr2_under_pal_idx
			               : chip0_drawn    ? spr_pal_idx
			                                : tmap_pal_idx;
			pixel_alpha_r <= spr2_alpha;
		end
		// Mode 3 shadow: src=shadow (top), dst=sprite (bot). sub_blend8(src,dst,a)=dst-src*a.
		if (mode3_shadow_apply) begin
			blend_en_r    <= 1'b1;
			sub_blend_r   <= (ace_regs[6'h1f][7:0] == 8'h22);
			top_pal_idx_r <= bg2a_pal_idx;     // src = shadow layer FG0
			bot_pal_idx_r <= spr2_pal_idx;     // dst = sprite chip1 sotto
			pixel_alpha_r <= ace_alpha;        // alpha3 = get_alpha(0x1f)
		end
	end else if (chip0_drawn) begin
		top_pal_idx_r <= spr_pal_idx;
		if (mode3_shadow_apply) begin
			blend_en_r    <= 1'b1;
			sub_blend_r   <= (ace_regs[6'h1f][7:0] == 8'h22);
			top_pal_idx_r <= bg2a_pal_idx;
			bot_pal_idx_r <= spr_pal_idx;
			pixel_alpha_r <= ace_alpha;
		end
	end else if (mode_combine) begin
		// Modo 4: combine (BOT) + BG1 (top)
		// Modo 5: BG1 (BOT) + combine (top)
		if (mode_5) begin
			if      ((layer_fg0_en | layer_fg1_en) && bg2c_opq) top_pal_idx_r <= bg2c_pal_idx;
			else if (layer_bg1_en && d16_0_pf2_opq)             top_pal_idx_r <= bg1_pal_idx;
			else                                                 top_pal_idx_r <= PAL_BACKDROP;
		end else begin
			if      (layer_bg1_en && d16_0_pf2_opq)              top_pal_idx_r <= bg1_pal_idx;
			else if ((layer_fg0_en | layer_fg1_en) && bg2c_opq)  top_pal_idx_r <= bg2c_pal_idx;
			else                                                  top_pal_idx_r <= PAL_BACKDROP;
		end
	end else if (pri == 3'd3) begin
		// Modo 3: base layer = BG1 (terreno) sopra FG1. FG0 = shadow tilemap
		// applicato come sub_blend SOPRA il pixel base SE shadow_apply.
		// MAME: bg2_drawed = (bgpri==8) → BG1 disegnato + ombra cade su BG1.
		if (layer_bg1_en && d16_0_pf2_opq) begin
			top_pal_idx_r <= bg1_pal_idx;
			if (mode3_shadow_apply) begin
				blend_en_r    <= 1'b1;
				sub_blend_r   <= (ace_regs[6'h1f][7:0] == 8'h22);
				top_pal_idx_r <= bg2a_pal_idx;   // src = shadow
				bot_pal_idx_r <= bg1_pal_idx;    // dst = BG1
				pixel_alpha_r <= ace_alpha;
			end
		end else if (layer_fg1_en) begin
			top_pal_idx_r <= bg2b_pal_idx;
		end else begin
			top_pal_idx_r <= PAL_BACKDROP;
		end
	end else if (mode_bg2a_top) begin
		// Modi 1/2: bg2b (BOT) | bg1 (mid) | bg2a (top), no blend
		if      (layer_fg0_en && d16_1_pf1_opq) top_pal_idx_r <= bg2a_pal_idx;
		else if (layer_bg1_en && d16_0_pf2_opq) top_pal_idx_r <= bg1_pal_idx;
		else if (layer_fg1_en)                  top_pal_idx_r <= bg2b_pal_idx;
		else                                     top_pal_idx_r <= PAL_BACKDROP;
	end else begin
		// Modi 0/6/7 (default): bg2b (BOT) | bg2a (mid) | bg1 (top)
		if      (layer_bg1_en && d16_0_pf2_opq) top_pal_idx_r <= bg1_pal_idx;
		else if (layer_fg0_en && d16_1_pf1_opq) top_pal_idx_r <= bg2a_pal_idx;
		else if (layer_fg1_en)                  top_pal_idx_r <= bg2b_pal_idx;
		else                                     top_pal_idx_r <= PAL_BACKDROP;
	end
end

// DECO_ACE RGB888 lookup. pal_buf duplicato in 2 M10K (top + bot) per consentire
// 2 read paralleli senza conflitto port. DMA scrive in entrambi.
reg [23:0] top_color_raw;   // {B,G,R}
reg [23:0] bot_color_raw;
always @(posedge clk) top_color_raw <= pal_buf_top[top_pal_idx_r[10:0]];
always @(posedge clk) bot_color_raw <= pal_buf_bot[bot_pal_idx_r[10:0]];

// === DECO_ACE FADE (deco_ace.cpp:165-199) — ESATTO, identico a MAME bit-per-bit.
//   mult (0x1100): c = clamp(0,255, c + ((fadept - c) * fadeps) / 255)
//   add  (0x1000): c = min(c + fadeps, 255)
// /255 esatto = (|prod| * 32897) >> 23 (0 mismatch su tutto il range, verificato). Niente
// approssimazione >>8. Il menu scelta player (fine gioco) scrive $3C0040 (ace_regs 0x20-0x26).
// Gioco azzera il fade in init (0x76D6) -> con fadeps=0 il fade non altera nulla.
wire [7:0]  fade_pt_r = ace_regs[6'h20][7:0];
wire [7:0]  fade_pt_g = ace_regs[6'h21][7:0];
wire [7:0]  fade_pt_b = ace_regs[6'h22][7:0];
wire [7:0]  fade_st_r = ace_regs[6'h23][7:0];
wire [7:0]  fade_st_g = ace_regs[6'h24][7:0];
wire [7:0]  fade_st_b = ace_regs[6'h25][7:0];
wire [15:0] fade_mode = ace_regs[6'h26];
wire        fade_active = (fade_st_r | fade_st_g | fade_st_b) != 8'd0;
wire        fade_add    = (fade_mode == 16'h1000);   // additive; altrimenti multiplicative

// Palette RAW vs FADED (deco_ace.cpp:175-198): la palette deco_ace ha 4096 pen:
//   0x000-0x7FF = palette CON fade (set_pen_color(i)).
//   0x800-0xFFF = stesse entry RAW, SENZA fade (set_pen_color(i+2048)).
// MAME indicizza con paldata[pal_idx]: se pal_idx >= 0x800 -> RAW (no fade). Il TEXT (chip0 pf1,
// GFXDECODE base 0x800) usa SEMPRE le raw -> il testo non e' MAI fadato. Gli sprite/BG (base <0x800)
// vanno raw solo col calculated_coloffs (priority bit3 -> +0x800, boogwing.cpp:355).
// Nel core: pal_buf e' una sola copia [0:2047]; il lookup tronca [10:0] (= indice raw corretto).
// Il bit 11 dell'indice (0x800) marca "raw" = bypass del fade, PER-PIXEL su top e bot separati
// (come MAME: l'offset 0x800 e' per-sorgente, NON globale). Senza questo il testo (idx >=0x800)
// veniva fadato -> annerito/confuso con lo sfondo -> yes/no invisibile.
wire top_fade = fade_active & ~(top_pal_idx_r[11] | priority_reg[3]);
wire bot_fade = fade_active & ~(bot_pal_idx_r[11] | priority_reg[3]);

// Alpha factor — MAME deco_ace.cpp get_alpha():
//   alpha = m_ace_ram[val] & 0xff;
//   if (alpha > 0x20) return 0x80;       // special blending command
//   else alpha = 255 - (alpha << 3); clamp 0;
// Boogwing usa val=0x1f per tilemap alpha (chip1.pf1).
wire [7:0] ace_alpha_byte = ace_regs[6'h1f][7:0];
wire [10:0] ace_alpha_sh  = {3'd0, ace_alpha_byte} << 3;   // val << 3
wire [10:0] ace_alpha_sub = 11'd255 - ace_alpha_sh;
wire [7:0]  ace_alpha     = (ace_alpha_byte > 8'h20) ? 8'h80
                          : (ace_alpha_sub[10] ? 8'd0 : ace_alpha_sub[7:0]);

// Blend stage: dst = src*alpha + dst*(255-alpha) (per canale, /256).
// blend_en_r ritardato 1 ck per allinearsi al lookup pal_buf (top/bot_color_raw): da li'
// viaggia nella pipeline colore insieme al dato.
reg        blend_en_d;
reg        sub_blend_d;
reg [7:0]  alpha_d;
always @(posedge clk) blend_en_d  <= blend_en_r;
always @(posedge clk) sub_blend_d <= sub_blend_r;
always @(posedge clk) alpha_d     <= pixel_alpha_r;

// ============================================================================
// CATENA COLORE PIPELINATA: fade DECO_ACE + blend, 5 registri a OGNI clock.
// Prima fade e blend erano combinatori dalla BRAM palette al pin: 29 ns (2 moltiplicatori
// del fade + 1 del blend) in un ciclo da 10.4 -> setup -20 ns sul clock del core.
// L'uscita e' ESATTAMENTE quella combinatoria di prima ritardata di 5 clk: ogni segnale
// che la accompagna (flag raw/fade, modo add, blend_en/sub/alpha, parametri del fade)
// viene preso nello STESSO istante del colore (stadio A) e viaggia con lui.
// Latenza da hcnt all'uscita: lb read, lb_rd, *_pal_idx_r, *_color_raw = 4, + 5 = 9 clk.
// Un pixel dura 14 clk e sys campiona nel ciclo di ce_pix (il 14esimo): 9 < 14 -> viene
// campionato lo stesso pixel di prima (HDMI e analogico invariati, nessuno shift dei
// layer: passano tutti dalla stessa pipeline).
//
// Formule MAME invariate, bit per bit:
//  fade mult (0x1100): c = clamp(0,255, c + ((fadept - c) * fadeps) / 255)
//    /255 esatto = (|prod| * 32897) >> 23, quoziente troncato verso zero
//  fade add  (0x1000): c = min(c + fadeps, 255)
//  alpha_blend_r32: (src * alpha + dst * (256 - alpha)) >> 8
//  sub_blend_r32 (boogwing.cpp:180-188): (inv_src * alpha + dst * (256 - alpha)) >> 9,
//    inv_src = 0xff - src; mai sotto zero (la sottrazione pura clampava a NERO).
//  Mapping: dst = bot_color (BG1), src = top_color (FG0 ombra) - MAME line 408.
// Stadi: A = (pt-c)*st e somma satura del modo add | B = |prod|/255 |
//        C = colore fadato | D = prodotti del blend | E = somma, scelta, uscita.
// ============================================================================
wire [23:0] fade_pt24 = {fade_pt_b, fade_pt_g, fade_pt_r};   // stesso ordine {B,G,R}
wire [23:0] fade_st24 = {fade_st_b, fade_st_g, fade_st_r};

function signed [16:0] fade_prod(input [7:0] c, input [7:0] pt, input [7:0] st);
	fade_prod = ($signed({1'b0, pt}) - $signed({1'b0, c})) * $signed({1'b0, st});
endfunction

function [7:0] fade_add8(input [7:0] c, input [7:0] st);
	reg [9:0] asum;
	begin
		asum      = {2'd0, c} + {2'd0, st};
		fade_add8 = asum[9:8] != 2'd0 ? 8'hFF : asum[7:0];
	end
endfunction

function [8:0] fade_qmag(input [16:0] prod);   // |prod| / 255 esatto
	reg [15:0] mag;
	reg [31:0] qmul;
	begin
		mag       = prod[16] ? (~prod[15:0] + 16'd1) : prod[15:0];
		qmul      = mag * 32'd32897;
		fade_qmag = qmul[31:23];
	end
endfunction

function [7:0] fade_fin(input [7:0] c, input neg, input [8:0] qmag);
	reg signed [9:0] q, res;
	begin
		q        = neg ? -$signed({1'b0, qmag}) : $signed({1'b0, qmag});
		res      = $signed({2'b0, c}) + q;
		fade_fin = res[9] ? 8'd0 : (res > 10'sd255 ? 8'hFF : res[7:0]);
	end
endfunction

// Stadio A
reg [23:0] ta_c, ba_c, ta_add, ba_add;
reg [50:0] ta_prod, ba_prod;                 // 3 x 17
reg        ta_fade, ba_fade, a_add, a_blend, a_sub;
reg [7:0]  a_alpha;
// Stadio B
reg [23:0] tb_c, bb_c, tb_add, bb_add;
reg [26:0] tb_q, bb_q;                       // 3 x 9
reg [2:0]  tb_neg, bb_neg;
reg        tb_fade, bb_fade, b_add, b_blend, b_sub;
reg [7:0]  b_alpha;
// Stadio C
reg [23:0] tc_col, bc_col;
reg        c_blend, c_sub;
reg [7:0]  c_alpha;
// Stadio D
reg [50:0] d_s, d_d;                         // 3 x 17
reg [23:0] d_top;
reg        d_blend, d_sub;
// Stadio E
reg [23:0] rgb_q;                            // {R,G,B}

integer ch;
always @(posedge clk) begin
	// A
	ta_c    <= top_color_raw;  ba_c    <= bot_color_raw;
	ta_fade <= top_fade;       ba_fade <= bot_fade;      a_add <= fade_add;
	a_blend <= blend_en_d;     a_sub   <= sub_blend_d;   a_alpha <= alpha_d;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		ta_prod[ch*17 +: 17] <= fade_prod(top_color_raw[ch*8 +: 8], fade_pt24[ch*8 +: 8], fade_st24[ch*8 +: 8]);
		ba_prod[ch*17 +: 17] <= fade_prod(bot_color_raw[ch*8 +: 8], fade_pt24[ch*8 +: 8], fade_st24[ch*8 +: 8]);
		ta_add[ch*8 +: 8]    <= fade_add8(top_color_raw[ch*8 +: 8], fade_st24[ch*8 +: 8]);
		ba_add[ch*8 +: 8]    <= fade_add8(bot_color_raw[ch*8 +: 8], fade_st24[ch*8 +: 8]);
	end
	// B
	tb_c    <= ta_c;     bb_c    <= ba_c;
	tb_add  <= ta_add;   bb_add  <= ba_add;
	tb_fade <= ta_fade;  bb_fade <= ba_fade;  b_add <= a_add;
	b_blend <= a_blend;  b_sub   <= a_sub;    b_alpha <= a_alpha;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		tb_q[ch*9 +: 9] <= fade_qmag(ta_prod[ch*17 +: 17]);
		bb_q[ch*9 +: 9] <= fade_qmag(ba_prod[ch*17 +: 17]);
		tb_neg[ch]      <= ta_prod[ch*17 + 16];
		bb_neg[ch]      <= ba_prod[ch*17 + 16];
	end
	// C
	c_blend <= b_blend;  c_sub <= b_sub;  c_alpha <= b_alpha;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		tc_col[ch*8 +: 8] <= !tb_fade ? tb_c[ch*8 +: 8]
		                   : b_add    ? tb_add[ch*8 +: 8]
		                   :            fade_fin(tb_c[ch*8 +: 8], tb_neg[ch], tb_q[ch*9 +: 9]);
		bc_col[ch*8 +: 8] <= !bb_fade ? bb_c[ch*8 +: 8]
		                   : b_add    ? bb_add[ch*8 +: 8]
		                   :            fade_fin(bb_c[ch*8 +: 8], bb_neg[ch], bb_q[ch*9 +: 9]);
	end
	// D
	d_top <= tc_col;  d_blend <= c_blend;  d_sub <= c_sub;
	for (ch = 0; ch < 3; ch = ch + 1) begin
		d_s[ch*17 +: 17] <= (c_sub ? 8'hff - tc_col[ch*8 +: 8] : tc_col[ch*8 +: 8]) * c_alpha;
		d_d[ch*17 +: 17] <= bc_col[ch*8 +: 8] * (9'd256 - {1'b0, c_alpha});
	end
end

// E: somma dei prodotti, >>8 (alpha) o >>9 (sub), oppure top diretto se niente blend.
wire [16:0] e_sum_r = d_s[16:0]  + d_d[16:0];
wire [16:0] e_sum_g = d_s[33:17] + d_d[33:17];
wire [16:0] e_sum_b = d_s[50:34] + d_d[50:34];
always @(posedge clk)
	rgb_q <= !d_blend ? {d_top[7:0], d_top[15:8], d_top[23:16]}
	       :  d_sub   ? {e_sum_r[16:9], e_sum_g[16:9], e_sum_b[16:9]}
	       :            {e_sum_r[15:8], e_sum_g[15:8], e_sum_b[15:8]};

// === DEBUG overlay: 8 valori 16-bit hex in alto. Riga0: priority | c1_pf1_x | c1_pf1_y | c1_pf2_x
//     Riga1: c1_pf2_y | c1_ctrl5 | c1_ctrl6 | (riserva=priority). Per diagnosi combine 8bpp. ===
wire        dbg_text_on;
wire [23:0] dbg_text_color;
// DEBUG: su una SCANLINE della foto (render_y=120, render_x 64..255 = larghezza riquadro),
// conta quanti pixel pf1 e pf2 sono OPACHI, e l'ultimo valore pf1/pf2 visto. Cosi' il dato
// e' robusto: se pf2_opq_cnt << pf1_opq_cnt -> pf2 sparisce; se ~uguali -> pf2 c'e' ma valore.
reg [15:0] dbg_pf1_cnt, dbg_pf2_cnt;   // count opachi sulla scanline
reg [15:0] dbg_smp_pf1, dbg_smp_pf2;   // ultimo pen pf1/pf2 nella zona
reg [15:0] dbg_cnt_pf1_acc, dbg_cnt_pf2_acc;
// DEBUG yes/no: campiona BG0 (chip0 pf1 = TEXT) su TUTTO lo schermo. Conta quanti pixel BG0
// sono opachi (= testo/UI disegnata) e campiona pen+col+opq. Se il testo yes/no e' su BG0 e
// renderizzato, dbg_bg0_cnt deve essere > 0 e dbg_bg0_pen/col devono mostrare i valori del testo.
// Se cnt=0 / pen=0 -> il tile NON viene letto (mapping/indirizzo). Se pen!=0 -> e' palette.
reg [15:0] dbg_bg0_cnt, dbg_bg0_cnt_acc;
reg [15:0] dbg_bg0_pen, dbg_bg0_col;
wire in_dbg_line = (render_y == 10'd120) && (render_x >= 10'd64) && (render_x < 10'd256);
// Zona dei box di dialogo yes/no (coord native 320x240): x 40..280, y 50..120.
wire in_box_zone = (render_y >= 10'd50) && (render_y < 10'd120) &&
                   (render_x >= 10'd40) && (render_x < 10'd280);
always @(posedge clk) begin
	if (render_y == 10'd120 && render_x == 10'd0) begin   // inizio riga: reset accumulatori
		dbg_cnt_pf1_acc <= 16'd0; dbg_cnt_pf2_acc <= 16'd0;
	end else if (in_dbg_line) begin
		if (d16_1_pf1_opq) dbg_cnt_pf1_acc <= dbg_cnt_pf1_acc + 1'b1;
		if (d16_1_pf2_opq) dbg_cnt_pf2_acc <= dbg_cnt_pf2_acc + 1'b1;
		dbg_smp_pf1 <= {11'd0, d16_1_pf1_pix};
		dbg_smp_pf2 <= {11'd0, d16_1_pf2_pix};
	end else if (render_y == 10'd121 && render_x == 10'd0) begin  // fine riga: latch i count
		dbg_pf1_cnt <= dbg_cnt_pf1_acc;
		dbg_pf2_cnt <= dbg_cnt_pf2_acc;
	end
	// BG0 (text) SOLO nella zona dei box di dialogo yes/no (x 40..280, y 50..120).
	// Conta i pixel BG0 OPACHI lì + campiona pen/col. Se cnt=0 nei box -> il testo yes/no
	// NON e' renderizzato lì (mapping). Se cnt>0 -> il tile e' letto (palette/colore).
	// Latch e reset su frame boundary SEPARATI dall'accumulo (no else-if conflict).
	if (render_y == 10'd121 && render_x == 10'd0) begin
		dbg_bg0_cnt <= dbg_bg0_cnt_acc;          // latch a fine zona box
		dbg_bg0_cnt_acc <= 16'd0;                // e reset per il frame dopo
	end else if (in_box_zone && d16_0_pf1_opq) begin
		dbg_bg0_cnt_acc <= dbg_bg0_cnt_acc + 1'b1;
		dbg_bg0_pen <= {11'd0, d16_0_pf1_pix};   // pen del text nei box (0 = trasparente)
		dbg_bg0_col <= {11'd0, d16_0_pf1_col};   // color del text nei box (yes/no = 6)
	end
end
vram_debug_overlay u_dbg_overlay (
	.clk(clk),
	.render_x(render_x),
	.render_y(render_y[8:0]),
	.dbg_c0_pf1_cnt(priority_reg),
	.dbg_c0_pf2_cnt(dbg_c0_ctrl2),    // CHIP0 ctrl2 RUNTIME (scroll_y)
	.dbg_c1_pf1_cnt(dbg_ram_8002),  // $208003|$208002 (bit7 hi/lo = player in gioco)
	.dbg_c1_pf2_cnt(dbg_ram_8000),  // $208001|$208000 (bit3 = gate)
	.dbg_c0_pf1_v0 (dbg_c0_ctrl7),    // CHIP0 ctrl7 RUNTIME (bank)
	.dbg_c0_pf2_v0 (dbg_smp_opq),    // opaque pf1|pf2
	.dbg_c1_pf1_v0 (dbg_c1_ctrl5),
	.dbg_c1_pf2_v0 (dbg_c1_ctrl6),
	.text_on(dbg_text_on),
	.text_color(dbg_text_color)
);

// rgb_out: {R, G, B} (video_r = rgb[23:16]), uscita registrata della pipeline colore.
// assign rgb_out = dbg_text_on ? dbg_text_color : rgb_q;
assign rgb_out = rgb_q;

// =====================================================================
// AUDIO subsystem (boogwings_audio.sv)
// =====================================================================
// Audiocpu ROM download: ioctl_dout è 16-bit (word), ROM è byte-addressed.
// ioctl_addr step 2 (= byte units), low byte = [7:0], high byte = [15:8].
// Per ogni ioctl_wr scrivo 2 byte sequenziali: byte 0 a addr N, byte 1 a addr N+1.
// Approach: faccio 2 cicli write con un piccolo flag toggle.
reg        audio_rom_we_lo, audio_rom_we_hi;
reg [15:0] audio_rom_waddr_lo, audio_rom_waddr_hi;
reg [7:0]  audio_rom_wdata_lo, audio_rom_wdata_hi;
reg        ioctl_wr_prev_aud;
always @(posedge clk) begin
	audio_rom_we_lo <= 1'b0;
	audio_rom_we_hi <= 1'b0;
	ioctl_wr_prev_aud <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev_aud && is_audio_dl) begin
		audio_rom_we_lo    <= 1'b1;
		audio_rom_waddr_lo <= ioctl_addr[15:0] - AUDIO_DL_LO[15:0];
		audio_rom_wdata_lo <= ioctl_dout[7:0];
		audio_rom_we_hi    <= 1'b1;
		audio_rom_waddr_hi <= (ioctl_addr[15:0] - AUDIO_DL_LO[15:0]) + 16'd1;
		audio_rom_wdata_hi <= ioctl_dout[15:8];
	end
end

// Mux per scrivere 2 byte in 1 ck: serve dual-port o write seq. Faccio dual writes
// con priority hi (= scrive entrambi insieme; modulo audio gestisce con 2 write port).
// Versione semplice: combino in 1 we + waddr/wdata wide (= modulo audio gestisce 2 byte).
// → Per ora uso solo we_lo + waddr seq con +0/+1 toggle in stesso modulo.
// Modifico: passo word16 al modulo che internamente splitta byte.

wire        audio_rom_we    = audio_rom_we_lo;   // we singolo per word
wire [14:0] audio_rom_waddr_word = (ioctl_addr[15:1] - AUDIO_DL_LO[15:1]);
wire [15:0] audio_rom_wdata = ioctl_dout;

wire [27:0] oki0_ddr_addr_w, oki1_ddr_addr_w;
wire        oki0_ddr_req_w, oki1_ddr_req_w;
wire [31:0] oki0_ddr_data_w, oki1_ddr_data_w;     // 32-bit port (port 5/6 con prefetch)
wire        oki0_ddr_ack_w, oki1_ddr_ack_w;

// Audio cen: gating frame-aligned DENTRO i contatori di Template.sv (i contatori congelano
// quando paused_safe, NON taglio del pulse via AND esterno). Ripresa pulita al frame boundary,
// come F2 .cen_in(~obj_paused). I ce_* arrivano gia' fermati durante pausa/SS.

boogwings_audio #(.SS_HUC_RAM_IDX(SS_IDX_HUC_RAM), .SS_HUC_CPU_IDX(SS_IDX_HUC_CPU),
                  .SS_OKI0_IDX(SS_IDX_OKI0), .SS_OKI1_IDX(SS_IDX_OKI1),
                  .SS_YM_IDX(SS_IDX_YM), .SS_AUDIO_BUS_IDX(SS_IDX_AUDIO_BUS)) u_audio (
	.clk            (clk),
	.reset          (reset),
	.ce_audio       (ce_audio),
	.ce_ym          (ce_ym),
	.ce_ym_p1       (ce_ym_p1),
	.ce_oki0        (ce_oki0),
	.ce_oki1        (ce_oki1),
	.ce_audio_cnt_in  (ce_audio_cnt_in),
	.ce_ym_cnt_in     (ce_ym_cnt_in),
	.ce_ym_toggle_in  (ce_ym_toggle_in),
	.ce_oki0_cnt_in   (ce_oki0_cnt_in),
	.ce_oki1_cnt_in   (ce_oki1_cnt_in),
	.ce_audio_cnt_load (ce_audio_cnt_load),
	.ce_ym_cnt_load    (ce_ym_cnt_load),
	.ce_ym_toggle_load (ce_ym_toggle_load),
	.ce_oki0_cnt_load  (ce_oki0_cnt_load),
	.ce_oki1_cnt_load  (ce_oki1_cnt_load),
	.ce_cnt_load_wr    (ce_cnt_load_wr),
	.pause          (paused_safe),
	.soundlatch_data     (sndlatch_data),
	.soundlatch_irq_pulse(sndlatch_irq_main_pulse),
	.rom_we_lo      (audio_rom_we_lo),
	.rom_we_hi      (audio_rom_we_hi),
	.rom_waddr_lo   (audio_rom_waddr_lo),
	.rom_waddr_hi   (audio_rom_waddr_hi),
	.rom_wdata_lo   (audio_rom_wdata_lo),
	.rom_wdata_hi   (audio_rom_wdata_hi),
	.oki0_ddr_addr  (oki0_ddr_addr_w),
	.oki0_ddr_req   (oki0_ddr_req_w),
	.oki0_ddr_data  (oki0_ddr_data_w),
	.oki0_ddr_ack   (oki0_ddr_ack_w),
	.oki1_ddr_addr  (oki1_ddr_addr_w),
	.oki1_ddr_req   (oki1_ddr_req_w),
	.oki1_ddr_data  (oki1_ddr_data_w),
	.oki1_ddr_ack   (oki1_ddr_ack_w),
	.osd_sel_fm     (osd_sel_fm),
	.osd_sel_oki0   (osd_sel_oki0),
	.osd_sel_oki1   (osd_sel_oki1),
	.osd_presence   (osd_presence),
	.audio_l        (audio_l),
	.audio_r        (audio_r),
	.ss_huc_ram     (ssb[SS_IDX_HUC_RAM]),
	.ss_huc_cpu     (ssb[SS_IDX_HUC_CPU]),
	.ss_oki0        (ssb[SS_IDX_OKI0]),
	.ss_oki1        (ssb[SS_IDX_OKI1]),
	.ss_ym          (ssb[SS_IDX_YM]),
	.ss_audio_bus   (ssb[SS_IDX_AUDIO_BUS])
);

// =====================================================================
// TILEMAP ROM arbiter (4 client = 2 chip × 2 layer)
//   r0 = deco16_0 pf1  → region TILES2_LO  (BG1 baseline plane 1..4)
//   r1 = deco16_0 pf2  → region TILES2_LO  (idem chip 0 pf2)
//   r2 = deco16_1 pf1  → region TILES3_LO  (BG2 plane 0..3)
//   r3 = deco16_1 pf2  → region TILES3_LO  (idem chip 1 pf2)
//   r4 = unused (riservato per text/FG futuro)
//
// Region IDs propagati dai deco16ic via wire d16_*_pf*_rid (parameter-driven).
// =====================================================================
// 2 arbiter SEPARATI: ognuno serve 2 client su una porta SDRAM dedicata.
// Arbiter A (port 0 → bridge tile_*): chip0.pf1 + chip0.pf2 (text + BG1).
// Arbiter B (port 3 → bridge tile2_*): chip1.pf1 + chip1.pf2 (BG2 chip1).
// Schema NinjaWarriors: 2 trans SDRAM concurrent invece di 1 → bandwidth x2.
wire        tilerom_req_w;
wire [23:0] tilerom_addr_w;
wire [2:0]  tilerom_rid_w;
// ARBITER chip0 RIMOSSO: text chip0.pf1 ora ha DDR3 port 8 (txt_ddr_bridge sopra).
// chip0.pf2 (BG1) ha DDR3 port 5 (bg1_ddr_bridge sopra). Nessun client SDRAM chip0.
assign tilerom_addr      = 24'd0;
assign tilerom_region_id = 3'd0;

// Bypass u_arb_b: chip1.pf1 → tilerom_fg0_* (ba0), chip1.pf2 → tilerom_fg1_* (ba1).
// Niente round-robin: 2 porte SDRAM indipendenti = parallelism reale.
assign tilerom_fg0_addr      = d16_1_pf1_rom_addr;
assign tilerom_fg0_region_id = d16_1_pf1_rid;
assign tilerom_fg0_req       = d16_1_pf1_rom_req;
wire [31:0] bg2a_arb_data  = tilerom_fg0_data;
wire        bg2a_arb_valid = tilerom_fg0_valid;

assign tilerom_fg1_addr      = d16_1_pf2_rom_addr;
assign tilerom_fg1_region_id = d16_1_pf2_rid;
assign tilerom_fg1_req       = d16_1_pf2_rom_req;
wire [31:0] bg2b_arb_data  = tilerom_fg1_data;
wire        bg2b_arb_valid = tilerom_fg1_valid;

// Legacy tilerom2 (port arbiter) — non più usato, tied off
assign tilerom2_addr      = 24'd0;
assign tilerom2_region_id = 3'd0;
assign tilerom2_req       = 1'b0;
assign tilerom_req        = tilerom_req_w;

// =====================================================================
// DDRAM 4-port instance
//   Port wr  : sprite ROM ioctl download (+ audio rom + OKI samples TODO)
//   Port rd1 : H6280 ROM (TODO)
//   Port rd2 : OKI1 samples (TODO)
//   Port rd3 : OKI2 samples (TODO)
//   Port rd4 : sprite ROM 32-bit (bridge inline)
// =====================================================================
// Sprite chip0 (sprites1) — bridge inline NO cache (risparmio LAB).
wire [23:0] sprite_romaddr;
wire        sprite_romreq;
reg  [31:0] sprite_romdata;
reg         sprite_romvalid;
reg  [27:0] sprite_ddr_rdaddr;
reg         sprite_ddr_rd_req;
wire [31:0] sprite_ddr_dout;
wire        sprite_ddr_rd_ack;
localparam [27:0] SPRITES1_BASE = 28'h0400000;

reg [1:0] spr1_state;
localparam SPR1_IDLE = 2'd0, SPR1_WAIT = 2'd1;
reg spr1_req_prev;
always @(posedge clk) begin
	if (reset) begin
		spr1_state        <= SPR1_IDLE;
		spr1_req_prev     <= 0;
		sprite_ddr_rd_req <= 0;
		sprite_romvalid   <= 0;
	end else begin
		spr1_req_prev   <= sprite_romreq;
		sprite_romvalid <= 0;
		case (spr1_state)
			SPR1_IDLE: if (sprite_romreq & ~spr1_req_prev) begin
				// Download interleave 2x: 1 byte source -> 2 byte DDR3.
				// sprite_romaddr e' in spazio MAME (= source 4MB).
				// DDR3 = 8MB interleavato -> shift left 1.
				sprite_ddr_rdaddr <= SPRITES1_BASE + {3'd0, sprite_romaddr, 1'b0};
				sprite_ddr_rd_req <= ~sprite_ddr_rd_req;
				spr1_state <= SPR1_WAIT;
			end
			SPR1_WAIT: if (sprite_ddr_rd_ack == sprite_ddr_rd_req) begin
				sprite_romdata  <= sprite_ddr_dout;
				sprite_romvalid <= 1'b1;
				spr1_state <= SPR1_IDLE;
			end
			default: spr1_state <= SPR1_IDLE;
		endcase
	end
end

// Sprite chip1 (sprites2) — bridge inline NO cache (risparmio LAB).
// req_pulse → toggle DDR3 → wait ack → resp_valid pulse.
wire [23:0] sprite2_romaddr;
wire        sprite2_romreq;
reg  [31:0] sprite2_romdata;
reg         sprite2_romvalid;
reg  [27:0] sprite2_ddr_rdaddr;
reg         sprite2_ddr_rd_req;
wire [31:0] sprite2_ddr_dout;
wire        sprite2_ddr_rd_ack;
// BUG FIX: era 0x0440000 = chip1 sovrappone chip0 (chip0 occupa 0x400000..0x7FFFFF).
// Corretto: chip1 = chip0_base + chip0_size = 0x0400000 + 0x0400000 = 0x0800000.
localparam [27:0] SPRITES2_BASE = 28'h0800000;

reg [1:0] spr2_state;
localparam SPR2_IDLE = 2'd0, SPR2_REQ = 2'd1, SPR2_WAIT = 2'd2, SPR2_DONE = 2'd3;
reg spr2_req_prev;
always @(posedge clk) begin
	if (reset) begin
		spr2_state       <= SPR2_IDLE;
		spr2_req_prev    <= 0;
		sprite2_ddr_rd_req <= 0;
		sprite2_romvalid <= 0;
	end else begin
		spr2_req_prev    <= sprite2_romreq;
		sprite2_romvalid <= 0;
		case (spr2_state)
			SPR2_IDLE: if (sprite2_romreq & ~spr2_req_prev) begin
				// Download interleave 2x: shift left 1 (vedi SPR1).
				sprite2_ddr_rdaddr <= SPRITES2_BASE + {3'd0, sprite2_romaddr, 1'b0};
				sprite2_ddr_rd_req <= ~sprite2_ddr_rd_req;
				spr2_state <= SPR2_WAIT;
			end
			SPR2_WAIT: if (sprite2_ddr_rd_ack == sprite2_ddr_rd_req) begin
				sprite2_romdata  <= sprite2_ddr_dout;
				sprite2_romvalid <= 1'b1;
				spr2_state <= SPR2_IDLE;
			end
			default: spr2_state <= SPR2_IDLE;
		endcase
	end
end

// Sprite + Tile2 ROM ioctl download → DDR3 write port (MUX-ato).
// BoogieWings MRA layout:
//   0x130000-0x42FFFF tile2 (3 MB, BG1 5bpp = mbd-01+00+02_remap)
//   0x630000-0xE2FFFF sprite (8 MB)
// Tile2 va a DDR3 base 0x05000000 (80 MB offset).
// Sprite a DDR3 base 0x04000000.
// MRA layout (BoogieWings_dec_jt.mra):
//   0x630000-0x82FFFF = tiles3 #2 (duplicato per SDRAM ba1 FG1, NON sprite!)
//   0x830000-0x102FFFF = sprite (8 MB, dest DDR3 chip0+chip1)
// Bug pre-fix: SPRITE_DL_LO = 0x630000 → top scriveva tiles3 in DDR3 sprite area
//              + perdeva ultimi 2 MB di sprite veri perché range overshoot.
localparam [26:0] SPRITE_DL_LO = 27'h830000;
localparam [26:0] SPRITE_DL_SZ = 27'h800000;
localparam [26:0] TILE2_DL_LO  = 27'h130000;
localparam [26:0] TILE2_DL_SZ  = 27'h300000;
// Tile3 (BG2) ora va a DDR3 invece SDRAM:
//   0x430000-0x52FFFF = mbd-03 (1 MB, plane 0+1 = LO)  → DDR 0x5300000
//   0x530000-0x62FFFF = mbd-04 (1 MB, plane 2+3 = HI)  → DDR 0x5400000
localparam [26:0] TILE3_DL_LO  = 27'h430000;
localparam [26:0] TILE3_DL_SZ  = 27'h200000;
// Tile1 (text) ora va a DDR3:
//   0x110000-0x11FFFF = tiles1_lo (64 KB)  → DDR 0x5500000
//   0x120000-0x12FFFF = tiles1_hi (64 KB)  → DDR 0x5510000
localparam [26:0] TILE1_DL_LO  = 27'h110000;
localparam [26:0] TILE1_DL_SZ  = 27'h020000;
// Audiocpu ROM (H6280): 64 KB BRAM, dest interno modulo audio
localparam [26:0] AUDIO_DL_LO  = 27'h100000;
localparam [26:0] AUDIO_DL_SZ  = 27'h010000;
wire is_audio_dl  = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= AUDIO_DL_LO)
                     && (ioctl_addr <  AUDIO_DL_LO + AUDIO_DL_SZ);
wire is_sprite_dl = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= SPRITE_DL_LO)
                     && (ioctl_addr <  SPRITE_DL_LO + SPRITE_DL_SZ);
wire is_tile2_dl  = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= TILE2_DL_LO)
                     && (ioctl_addr <  TILE2_DL_LO + TILE2_DL_SZ);
wire is_tile3_dl  = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= TILE3_DL_LO)
                     && (ioctl_addr <  TILE3_DL_LO + TILE3_DL_SZ);
wire is_tile1_dl  = ioctl_download && (ioctl_index == 16'd0)
                     && (ioctl_addr >= TILE1_DL_LO)
                     && (ioctl_addr <  TILE1_DL_LO + TILE1_DL_SZ);
// OKI1/OKI2 (512 KB ciascuna) → DDR3 base 0x5500000 / 0x5580000
localparam [26:0] OKI1_DL_LO  = 27'h1030000;
localparam [26:0] OKI1_DL_SZ  = 27'h0080000;
localparam [26:0] OKI2_DL_LO  = 27'h10B0000;
localparam [26:0] OKI2_DL_SZ  = 27'h0080000;
localparam [27:0] DDR_OKI1_BASE = 28'h5500000;
localparam [27:0] DDR_OKI2_BASE = 28'h5580000;
wire is_oki1_dl  = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= OKI1_DL_LO)
                    && (ioctl_addr <  OKI1_DL_LO + OKI1_DL_SZ);
wire is_oki2_dl  = ioctl_download && (ioctl_index == 16'd0)
                    && (ioctl_addr >= OKI2_DL_LO)
                    && (ioctl_addr <  OKI2_DL_LO + OKI2_DL_SZ);
reg  [27:0] ddr_dl_waddr;
reg  [15:0] ddr_dl_wdata;
reg         ddr_dl_we_req;
wire        ddr_dl_we_ack;
reg         ioctl_wr_prev_ddr;
// Sprite download interleave: layout MAME tile_16x16_layout richiede
// plane 0,1 da LO region, plane 2,3 da HI region. Il bridge sprite legge 4 byte
// consecutivi. Interleavo durante download cosi' DDR3 ha 4 byte = [LO+0, LO+1, HI+0, HI+1].
//
// Source layout (ioctl_addr - SPRITE_DL_LO):
//   0..2MB = chip0 LO (mbd-06)
//   2..4MB = chip0 HI (mbd-05)
//   4..6MB = chip1 LO (mbd-08)
//   6..8MB = chip1 HI (mbd-07)
// Destination layout in DDR3 (a partire da 0x04000000):
//   chip0 occupa 0..4MB (4 byte per ogni 2 byte source)
//   chip1 occupa 4..8MB
// Per ogni word16 source (2 byte) a offset rel:
//   se rel < 2MB: chip=0, region=LO, dst_base=0          , dst_off=2*rel
//   se rel < 4MB: chip=0, region=HI, dst_base=2          , dst_off=2*(rel-2MB)
//   se rel < 6MB: chip=1, region=LO, dst_base=0+4MB      , dst_off=2*(rel-4MB)
//   se rel < 8MB: chip=1, region=HI, dst_base=2+4MB      , dst_off=2*(rel-6MB)
wire [22:0] spr_src_off = ioctl_addr[22:0] - SPRITE_DL_LO[22:0];   // 0..8MB
wire [1:0]  spr_chip_reg = spr_src_off[22:21];                      // 00=c0LO 01=c0HI 10=c1LO 11=c1HI
wire [20:0] spr_off_in_region = spr_src_off[20:0];                  // 0..2MB byte addr
// HALF-ADIACENTE (2026-09-18, come Night Slashers): la word sorgente w =
// off_in_region[20:1] = {code, half, row[3:0]} va scritta al gruppo DDR
// {code, row, half} (bit 4 in fondo), che e' l'indirizzo chiesto da bw_sprites
// ({code, row_use, half_use}): le due meta' A/B di una riga stanno adiacenti in
// DDR e la fetch della B trova la riga gia' aperta. Stesso numero di byte,
// solo l'ordine dei gruppi dentro il blocco da 32.
wire [19:0] spr_w   = spr_off_in_region[20:1];
wire [19:0] spr_w_s = {spr_w[19:5], spr_w[3:0], spr_w[4]};
wire [22:0] spr_dst_off = (spr_chip_reg[1] ? 23'h400000 : 23'h000000)  // chip base
                        + ({1'b0, spr_w_s, 2'b00})                     // 4*gruppo (half-adiacente)
                        + (spr_chip_reg[0] ? 23'd2 : 23'd0);           // LO vs HI offset

// Write diretta DDR3 download (no pending queue).
// Pre-fix `23ac95a` aveva pending queue: causa race su `ddr_dl_we_ack` lento.
always @(posedge clk) begin
	ioctl_wr_prev_ddr <= ioctl_wr;
	if (ioctl_wr && !ioctl_wr_prev_ddr) begin
		if (is_sprite_dl) begin
			ddr_dl_waddr  <= 28'h0400000 + {5'd0, spr_dst_off};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_oki1_dl) begin
			ddr_dl_waddr  <= DDR_OKI1_BASE + {1'b0, ioctl_addr - OKI1_DL_LO};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end else if (is_oki2_dl) begin
			ddr_dl_waddr  <= DDR_OKI2_BASE + {1'b0, ioctl_addr - OKI2_DL_LO};
			ddr_dl_wdata  <= ioctl_dout;
			ddr_dl_we_req <= ~ddr_dl_we_req;
		end
	end
end

// =====================================================================
// tile_perm: 4 toggle indipendenti per debug HW (run-time).
// =====================================================================
function [7:0] brev8(input [7:0] b);
	brev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
endfunction

function [31:0] tile_perm(input [15:0] hi_w, input [15:0] lo_w,
                          input swap_hl, input brev_en, input nibsw_en, input bs_ab_en);
	reg [31:0] w0, w1, w2, w3;
	begin
		w0 = swap_hl ? {lo_w, hi_w} : {hi_w, lo_w};
		w1 = bs_ab_en ?
			{w0[23:16], w0[31:24], w0[7:0],  w0[15:8]} :
			w0;
		w2 = nibsw_en ?
			{w1[27:24], w1[31:28], w1[19:16], w1[23:20],
			 w1[11:8],  w1[15:12], w1[3:0],   w1[7:4]} :
			w1;
		w3 = brev_en ?
			{brev8(w2[31:24]), brev8(w2[23:16]), brev8(w2[15:8]), brev8(w2[7:0])} :
			w2;
		tile_perm = w3;
	end
endfunction

// =====================================================================
// BG1 chip0.pf2 5bpp → SDRAM ba3 (jtframe_sdram64).
// Bridge SDRAM (in sdram_bridge.sv) gestisce 3 region: mbd-01/mbd-00/mbd-02.
// - 4 plane base: 2 fetch sequenziali (MID+LO) → tilerom_bg1_data 32-bit
// - p4 (mbd-02): canale dedicato → tilerom_bg1_p4_data 8-bit RAW (no tile_perm)
// =====================================================================
assign tilerom_bg1_addr   = d16_0_pf2_rom_addr;
assign tilerom_bg1_req    = d16_0_pf2_rom_req;
assign tilerom_bg1_p4_req = d16_0_pf2_p4_req;

// Lettura TRASPARENTE (come _dec_jt): il dato in SDRAM ba3 e' gia' decrittato
// in download. tile_perm identico al dec.
assign d16_0_pf2_rom_data  = tile_perm(tilerom_bg1_data[31:16], tilerom_bg1_data[15:0],
                                         osd_bg1_swap_hl, osd_bg1_brev8,
                                         osd_bg1_nibsw,   osd_bg1_bs_ab);
assign d16_0_pf2_rom_valid = tilerom_bg1_valid;
assign d16_0_pf2_p4_data   = tilerom_bg1_p4_data;
assign d16_0_pf2_p4_valid  = tilerom_bg1_p4_valid;

// =====================================================================
// BG2 chip1.pf1 / chip1.pf2 → DDR3 port 6 / port 7
// Stesso pattern di bg1_ddr_bridge ma 4bpp puro (no p4 plane).
// Base DDR3 dedicate per evitare conflict con tile2 (BG1).
// =====================================================================
localparam [27:0] DDR_TILE3_LO_BASE = 28'h5300000;
localparam [27:0] DDR_TILE3_HI_BASE = 28'h5400000;

localparam BG2_IDLE   = 4'd0;
localparam BG2_REQ_HI = 4'd1;
localparam BG2_WAIT_HI= 4'd2;
localparam BG2_REQ_LO = 4'd3;
localparam BG2_WAIT_LO= 4'd4;
localparam BG2_DONE   = 4'd5;

// ===== Bridge BG2 chip1.pf1 (DDR3 port 6) =====
wire [27:0] bg2a_ddr_rdaddr;
wire [31:0] bg2a_ddr_dout;
wire        bg2a_ddr_rd_req;
wire        bg2a_ddr_rd_ack;

reg [3:0]  bg2a_state;
reg [15:0] bg2a_hi_word;
reg [15:0] bg2a_lo_word;
reg        bg2a_req_prev;
reg        bg2a_ddr_req_r;
reg [27:0] bg2a_ddr_addr_r;
assign bg2a_ddr_rdaddr = bg2a_ddr_addr_r;
assign bg2a_ddr_rd_req = bg2a_ddr_req_r;

wire [27:0] bg2a_addr_lo_full = DDR_TILE3_LO_BASE + {4'd0, d16_1_pf1_rom_addr};
wire [27:0] bg2a_addr_hi_full = DDR_TILE3_HI_BASE + {4'd0, d16_1_pf1_rom_addr};

always @(posedge clk) begin
	if (reset) begin
		bg2a_state     <= BG2_IDLE;
		bg2a_req_prev  <= 0;
		bg2a_ddr_req_r <= 0;
		bg2a_ddr_addr_r<= 28'd0;
		bg2a_hi_word   <= 16'd0;
		bg2a_lo_word   <= 16'd0;
	end else begin
		bg2a_req_prev <= d16_1_pf1_rom_req;
		case (bg2a_state)
			BG2_IDLE: if (d16_1_pf1_rom_req ^ bg2a_req_prev) bg2a_state <= BG2_REQ_HI;
			BG2_REQ_HI: begin
				bg2a_ddr_addr_r <= bg2a_addr_hi_full;
				bg2a_ddr_req_r  <= ~bg2a_ddr_req_r;
				bg2a_state      <= BG2_WAIT_HI;
			end
			BG2_WAIT_HI: if (bg2a_ddr_rd_ack == bg2a_ddr_req_r) begin
				if (bg2a_ddr_addr_r[1] == 1'b0)
					bg2a_hi_word <= bg2a_ddr_dout[15:0];
				else
					bg2a_hi_word <= bg2a_ddr_dout[31:16];
				bg2a_state <= BG2_REQ_LO;
			end
			BG2_REQ_LO: begin
				bg2a_ddr_addr_r <= bg2a_addr_lo_full;
				bg2a_ddr_req_r  <= ~bg2a_ddr_req_r;
				bg2a_state      <= BG2_WAIT_LO;
			end
			BG2_WAIT_LO: if (bg2a_ddr_rd_ack == bg2a_ddr_req_r) begin
				if (bg2a_ddr_addr_r[1] == 1'b0)
					bg2a_lo_word <= bg2a_ddr_dout[15:0];
				else
					bg2a_lo_word <= bg2a_ddr_dout[31:16];
				bg2a_state <= BG2_DONE;
			end
			BG2_DONE: bg2a_state <= BG2_IDLE;
			default:  bg2a_state <= BG2_IDLE;
		endcase
	end
end

// Data 32-bit da arbiter B (= SDRAM). Switch DDR3→SDRAM richiede swap HI/LO
// (regola dogma utente convalidata HW).
assign d16_1_pf1_rom_data  = tile_perm(bg2a_arb_data[15:0], bg2a_arb_data[31:16],
                                         osd_fg0_swap_hl, osd_fg0_brev8,
                                         osd_fg0_nibsw,   osd_fg0_bs_ab);
assign d16_1_pf1_rom_valid = bg2a_arb_valid;

// ===== Bridge BG2 chip1.pf2 (DDR3 port 7) =====
wire [27:0] bg2b_ddr_rdaddr;
wire [31:0] bg2b_ddr_dout;
wire        bg2b_ddr_rd_req;
wire        bg2b_ddr_rd_ack;

reg [3:0]  bg2b_state;
reg [15:0] bg2b_hi_word;
reg [15:0] bg2b_lo_word;
reg        bg2b_req_prev;
reg        bg2b_ddr_req_r;
reg [27:0] bg2b_ddr_addr_r;
assign bg2b_ddr_rdaddr = bg2b_ddr_addr_r;
assign bg2b_ddr_rd_req = bg2b_ddr_req_r;

wire [27:0] bg2b_addr_lo_full = DDR_TILE3_LO_BASE + {4'd0, d16_1_pf2_rom_addr};
wire [27:0] bg2b_addr_hi_full = DDR_TILE3_HI_BASE + {4'd0, d16_1_pf2_rom_addr};

always @(posedge clk) begin
	if (reset) begin
		bg2b_state     <= BG2_IDLE;
		bg2b_req_prev  <= 0;
		bg2b_ddr_req_r <= 0;
		bg2b_ddr_addr_r<= 28'd0;
		bg2b_hi_word   <= 16'd0;
		bg2b_lo_word   <= 16'd0;
	end else begin
		bg2b_req_prev <= d16_1_pf2_rom_req;
		case (bg2b_state)
			BG2_IDLE: if (d16_1_pf2_rom_req ^ bg2b_req_prev) bg2b_state <= BG2_REQ_HI;
			BG2_REQ_HI: begin
				bg2b_ddr_addr_r <= bg2b_addr_hi_full;
				bg2b_ddr_req_r  <= ~bg2b_ddr_req_r;
				bg2b_state      <= BG2_WAIT_HI;
			end
			BG2_WAIT_HI: if (bg2b_ddr_rd_ack == bg2b_ddr_req_r) begin
				if (bg2b_ddr_addr_r[1] == 1'b0)
					bg2b_hi_word <= bg2b_ddr_dout[15:0];
				else
					bg2b_hi_word <= bg2b_ddr_dout[31:16];
				bg2b_state <= BG2_REQ_LO;
			end
			BG2_REQ_LO: begin
				bg2b_ddr_addr_r <= bg2b_addr_lo_full;
				bg2b_ddr_req_r  <= ~bg2b_ddr_req_r;
				bg2b_state      <= BG2_WAIT_LO;
			end
			BG2_WAIT_LO: if (bg2b_ddr_rd_ack == bg2b_ddr_req_r) begin
				if (bg2b_ddr_addr_r[1] == 1'b0)
					bg2b_lo_word <= bg2b_ddr_dout[15:0];
				else
					bg2b_lo_word <= bg2b_ddr_dout[31:16];
				bg2b_state <= BG2_DONE;
			end
			BG2_DONE: bg2b_state <= BG2_IDLE;
			default:  bg2b_state <= BG2_IDLE;
		endcase
	end
end

assign d16_1_pf2_rom_data  = tile_perm(bg2b_arb_data[15:0], bg2b_arb_data[31:16],
                                         osd_fg1_swap_hl, osd_fg1_brev8,
                                         osd_fg1_nibsw,   osd_fg1_bs_ab);
assign d16_1_pf2_rom_valid = bg2b_arb_valid;

// =====================================================================
// Text chip0.pf1 → BRAM (tile1 128 KB in M10K — eliminata race DDR3).
// 2 BRAM 32K×16 (= LO region 64 KB + HI region 64 KB).
// Download CPU side: ioctl_addr 0x110000-0x11FFFF (LO) / 0x120000-0x12FFFF (HI).
// Bridge side: rom_addr byte → split bit 17 = region, bit 16:1 = word_idx.
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [15:0] tile1_lo [0:32767];
(* ramstyle = "M10K", no_rw_check *) reg [15:0] tile1_hi [0:32767];

// CPU download write — HPS WIDE=1: ioctl_dout 16-bit, ioctl_wr 1 pulse per word16,
// ioctl_addr += 2 per ogni write. Quindi scrivo 1 word16 direttamente per ioctl_wr.
wire        is_tile1_lo_dl = ioctl_download && (ioctl_index == 16'd0)
                              && (ioctl_addr >= 27'h110000) && (ioctl_addr < 27'h120000);
wire        is_tile1_hi_dl = ioctl_download && (ioctl_index == 16'd0)
                              && (ioctl_addr >= 27'h120000) && (ioctl_addr < 27'h130000);

// word_idx dentro la region: (ioctl_addr - base_region) >> 1.
// Per LO base=0x110000 → addr range [0x110000..0x11FFFE] step 2 → word_idx [0..0x7FFF].
// addr[15:1] = stesso valore (bit 16=1 fuori, bit 15:1 = offset[15:1]).
wire [14:0] tile1_dl_word_idx = ioctl_addr[15:1];

always @(posedge clk) begin
	if (ioctl_wr && is_tile1_lo_dl) tile1_lo[tile1_dl_word_idx] <= ioctl_dout;
	if (ioctl_wr && is_tile1_hi_dl) tile1_hi[tile1_dl_word_idx] <= ioctl_dout;
end

// Bridge text: rom_addr byte (24-bit) → word_idx = addr[16:1].
// Output 32-bit = {hi_word_byte_hi, hi_word_byte_lo, lo_word_byte_hi, lo_word_byte_lo}
//              = {tile1_hi[idx], tile1_lo[idx]}
// rom_req toggle protocol → 1 ck di latenza BRAM read + 1 ck DONE.
reg [14:0] txt_word_idx;
reg [15:0] txt_hi_word, txt_lo_word;
reg        txt_req_prev;
reg [2:0]  txt_lat_cnt;   // 0=idle, 1..2=read pipeline
reg        txt_valid_r;

// word_idx = byte_addr[15:1] (= byte_addr / 2). Text region 64 KB = 32K word16.
// Latch addr all'edge del req per fissarlo durante BRAM read.
reg [14:0] txt_word_idx_r;
always @(posedge clk) begin
	if (reset) begin
		txt_req_prev   <= 0;
		txt_word_idx_r <= 0;
		txt_lat_cnt    <= 0;
		txt_valid_r    <= 0;
	end else begin
		txt_req_prev <= d16_0_pf1_rom_req;
		txt_valid_r  <= 1'b0;
		if (d16_0_pf1_rom_req ^ txt_req_prev) begin
			txt_word_idx_r <= d16_0_pf1_rom_addr[15:1];
			txt_lat_cnt    <= 3'd2;
		end else if (txt_lat_cnt != 0) begin
			txt_lat_cnt <= txt_lat_cnt - 1;
			if (txt_lat_cnt == 1) txt_valid_r <= 1'b1;
		end
	end
end

// BRAM read sull'addr latched (1 ck di lat).
always @(posedge clk) begin
	txt_hi_word <= tile1_hi[txt_word_idx_r];
	txt_lo_word <= tile1_lo[txt_word_idx_r];
end

assign d16_0_pf1_rom_data  = tile_perm(txt_hi_word, txt_lo_word,
                                         osd_bg0_swap_hl, osd_bg0_brev8,
                                         osd_bg0_nibsw,   osd_bg0_bs_ab);
assign d16_0_pf1_rom_valid = txt_valid_r;

// === Savestate DDR MUX (gated su ss_ddr_grant, con QUIESCENZA latch-on-drain) ===
// Il MUX NON commuta su ss_busy raw: lo farebbe mentre ddram_4port ha fetch sprite/OKI in
// volo -> i DDRAM_DOUT_READY del savestate verrebbero mangiati dalla FSM dell'arbitro ->
// OKI/sprite corrotti o appesi. ss_ddr_grant si ALZA solo dopo che il bus DDR e' fisicamente
// DRENATO (nessuna transazione in volo, stabile per N cicli) e poi RESTA latchato fino a fine
// SS. NON dipende da rd_ack==rd_req: sotto hold l'arbitro non serve i rd_req di sprite/OKI,
// quindi attendere quella quiescenza appenderebbe il restore a COLD BOOT (cache-miss iniziale
// non servito). Equivalente del ddr_mux / RESTORE_WAIT_PAUSE di F2. Vedi blocco hold/grant sotto.
wire  [7:0] d4_DDRAM_BURSTCNT;
wire [28:0] d4_DDRAM_ADDR;
wire        d4_DDRAM_RD;
wire [63:0] d4_DDRAM_DIN;
wire  [7:0] d4_DDRAM_BE;
wire        d4_DDRAM_WE;

ddr_if ss_ddr();   // dichiarata qui (prima del MUX che usa ss_ddr.read/write)
// ss_hold: appena il SS chiede il bus (ss_busy), BLOCCA l'emissione di ddram_4port (resta in
// state 0, richieste pendenti). Cosi' l'arbitro non emette read mentre il SS ha/prende il bus.
// ss_ddr_grant: il MUX devia DDRAM_* al SS solo dopo che l'arbitro e' diventato idle (ss_idle).
// Al termine (ss_busy basso & SS senza transazioni in volo) si rilascia tutto: ss_hold scende,
// l'arbitro riprende a servire le richieste accumulate. NESSUNA read persa.
// Gate DDR savestate estratto in modulo generico cross-core (rtl/common/ss_ddr_gate.sv).
// La REGOLA DI TRASPARENZA (discesa hold/grant solo su segnali interni SS, drain-on-rise)
// vive nel modulo: il core la eredita istanziandolo, non la re-implementa. Vedi ss_ddr_gate.sv.
wire ss_hold, ss_ddr_grant;
wire ss_tx_inflight = ss_ddr.read | ss_ddr.write;   // transazione del SOLO savestate in volo
ss_ddr_gate #(.AW(29), .DRAIN_TH(3)) u_ss_ddr_gate (
	.clk            (clk),
	.reset          (reset),
	.ss_busy        (ss_busy),
	.ss_tx_inflight (ss_tx_inflight),
	// master gioco (arbitro)
	.game_burstcnt  (d4_DDRAM_BURSTCNT),
	.game_addr      (d4_DDRAM_ADDR),
	.game_rd        (d4_DDRAM_RD),
	.game_din       (d4_DDRAM_DIN),
	.game_be        (d4_DDRAM_BE),
	.game_we        (d4_DDRAM_WE),
	// master savestate (memory_stream)
	.ss_burstcnt    (ss_DDRAM_BURSTCNT),
	.ss_addr        (ss_DDRAM_ADDR),
	.ss_rd          (ss_DDRAM_RD),
	.ss_din         (ss_DDRAM_DIN),
	.ss_be          (ss_DDRAM_BE),
	.ss_we          (ss_DDRAM_WE),
	.DDRAM_BUSY     (DDRAM_BUSY),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	// uscite mux'd verso il controller DDR3
	.DDRAM_BURSTCNT (DDRAM_BURSTCNT),
	.DDRAM_ADDR     (DDRAM_ADDR),
	.DDRAM_RD       (DDRAM_RD),
	.DDRAM_DIN      (DDRAM_DIN),
	.DDRAM_BE       (DDRAM_BE),
	.DDRAM_WE       (DDRAM_WE),
	.ss_hold        (ss_hold),
	.ss_ddr_grant   (ss_ddr_grant)
);

ddram_4port u_ddram (
	.DDRAM_CLK       (DDRAM_CLK),
	.DDRAM_BUSY      (DDRAM_BUSY),
	.DDRAM_BURSTCNT  (d4_DDRAM_BURSTCNT),
	.DDRAM_ADDR      (d4_DDRAM_ADDR),
	.DDRAM_DOUT      (DDRAM_DOUT),
	.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
	.DDRAM_RD        (d4_DDRAM_RD),
	.DDRAM_DIN       (d4_DDRAM_DIN),
	.DDRAM_BE        (d4_DDRAM_BE),
	.DDRAM_WE        (d4_DDRAM_WE),

	// Write port: sprite + tile2 download (MUX-ato sopra in ddr_dl_*)
	.wraddr (ddr_dl_waddr),
	.din    (ddr_dl_wdata),
	.we_byte(1'b0),
	.we_req (ddr_dl_we_req),
	.we_ack (ddr_dl_we_ack),

	// Read port 1: NON USATA (H6280 ROM ora in BRAM rom_even/rom_odd)
	.rdaddr (28'd0), .dout (), .rd_req(1'b0), .rd_ack(),
	// Read port 2: NON USATA (OKI #0 spostato a port 5 32-bit con prefetch)
	.rdaddr2(28'd0), .dout2(), .rd_req2(1'b0), .rd_ack2(),
	// Read port 3: NON USATA (OKI #1 spostato a port 6 32-bit con prefetch)
	.rdaddr3(28'd0), .dout3(), .rd_req3(1'b0), .rd_ack3(),

	// Read port 4: sprite ROM 32-bit
	.rdaddr4(sprite_ddr_rdaddr),
	.dout4  (sprite_ddr_dout),
	.rd_req4(sprite_ddr_rd_req),
	.rd_ack4(sprite_ddr_rd_ack),

	// Read port 5: OKI #0 samples (512 KB @ DDR3 0x5500000, 32-bit + prefetch)
	.rdaddr5(oki0_ddr_addr_w), .dout5(oki0_ddr_data_w),
	.rd_req5(oki0_ddr_req_w),  .rd_ack5(oki0_ddr_ack_w),

	// Read port 6: OKI #1 samples (512 KB @ DDR3 0x5580000, 32-bit + prefetch)
	.rdaddr6(oki1_ddr_addr_w), .dout6(oki1_ddr_data_w),
	.rd_req6(oki1_ddr_req_w),  .rd_ack6(oki1_ddr_ack_w),

	// Read port 7: NON USATA (BG2 chip1.pf2 spostato su SDRAM via arb_b)
	.rdaddr7(28'd0), .dout7(), .rd_req7(1'b0), .rd_ack7(),

	// Read port 8: NON USATA (text ora in BRAM tile1_lo/hi)
	.rdaddr8(28'd0), .dout8(), .rd_req8(1'b0), .rd_ack8(),

	// Read port 9: sprites2 chip1 ROM (DDR3 0x4400000-0x47FFFFF, 4 MB)
	.rdaddr9(sprite2_ddr_rdaddr),
	.dout9  (sprite2_ddr_dout),
	.rd_req9(sprite2_ddr_rd_req),
	.rd_ack9(sprite2_ddr_rd_ack),

	// Copy port non usato
	.cpaddr(28'd0), .cpdout(), .cpwr(), .cpreq(1'b0), .cpbusy(),
	.ss_idle(ddram_ss_idle),
	.ss_hold(ss_hold)
);
wire ddram_ss_idle;

// =====================================================================
// SAVESTATE — infrastruttura (DORMIENTE finché ss_save/ss_load arrivano).
// memory_stream (dentro save_state_data) parla ddr_if; lo adatto ai segnali raw
// ss_DDRAM_* che il MUX sopra instrada verso DDRAM_* quando ss_busy.
// ss_save/ss_load per ora = 0 → ss_busy=0 → MUX dà sempre il DDR al gioco (baseline).
// =====================================================================
wire        ss_busy;
wire  [7:0] ss_DDRAM_BURSTCNT;
wire [28:0] ss_DDRAM_ADDR;
wire        ss_DDRAM_RD;
wire [63:0] ss_DDRAM_DIN;
wire  [7:0] ss_DDRAM_BE;
wire        ss_DDRAM_WE;

// === SS-68000 (ss_m68k): pilota il save/load via mini-handler 68K ===
// Trigger dalla UI (ss_save/ss_load = pulse). Lo slot (ss_slot) seleziona la regione DDR.
wire        ss_ui_save = ss_save;
wire        ss_ui_load = ss_load;

// Output del modulo SS (usati sopra: cpu_din mux, IPL7, reset, pausa, cen gating)
wire        ss_din_en, ss_irq, ss_reset, ss_pause, ss_cpu_exec;
wire [15:0] ss_din_data;
wire        ss_do_save, ss_do_load;   // pulse verso memory_stream (da ss_m68k)
wire        ss_slot_empty;            // load su sotto-slot mai scritto -> restore annullato
wire        ss_restore_done;          // pulse: restore finito -> riavvia DMA palette (ricostruisce pal_buf)
wire [3:0]  ss_state_dbg;

ss_m68k #(.SS_GLOB_IDX(SS_IDX_GLOBAL)) u_ss_m68k (
	.clk          (clk),
	.ce_cpu       (cpu_cen_g),
	.cpu_word_addr(cpu_addr),          // gia' byte-addr 24-bit
	.cpu_ds_n     (cpu_dsn),
	.cpu_rw       (~cpu_wr),           // 1=read
	.cpu_fc       (cpu_fc),
	.iack_n       (~cpu_iack),
	.cpu_data_out (cpu_wdata),
	.do_save      (ss_ui_save),
	.do_restore   (ss_ui_load),
	.paused_real  (paused_safe_r),   // pausa REALE frame-aligned (NON paused_safe combinatorio)
	.ss_mem_write (ss_do_save),
	.ss_mem_read  (ss_do_load),
	.ss_busy      (ss_busy),
	.slot_empty   (ss_slot_empty),
	.ss_glob      (ssb[SS_IDX_GLOBAL]),
	.ss_din_en    (ss_din_en),
	.ss_din_data  (ss_din_data),
	.ss_irq       (ss_irq),
	.ss_reset     (ss_reset),
	.ss_pause     (ss_pause),
	.ss_cpu_exec  (ss_cpu_exec),
	.ss_restore_done (ss_restore_done),
	.ss_state_out (ss_state_dbg)
);

// ddr_if del savestate <-> segnali raw ss_DDRAM_* (ss_ddr dichiarata sopra, prima del MUX)
assign ss_DDRAM_ADDR     = ss_ddr.addr[31:3];
assign ss_DDRAM_DIN      = ss_ddr.wdata;
assign ss_DDRAM_RD       = ss_ddr.read;
assign ss_DDRAM_WE       = ss_ddr.write;
assign ss_DDRAM_BURSTCNT = ss_ddr.burstcnt;
assign ss_DDRAM_BE       = ss_ddr.byteenable;
assign ss_ddr.rdata      = DDRAM_DOUT;
// Finche' il MUX non concede il bus al SS (ss_ddr_grant), memory_stream deve STALLARE:
// busy=1 (non emette transazioni che andrebbero perse) e rdata_ready=0 (non campiona i
// DOUT del gioco). Col grant vede i veri DDRAM_*.
assign ss_ddr.rdata_ready= ss_ddr_grant & DDRAM_DOUT_READY;
assign ss_ddr.busy       = ~ss_ddr_grant | DDRAM_BUSY;

// ssbus/ssb dichiarati in alto (prima del primo adaptor RAM). Qui: mux + master.
ssbus_mux #(.COUNT(SS_NSLAVES)) ss_mux (
	.clk     (clk),
	.slave   (ssbus),
	.masters (ssb)
);

// COUNT = SS_MS_COUNT (potenza di 2 >= SS_NSLAVES). CHUNK_BITS=$clog2(COUNT). NON usare 1
// (CHUNK_BITS=0 rompe i bit-select di memory_stream). I chunk oltre SS_NSLAVES restano vuoti
// (timeout query) → save/load auto-coerenti. Costo trascurabile.
save_state_data #(.COUNT(SS_MS_COUNT)) u_save_state (
	.clk        (clk),
	.reset      (reset),
	.ddr        (ss_ddr),
	.read_start (ss_do_load),
	.write_start(ss_do_save),
	.index      (ss_slot),
	.busy       (ss_busy),
	.slot_empty (ss_slot_empty),
	.ssbus      (ssbus)
);

// Sprite renderer: bw_sprites (stesso motore di Night Slashers / Tattoo), DUE istanze, una per
// chip, come i due DECO52 veri. Porta a BW il lavoro anti-glitch di NS: scan
// parallelo, scan-ombra con FIFO match, draw disaccoppiato con prefetch fra
// sprite, ring elastico a 12 buffer (consumo solo a hbl), latch degli arrivi.
// SPR0_5BPP=0 = formato BW (4bpp, pxl 12 bit). Il layout DDR half-adiacente
// e' applicato al download (spr_dst_off). Ogni istanza usa SOLO le sue porte:
// buffer e logica dell'altro chip vengono spazzati in sintesi.
// sprite_pxl / sprite2_pxl dichiarati sopra (forward use).
wire [12:0] sprite_pxl13;
assign sprite_pxl = sprite_pxl13[11:0];   // [12] = 0 con SPR0_5BPP=0

bw_sprites #(.SPR0_5BPP(0), .CHIP_ONLY(2'b01)) u_sprites (
	.clk(clk), .reset(reset),
	.sram0_addr(spr_render_addr),
	.sram0_data(spr_render_data),
	.sram1_addr(),
	.sram1_data(16'd0),
	.rom0_addr (sprite_romaddr),
	.rom0_req  (sprite_romreq),
	.rom0_data (sprite_romdata),
	.rom0_valid(sprite_romvalid),
	.rom1_addr (),
	.rom1_req  (),
	.rom1_data (32'd0),
	.rom1_valid(1'b0),
	.rom0_p4_addr (),
	.rom0_p4_req  (),
	.rom0_p4_data (8'd0),
	.rom0_p4_valid(1'b0),
	// Coordinate GREZZE: il flip degli sprite lo fa bw_sprites (flipscreen_spr
	// = ~flip_screen -> x=304-x, y=240-y, mult=-16), nello stesso spazio della
	// bitmap MAME. Passargli render_*_flip = doppio flip, i due si annullano e
	// gli sprite restano dritti (spostati di 15 px). Il tilegen invece le vuole
	// flippate: li' il flip lo fa solo questo top.
	.render_x  (render_x), .render_y(render_y),
	.hblank_in (hblank_in),
	.vblank_in (vblank_in),
	.ce_pix    (ce_pix),
	.pause_in  (paused_safe),
	.flip_screen(flip_screen),
	.osd_spr_swap_hl(osd_spr_swap_hl),
	.osd_spr_brev8  (osd_spr_brev8),
	.osd_spr_nibsw  (osd_spr_nibsw),
	.osd_spr_bs_ab  (osd_spr_bs_ab),
	.osd_spr_msb_first   (osd_spr_msb_first),
	.osd_spr_half_inv    (osd_spr_half_inv),
	.osd_spr_half_eff_inv(osd_spr_half_eff_inv),
	.osd_spr_row_inv     (osd_spr_row_inv),
	.osd_spr_plane_inv   (osd_spr_plane_inv),
	.osd_spr_p0_src      (osd_spr_p0_src),
	.osd_spr_p1_src      (osd_spr_p1_src),
	.osd_spr_p2_src      (osd_spr_p2_src),
	.osd_spr_p3_src      (osd_spr_p3_src),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),
	.pxl0      (sprite_pxl13),
	.pxl1      (),
	.pxl1_alpha()
);

bw_sprites #(.SPR0_5BPP(0), .CHIP_ONLY(2'b10)) u_sprites_c1 (
	.clk(clk), .reset(reset),
	.sram0_addr(),
	.sram0_data(16'd0),
	.sram1_addr(spr2_render_addr),
	.sram1_data(spr2_render_data),
	.rom0_addr (),
	.rom0_req  (),
	.rom0_data (32'd0),
	.rom0_valid(1'b0),
	.rom1_addr (sprite2_romaddr),
	.rom1_req  (sprite2_romreq),
	.rom1_data (sprite2_romdata),
	.rom1_valid(sprite2_romvalid),
	.rom0_p4_addr (),
	.rom0_p4_req  (),
	.rom0_p4_data (8'd0),
	.rom0_p4_valid(1'b0),
	// Coordinate GREZZE: il flip degli sprite lo fa bw_sprites (flipscreen_spr
	// = ~flip_screen -> x=304-x, y=240-y, mult=-16), nello stesso spazio della
	// bitmap MAME. Passargli render_*_flip = doppio flip, i due si annullano e
	// gli sprite restano dritti (spostati di 15 px). Il tilegen invece le vuole
	// flippate: li' il flip lo fa solo questo top.
	.render_x  (render_x), .render_y(render_y),
	.hblank_in (hblank_in),
	.vblank_in (vblank_in),
	.ce_pix    (ce_pix),
	.pause_in  (paused_safe),
	.flip_screen(flip_screen),
	.osd_spr_swap_hl(osd_spr_swap_hl),
	.osd_spr_brev8  (osd_spr_brev8),
	.osd_spr_nibsw  (osd_spr_nibsw),
	.osd_spr_bs_ab  (osd_spr_bs_ab),
	.osd_spr_msb_first   (osd_spr_msb_first),
	.osd_spr_half_inv    (osd_spr_half_inv),
	.osd_spr_half_eff_inv(osd_spr_half_eff_inv),
	.osd_spr_row_inv     (osd_spr_row_inv),
	.osd_spr_plane_inv   (osd_spr_plane_inv),
	.osd_spr_p0_src      (osd_spr_p0_src),
	.osd_spr_p1_src      (osd_spr_p1_src),
	.osd_spr_p2_src      (osd_spr_p2_src),
	.osd_spr_p3_src      (osd_spr_p3_src),
	.osd_spr_w_swap_pos    (osd_spr_w_swap_pos),
	.osd_spr_w_offset_first(osd_spr_w_offset_first),
	.osd_spr_w_code_swap   (osd_spr_w_code_swap),
	.osd_spr_w_offset      (osd_spr_w_offset),
	.pxl0      (),
	.pxl1      (sprite2_opq_pxl),
	.pxl1_alpha(sprite2_alp_pxl)
);

// ioctl_wait: backpressure verso HPS durante DDR3 write.
// Pattern Raiden (sdram_bridge.sv:242): wait pendente + stretch counter post-write.
// Stretch serve a dare margine al cross-clock domain (clk_sys vs DDRAM_CLK) e a
// completare refresh/cacheline. Senza stretch: race su toggle req/ack → scritture
// scartate → DDR3 corrotta → sprite con buchi e silhouette monochrome.
wire ddr_dl_we_pending = (ddr_dl_we_req != ddr_dl_we_ack);
reg [7:0] ddr_dl_stretch;
reg       ddr_dl_pending_d;
always @(posedge clk) begin
	if (reset) begin
		ddr_dl_stretch   <= 0;
		ddr_dl_pending_d <= 0;
	end else begin
		ddr_dl_pending_d <= ddr_dl_we_pending;
		// Falling edge di pending → carica stretch (64 ck = ~670 ns @ 96 MHz)
		if (ddr_dl_pending_d & ~ddr_dl_we_pending)
			ddr_dl_stretch <= 8'd64;
		else if (ddr_dl_stretch != 0)
			ddr_dl_stretch <= ddr_dl_stretch - 8'd1;
	end
end
assign ioctl_wait = ddr_dl_we_pending | (ddr_dl_stretch != 0);

endmodule
