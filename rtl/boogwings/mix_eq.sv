// SPDX-License-Identifier: GPL-3.0-or-later
//
// mix_eq — correzione del mix audio verso MAME, 4 biquad in cascata per canale a 192 kHz:
//   S0 low-shelf  461 Hz  +1.80 dB
//   S1 peaking   1525 Hz  -0.72 dB  Q 6.00
//   S2 peaking   6107 Hz  -3.33 dB  Q 1.39
//   S3 high-shelf 6019 Hz +1.26 dB
//
// I parametri vengono da due registrazioni allineate dello stesso attract, MAME e core
// (MiSTer_Utility/AudioTrack_Compare: match_eq4.py, adattamento pesato sull'incertezza
// di misura); coefficienti e modello intero bit-esatto da eq_rtl_gen.py. Dopo la
// correzione nessuna banda (50 Hz - 12.5 kHz) resta fuori dall'incertezza e l'rms
// coincide con MAME entro 0.07 dB.
//
// Direct Form I, coefficienti Q2.24 (27 bit), campioni interni Q18.8 (26 bit, saturati).
// Un solo moltiplicatore 27x26 riusato in sequenza: 3 ck per termine + 1 di chiusura
// stadio = 16 ck per stadio, 128 ck per campione stereo su 500 disponibili (96 MHz / 192 kHz).
module mix_eq (
	input  wire               clk,
	input  wire               reset,
	input  wire               ce,          // 1 ck per campione (192 kHz), gia' fermo in pausa
	input  wire signed [15:0] in_l,
	input  wire signed [15:0] in_r,
	output reg  signed [15:0] out_l,
	output reg  signed [15:0] out_r
);

localparam signed [26:0] S0_B0 = 27'sd16795809;
localparam signed [26:0] S0_B1 = -27'sd33214124;
localparam signed [26:0] S0_B2 = 27'sd16422511;
localparam signed [26:0] S0_A1 = -27'sd33214517;
localparam signed [26:0] S0_A2 = 27'sd16440710;
localparam signed [26:0] S1_B0 = 27'sd16771456;
localparam signed [26:0] S1_B1 = -27'sd33368055;
localparam signed [26:0] S1_B2 = 27'sd16638201;
localparam signed [26:0] S1_A1 = -27'sd33368055;
localparam signed [26:0] S1_A2 = 27'sd16632440;
localparam signed [26:0] S2_B0 = 27'sd16350935;
localparam signed [26:0] S2_B1 = -27'sd30262296;
localparam signed [26:0] S2_B2 = 27'sd14525947;
localparam signed [26:0] S2_A1 = -27'sd30262296;
localparam signed [26:0] S2_A2 = 27'sd14099665;
localparam signed [26:0] S3_B0 = 27'sd19198141;
localparam signed [26:0] S3_B1 = -27'sd33263142;
localparam signed [26:0] S3_B2 = 27'sd14674587;
localparam signed [26:0] S3_A1 = -27'sd28737278;
localparam signed [26:0] S3_A2 = 27'sd12569647;

function signed [25:0] sat26(input signed [55:0] v);
	if      (v >  $signed(56'sd33554431)) sat26 = 26'sd33554431;
	else if (v < -$signed(56'sd33554432)) sat26 = -26'sd33554432;
	else                                  sat26 = v[25:0];
endfunction

function signed [15:0] sat16(input signed [25:0] v);
	if      (v >  $signed(26'sd32767)) sat16 = 16'sd32767;
	else if (v < -$signed(26'sd32768)) sat16 = -16'sd32768;
	else                               sat16 = v[15:0];
endfunction

// stato: z[{ch, stadio, k}], k = 0 x1, 1 x2, 2 y1, 3 y2
reg signed [25:0] z [0:31];
reg        busy, ch, sub;
reg  [1:0] stg;
reg  [2:0] term;
reg  [1:0] ph;
reg signed [15:0] in_r_q;
reg signed [25:0] s;
reg signed [26:0] ma;
reg signed [25:0] mb;
reg signed [52:0] prod;
reg signed [55:0] acc;

wire [4:0] zb = {ch, stg, 2'b00};
wire signed [55:0] prod_x = {{3{prod[52]}}, prod};
wire signed [55:0] acc_sh = acc >>> 24;
wire signed [25:0] y_new  = sat26(acc_sh);

reg signed [26:0] coef;
always @(*) begin
	case ({stg, term})
		5'b00_000: coef = S0_B0;  5'b00_001: coef = S0_B1;  5'b00_010: coef = S0_B2;
		5'b00_011: coef = S0_A1;  5'b00_100: coef = S0_A2;
		5'b01_000: coef = S1_B0;  5'b01_001: coef = S1_B1;  5'b01_010: coef = S1_B2;
		5'b01_011: coef = S1_A1;  5'b01_100: coef = S1_A2;
		5'b10_000: coef = S2_B0;  5'b10_001: coef = S2_B1;  5'b10_010: coef = S2_B2;
		5'b10_011: coef = S2_A1;  5'b10_100: coef = S2_A2;
		5'b11_000: coef = S3_B0;  5'b11_001: coef = S3_B1;  5'b11_010: coef = S3_B2;
		5'b11_011: coef = S3_A1;  default:   coef = S3_A2;
	endcase
end
reg signed [25:0] samp;
always @(*) begin
	case (term)
		3'd0:    samp = s;
		3'd1:    samp = z[zb | 5'd0];
		3'd2:    samp = z[zb | 5'd1];
		3'd3:    samp = z[zb | 5'd2];
		default: samp = z[zb | 5'd3];
	endcase
end

integer i;
always @(posedge clk) begin
	if (reset) begin
		busy <= 1'b0; ph <= 2'd0; term <= 3'd0; ch <= 1'b0; stg <= 2'd0;
		acc <= 56'sd0; out_l <= 16'sd0; out_r <= 16'sd0;
		for (i = 0; i < 32; i = i + 1) z[i] <= 26'sd0;
	end else if (!busy) begin
		if (ce) begin
			busy <= 1'b1; ch <= 1'b0; stg <= 2'd0; term <= 3'd0; ph <= 2'd0;
			s <= {{2{in_l[15]}}, in_l, 8'd0};
			in_r_q <= in_r;
			acc <= 56'sd0;
		end
	end else begin
		case (ph)
			2'd0: begin                                   // operandi
				ma  <= coef;
				mb  <= samp;
				sub <= (term >= 3'd3);
				ph  <= 2'd1;
			end
			2'd1: begin                                   // prodotto (DSP)
				prod <= ma * mb;
				ph   <= 2'd2;
			end
			2'd2: begin                                   // accumulo
				acc <= sub ? acc - prod_x : acc + prod_x;
				if (term == 3'd4) ph <= 2'd3;
				else begin term <= term + 3'd1; ph <= 2'd0; end
			end
			default: begin                                // fine stadio
				z[zb | 5'd1] <= z[zb | 5'd0];
				z[zb | 5'd0] <= s;
				z[zb | 5'd3] <= z[zb | 5'd2];
				z[zb | 5'd2] <= y_new;
				acc  <= 56'sd0;
				term <= 3'd0;
				ph   <= 2'd0;
				s    <= y_new;
				if (stg != 2'd3) begin
					stg <= stg + 2'd1;
				end else begin
					stg <= 2'd0;
					if (!ch) begin
						out_l <= sat16(y_new >>> 8);
						ch    <= 1'b1;
						s     <= {{2{in_r_q[15]}}, in_r_q, 8'd0};
					end else begin
						out_r <= sat16(y_new >>> 8);
						busy  <= 1'b0;
					end
				end
			end
		endcase
	end
end

endmodule
