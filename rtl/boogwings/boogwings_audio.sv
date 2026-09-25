// SPDX-License-Identifier: GPL-3.0-or-later
//
// boogwings_audio — sound subsystem BoogieWings.
//
// MAME boogwing.cpp:
//   - HuC6280A (audio CPU) @ SOUND_XTAL/4 ≈ 8.055 MHz
//   - YM2151 @ SOUND_XTAL/9 ≈ 3.580 MHz
//   - OKI M6295 #0 @ SOUND_XTAL/32 ≈ 1.007 MHz (PIN7_HIGH)
//   - OKI M6295 #1 @ SOUND_XTAL/16 ≈ 2.014 MHz (PIN7_HIGH)
//
// Memory map H6280 (audio_map boogwing.cpp:547):
//   0x000000-0x00FFFF: ROM (64 KB, audiocpu.bin)
//   0x100000-0x100001: NOP (read/write)
//   0x110000-0x110001: YM2151 r/w
//   0x120000-0x120001: OKI #0 r/w
//   0x130000-0x130001: OKI #1 r/w
//   0x140000:          soundlatch (read only)
//   0x1F0000-0x1F1FFF: RAM (8 KB)
//
// IRQ:
//   IRQ0 = soundlatch_irq_cb (= main CPU scrive nuovo latch)
//   IRQ1 = YM2151 IRQ
//
// STEP 1: solo H6280 + ROM + RAM + soundlatch. YM/OKI vengono dopo.
//         Audio output = 0 finché non istanziati YM/OKI.

module boogwings_audio #(
	parameter integer SS_HUC_RAM_IDX   = 0,
	parameter integer SS_HUC_CPU_IDX   = 0,
	parameter integer SS_OKI0_IDX      = 0,
	parameter integer SS_OKI1_IDX      = 0,
	parameter integer SS_YM_IDX        = 0,
	parameter integer SS_AUDIO_BUS_IDX = 0
) (
	input  wire        clk,             // clk_sys (96 MHz)
	input  wire        reset,
	input  wire        ce_audio,        // ~8 MHz (clk_sys / 12)
	input  wire        ce_ym,           // ~3.58 MHz (YM2151 cen)
	input  wire        ce_ym_p1,        // ~1.79 MHz (jt51 cen_p1)
	input  wire        ce_oki0,         // ~1.0 MHz (OKI #0, PIN7_HIGH)
	input  wire        ce_oki1,         // ~2.0 MHz (OKI #1, PIN7_HIGH)
	// Savestate fase contatori ce (da Template): SAVE = valori in; RESTORE = valori out + load pulse.
	// Salvare la fase dei contatori fa ripartire HuC+chip dalla STESSA fase del save (audio in sync).
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
	output wire        ce_cnt_load_wr,   // pulse: ricarica i contatori in Template
	input  wire        pause,           // paused_safe (frame-aligned): gate UNICO audio (= obj_paused F2).
	                                    // Ferma HuC (CE_IN), chip (ce gated), FIFO soundlatch -> tutto
	                                    // si ferma e riparte nello STESSO ciclo. La HuC via CE_IN (divisore congelato), non RDY.

	// Soundlatch dalla CPU principale (via DECO104)
	input  wire [7:0]  soundlatch_data,
	input  wire        soundlatch_irq_pulse,  // pulse: nuovo latch scritto

	// Audiocpu ROM download (BRAM 64 KB) — 2 byte/ck (low + high di ioctl word16)
	input  wire        rom_we_lo,
	input  wire        rom_we_hi,
	input  wire [15:0] rom_waddr_lo,
	input  wire [15:0] rom_waddr_hi,
	input  wire [7:0]  rom_wdata_lo,
	input  wire [7:0]  rom_wdata_hi,

	// DDR3 read port per OKI #0 (32-bit fetch con prefetch+1 linea da ddram_4port)
	output wire [27:0] oki0_ddr_addr,
	output wire        oki0_ddr_req,
	input  wire [31:0] oki0_ddr_data,
	input  wire        oki0_ddr_ack,

	// DDR3 read port per OKI #1 (32-bit fetch con prefetch+1 linea)
	output wire [27:0] oki1_ddr_addr,
	output wire        oki1_ddr_req,
	input  wire [31:0] oki1_ddr_data,
	input  wire        oki1_ddr_ack,

	// OSD audio sel (4 bit each: 0=Default, 1=Mute, 2=MAME, 3-15 = percentual scale)
	input  wire [3:0]  osd_sel_fm,
	input  wire [3:0]  osd_sel_oki0,
	input  wire [3:0]  osd_sel_oki1,
	input  wire [1:0]  osd_presence,     // shelving alti sul mix: 0 Off, 1 +3, 2 +6, 3 +9 dB

	// Audio output (16-bit signed)
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r,

	// Savestate: RAM HUC6280 (ram_mem 8KB 8-bit). Adaptor inline: durante SS (HUC in pausa
	// via RDY) la porta read/write della RAM e' dirottata al bus SS. A SS idle: trasparente.
	ssbus_if.slave     ss_huc_ram,
	// Savestate: stato interno HUC6280 (auto_ss, 246 bit) via auto_save_adaptor.
	ssbus_if.slave     ss_huc_cpu,
	// Savestate: stato interno OKI #0/#1 (jt6295, auto_ss 359 bit ciascuno).
	ssbus_if.slave     ss_oki0,
	ssbus_if.slave     ss_oki1,
	// Savestate: stato interno YM2151 (jt51, auto_ss 2774 bit).
	ssbus_if.slave     ss_ym,
	// Savestate: stato persistente wrapper audio (FIFO sndlatch + YM/OKI ctrl, 161 bit).
	ssbus_if.slave     ss_audio_bus
);

// Default = bilanciamento del mix di MAME, misurato sull'attract: le scritture ai chip
// registrate in MAME suonate sui chip del core (banco AudioTrack_Compare), e i tre
// guadagni adattati perche' il mix coincida con l'uscita di MAME banda per banda.
// Livello complessivo lasciato uguale a prima: cambia solo il rapporto fra i chip
// (FM -3.8 dB, OKI0 +1.1, OKI1 -1.6), cioe' effetti piu' avanti rispetto alla musica.
localparam [7:0] DEF_GAIN_FM   = 8'h03;   // 0.1875 (era 0x04 = 0.250)
localparam [7:0] DEF_GAIN_OKI0 = 8'h60;   // 6.0    (era 0x55 = 5.3125)
localparam [7:0] DEF_GAIN_OKI1 = 8'h17;   // 1.4375 (era 0x1C = 1.75)
localparam [7:0] MAME_GAIN_FM   = 8'h05;
localparam [7:0] MAME_GAIN_OKI0 = 8'h09;
localparam [7:0] MAME_GAIN_OKI1 = 8'h02;

