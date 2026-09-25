//
// deco56_ioctl_decrypt.sv
// Wrapper trasparente sul flusso ioctl che decritta le TILE DECO56 di
// BoogieWings DURANTE IL DOWNLOAD. Modellato ESATTAMENTE su de102_ioctl_decrypt:
// COMBINATORIO PURO, remap inverso dell'indirizzo INLINE, zero buffer, zero FSM,
// zero ioctl_wait. ioctl_wr passthrough -> hps_io fa il pacing naturale (1 word,
// bridge alza prog_wr, hps_io si ferma su ioctl_wait_sdram, prog_ack, riprende).
// IMPOSSIBILE deadlock. Il bridge scrive a indirizzi logici scattered 1:1.
//
// REMAP (deco56): la word FISICA all'indice p va scritta all'indice LOGICO
//   i = (p & ~0x7FF) | inv_addr[p & 0x7FF].  inv_addr e' l'inversa di address_table.
// DATA DECRYPT (deco56): dec = bitswap(swap[i_lo], raw ^ xor_mask[xor[p_lo]]).
//   xi su FISICO (p_lo), pat su LOGICO (i_lo) — come lo script de56_decrypt.
// remap_only (mbd-02, tiles2_hi): solo remap dell'indirizzo, dato invariato.
//
// Opera su WORD 16-bit. Le basi tile sono multipli di 0x1000 byte (=0x800 word)
// -> p_lo = wrel[10:0].
//

