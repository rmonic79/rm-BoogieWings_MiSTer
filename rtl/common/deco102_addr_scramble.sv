//
// deco102_addr_scramble.sv
// DE102 address scramble (combinatorial)
//
// Riferimento C++: reference/mame/deco102.cpp:63-80
//   for each i_logical (CPU address):
//     src = i & 0xf0000;        // bit 19:16 preservati
//     if (i & 0x0001) src ^= 0xbe0b;
//     if (i & 0x0002) src ^= 0x5699;
//     ...
//     src ^= address_xor;
//   ROM_physical[src] = encrypted word
//
// Quindi: indirizzo_fisico_ROM = scramble(indirizzo_logico_CPU) ^ address_xor
//
// Per BoogieWings: address_xor = 0x42BA
//

module deco102_addr_scramble
(
	input  wire [19:0] i_logical,   // CPU word index addr[19:1] zero-extended a 20 bit
	output wire [19:0] i_physical   // ROM word index (= rom_addr[19:1])
);

parameter [15:0] ADDRESS_XOR = 16'h0000;

// i = i_logical (assume bit 0 = 0, ignorato)
wire [19:0] i = i_logical;

// Step 1: src = i & 0xF0000 (preserva bit 19:16)
// In MAME `i` è word index, quindi bit 19:16 sono i bit "alti" del banco.
wire [19:0] preserve_hi = {i[19:16], 16'h0000};

// Step 2: applicazione XOR conditional su bit 15:0 in base a bit i[15:0]
wire [15:0] xor_acc =
	(i[0]  ? 16'hbe0b : 16'h0000) ^
	(i[1]  ? 16'h5699 : 16'h0000) ^
	(i[2]  ? 16'h1322 : 16'h0000) ^
	(i[3]  ? 16'h0004 : 16'h0000) ^
	(i[4]  ? 16'h08a0 : 16'h0000) ^
	(i[5]  ? 16'h0089 : 16'h0000) ^
	(i[6]  ? 16'h0408 : 16'h0000) ^
	(i[7]  ? 16'h1212 : 16'h0000) ^
	(i[8]  ? 16'h08e0 : 16'h0000) ^
	(i[9]  ? 16'h5499 : 16'h0000) ^
	(i[10] ? 16'h9a8b : 16'h0000) ^
	(i[11] ? 16'h1222 : 16'h0000) ^
	(i[12] ? 16'h1200 : 16'h0000) ^
	(i[13] ? 16'h0008 : 16'h0000) ^
	(i[14] ? 16'h1210 : 16'h0000) ^
	(i[15] ? 16'h00e0 : 16'h0000);

wire [15:0] src_lo = xor_acc ^ ADDRESS_XOR;

assign i_physical = {preserve_hi[19:16], src_lo};

endmodule