// mul12 OSD: 0,2 = placeholder, 1 = mute (handled below), 3+ = percent
function [11:0] osd_mul12_aud;
	input [3:0] sel;
	case (sel)
		4'd3:  osd_mul12_aud = 12'd64;    // 25%
		4'd4:  osd_mul12_aud = 12'd128;   // 50%
		4'd5:  osd_mul12_aud = 12'd192;   // 75%
		4'd6:  osd_mul12_aud = 12'd256;   // 100%
		4'd7:  osd_mul12_aud = 12'd320;   // 125%
		4'd8:  osd_mul12_aud = 12'd384;   // 150%
		4'd9:  osd_mul12_aud = 12'd512;   // 200%
		4'd10: osd_mul12_aud = 12'd640;   // 250%
		4'd11: osd_mul12_aud = 12'd768;   // 300%
		4'd12: osd_mul12_aud = 12'd1024;  // 400%
		4'd13: osd_mul12_aud = 12'd1280;  // 500%
		4'd14: osd_mul12_aud = 12'd1792;  // 700%
		4'd15: osd_mul12_aud = 12'd2560;  // 1000%
		default: osd_mul12_aud = 12'd256;
	endcase
endfunction

function [7:0] gain_resolve;
	input [3:0] sel;
	input [7:0] def_g;
	input [7:0] mame_g;
	reg [19:0] scaled;
	begin
		case (sel)
			4'd0: gain_resolve = def_g;
			4'd1: gain_resolve = 8'h00;
			4'd2: gain_resolve = mame_g;
			default: begin
				scaled = def_g * osd_mul12_aud(sel);
				gain_resolve = (scaled[19:8] > 12'hFF) ? 8'hFF : scaled[15:8];
			end
		endcase
	end
endfunction

wire [7:0] gain_fm   = gain_resolve(osd_sel_fm,   DEF_GAIN_FM,   MAME_GAIN_FM);
wire [7:0] gain_oki0 = gain_resolve(osd_sel_oki0, DEF_GAIN_OKI0, MAME_GAIN_OKI0);
wire [7:0] gain_oki1 = gain_resolve(osd_sel_oki1, DEF_GAIN_OKI1, MAME_GAIN_OKI1);

// =====================================================================
// Audiocpu ROM 64 KB — split in 2 BRAM (even/odd byte) per scrivere entrambi
// byte di un word ioctl nello stesso ck (no serialize FSM).
// rom_even[N] = byte addr 2N (= rom_waddr_lo[15:1])
// rom_odd [N] = byte addr 2N+1 (= rom_waddr_hi[15:1])
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] rom_even [0:32767];
(* ramstyle = "M10K", no_rw_check *) reg [7:0] rom_odd  [0:32767];
reg [7:0] rom_even_rd, rom_odd_rd;
reg       cpu_addr0_d;

always @(posedge clk) begin
	if (rom_we_lo) rom_even[rom_waddr_lo[15:1]] <= rom_wdata_lo;
end
always @(posedge clk) begin
	if (rom_we_hi) rom_odd [rom_waddr_hi[15:1]] <= rom_wdata_hi;
end

// =====================================================================
// Audiocpu RAM 8 KB (BRAM)
// =====================================================================
(* ramstyle = "M10K", no_rw_check *) reg [7:0] ram_mem [0:8191];
reg [7:0] ram_rd_r;

// =====================================================================
// H6280 bus
// =====================================================================
wire [20:0] cpu_addr;
wire [7:0]  cpu_dout;
wire        cpu_wr_n, cpu_rd_n;
wire        cpu_ce_pulse;          // CE_N (active LOW) → high pulse quando bus valido
wire [23:0] cpu_aud_l, cpu_aud_r;  // PSG interno (non usato per boogwing)
reg  [7:0]  cpu_din;