module deco56_ioctl_decrypt
(
	input  wire        clk,

	input  wire [26:0] ioctl_addr_in,
	input  wire [15:0] ioctl_dout_in,
	input  wire        ioctl_wr_in,
	input  wire [15:0] ioctl_index_in,
	input  wire        ioctl_download_in,

	output wire [26:0] ioctl_addr_out,   // logico (scattered) nei range tile
	output wire [15:0] ioctl_dout_out,   // decrittato nei range tile
	output wire        ioctl_wr_out,
	output wire [15:0] ioctl_index_out,
	output wire        ioctl_download_out,

	// TIMING 2026-09-18: esposto per il mux a PRIORITA' del download (Template.sv),
	// che sostituisce la cascata in serie de102 -> deco56.
	output wire        remap_out
);

	// ── Basi range tile (MRA byte address) ──────────────────────────────────
	localparam [26:0] T1_BASE   = 27'h110000;  // tiles1     decrypt completo
	localparam [26:0] T1_END    = 27'h130000;
	localparam [26:0] T2_BASE   = 27'h130000;  // tiles2 lo  decrypt completo (mbd-01+00)
	localparam [26:0] T2_END    = 27'h330000;
	localparam [26:0] T2HI_BASE = 27'h330000;  // tiles2 hi  remap_only (mbd-02)
	localparam [26:0] T2HI_END  = 27'h430000;
	localparam [26:0] T3_BASE   = 27'h430000;  // tiles3 #1  decrypt completo (ba0/FG0)
	localparam [26:0] T3_END    = 27'h630000;
	localparam [26:0] T3B_BASE  = 27'h630000;  // tiles3 #2  decrypt completo (ba1/FG1 dup)
	localparam [26:0] T3B_END   = 27'h830000;

	wire is_rom_dl = ioctl_download_in & (ioctl_index_in == 16'd0);

	wire in_t1   = is_rom_dl && (ioctl_addr_in >= T1_BASE)   && (ioctl_addr_in < T1_END);
	wire in_t2   = is_rom_dl && (ioctl_addr_in >= T2_BASE)   && (ioctl_addr_in < T2_END);
	wire in_t2hi = is_rom_dl && (ioctl_addr_in >= T2HI_BASE) && (ioctl_addr_in < T2HI_END);
	wire in_t3   = is_rom_dl && (ioctl_addr_in >= T3_BASE)   && (ioctl_addr_in < T3_END);
	wire in_t3b  = is_rom_dl && (ioctl_addr_in >= T3B_BASE)  && (ioctl_addr_in < T3B_END);

	wire is_remapped = in_t1 | in_t2 | in_t2hi | in_t3 | in_t3b;
	wire remap_only  = in_t2hi;

	wire [26:0] cur_base = in_t1   ? T1_BASE   :
	                       in_t2   ? T2_BASE   :
	                       in_t2hi ? T2HI_BASE :
	                       in_t3   ? T3_BASE   :
	                       in_t3b  ? T3B_BASE  : 27'd0;

	wire [25:0] wrel    = (ioctl_addr_in - cur_base) >> 1;   // word index fisico relativo
	wire [10:0] p_lo    = wrel[10:0];
	wire [14:0] blk_hi  = wrel[25:11];

	// ── Tabelle (ROM combinatorie async, solo download) ─────────────────────
	// TIMING 2026-09-18 (come Night Slashers): swap era letta come swap_table[i_lo]
	// con i_lo a sua volta uscita di inv_addr_table -> DUE ROM async da 2048 voci IN
	// SERIE nel cammino del download. swap[inv[p]] e' funzione del solo p: precomposta
	// in swap_of_p (verificata 2048/2048 sulle tabelle di questo core), le due letture
	// ora sono PARALLELE. Nessuna latenza aggiunta: l'uscita resta combinatoria.
	(* ramstyle = "logic" *) reg [10:0] inv_addr_table [0:2047];
	(* ramstyle = "logic" *) reg [3:0]  xor_table      [0:2047];
	(* ramstyle = "logic" *) reg [2:0]  swap_of_p_table[0:2047];
	initial $readmemh("deco56_inv_address_table.hex", inv_addr_table);
	initial $readmemh("deco56_xor_table.hex",         xor_table);
	initial $readmemh("deco56_swap_of_p.hex",         swap_of_p_table);

	// la word FISICA p va al LOGICO i_lo = inv_addr[p_lo]. decrypt: xi su p (fisico),
	// pat su i_lo (logico) — come lo script de56_decrypt.
	wire [10:0] i_lo = inv_addr_table[p_lo];

	// ── xor_masks[16] (decocrpt.cpp:49) ─────────────────────────────────────
	function [15:0] xor_mask(input [3:0] idx);
		case (idx)
			4'h0: xor_mask = 16'hd556; 4'h1: xor_mask = 16'h73cb;
			4'h2: xor_mask = 16'h2963; 4'h3: xor_mask = 16'h4b9a;
			4'h4: xor_mask = 16'hb3bc; 4'h5: xor_mask = 16'hbc73;
			4'h6: xor_mask = 16'hcbc9; 4'h7: xor_mask = 16'haeb5;
			4'h8: xor_mask = 16'h1e6d; 4'h9: xor_mask = 16'hd5b5;
			4'ha: xor_mask = 16'he676; 4'hb: xor_mask = 16'h5cc5;
			4'hc: xor_mask = 16'h395a; 4'hd: xor_mask = 16'hdaae;
			4'he: xor_mask = 16'h2629; 4'hf: xor_mask = 16'he59e;
		endcase
	endfunction

	// swap_patterns[8][16] (decocrpt.cpp:55), out[15-k]=in[pat[k]]
	function [15:0] bitswap_apply(input [2:0] pat_idx, input [15:0] d);
		case (pat_idx)
			3'd0: bitswap_apply = {d[15],d[ 8],d[ 9],d[12],d[10],d[13],d[11],d[14], d[ 2],d[ 7],d[ 4],d[ 3],d[ 1],d[ 5],d[ 6],d[ 0]};
			3'd1: bitswap_apply = {d[12],d[10],d[11],d[ 9],d[ 8],d[15],d[14],d[13], d[ 6],d[ 0],d[ 3],d[ 5],d[ 7],d[ 4],d[ 2],d[ 1]};
			3'd2: bitswap_apply = {d[ 8],d[12],d[11],d[ 9],d[13],d[14],d[15],d[10], d[ 4],d[ 6],d[ 5],d[ 0],d[ 3],d[ 1],d[ 7],d[ 2]};
			3'd3: bitswap_apply = {d[ 8],d[ 9],d[10],d[13],d[11],d[15],d[14],d[12], d[ 5],d[ 4],d[ 0],d[ 7],d[ 2],d[ 6],d[ 1],d[ 3]};
			3'd4: bitswap_apply = {d[12],d[13],d[14],d[15],d[ 8],d[ 9],d[10],d[11], d[ 1],d[ 5],d[ 0],d[ 3],d[ 2],d[ 7],d[ 6],d[ 4]};
			3'd5: bitswap_apply = {d[14],d[15],d[13],d[ 8],d[12],d[10],d[11],d[ 9], d[ 1],d[ 2],d[ 7],d[ 6],d[ 4],d[ 3],d[ 0],d[ 5]};
			3'd6: bitswap_apply = {d[13],d[14],d[10],d[11],d[ 9],d[ 8],d[12],d[15], d[ 3],d[ 1],d[ 7],d[ 4],d[ 5],d[ 0],d[ 2],d[ 6]};
			3'd7: bitswap_apply = {d[ 9],d[ 8],d[14],d[10],d[15],d[11],d[13],d[12], d[ 6],d[ 0],d[ 5],d[ 2],d[ 4],d[ 1],d[ 3],d[ 7]};
		endcase
	endfunction

	// BYTE-SWAP ingresso: hps_io WIDE da' le word LITTLE-endian, ma il decode
	// DECO56 (tabelle MAME) opera su word BIG-endian. Verificato sui dati reali
	// vs golden tiles1: BIG-endian = 1000/1000 match, LITTLE = 2/1000.
	// NB: il de102 (main) NON va swappato (verificato: main vuole LITTLE 1000/1000).
	wire [15:0] din_be = {ioctl_dout_in[7:0], ioctl_dout_in[15:8]};

	// dato decrittato della word fisica corrente: xi su p (fisico), pat su i_lo (logico)
	wire [15:0] dec_phys  = bitswap_apply(swap_of_p_table[p_lo], din_be ^ xor_mask(xor_table[p_lo]));
	// remap_only (p4/mbd-02): col MRA enc_T1T2 (mbd-02 map="01") il dato arriva nel
	// byte LOW, ma il p4 read FSM (sdram_bridge:594) legge il byte HIGH -> plane4=0
	// -> asfalto linea gialla (stesso problema di all'epoca). Byte-swap QUI mette
	// mbd-02 nel byte HIGH = come il decrypted (0/524288 vs ba3 dec), SENZA toccare
	// l'MRA (map="01" serve a non rompere FG). Il fix sta nel wrapper, non nell'MRA.
	wire [15:0] data_phys = remap_only ? {ioctl_dout_in[7:0], ioctl_dout_in[15:8]} : dec_phys;

	// indirizzo LOGICO: base + ((blk_hi<<11 | i_lo) << 1).  blk_hi invariato
	// (il remap e' DENTRO il blocco di 0x800 word).
	wire [26:0] addr_logical = cur_base + {{blk_hi, i_lo}, 1'b0};

	// ── Output COMBINATORIO (no registri): ioctl_wait e dati allineati 0ck ->
	// hps_io si ferma in tempo, nessuna word in volo persa. I registri (rimossi)
	// sfasavano il pacing -> word perse in SDRAM ("mancano tile" prima del decoding).
	assign ioctl_addr_out     = is_remapped ? addr_logical : ioctl_addr_in;
	assign ioctl_dout_out     = is_remapped ? data_phys    : ioctl_dout_in;
	assign ioctl_wr_out       = ioctl_wr_in;
	assign ioctl_index_out    = ioctl_index_in;
	assign ioctl_download_out = ioctl_download_in;
	assign remap_out          = is_remapped;

endmodule
