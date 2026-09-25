//
// deco146_base.sv
// Data East 146/104 protection chip — porting RTL.
//
// Riferimento C++: reference/mame/deco146.cpp (read_data, read_protport,
// write_protport, reorder).
//
// Read latency: 2 ck (registered table BRAM + registered final output).
// Per 68K: jtframe_68kdtack_cen wait1 interno + bus_busy 1 ck = 2 ck totali.
//

module deco146_base #(
    parameter [7:0]  XOR_PORT  = 8'h2c,
    parameter [7:0]  MASK_PORT = 8'h36,
    parameter [7:0]  SOUND_PORT= 8'h64,
    parameter [7:0]  BANK_SWAP_READ_ADDR = 8'h78,
    parameter [15:0] MAGIC_READ_ADDR_XOR = 16'h44a,
    parameter        MAGIC_XOR_ENABLED = 1'b0,
    parameter [1:0]  ADDR_SCRAMBLE = 2'd0,   // 0=none, 1=reversed, 2=interleave
    parameter        TABLE_OFFSET_HEX  = "deco146_offset.hex",
    parameter        TABLE_MAPPING_HEX = "deco146_mapping.hex",
    parameter        TABLE_FLAGS_HEX   = "deco146_flags.hex",
    parameter integer SS_RB0_IDX        = 0,
    parameter integer SS_RB1_IDX        = 0
)(
    input  wire        clk,
    input  wire        reset,

    input  wire [11:0] cpu_addr,
    input  wire        cpu_cs,
    input  wire        cpu_rd,
    input  wire        cpu_wr,
    input  wire [15:0] cpu_wdata,
    input  wire  [1:0] cpu_dsn,
    output reg  [15:0] cpu_rdata,

    input  wire [15:0] port_a,
    input  wire [15:0] port_b,
    input  wire [15:0] port_c,

    output reg   [7:0] soundlatch_data,
    output reg         soundlatch_irq,
    input  wire        soundlatch_rd,
    output wire  [7:0] soundlatch_dout,

    // Savestate auto_ss (69 bit): stato protezione DECO104. NON include soundlatch_irq (pulse
    // transitorio 1 ciclo: salvarlo crea edge artificiale -> push spurio FIFO al restore).
    //  [15:0] xor_reg  [31:16] nand_reg  [32] current_rambank  [43:33] latch_addr
    //  [59:44] latch_data  [60] latch_flag  [68:61] soundlatch_data
    input  wire [68:0] dc_ss_in,
    output wire [68:0] dc_ss_out,
    input  wire        dc_ss_wr,
    // Savestate rambank0/1 (RAM 128x16 protezione) via ssbus
    ssbus_if.slave     ss_rb0,
    ssbus_if.slave     ss_rb1
);

// ============================================================
// Address scramble
// ============================================================
wire [10:0] addr_w = cpu_addr[11:1];
reg [10:0] addr_scrambled;
always @(*) begin
    case (ADDR_SCRAMBLE)
        2'd1: begin // reversed (boogwing)
            addr_scrambled = {addr_w[10],
                              addr_w[0], addr_w[1], addr_w[2], addr_w[3], addr_w[4],
                              addr_w[5], addr_w[6], addr_w[7], addr_w[8], addr_w[9]};
        end
        2'd2: begin // interleave
            addr_scrambled = {addr_w[10],
                              addr_w[8], addr_w[9], addr_w[6], addr_w[7],
                              addr_w[4], addr_w[5], addr_w[2], addr_w[3],
                              addr_w[0], addr_w[1]};
        end
        default: addr_scrambled = addr_w;
    endcase
end

