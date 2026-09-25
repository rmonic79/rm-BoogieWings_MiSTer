//
// deco56_gfx_decrypt.sv
// Data East 56 GFX decryption (per Boogie Wings tile region tiles1/2/3).
//
// Riferimento bit-exact: reference/mame/decocrpt.cpp `deco_decrypt()` con
// remap_only=0 (xor + bitswap + address remap dentro blocchi 4KB / 2048 word).
//
// Algoritmo MAME (decocrpt.cpp:603-647):
//
//   for i in 0..N_words:
//     addr_remap = (i & ~0x7FF) | address_table[i & 0x7FF]
//     pat        = swap_table[i & 0x7FF]
//     xor_idx    = xor_table[addr_remap & 0x7FF]
//     out[i]     = bitswap16(rom[addr_remap] ^ xor_masks[xor_idx],
//                            swap_patterns[pat][0..15])
//
// Architettura HW:
//
//   Servono 2 funzioni distinte:
//
//   (1) ADDRESS REMAP — combinatorio. Input: word_addr logico. Output:
//       physical word_addr da usare per indicizzare la SDRAM (post-load).
//       Usato dal bridge SDRAM PRIMA di emettere la read.
//
//   (2) DATA DECRYPT — combinatorio. Input: raw_data 16-bit (dal physical
//       addr) + word_addr logico. Output: decrypted data 16-bit. Usato
//       DOPO la lettura SDRAM, prima di consegnare al pixel decoder.
//
//   Le tabelle `address_table`, `swap_table`, `xor_table` (2048 entry ciascuna)
//   vivono in M10K e sono inizializzate da $readmemh (i 3 file .hex generati
//   da sim/scripts/extract_deco56_tables.py).
//
//   xor_masks[16] e swap_patterns[8][16] sono piccoli e cablati nel codice.
//
// `remap_only`: per tiles2_hi (mbd-02) MAME chiama `deco56_remap_gfx` che
//   applica SOLO l'address remap (no XOR, no bitswap). Esposto come parameter
//   o flag I/O per chi istanzia.
//

// ============================================================================
// Modulo (1): address remapper combinatorio (no BRAM lookup esterno richiesto
// dal chiamante: la lookup è interna). 1 cycle latency.
// ============================================================================

module deco56_addr_remap
#(
    parameter ADDR_BITS = 24    // larghezza word_addr (max ROM region size)
)
(
    input  wire                  clk,
    input  wire [ADDR_BITS-1:0]  word_addr_in,    // word index logico
    output reg  [ADDR_BITS-1:0]  word_addr_out    // word index fisico (registered)
);

    // Address table: 2048 entry × 11-bit (valori 0..0x7FF) — Quartus userà 1 M10K
    (* ramstyle = "M10K" *) reg [10:0] address_table [0:2047];
    initial $readmemh("deco56_address_table.hex", address_table);

    wire [10:0] in_blk_idx  = word_addr_in[10:0];
    reg  [10:0] remap_in_blk;
    always @(posedge clk) remap_in_blk <= address_table[in_blk_idx];

    // Registriamo anche i bit alti per allineare con la BRAM lookup
    reg [ADDR_BITS-1:11] hi_bits_r;
    always @(posedge clk) hi_bits_r <= word_addr_in[ADDR_BITS-1:11];

    always @(*) word_addr_out = {hi_bits_r, remap_in_blk};

endmodule


// ============================================================================
// Modulo (2): data decrypter. Input raw 16-bit + word_addr logico, output 16-bit.
// 1 cycle latency (per BRAM lookup di xor_table[addr_remap&0x7FF] e
// swap_table[word_addr_in&0x7FF]).
//
// IMPORTANTE: xor_idx si calcola su `addr_remap & 0x7FF`, NON su
//             `word_addr_in & 0x7FF`. Per riprodurre questa dipendenza
//             serve sapere `addr_remap[10:0]`, che è il valore della
//             address_table dello stesso modulo (1). Per evitare di
//             leggere la tabella due volte, esponiamo qui un input
//             `remap_in_blk` proveniente dal modulo (1).
// ============================================================================

module deco56_data_decrypt
(
    input  wire        clk,
    input  wire        remap_only,           // 1 = no XOR/bitswap, return raw
    input  wire [10:0] word_addr_in_blk,     // word_addr_in[10:0]
    input  wire [10:0] remap_in_blk,         // address_table[word_addr_in[10:0]]
    input  wire [15:0] raw_data,
    output wire [15:0] decrypted_data
);

    // BRAM lookups (1 ck latency)
    (* ramstyle = "M10K" *) reg [3:0] xor_table  [0:2047];    // valori 0..15
    (* ramstyle = "M10K" *) reg [2:0] swap_table [0:2047];    // valori 0..7
    initial $readmemh("deco56_xor_table.hex",  xor_table);
    initial $readmemh("deco56_swap_table.hex", swap_table);

    reg [3:0] xor_idx_q;
    reg [2:0] pat_q;
    reg       remap_only_q;
    reg [15:0] raw_data_q;
    always @(posedge clk) begin
        xor_idx_q    <= xor_table [remap_in_blk];
        pat_q        <= swap_table[word_addr_in_blk];
        remap_only_q <= remap_only;
        raw_data_q   <= raw_data;
    end

    // xor_masks[16] (decocrpt.cpp:49)
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

    // swap_patterns[8][16] (decocrpt.cpp:55) applicato come MAME bitswap<16>:
    //   out[15] = in[ pat[0]  ], out[14] = in[ pat[1] ], ...
    //   out[0]  = in[ pat[15] ]
    // → out[15-k] = in[ pat[k] ]
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

    wire [15:0] xored      = raw_data_q ^ xor_mask(xor_idx_q);
    wire [15:0] decrypted  = bitswap_apply(pat_q, xored);

    assign decrypted_data = remap_only_q ? raw_data_q : decrypted;

endmodule