// Memory decode
wire is_rom = (cpu_addr[20:16] == 5'h00);                 // 0x000000-0x00FFFF
wire is_nop = (cpu_addr[20:16] == 5'h10);                 // 0x100000
wire is_ym  = (cpu_addr[20:16] == 5'h11);                 // 0x110000
wire is_ok0 = (cpu_addr[20:16] == 5'h12);                 // 0x120000
wire is_ok1 = (cpu_addr[20:16] == 5'h13);                 // 0x130000
wire is_snd = (cpu_addr[20:16] == 5'h14);                 // 0x140000
wire is_ram = (cpu_addr[20:13] == 8'b1111_1000);          // 0x1F0000-0x1F1FFF (= [20:13]=0xF8)

// BRAM read pipeline (1 ck latency)
// ROM: addr bit 0 seleziona even/odd. Indexing usa addr[15:1].
// Pattern ActFancer: WAIT_N basso durante ROM read fino a dati pronti
// (= cs_rom registrato 1 ck, poi WAIT_N alto → CPU resume).
always @(posedge clk) rom_even_rd <= rom_even[cpu_addr[15:1]];
always @(posedge clk) rom_odd_rd  <= rom_odd [cpu_addr[15:1]];
always @(posedge clk) cpu_addr0_d <= cpu_addr[0];
wire [7:0] rom_rd_r = cpu_addr0_d ? rom_odd_rd : rom_even_rd;

// WAIT_N=1 sempre. jt51_mmr campiona `write=!cs_n && !wr_n` direttamente a
// posedge clk (NON gated da cen_p1) per i registri MMR: reg_sel <= din avviene
// ad ogni ck con write=1. Quindi 1 ck di wr_n=0 è sufficiente.
wire wait_n = 1'b1;

// Savestate: durante SS (HUC in pausa) read/write RAM dirottati al bus SS. A SS idle:
// trasparente (addr=cpu_addr, write=is_ram&~cpu_wr_n, data=cpu_dout).
wire        ss_huc_sel  = ss_huc_ram.access(SS_HUC_RAM_IDX);
wire [12:0] ram_addr    = ss_huc_sel ? ss_huc_ram.addr[12:0] : cpu_addr[12:0];
// ram_we gated da ~pause: se la pausa cade a meta' di una write RAM, WR_N resta congelato
// basso -> senza gate la write stantia RISCRIVE ogni clk la RAM appena restaurata dal
// chunk HUC_RAM (che precede il chunk HUC_CPU che riallinea gli strobe) = 1 byte corrotto.
// In pausa utente sopprime solo riscritture idempotenti (stesso dato). A pause=0 identico.
wire        ram_we      = ss_huc_sel ? ss_huc_ram.write      : (is_ram & ~cpu_wr_n & ~pause);
wire [7:0]  ram_wdata   = ss_huc_sel ? ss_huc_ram.data[7:0]  : cpu_dout;

always @(posedge clk) ram_rd_r <= ram_mem[ram_addr];

// RAM write — livello: cpu_wr_n=0 per ~4 ck, ma write idempotente (stesso dato
// scritto N volte = 1 volta). Pattern ActFancer line 151.
always @(posedge clk) begin
	if (ram_we) ram_mem[ram_addr] <= ram_wdata;
end

// SS setup + read_response (read_delay 1 ck = latenza BRAM ram_rd_r).
reg ss_huc_rd_d;
always @(posedge clk) begin
	ss_huc_ram.setup(SS_HUC_RAM_IDX, 8192, 0);  // 8192 byte, width 0 = 8 bit
	ss_huc_rd_d <= ss_huc_sel & ss_huc_ram.read;
	if (ss_huc_sel & ss_huc_ram.write) ss_huc_ram.write_ack(SS_HUC_RAM_IDX);
	if (ss_huc_rd_d) ss_huc_ram.read_response(SS_HUC_RAM_IDX, {56'b0, ram_rd_r});
end

// Soundlatch FIFO 16-deep — col refresh +2% il 68K invia i comandi audio piu'
// fitti, mentre la H6280 (clock fisso) li smaltisce in IRQ1: due write prima
// della read clobberavano un comando = singhiozzo. La FIFO accoda ogni comando
// e li consegna tutti. Puntatori a 5 bit (1 bit di wrap) -> FULL ed EMPTY
// distinti (no aliasing). Push gated su !full. Edge-detect su pulse (livello
// largo bus-cycle 68K) e su read H6280 (RD_N basso 6-24 ck).
reg  [7:0] sndlatch_fifo [0:15];
reg  [4:0] sl_wptr, sl_rptr;       // 5 bit: [4]=wrap, [3:0]=index
reg        sl_pulse_d, sl_rd_d;
wire       sl_rd_lvl = is_snd && ~cpu_rd_n;
wire       sl_empty  = (sl_wptr == sl_rptr);
wire       sl_full   = (sl_wptr[4] != sl_rptr[4]) && (sl_wptr[3:0] == sl_rptr[3:0]);
// soundlatch_irq_pulse NON gated: durante il SS il 68k (mini-handler) NON scrive il soundlatch
// (solo stack), quindi gatare il push perderebbe un comando (BUCO 2). Edge-detect su pulse diretto.
// sl_pulse_d/sl_rd_d sono salvati nel SS -> al restore nessun edge spurio. Trasparente a SS spento.
wire       sl_push   = (soundlatch_irq_pulse & ~sl_pulse_d) & ~sl_full;   // rising-edge, no overflow
wire       sl_pop    = (~sl_rd_lvl & sl_rd_d) & ~sl_empty;                // falling-edge read

integer sl_i;
always @(posedge clk) begin
	sl_pulse_d <= soundlatch_irq_pulse;   // edge-detect sul pulse diretto (no comando perso al SS)
	sl_rd_d    <= sl_rd_lvl;
	if (reset) begin
		sl_wptr <= 5'd0;
		sl_rptr <= 5'd0;
	end else if (audio_bus_ss_wr) begin
		// RESTORE savestate (priorita'): carica FIFO + puntatori + edge-detect. Stesso ordine del
		// save (fifo[i] da bit [8*i+:8]). Gioco in pausa -> push/pop disabilitati in questo ciclo.
		// sl_pulse_d/sl_rd_d ripristinati COERENTI (vincono sulle assegnazioni 240-241 di questo
		// stesso always) -> nessun edge artificiale sul soundlatch_irq al restore -> no push spurio.
		for (sl_i = 0; sl_i < 16; sl_i = sl_i + 1)
			sndlatch_fifo[sl_i] <= ab_fifo_flat_load[8*sl_i +: 8];
		sl_wptr    <= ab_sl_wptr_load;
		sl_rptr    <= ab_sl_rptr_load;
		sl_pulse_d <= ab_sl_pulse_d_load;
		// sl_rd_d: NON dal save ma dal livello VIVO. Il valore salvato appartiene alla macchina
		// salvata, ma sl_rd_lvl qui riflette gli strobe della sessione corrente (gia' riallineati
		// allo stato restaurato dal chunk 20, che precede questo): caricare il valore salvato
		// creerebbe un falso falling-edge = pop spurio (comando audio perso). d==lvl -> nessun
		// edge per costruzione; gli edge successivi sono quelli reali della CPU ripresa.
		sl_rd_d    <= sl_rd_lvl;
	end else begin
		if (sl_push) begin
			sndlatch_fifo[sl_wptr[3:0]] <= soundlatch_data;
			sl_wptr <= sl_wptr + 5'd1;
		end
		if (sl_pop) sl_rptr <= sl_rptr + 5'd1;
	end
end

wire [7:0] sndlatch_reg = sndlatch_fifo[sl_rptr[3:0]];   // testa coda letta dall'H6280
wire irq1_n = sl_empty;   // IRQ1 asserito (=0) finche' ci sono comandi in coda

// =====================================================================
// YM2151 (jt51) — addr 0x110000, controllato dal H6280
// =====================================================================
// jt51_mmr.v line 162: `if(write) reg_sel <= din` è in @(posedge clk) SENZA
// gating cen_p1. Quindi wr_n=0 per 1 ck è sufficiente. Wiring diretto livello.
// FIX pitch FM: la write YM deve essere UN SOLO impulso clk con addr/dato STABILI,
// non un livello largo. La HuC6280 tiene wr_n basso ~12 ck e jt51_mmr campiona ogni
// posedge SENZA edge-detect: sul passaggio a0 0->1 (addr->dato) un campione transitorio
// corrompe reg_kc/reg_kf di un canale -> stonato fino a reload. Qualifico con
// cpu_ce_pulse (= bus valido, 1 ck, addr/dout garantiti stabili) -> 1 sola write pulita.
wire        ym_cs_n  = ~is_ym;
wire        ym_wr_n  = ~(is_ym & ~cpu_wr_n & cpu_ce_pulse);  // impulso 1 ck su bus valido
wire        ym_a0    = cpu_addr[0];
wire [7:0]  ym_din   = cpu_dout;
wire [7:0]  ym_dout_raw;
wire        ym_irq_n;

// FIX pitch FM: il busy del jt51 e' di fatto morto (settato solo su cen=1, ma la write
// dura 1 clk -> coincide ~2%). Il driver H6280 legge busy=0 e scrive note ravvicinate:
// la 2a write azzera l'update KC/KF pendente della 1a (jt51_mmr up_* clear) -> un canale
// resta stonato fino a reload. Il chip reale ha busy ~80us che frena la CPU tra le write.
// Ripristino il back-pressure: timer locale armato su ogni write YM data (a0=1), messo
// in OR sul bit7 (busy) del dout letto dall'H6280 -> il driver in polling aspetta.
localparam [12:0] YM_BUSY_TICKS = 13'd7680;  // ~80us @ 96MHz (80e-6*96e6)
reg [12:0] ym_busy_cnt;
wire ym_data_wr = is_ym & cpu_addr[0] & ~cpu_wr_n & cpu_ce_pulse;  // write al data reg (a0=1)
always @(posedge clk) begin
	if (reset)               ym_busy_cnt <= 13'd0;
	else if (audio_bus_ss_wr) ym_busy_cnt <= ab_ym_busy_cnt_load;   // restore (priorita')
	else if (ym_data_wr)     ym_busy_cnt <= YM_BUSY_TICKS;          // arma busy su write data
	// decremento gated da ~pause: il busy modella tempo-CHIP (jt51 congelato in pausa) -> se
	// scala a 96MHz in pausa scade in anticipo (write FM ravvicinata al resume) e al save
	// viene catturato gia' decaduto. A pause=0 identico al baseline.
	else if (ym_busy_cnt != 13'd0 && !pause) ym_busy_cnt <= ym_busy_cnt - 13'd1;
end
wire ym_busy_local = (ym_busy_cnt != 13'd0);
// dout letto dall'H6280: bit7 = busy reale jt51 OR busy locale (back-pressure).
wire [7:0]  ym_dout = {ym_dout_raw[7] | ym_busy_local, ym_dout_raw[6:0]};
wire signed [15:0] ym_left, ym_right;

jt51 u_ym (
	.rst    (reset),
	.clk    (clk),
	.cen    (ce_ym),
	.cen_p1 (ce_ym_p1),
	.cs_n   (ym_cs_n),
	.wr_n   (ym_wr_n),
	.a0     (ym_a0),
	.din    (ym_din),
	.dout   (ym_dout_raw),
	.ct1    (),
	.ct2    (),
	.irq_n  (ym_irq_n),
	.sample (),
	.left   (),
	.right  (),
	.xleft  (ym_left),   // Pattern Asuka: xleft/xright (full-res continuous)
	.xright (ym_right),  // invece di left/right (low-res latched a sample strobe)
	.auto_ss_in (ym_ss_in),
	.auto_ss_out(ym_ss_out),
	.auto_ss_wr (ym_ss_wr)
);

// =====================================================================
// Bank switch OKI: MAME port_write_handler riceve {CT2, CT1} (= bit 7:6 del
// dato scritto al YM2151 register 0x1B). MAME boogwing.cpp:694-695:
//   oki[1].bank = (data & 2) >> 1 = CT2 bit
//   oki[0].bank = data & 1 = CT1 bit
// Quindi devo prendere data[7:6] = {CT2,CT1} e mapparli ai bank.
// =====================================================================
reg [7:0] ym_last_reg;
always @(posedge clk) begin
	if (audio_bus_ss_wr)                                     // restore (priorita')
		ym_last_reg <= ab_ym_last_reg_load;
	else if (is_ym && ~cpu_addr[0] && ~cpu_wr_n && cpu_ce_pulse)  // 1 ck, bus stabile
		ym_last_reg <= cpu_dout;
end
reg [1:0] oki_bank_bits;        // {CT2, CT1}
always @(posedge clk) begin
	if (reset) oki_bank_bits <= 2'd0;
	else if (audio_bus_ss_wr) oki_bank_bits <= ab_oki_bank_load;   // restore (priorita')
	else if (is_ym && cpu_addr[0] && ~cpu_wr_n && cpu_ce_pulse && ym_last_reg == 8'h1B)
		oki_bank_bits <= cpu_dout[7:6];   // {CT2, CT1}
end
wire oki0_bank = oki_bank_bits[0];   // CT1 → OKI #0 bank
wire oki1_bank = oki_bank_bits[1];   // CT2 → OKI #1 bank

// =====================================================================
// OKI #0 (jt6295) — 1.0 MHz, PIN7_HIGH (ss=1), DDR3 ROM 512 KB
// =====================================================================
wire        oki0_wrn = ~(is_ok0 & ~cpu_wr_n);
wire [7:0]  oki0_dout;
wire signed [13:0] oki0_sound;
wire [17:0] oki0_rom_addr;
wire        oki0_rom_ok_w;
// cen=ce_oki0 raw (no gating con rom_ok): jt6295_ctrl gestisce internamente
// il wait su rom_ok. Gatare il pulse di 1 ck con rom_ok perde sample (= silenzio).
jt6295 #(.INTERPOL(1)) u_oki0 (
	.rst        (reset),
	.clk        (clk),
	.cen        (ce_oki0),
	.ss         (1'b1),
	.wrn        (oki0_wrn),
	.din        (cpu_dout),
	.dout       (oki0_dout),
	.rom_addr   (oki0_rom_addr),
	.rom_data   (oki0_rom_data),
	.rom_ok     (oki0_rom_ok_w),
	.sound      (oki0_sound),
	.sample     (),
	.auto_ss_in (oki0_ss_in),
	.auto_ss_out(oki0_ss_out),
	.auto_ss_wr (oki0_ss_wr)
);

// =====================================================================
// OKI #1 (jt6295) — 2.0 MHz, PIN7_HIGH (ss=1), DDR3 ROM 512 KB
// =====================================================================
wire        oki1_wrn = ~(is_ok1 & ~cpu_wr_n);
wire [7:0]  oki1_dout;
wire signed [13:0] oki1_sound;
wire [17:0] oki1_rom_addr;
wire        oki1_rom_ok_w;

jt6295 #(.INTERPOL(1)) u_oki1 (
	.rst        (reset),
	.clk        (clk),
	.cen        (ce_oki1),
	.ss         (1'b1),
	.wrn        (oki1_wrn),
	.din        (cpu_dout),
	.dout       (oki1_dout),
	.rom_addr   (oki1_rom_addr),
	.rom_data   (oki1_rom_data),
	.rom_ok     (oki1_rom_ok_w),
	.sound      (oki1_sound),
	.sample     (),
	.auto_ss_in (oki1_ss_in),
	.auto_ss_out(oki1_ss_out),
	.auto_ss_wr (oki1_ss_wr)
);

// =====================================================================
// DDR3 bridge OKI — rom_ok stabile + dato mai perso.
// jt6295 cambia rom_addr ogni ~3 ck (cen32). DDR3 cache hit = 1 ck, miss = 20 ck.
// Mantengo rom_ok=1 fino al prossimo cambio addr. Latch dato sull'ack anche se
// l'addr nel frattempo è già cambiato (= salviamo il byte richiesto un attimo
// prima del prossimo toggle).
// MAME oki bank: 0x40000 (256 KB) finestra dentro 512 KB ROM.
// =====================================================================
// =====================================================================
// Bridge OKI — port DDR3 a 32-bit con cache 8-byte + prefetch linea+1 dentro
// ddram_4port. Bridge mio:
//  - emette addr byte; ddram_4port aggrega 4-byte (cache_addr[27:3] match in
//    una linea da 8 byte = 2 parole 32-bit). Hit cache = ack 1 ck.
//  - latch della parola 32-bit appena ack arriva, in `oki0_word`. Latch del
//    byte_sel (= addr[1:0]) salvato pure → estrai sempre il byte giusto.
//  - rom_ok mantenuto a 1 finché il prossimo addr richiesto è dentro la stessa
//    parola 32-bit già latched (= addr[17:2] uguale) → 0 round-trip → byte
//    estratto direttamente dalla parola. Quando esce parola → 1 round-trip
//    (hit cache 1 ck se dentro la linea 8-byte, miss altrimenti).
// MAME oki bank: 0x40000 (256 KB) finestra dentro 512 KB ROM.
// =====================================================================
// BUFFER PREFETCH (libera la stretta DDR sull'audio senza aggiungere carico):
// oltre alla parola CORRENTE (oki0_word), tengo la parola SUCCESSIVA gia' precaricata
// (oki0_word_n). Quando jt6295 avanza alla parola dopo, e' GIA' pronta -> rom_ok=1
// senza aspettare la DDR (che potrebbe essere occupata da tile/sprite). Il prefetch
// della "next" parte SOLO quando current+next sono valide e c'e' margine: 1 richiesta
// per volta, lo STESSO numero di accessi DDR di prima ma ANTICIPATI -> NON ruba banda
// a sprite/tile, disaccoppia solo la LATENZA.
reg [17:0] oki0_addr_pending;    // addr richiesto al DDR (fetch in corso)
reg [15:0] oki0_word_addr;       // addr[17:2] della parola CORRENTE (16'hFFFF=invalid)
reg [15:0] oki0_word_n_addr;     // addr[17:2] della parola NEXT (prefetch)
reg [31:0] oki0_word;            // parola 32-bit corrente
reg [31:0] oki0_word_n;          // parola 32-bit next (prefetch)
reg        oki0_req_toggle;
reg        oki0_fetch_busy;
reg        oki0_fetch_is_next;   // 1 = il fetch in corso e' per la NEXT, 0 = per la current
reg        oki0_rom_ok;
wire       oki0_ddr_ack_match = (oki0_ddr_ack == oki0_req_toggle);
wire [15:0] oki0_cur_widx  = oki0_rom_addr[17:2];
wire [15:0] oki0_next_widx = oki0_rom_addr[17:2] + 16'd1;
wire       oki0_word_hit   = (oki0_word_addr   == oki0_cur_widx);
wire       oki0_word_n_hit = (oki0_word_n_addr == oki0_cur_widx);  // jt6295 e' avanzato a next

always @(posedge clk) begin
	if (reset) begin
		oki0_addr_pending <= 18'h00000;
		oki0_word_addr    <= 16'hFFFF;        // invalid
		oki0_word_n_addr  <= 16'hFFFF;
		oki0_word         <= 32'd0;
		oki0_word_n       <= 32'd0;
		oki0_req_toggle   <= 1'b0;
		oki0_fetch_busy   <= 1'b0;
		oki0_fetch_is_next<= 1'b0;
		oki0_rom_ok       <= 1'b0;
	end else begin
		// 1) Ack del fetch: latch nella current o nella next a seconda del tipo.
		//    In pausa/SS la req in volo si CHIUDE comunque (fetch_busy scende -> quiescenza,
		//    no deadlock) ma il DATO viene scartato (tag non scritti): apparterrebbe al bank
		//    pre-restore. Al resume: miss pulito -> refetch col bank definitivo.
		if (oki0_fetch_busy && oki0_ddr_ack_match) begin
			if (!pause) begin
				if (oki0_fetch_is_next) begin
					oki0_word_n      <= oki0_ddr_data;
					oki0_word_n_addr <= oki0_addr_pending[17:2];
				end else begin
					oki0_word        <= oki0_ddr_data;
					oki0_word_addr   <= oki0_addr_pending[17:2];
				end
			end
			oki0_fetch_busy <= 1'b0;
		end

		// 2) jt6295 e' avanzato alla parola NEXT (gia' precaricata): promuovi next->current
		//    (shift) senza round-trip DDR. Avviene quando current non e' piu' hit ma next si'.
		// SS: promozione e scheduler (sotto) gated con !pause (paused_safe): in pausa/SS il
		// bridge NON lancia nuove req ne' rimescola lo stato (il restore jt6295 cambia rom_addr
		// sotto ss_hold: una req lanciata li' resterebbe PENDENTE per tutta la finestra SS,
		// ddram_ss_idle=0 — verificato in SIM, tb_oki_ss_bridge). Il ramo ack (1) resta SEMPRE
		// vivo: la req in volo si chiude e ss_idle puo' salire. A pause=0 gating inerte.
		if (!pause && !oki0_fetch_busy && !oki0_word_hit && oki0_word_n_hit) begin
			oki0_word      <= oki0_word_n;
			oki0_word_addr <= oki0_word_n_addr;
			oki0_word_n_addr <= 16'hFFFF;   // next ora va riprefetchata
		end

		// 3) rom_ok: la current e' pronta (hit) oppure la next lo e' (verra' promossa)
		oki0_rom_ok <= (oki0_word_hit || oki0_word_n_hit) && !oki0_fetch_busy;

		// 4) Scheduler fetch (1 richiesta per volta, priorita' alla CURRENT):
		if (!pause && !oki0_fetch_busy) begin
			if (!oki0_word_hit && !oki0_word_n_hit) begin
				// miss totale: fetch la current SUBITO
				oki0_addr_pending  <= oki0_rom_addr;
				oki0_fetch_is_next <= 1'b0;
				oki0_req_toggle    <= ~oki0_req_toggle;
				oki0_fetch_busy    <= 1'b1;
			end else if (oki0_word_hit && (oki0_word_n_addr != oki0_next_widx)) begin
				// current pronta ma next mancante: PREFETCH la next (anticipo, 1 richiesta)
				oki0_addr_pending  <= {oki0_next_widx[15:0], 2'b00};
				oki0_fetch_is_next <= 1'b1;
				oki0_req_toggle    <= ~oki0_req_toggle;
				oki0_fetch_busy    <= 1'b1;
			end
		end

		// Restore: invalida i tag della cache al load del CHIP (chunk OKI0, che PRECEDE il
		// chunk AUDIO_BUS col bank): il tag e' solo addr[17:2] SENZA il bank, e la FSM ctrl
		// del jt6295 gira a clk pieno anche in pausa — con tag stantii vedrebbe rom_ok=1 e
		// consumerebbe rom_data del bank/della sessione vecchia subito dopo il proprio load.
		// Tag invalidi -> rom_ok=0 -> FSM ferma fino al resume. Pulse solo al restore.
		if (oki0_ss_wr) begin
			oki0_word_addr   <= 16'hFFFF;
			oki0_word_n_addr <= 16'hFFFF;
			oki0_rom_ok      <= 1'b0;   // il registro rom_ok valuterebbe i tag PRE-invalidazione
		end
	end
end
// Byte extract: dalla current se hit, altrimenti dalla next (appena prima della promozione)
wire [31:0] oki0_word_sel = oki0_word_hit ? oki0_word : oki0_word_n;
wire [7:0] oki0_rom_data = oki0_word_sel[{oki0_rom_addr[1:0], 3'b000} +:8];
assign oki0_ddr_addr = 28'h5500000 + {9'd0, oki0_bank, oki0_addr_pending};
assign oki0_ddr_req  = oki0_req_toggle;
assign oki0_rom_ok_w = oki0_rom_ok;

// BUFFER PREFETCH OKI1 (identico a OKI0: current + next precaricata, disaccoppia latenza
// DDR senza aggiungere carico -> audio robusto, sprite/tile intatti).
reg [17:0] oki1_addr_pending;
reg [15:0] oki1_word_addr;
reg [15:0] oki1_word_n_addr;
reg [31:0] oki1_word;
reg [31:0] oki1_word_n;
reg        oki1_req_toggle;
reg        oki1_fetch_busy;
reg        oki1_fetch_is_next;
reg        oki1_rom_ok;
wire       oki1_ddr_ack_match = (oki1_ddr_ack == oki1_req_toggle);
wire [15:0] oki1_cur_widx  = oki1_rom_addr[17:2];
wire [15:0] oki1_next_widx = oki1_rom_addr[17:2] + 16'd1;
wire       oki1_word_hit   = (oki1_word_addr   == oki1_cur_widx);
wire       oki1_word_n_hit = (oki1_word_n_addr == oki1_cur_widx);

always @(posedge clk) begin
	if (reset) begin
		oki1_addr_pending <= 18'h00000;
		oki1_word_addr    <= 16'hFFFF;
		oki1_word_n_addr  <= 16'hFFFF;
		oki1_word         <= 32'd0;
		oki1_word_n       <= 32'd0;
		oki1_req_toggle   <= 1'b0;
		oki1_fetch_busy   <= 1'b0;
		oki1_fetch_is_next<= 1'b0;
		oki1_rom_ok       <= 1'b0;
	end else begin
		// Ack: chiude sempre, dato scartato in pausa (come OKI0)
		if (oki1_fetch_busy && oki1_ddr_ack_match) begin
			if (!pause) begin
				if (oki1_fetch_is_next) begin
					oki1_word_n      <= oki1_ddr_data;
					oki1_word_n_addr <= oki1_addr_pending[17:2];
				end else begin
					oki1_word        <= oki1_ddr_data;
					oki1_word_addr   <= oki1_addr_pending[17:2];
				end
			end
			oki1_fetch_busy <= 1'b0;
		end

		// SS: promozione+scheduler gated con !pause, ramo ack sempre vivo (come OKI0)
		if (!pause && !oki1_fetch_busy && !oki1_word_hit && oki1_word_n_hit) begin
			oki1_word        <= oki1_word_n;
			oki1_word_addr   <= oki1_word_n_addr;
			oki1_word_n_addr <= 16'hFFFF;
		end

		oki1_rom_ok <= (oki1_word_hit || oki1_word_n_hit) && !oki1_fetch_busy;

		if (!pause && !oki1_fetch_busy) begin
			if (!oki1_word_hit && !oki1_word_n_hit) begin
				oki1_addr_pending  <= oki1_rom_addr;
				oki1_fetch_is_next <= 1'b0;
				oki1_req_toggle    <= ~oki1_req_toggle;
				oki1_fetch_busy    <= 1'b1;
			end else if (oki1_word_hit && (oki1_word_n_addr != oki1_next_widx)) begin
				oki1_addr_pending  <= {oki1_next_widx[15:0], 2'b00};
				oki1_fetch_is_next <= 1'b1;
				oki1_req_toggle    <= ~oki1_req_toggle;
				oki1_fetch_busy    <= 1'b1;
			end
		end

		// Restore: invalida i tag cache al load del chip (come OKI0)
		if (oki1_ss_wr) begin
			oki1_word_addr   <= 16'hFFFF;
			oki1_word_n_addr <= 16'hFFFF;
			oki1_rom_ok      <= 1'b0;   // come OKI0
		end
	end
end
wire [31:0] oki1_word_sel = oki1_word_hit ? oki1_word : oki1_word_n;
wire [7:0] oki1_rom_data = oki1_word_sel[{oki1_rom_addr[1:0], 3'b000} +:8];
assign oki1_ddr_addr = 28'h5580000 + {9'd0, oki1_bank, oki1_addr_pending};
assign oki1_ddr_req  = oki1_req_toggle;
assign oki1_rom_ok_w = oki1_rom_ok;

// CPU din mux — priority if-else (più sicuro di case(1'b1))
always @(*) begin
	if      (is_rom) cpu_din = rom_rd_r;
	else if (is_ram) cpu_din = ram_rd_r;
	else if (is_snd) cpu_din = sndlatch_reg;
	else if (is_ym ) cpu_din = ym_dout;
	else if (is_ok0) cpu_din = oki0_dout;
	else if (is_ok1) cpu_din = oki1_dout;
	else             cpu_din = 8'hFF;
end

// =====================================================================
// Savestate stato interno HUC6280 (auto_ss) — pattern F2 (auto_save_adaptor su Z80).
// A SS idle huc_ss_wr=0 -> il chip e' trasparente. Durante restore huc_ss_wr pulsa (CPU ferma
// in paused_safe) -> il chip ricarica i suoi registri da huc_ss_in.
// =====================================================================
localparam integer HUC_SS_BITS = 298;   // 252 core+AG+CS+SavedC+MI(42) + stato top(38) + CPU_CLK_CNT(5) + IO_CLK_CNT(3)
wire [HUC_SS_BITS-1:0] huc_ss_out, huc_ss_in;
wire                   huc_ss_wr;
auto_save_adaptor #(.N_BITS(HUC_SS_BITS), .SS_IDX(SS_HUC_CPU_IDX)) u_huc_ss_adaptor (
	.clk     (clk),
	.ssbus   (ss_huc_cpu),
	.bits_in (huc_ss_out),
	.bits_out(huc_ss_in),
	.bits_wr (huc_ss_wr)
);

// OKI #0/#1 (jt6295) stato interno — auto_ss 359 bit ciascuno.
localparam integer OKI_SS_BITS = 359;
wire [OKI_SS_BITS-1:0] oki0_ss_out, oki0_ss_in, oki1_ss_out, oki1_ss_in;
wire                   oki0_ss_wr, oki1_ss_wr;
auto_save_adaptor #(.N_BITS(OKI_SS_BITS), .SS_IDX(SS_OKI0_IDX)) u_oki0_ss_adaptor (
	.clk(clk), .ssbus(ss_oki0),
	.bits_in(oki0_ss_out), .bits_out(oki0_ss_in), .bits_wr(oki0_ss_wr)
);
auto_save_adaptor #(.N_BITS(OKI_SS_BITS), .SS_IDX(SS_OKI1_IDX)) u_oki1_ss_adaptor (
	.clk(clk), .ssbus(ss_oki1),
	.bits_in(oki1_ss_out), .bits_out(oki1_ss_in), .bits_wr(oki1_ss_wr)
);

// YM2151 (jt51) stato interno — auto_ss 2774 bit.
localparam integer YM_SS_BITS = 2820;   // 2780 + write-staging(40) = up_*/op_din/reg_sel in volo
wire [YM_SS_BITS-1:0] ym_ss_out, ym_ss_in;
wire                  ym_ss_wr;
auto_save_adaptor #(.N_BITS(YM_SS_BITS), .SS_IDX(SS_YM_IDX)) u_ym_ss_adaptor (
	.clk(clk), .ssbus(ss_ym),
	.bits_in(ym_ss_out), .bits_out(ym_ss_in), .bits_wr(ym_ss_wr)
);

// Audio bus wrapper state — 161 bit di stato PERSISTENTE non interno ai chip:
//   FIFO sndlatch 16x8 (128) + sl_wptr[4:0]+sl_rptr[4:0] (10) + ym_busy_cnt[12:0] (13)
//   + ym_last_reg[7:0] (8) + oki_bank_bits[1:0] (2). Senza, al restore i comandi audio in
//   coda spariscono e bank/busy YM si perdono -> audio muto/glitch (causa validata).
// 186 bit: 163 base (FIFO+ctrl+edge) + 23 fase contatori ce ([185:163]).
//   [185:180] ce_oki1_cnt(6)  [179:173] ce_oki0_cnt(7)  [172] ce_ym_toggle  [171:167] ce_ym_cnt(5)
//   [166:163] ce_audio_cnt(4)  [162] sl_rd_d  [161] sl_pulse_d  [160:0] base (vedi sotto)
localparam integer AUDIO_BUS_SS_BITS = 186;
wire [AUDIO_BUS_SS_BITS-1:0] audio_bus_ss_out, audio_bus_ss_in;
wire                         audio_bus_ss_wr;
auto_save_adaptor #(.N_BITS(AUDIO_BUS_SS_BITS), .SS_IDX(SS_AUDIO_BUS_IDX)) u_audio_bus_ss_adaptor (
	.clk(clk), .ssbus(ss_audio_bus),
	.bits_in(audio_bus_ss_out), .bits_out(audio_bus_ss_in), .bits_wr(audio_bus_ss_wr)
);
// SAVE: FIFO (fifo[i] in [8*i+7:8*i]) + registri + fase contatori ce (dai _in, da Template).
wire [127:0] fifo_flat;
genvar gi;
generate for (gi = 0; gi < 16; gi = gi + 1) begin : g_fifo_flat
	assign fifo_flat[8*gi +: 8] = sndlatch_fifo[gi];
end endgenerate
assign audio_bus_ss_out = {ce_oki1_cnt_in, ce_oki0_cnt_in, ce_ym_toggle_in, ce_ym_cnt_in, ce_audio_cnt_in,
                           sl_rd_d, sl_pulse_d, oki_bank_bits, ym_last_reg, ym_busy_cnt, sl_rptr, sl_wptr, fifo_flat};
// RESTORE: scompatta con lo STESSO ordine (endianness identica al save).
wire [1:0]   ab_oki_bank_load    = audio_bus_ss_in[160:159];
wire [7:0]   ab_ym_last_reg_load = audio_bus_ss_in[158:151];
wire [12:0]  ab_ym_busy_cnt_load = audio_bus_ss_in[150:138];
wire [4:0]   ab_sl_rptr_load     = audio_bus_ss_in[137:133];
wire [4:0]   ab_sl_wptr_load     = audio_bus_ss_in[132:128];
wire [127:0] ab_fifo_flat_load   = audio_bus_ss_in[127:0];
wire         ab_sl_pulse_d_load  = audio_bus_ss_in[161];
wire         ab_sl_rd_d_load     = audio_bus_ss_in[162];
// RESTORE fase contatori ce -> output verso Template (caricati quando ce_cnt_load_wr pulsa).
assign ce_audio_cnt_load  = audio_bus_ss_in[166:163];
assign ce_ym_cnt_load     = audio_bus_ss_in[171:167];
assign ce_ym_toggle_load  = audio_bus_ss_in[172];
assign ce_oki0_cnt_load   = audio_bus_ss_in[179:173];
assign ce_oki1_cnt_load   = audio_bus_ss_in[185:180];
assign ce_cnt_load_wr     = audio_bus_ss_wr;   // pulse restore -> Template ricarica i contatori

// =====================================================================
// H6280 instance
// =====================================================================
// L'enable CE è generato dal modulo internamente; usiamo ce_audio come
// gate per simulare clock divisorio.
HUC6280 u_cpu (
	.CLK    (clk),
	.CE_IN  (~pause),       // cen come F2: a gioco normale (pause=0) CE_IN=1 -> divisore gira a clk
	                        // pieno (96/24=4MHz, identico originale). In pausa/SS (pause=paused_safe=1)
	                        // CE_IN=0 -> divisore CONGELATO (CPU_CLK_CNT fermo) -> la HuC non deriva di
	                        // fase: al restore riparte IN FASE. Fixa le note lunghe (key-off off-phase).
	.RST_N  (~reset),
	.WAIT_N (wait_n),       // Stall durante ROM read fino a dato pronto (pattern ActFancer)
	.RDY    (1'b1),         // RDY non piu' usato per la pausa (la fa CE_IN). Neutro su BoogieWings:
	                        // la HuC non accede a VDC/VCE (0xFF0000+), il wait-state video non scatta mai.
	.DI     (cpu_din),
	.NMI_N  (1'b1),
	.IRQ1_N (irq1_n),       // soundlatch IRQ (MAME IRQ0 → H6280 IRQ1)
	.IRQ2_N (ym_irq_n),     // YM2151 timer IRQ → H6280 IRQ2 (MAME IRQ2)
	.K      (8'h00),
	.VDCNUM (1'b0),
	.SX     (),
	.A      (cpu_addr),
	.DO     (cpu_dout),
	.WR_N   (cpu_wr_n),
	.RD_N   (cpu_rd_n),
	.CE     (cpu_ce_pulse),
	.CEK_N  (),
	.CE7_N  (),
	.CER_N  (),
	.PRE_RD (),
	.PRE_WR (),
	.HSM    (),
	.O      (),
	.AUD_LDATA (cpu_aud_l),
	.AUD_RDATA (cpu_aud_r),
	// Savestate auto_ss (246 bit). Collegato all'auto_save_adaptor sotto.
	.SS_DO     (huc_ss_out),
	.SS_DI     (huc_ss_in),
	.SS_WR     (huc_ss_wr)
);

// =====================================================================
// Audio chain: OKI → jtframe_pole (RC simulated, ~770 Hz cutoff come jtcps1) →
// jtframe_mixer (4.4 fixed gain, clip integrato).
// Pattern jtcps1_sound.v: pcmgain=0x18 (=1.5), fmgain=0x08 (=0.5).
// MAME pesi BoogieWings: ym=0.32, oki0=0.56, oki1=0.12. In 4.4 fixed:
//   ym = 0.32 × 16 = 5.12 → 0x05
//   oki0 = 0.56 × 16 = 8.96 → 0x09
//   oki1 = 0.12 × 16 = 1.92 → 0x02
// MA jtcps1 amplifica più di MAME float-equivalent perché jt6295 14-bit ≠ MAME
// peak. Scelta: scalo tutto ×2 per matching forza assoluta CPS1-like.
//   ym = 0x0A (=0.625)
//   oki0 = 0x12 (=1.125)
//   oki1 = 0x04 (=0.25)
// jtframe_mixer ha clip a 16-bit.
// =====================================================================

// Sample pulse OKI: cen_sr di jt6295 (= sample rate, ~7.6 kHz oki0, ~15 kHz oki1).
// Però jt6295 non espone cen_sr esterno. Uso ce_oki0/ce_oki1 come proxy (= cen del
// chip, 1 MHz / 2 MHz). Pole vede sample @ quel rate, fitlro pole a 770 Hz è
// =====================================================================
// Mixer pattern ActFancer (collaudato): mul Q4.4 + sum + saturazione.
// Niente sndchain/dcrm/pole (= jt non li usa in ActFancer e suona ottimo).
// Pesi gain_fm/oki0/oki1 da OSD (8-bit Q4.4). Sample ChannelDataExt:
//   OPM (jt51) ym_left/ym_right = 16-bit signed
//   OKI (jt6295) oki*_sound = 14-bit signed → sign-extend a 16-bit
// mul = signed × unsigned 8-bit → 24-bit signed
// accumula a 18-bit, shift >>> 4 (Q4.4 dec part), satura a 16-bit.
// =====================================================================
wire signed [15:0] oki0_ext = { {2{oki0_sound[13]}}, oki0_sound };
wire signed [15:0] oki1_ext = { {2{oki1_sound[13]}}, oki1_sound };

wire signed [24:0] ym_l_mul   = $signed(ym_left)  * $signed({1'b0, gain_fm});
wire signed [24:0] ym_r_mul   = $signed(ym_right) * $signed({1'b0, gain_fm});
wire signed [24:0] oki0_mul   = $signed(oki0_ext) * $signed({1'b0, gain_oki0});
wire signed [24:0] oki1_mul   = $signed(oki1_ext) * $signed({1'b0, gain_oki1});

// Pipeline 2 stadi: il path mul→shift→sum→reg non chiude a 96 MHz in 1 ck
// (worst setup -3.67ns, era il path critico unico del core → lotteria PnR
// = pixel spuri collaterali). Stadio 1 registra i prodotti shiftati (assorbiti
// nel registro output del DSP), stadio 2 somma. +1 ck latenza audio = nullo.
reg signed [20:0] ym_l_s, ym_r_s, oki0_s, oki1_s;
always @(posedge clk) begin
	ym_l_s <= ym_l_mul >>> 4;
	ym_r_s <= ym_r_mul >>> 4;
	oki0_s <= oki0_mul >>> 4;
	oki1_s <= oki1_mul >>> 4;
end

reg signed [19:0] mix_l, mix_r;
always @(posedge clk) begin
	mix_l <= ym_l_s + oki0_s + oki1_s;
	mix_r <= ym_r_s + oki0_s + oki1_s;
end

function signed [15:0] sat16(input signed [19:0] v);
	if      (v >  $signed(20'sd32767))  sat16 = 16'sd32767;
	else if (v < -$signed(20'sd32768))  sat16 = -16'sd32768;
	else                                sat16 = v[15:0];
endfunction

// Presenza (OSD O[24:23]): shelving sugli alti del mix, uscita = dry + g*(dry - lp).
// lp = passa-basso a 1 polo a 192 kHz (96 MHz / 500) con alfa 1/16 -> taglio ~2 kHz.
// g = 0, 7/16, 1, 29/16 -> 0 / +3 / +6 / +9 dB sopra ~2 kHz, bassi invariati.
// Con Off (g = 0) l'uscita e' identica al mix di prima (1 ck di latenza in piu').
// Pipeline a 3 stadi (a 96 MHz in un ciclo era -1.76 ns): 1) dry registrato e
// sottrazione, 2) prodotto, 3) somma + saturazione. 4 ck di latenza: irrilevante.
reg signed [15:0] dry_l, dry_r;
always @(posedge clk) begin
	dry_l <= sat16(mix_l);
	dry_r <= sat16(mix_r);
end
reg  [8:0] pr_div = 9'd0;
wire       pr_ce  = (pr_div == 9'd499);
always @(posedge clk) if (!pause) pr_div <= pr_ce ? 9'd0 : pr_div + 9'd1;

// Correzione verso MAME (low-shelf 498 Hz +1.8 dB, peaking 5773 Hz -3.0 dB) a 192 kHz,
// ricavata da registrazioni allineate MAME/core dell'attract. Vedi mix_eq.sv.
// ce gated anche qui: in pausa pr_div si ferma e pr_ce potrebbe restare alto.
wire signed [15:0] eq_l, eq_r;
mix_eq u_mix_eq (
	.clk   (clk),
	.reset (reset),
	.ce    (pr_ce & ~pause),
	.in_l  (dry_l),
	.in_r  (dry_r),
	.out_l (eq_l),
	.out_r (eq_r)
);

reg signed [19:0] lp_l = 20'sd0, lp_r = 20'sd0;   // Q16.4
always @(posedge clk) begin
	if (reset) begin
		lp_l <= 20'sd0;
		lp_r <= 20'sd0;
	end else if (pr_ce && !pause) begin
		lp_l <= lp_l + (($signed({eq_l, 4'd0}) - lp_l) >>> 4);
		lp_r <= lp_r + (($signed({eq_r, 4'd0}) - lp_r) >>> 4);
	end
end
reg [4:0] pr_g;
always @(*) begin
	case (osd_presence)
		2'd1:    pr_g = 5'd7;    // +3 dB
		2'd2:    pr_g = 5'd16;   // +6 dB
		2'd3:    pr_g = 5'd29;   // +9 dB
		default: pr_g = 5'd0;    // Off
	endcase
end
reg  signed [16:0] hp_l, hp_r;          // stadio 1: alti = eq - passa-basso
reg  signed [15:0] dry1_l, dry1_r;
always @(posedge clk) begin
	hp_l   <= eq_l - (lp_l >>> 4);
	hp_r   <= eq_r - (lp_r >>> 4);
	dry1_l <= eq_l;
	dry1_r <= eq_r;
end
reg  signed [22:0] boost_l, boost_r;    // stadio 2: prodotto per il guadagno
reg  signed [15:0] dry2_l, dry2_r;
always @(posedge clk) begin
	boost_l <= hp_l * $signed({1'b0, pr_g});
	boost_r <= hp_r * $signed({1'b0, pr_g});
	dry2_l  <= dry1_l;
	dry2_r  <= dry1_r;
end
reg  signed [15:0] out_l, out_r;        // stadio 3: somma + saturazione
always @(posedge clk) begin
	out_l <= sat16(dry2_l + (boost_l >>> 4));
	out_r <= sat16(dry2_r + (boost_r >>> 4));
end

assign audio_l = out_l;
assign audio_r = out_r;

endmodule
