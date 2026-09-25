//
// deco102_decrypt.sv
// Data East Custom Chip 102 decryption (combinatorial)
//
// Riferimento C++: reference/mame/deco102.cpp (Nicola Salmoria)
//
// Parametri per gioco (boogwing.cpp:1027):
//   boogwing: address_xor=0x42BA, data_select_xor=0x00, opcode_select_xor=0x18
//
// Uso tipico:
//   ROM (encrypted, indirizzata da `rom_addr`) ─din─>
//     deco102_decrypt(addr=cpu_addr, select_xor=is_opcode ? OP_XOR : DATA_XOR)
//   ─dout─> CPU
//
// NOTA: il decrypt usa l'address "logico" della CPU, non l'address ROM.
// L'address scramble (src = i ^ ...) trasforma l'address CPU in offset ROM.
// Vedi modulo deco102_addr_scramble.sv (separato) per quella parte.
//

module deco102_decrypt
(
	input  wire [19:0] addr,        // CPU address (bit 19:1 usati, bit 0 ignorato)
	input  wire [15:0] din,         // ROM word raw
	input  wire        is_opcode,   // 0=data fetch, 1=opcode fetch
	output wire [15:0] dout
);

// Parametri per gioco (default boogwing)
parameter [15:0] DATA_SELECT_XOR   = 16'h0000;
parameter [15:0] OPCODE_SELECT_XOR = 16'h0018;

// Select XOR runtime (data vs opcode)
wire [15:0] select_xor = is_opcode ? OPCODE_SELECT_XOR : DATA_SELECT_XOR;

// ============================================================
// XOR table (16 entries × 16-bit)
// ============================================================
function [15:0] xor_lut(input [3:0] idx);
	case (idx)
		4'h0: xor_lut = 16'hb52c;
		4'h1: xor_lut = 16'h2458;
		4'h2: xor_lut = 16'h139a;
		4'h3: xor_lut = 16'hc998;
		4'h4: xor_lut = 16'hce8e;
		4'h5: xor_lut = 16'h5144;
		4'h6: xor_lut = 16'h0429;
		4'h7: xor_lut = 16'haad4;
		4'h8: xor_lut = 16'ha331;
		4'h9: xor_lut = 16'h3645;
		4'ha: xor_lut = 16'h69a3;
		4'hb: xor_lut = 16'hac64;
		4'hc: xor_lut = 16'h1a53;
		4'hd: xor_lut = 16'h5083;
		4'he: xor_lut = 16'h4dea;
		4'hf: xor_lut = 16'hd237;
	endcase
endfunction

