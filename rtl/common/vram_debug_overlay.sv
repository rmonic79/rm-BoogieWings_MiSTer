// vram_debug_overlay.sv — overlay debug VRAM
//
// Disegna 8 valori 16-bit hex in alto allo schermo:
//   Row 0 (y 0..7):   c0p1_cnt  c0p2_cnt  c1p1_cnt  c1p2_cnt
//   Row 1 (y 9..16):  c0p1_v0   c0p2_v0   c1p1_v0   c1p2_v0
//
// Font 8x8 monospaziato, solo cifre 0-F.
// Layout: 4 cifre per valore × 4 valori per riga = 16 char × 8 px = 128 px.
//
// I counter c0p*/c1p* contano le scritture pf*_we_lo della CPU. Se incrementano
// la CPU scrive davvero. Se restano fissi, non scrive.
// v0 = valore attuale di pf*_vram[0]. Mostra se il dato arriva alla BRAM.

module vram_debug_overlay (
    input  wire        clk,

    input  wire [9:0]  render_x,
    input  wire [8:0]  render_y,

    input  wire [15:0] dbg_c0_pf1_cnt,
    input  wire [15:0] dbg_c0_pf2_cnt,
    input  wire [15:0] dbg_c1_pf1_cnt,
    input  wire [15:0] dbg_c1_pf2_cnt,
    input  wire [15:0] dbg_c0_pf1_v0,
    input  wire [15:0] dbg_c0_pf2_v0,
    input  wire [15:0] dbg_c1_pf1_v0,
    input  wire [15:0] dbg_c1_pf2_v0,

    output wire        text_on,
    output wire [23:0] text_color  // 24-bit RGB del pixel
);

// Font 8x8 cifre 0-F. Ogni char = 8 byte (8 righe x 8 bit = 64 bit).
function [63:0] font8;
    input [3:0] c;
    case (c)
        4'h0: font8 = 64'h3C66666E76663C00;
        4'h1: font8 = 64'h1838181818187E00;
        4'h2: font8 = 64'h3C66060C30607E00;
        4'h3: font8 = 64'h3C66061C06663C00;
        4'h4: font8 = 64'h0C1C2C4C7E0C0C00;
        4'h5: font8 = 64'h7E607C0606663C00;
        4'h6: font8 = 64'h1C30607C66663C00;
        4'h7: font8 = 64'h7E66060C18181800;
        4'h8: font8 = 64'h3C66663C66663C00;
        4'h9: font8 = 64'h3C66663E060C3800;
        4'hA: font8 = 64'h3C66667E66666600;
        4'hB: font8 = 64'h7C66667C66667C00;
        4'hC: font8 = 64'h3C66606060663C00;
        4'hD: font8 = 64'h786C6666666C7800;
        4'hE: font8 = 64'h7E60607C60607E00;
        4'hF: font8 = 64'h7E60607C60606000;
    endcase
endfunction

// 4 valori per riga, 2 righe = 8 valori. Ogni valore 4 cifre × 8 px = 32 px.
// Layout x: val0(0..31) sp(32..36) val1(37..68) sp val2 sp val3 → ~155 px tot.
// Layout y: row0(0..7) sp(8..9) row1(10..17) = 18 px tot.

// Limite zona overlay
// Righe dentro l'AREA VISIBILE (render_y 9..248 in BoogieWings; render_y<8 = VBlank = invisibile).
wire in_y0 = (render_y >= 9'd16) && (render_y < 9'd24);
wire in_y1 = (render_y >= 9'd26) && (render_y < 9'd34);
wire in_y  = in_y0 | in_y1;

// Char x position: 4 valori × (4 char × 8 px + 1 sp ch) ognuno
// Per semplicità ognuno parte a x = i * 40 (= 4 char + 1 space char)
// Quindi val0 0..31, val1 40..71, val2 80..111, val3 120..151
wire [9:0] x = render_x;
wire in_x = (x < 10'd152);
wire valid_overlay = in_y && in_x;

// 4 valori per riga, ogni valore 40 px = 4 char + 1 spazio char (8 px)
// val 0: x 0..31, val 1: x 40..71, val 2: x 80..111, val 3: x 120..151
reg [1:0] val_idx;
reg [9:0] x_off_in_val;
always @(*) begin
    if (x < 10'd32)       begin val_idx = 2'd0; x_off_in_val = x;             end
    else if (x < 10'd72)  begin val_idx = 2'd1; x_off_in_val = x - 10'd40;    end
    else if (x < 10'd112) begin val_idx = 2'd2; x_off_in_val = x - 10'd80;    end
    else                  begin val_idx = 2'd3; x_off_in_val = x - 10'd120;   end
end
wire [1:0] char_idx_in_val = x_off_in_val[4:3];
wire [2:0] char_x = x_off_in_val[2:0];
wire [2:0] char_y = in_y0 ? (render_y - 9'd16) : (render_y - 9'd26) ;

// Seleziona valore
reg [15:0] sel_val;
always @(*) begin
    if (in_y0) begin
        case (val_idx)
            2'd0: sel_val = dbg_c0_pf1_cnt;
            2'd1: sel_val = dbg_c0_pf2_cnt;
            2'd2: sel_val = dbg_c1_pf1_cnt;
            2'd3: sel_val = dbg_c1_pf2_cnt;
        endcase
    end else begin
        case (val_idx)
            2'd0: sel_val = dbg_c0_pf1_v0;
            2'd1: sel_val = dbg_c0_pf2_v0;
            2'd2: sel_val = dbg_c1_pf1_v0;
            2'd3: sel_val = dbg_c1_pf2_v0;
        endcase
    end
end

// Estrai nibble da mostrare (4 cifre per valore, MSB → LSB)
reg [3:0] nibble;
always @(*) begin
    case (char_idx_in_val)
        2'd0: nibble = sel_val[15:12];
        2'd1: nibble = sel_val[11:8];
        2'd2: nibble = sel_val[ 7:4];
        2'd3: nibble = sel_val[ 3:0];
    endcase
end

// Lookup font
wire [63:0] glyph = font8(nibble);
wire [7:0]  row_bits = glyph[8*(7-char_y) +: 8];
wire        pix = row_bits[7 - char_x];

// Check char_idx_in_val < 4 (= validi). Se x_off > 31 (= dentro spazio dopo val), no pix.
wire char_valid = x_off_in_val < 10'd32;

assign text_on = valid_overlay & char_valid & pix;
// Colore: top row giallo, bottom row ciano
assign text_color = in_y0 ? 24'hFFFF00 : 24'h00FFFF;

endmodule