wire [10:0] magic_xor_w = {1'b0, MAGIC_READ_ADDR_XOR[10:1]};
// MAME deco146.cpp: magic xor è applicato SOLO in read_protport (linea 1217-1218),
// NON in write_protport. Quindi serve un addr separato per la write path.
wire [10:0] addr_for_lookup = MAGIC_XOR_ENABLED ? (addr_scrambled ^ magic_xor_w) : addr_scrambled;
wire [10:0] addr_for_write  = addr_scrambled;

// ============================================================
// Lookup tables (BRAM, .hex initialized)
// ============================================================
(* ramstyle = "M10K" *) reg [15:0] tbl_offset  [0:1023];
(* ramstyle = "M10K" *) reg [79:0] tbl_mapping [0:1023];
(* ramstyle = "M10K" *) reg [1:0]  tbl_flags   [0:1023];
initial begin
    $readmemh(TABLE_OFFSET_HEX,  tbl_offset);
    $readmemh(TABLE_MAPPING_HEX, tbl_mapping);
    $readmemh(TABLE_FLAGS_HEX,   tbl_flags);
end

// ============================================================
// RAMBANK 2 x 128 word
// ============================================================
(* ramstyle = "MLAB" *) reg [15:0] rambank0 [0:127];
(* ramstyle = "MLAB" *) reg [15:0] rambank1 [0:127];
integer init_i;
initial begin
    for (init_i = 0; init_i < 128; init_i = init_i + 1) begin
        rambank0[init_i] = 16'hFFFF;
        rambank1[init_i] = 16'hFFFF;
    end
end
reg current_rambank;
reg [15:0] xor_reg;
reg [15:0] nand_reg;

reg [10:0] latch_addr;
reg [15:0] latch_data;
reg        latch_flag;

// ============================================================
// Pipeline read: 1 ck registered (BRAM read + source select + reorder + xor/nand)
// ============================================================
// Stage 0 (combinatorial): addr_for_lookup
// Stage 1 (clocked):       read BRAM, read rambank, sample ports
// Stage 2 (combinatorial): reorder + xor/nand + latch_hit mux
// Stage 3 (clocked):       cpu_rdata

reg [15:0] s1_offset;
reg [79:0] s1_mapping;
reg [1:0]  s1_flags;
reg [15:0] s1_rb0, s1_rb1;
reg [15:0] s1_pa, s1_pb, s1_pc;
reg        s1_latch_hit;
reg [15:0] s1_latch_val;
reg        s1_cb_bank;

wire latch_hit_w = cpu_cs && cpu_rd && (addr_for_lookup == latch_addr) && latch_flag;

// Indice della rambank REGISTRATO (path critico, build 23/09: -0.106).
// Prima la riga di s1_rb0 faceva tutto in un ciclo solo: indirizzo -> tabella
// tbl_offset da 1024 voci -> indice 7 bit -> mux 128:1 su 16 bit (rambank0/1
// hanno 2 letture e 2 scritture con la porta savestate, quindi NON si inferiscono
// come memoria e diventano registri + albero di mux). 9,93 ns su 10,416: era
// IL path peggiore del core, con altri dieci identici subito sotto.
// Spezzando in due cicli restano ~3,8 ns (tabella) e ~5,9 ns (mux del banco).
// NON aggiunge latenza e non tocca le attese del bus: l'indice si registra a
// ruota libera sull'indirizzo, che fx68k tiene stabile da S1 mentre cpu_cs/cpu_rd
// arrivano con AS in S2, cioe' un clock CPU dopo (= 7 clock del core). Quando la
// lettura parte, rb_idx_r e' gia' quello giusto e s1_rb0 esce nello stesso ciclo
// in cui usciva prima.
// Le attese NON si possono allungare: cpu_rd e' un livello per tutto il ciclo di
// bus e il toggle di current_rambank non ha edge-detect, quindi un ciclo in piu'
// ne cambierebbe la parita' e ribalterebbe il banco di protezione.
reg [6:0] rb_idx_r;
always @(posedge clk) rb_idx_r <= tbl_offset[addr_for_lookup[9:0]][7:1];

always @(posedge clk) begin
    s1_offset    <= tbl_offset[addr_for_lookup[9:0]];
    s1_mapping   <= tbl_mapping[addr_for_lookup[9:0]];
    s1_flags     <= tbl_flags[addr_for_lookup[9:0]];
    s1_rb0       <= rambank0[rb_idx_r];
    s1_rb1       <= rambank1[rb_idx_r];
    s1_pa        <= port_a;
    s1_pb        <= port_b;
    s1_pc        <= port_c;
    s1_latch_hit <= latch_hit_w;
    s1_latch_val <= latch_data;
    s1_cb_bank   <= current_rambank;
end

// Stage 2 (combinatorial)
function [15:0] reorder_fn(input [15:0] src, input [79:0] map);
    integer i;
    reg [4:0] dest;
    begin
        reorder_fn = 16'd0;
        for (i = 0; i < 16; i = i + 1) begin
            dest = map[i*5 +: 5];
            if (src[i] && (dest[4] == 1'b0))
                reorder_fn[dest[3:0]] = 1'b1;
        end
    end
endfunction

reg [15:0] src_sel;
always @(*) begin
    case (s1_offset)
        16'h8000: src_sel = s1_pa;
        16'h8001: src_sel = s1_pb;
        16'h8002: src_sel = s1_pc;
        default:  src_sel = s1_cb_bank ? s1_rb1 : s1_rb0;
    endcase
end

reg [15:0] reord;
always @(*) reord = reorder_fn(src_sel, s1_mapping);

reg [15:0] final_data;
always @(*) begin
    final_data = reord;
    if (s1_flags[0]) final_data = final_data ^ xor_reg;
    if (s1_flags[1]) final_data = final_data & ~nand_reg;
end

// Stage 3: register final output (1 ck total latency)
always @(posedge clk) begin
    if (s1_latch_hit) cpu_rdata <= s1_latch_val;
    else              cpu_rdata <= final_data;
end

// ============================================================
// Bankswitch on read: trigger ck dopo lookup
// ============================================================
always @(posedge clk) begin
    if (reset) begin
        current_rambank <= 1'b0;
    end else if (dc_ss_wr) begin
        current_rambank <= dc_ss_in[32];   // restore (trasparente)
    end else begin
        // s1_offset[15]=0 (= rambank) e [7:0] == BANK_SWAP_READ_ADDR
        if (cpu_cs && cpu_rd && !s1_latch_hit
            && s1_offset[15] == 1'b0 && s1_offset[7:0] == BANK_SWAP_READ_ADDR)
            current_rambank <= ~current_rambank;
    end
end

// ============================================================
// Write protport
// ============================================================
always @(posedge clk) begin
    if (reset) begin
        xor_reg  <= 16'h0000;
        nand_reg <= 16'h0000;
        soundlatch_data <= 8'h00;
        soundlatch_irq  <= 1'b0;
        latch_addr <= 11'h7FF;
        latch_data <= 16'h0000;
        latch_flag <= 1'b0;
    end else if (dc_ss_wr) begin
        // Restore savestate (priorita', trasparente a SS spento): ricarica i reg protezione.
        xor_reg         <= dc_ss_in[15:0];
        nand_reg        <= dc_ss_in[31:16];
        latch_addr      <= dc_ss_in[43:33];
        latch_data      <= dc_ss_in[59:44];
        latch_flag      <= dc_ss_in[60];
        soundlatch_data <= dc_ss_in[68:61];
        // soundlatch_irq NON ripristinato: pulse transitorio (1 ciclo). L'edge-detect del wrapper
        // (sl_pulse_d) e' salvato in AUDIO_BUS -> nessun edge artificiale al restore.
    end else begin
        soundlatch_irq <= 1'b0;

        // Write rambank0/1 da SS (restore) — nello STESSO always della write CPU per non creare
        // doppio driver. Durante SS la CPU e' ferma (no cpu_wr), quindi niente conflitto reale.
        if (rb0_ss_sel & ss_rb0.write) rambank0[ss_rb0.addr[6:0]] <= ss_rb0.data[15:0];
        if (rb1_ss_sel & ss_rb1.write) rambank1[ss_rb1.addr[6:0]] <= ss_rb1.data[15:0];

        if (cpu_cs && cpu_wr) begin
            latch_addr <= addr_for_write;
            latch_data <= cpu_wdata;
            latch_flag <= 1'b1;

            if (current_rambank)
                rambank1[addr_for_write[7:1]] <= cpu_wdata;
            else
                rambank0[addr_for_write[7:1]] <= cpu_wdata;

            // Special port writes (byte addr = addr_for_write << 1)
            if ((addr_for_write[7:0] << 1) == {1'b0, XOR_PORT})
                xor_reg <= cpu_wdata;
            else if ((addr_for_write[7:0] << 1) == {1'b0, MASK_PORT})
                nand_reg <= cpu_wdata;
            else if ((addr_for_write[7:0] << 1) == {1'b0, SOUND_PORT}) begin
                soundlatch_data <= cpu_wdata[7:0];
                soundlatch_irq  <= 1'b1;
            end
        end

        // Clear latch flag dopo una read non-latched
        if (cpu_cs && cpu_rd && !latch_hit_w) begin
            latch_flag <= 1'b0;
        end

        if (soundlatch_rd) begin
            soundlatch_irq <= 1'b0;
        end
    end
end

assign soundlatch_dout = soundlatch_data;

// ============================================================
// Savestate: SAVE dei reg protezione (combinatorio, non tocca la logica).
// ============================================================
assign dc_ss_out = {soundlatch_data, latch_flag, latch_data,
                    latch_addr, current_rambank, nand_reg, xor_reg};

// ============================================================
// Savestate rambank0/1 (RAM 128x16): porta SS dedicata in lettura/scrittura.
// A SS spento (no access) la RAM e' scritta solo dalla CPU (logica originale, trasparente).
// Durante SS: la porta SS dirotta addr/we/data e legge le word per save / scrive per restore.
// ============================================================
wire        rb0_ss_sel = ss_rb0.access(SS_RB0_IDX);
wire        rb1_ss_sel = ss_rb1.access(SS_RB1_IDX);
reg  [15:0] rb0_ss_rd, rb1_ss_rd;
always @(posedge clk) rb0_ss_rd <= rambank0[ss_rb0.addr[6:0]];
always @(posedge clk) rb1_ss_rd <= rambank1[ss_rb1.addr[6:0]];
// NB: la WRITE SS di rambank0/1 e' nell'always "Write protport" (stesso always della write CPU)
// per evitare doppio driver. Qui solo read/setup/ack/response.
reg rb0_rd_d, rb1_rd_d;
always @(posedge clk) begin
    ss_rb0.setup(SS_RB0_IDX, 128, 1);   // 128 word, width 1 = 16 bit
    ss_rb1.setup(SS_RB1_IDX, 128, 1);
    rb0_rd_d <= rb0_ss_sel & ss_rb0.read;
    rb1_rd_d <= rb1_ss_sel & ss_rb1.read;
    if (rb0_ss_sel & ss_rb0.write) ss_rb0.write_ack(SS_RB0_IDX);
    if (rb1_ss_sel & ss_rb1.write) ss_rb1.write_ack(SS_RB1_IDX);
    if (rb0_rd_d) ss_rb0.read_response(SS_RB0_IDX, {48'b0, rb0_ss_rd});
    if (rb1_rd_d) ss_rb1.read_response(SS_RB1_IDX, {48'b0, rb1_ss_rd});
end

endmodule