// ============================================================
// Bitswap tables (16 entries × 16 bit-indices da 4-bit)
// Pattern: din[bs[0]] → dout[15], din[bs[1]] → dout[14], ... din[bs[15]] → dout[0]
// (MAME bitswap<16>(data, bs[0], bs[1], ..., bs[15]) significa exactly this)
//
// IMPLEMENTAZIONE: case-driven con espressione PRE-CALCOLATA per ogni tbl.
// Evita 16-bit indexing da array runtime → Quartus produce mux fissi compatti.
// ============================================================
function [15:0] bs_apply(input [3:0] tbl, input [15:0] d);
	case (tbl)
		4'h0: bs_apply = {d[12],d[ 8],d[13],d[11],d[14],d[10],d[15],d[ 9], d[ 3],d[ 2],d[ 1],d[ 0],d[ 4],d[ 5],d[ 6],d[ 7]};
		4'h1: bs_apply = {d[10],d[11],d[14],d[12],d[15],d[13],d[ 8],d[ 9], d[ 6],d[ 7],d[ 5],d[ 3],d[ 0],d[ 4],d[ 2],d[ 1]};
		4'h2: bs_apply = {d[14],d[13],d[15],d[ 9],d[ 8],d[12],d[11],d[10], d[ 7],d[ 4],d[ 1],d[ 5],d[ 6],d[ 0],d[ 3],d[ 2]};
		4'h3: bs_apply = {d[15],d[14],d[ 8],d[ 9],d[10],d[11],d[13],d[12], d[ 1],d[ 2],d[ 7],d[ 3],d[ 4],d[ 6],d[ 0],d[ 5]};
		4'h4: bs_apply = {d[10],d[ 9],d[13],d[14],d[15],d[ 8],d[12],d[11], d[ 5],d[ 2],d[ 1],d[ 0],d[ 3],d[ 4],d[ 7],d[ 6]};
		4'h5: bs_apply = {d[ 8],d[ 9],d[15],d[14],d[10],d[11],d[13],d[12], d[ 0],d[ 6],d[ 5],d[ 4],d[ 1],d[ 2],d[ 3],d[ 7]};
		4'h6: bs_apply = {d[14],d[ 8],d[15],d[ 9],d[10],d[11],d[13],d[12], d[ 4],d[ 5],d[ 3],d[ 0],d[ 2],d[ 7],d[ 6],d[ 1]};
		4'h7: bs_apply = {d[13],d[11],d[12],d[10],d[15],d[ 9],d[14],d[ 8], d[ 6],d[ 0],d[ 7],d[ 5],d[ 1],d[ 4],d[ 3],d[ 2]};
		4'h8: bs_apply = {d[12],d[11],d[13],d[10],d[ 9],d[ 8],d[14],d[15], d[ 0],d[ 2],d[ 4],d[ 6],d[ 7],d[ 5],d[ 3],d[ 1]};
		4'h9: bs_apply = {d[15],d[13],d[ 9],d[ 8],d[10],d[11],d[12],d[14], d[ 2],d[ 1],d[ 0],d[ 7],d[ 6],d[ 5],d[ 4],d[ 3]};
		4'ha: bs_apply = {d[13],d[ 8],d[ 9],d[10],d[11],d[12],d[15],d[14], d[ 6],d[ 0],d[ 1],d[ 2],d[ 3],d[ 7],d[ 4],d[ 5]};
		4'hb: bs_apply = {d[12],d[11],d[10],d[ 8],d[ 9],d[13],d[14],d[15], d[ 6],d[ 5],d[ 4],d[ 0],d[ 7],d[ 1],d[ 2],d[ 3]};
		4'hc: bs_apply = {d[12],d[15],d[ 8],d[13],d[ 9],d[11],d[14],d[10], d[ 6],d[ 5],d[ 4],d[ 3],d[ 2],d[ 1],d[ 0],d[ 7]};
		4'hd: bs_apply = {d[11],d[12],d[13],d[14],d[15],d[ 8],d[ 9],d[10], d[ 4],d[ 5],d[ 7],d[ 1],d[ 6],d[ 3],d[ 2],d[ 0]};
		4'he: bs_apply = {d[13],d[ 8],d[12],d[14],d[11],d[15],d[10],d[ 9], d[ 7],d[ 6],d[ 5],d[ 4],d[ 3],d[ 2],d[ 1],d[ 0]};
		4'hf: bs_apply = {d[15],d[14],d[13],d[12],d[11],d[10],d[ 9],d[ 8], d[ 0],d[ 6],d[ 7],d[ 4],d[ 3],d[ 2],d[ 1],d[ 5]};
	endcase
endfunction

// ============================================================
// Index calculation (deco102.cpp:36-44)
//   j_bs  = ((address ^ select_xor) & 0xf0) >> 4
//   if (address & 0x20000) j_bs ^= 4
//
//   j_xor = (address ^ select_xor) & 0x0f
//   if (address & 0x40000) j_xor ^= 2  // boogwing
// ============================================================
// NOTA: l'address in MAME è ROM word index (i), che corrisponde a addr[19:1]
//       della CPU (16-bit access). Quindi qui usiamo addr[19:1] come "i".
wire [18:0] i = addr[19:1];

wire [3:0] j_bs_base  = (i[7:4] ^ select_xor[7:4]);
// MAME: if (address & 0x20000) j ^= 4   → 4=0b0100, XOR su bit 2
wire [3:0] j_bs       = j_bs_base ^ {1'b0, i[17], 2'b00};
wire [3:0] j_xor_base = (i[3:0] ^ select_xor[3:0]);
// MAME: if (address & 0x40000) j ^= 2   → 2=0b0010, XOR su bit 1
wire [3:0] j_xor      = j_xor_base ^ {2'b00, i[18], 1'b0};

// ============================================================
// Final decrypt: xor_lut(j_xor) ^ bitswap(j_bs, din)
// ============================================================
assign dout = xor_lut(j_xor) ^ bs_apply(j_bs, din);

endmodule
