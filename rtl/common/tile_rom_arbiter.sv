/*  This file is part of Darius_MiSTer.

    Darius_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    Darius_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with Darius_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// tile_rom_arbiter — Round-robin arbiter tile ROM (4 client tile, no sprite).
// Sprite ROM ora vive in DDR3 via bridge inline (esterno). Questo modulo
// gestisce solo i tile renderer (clients 0-3) + client 4 (FG text) opzionale.
//
// Cache tile 64-entry direct-mapped condivisa fra i 4 client tile.

module tile_rom_arbiter (
	input  wire        clk,
	input  wire        reset,
	input  wire        hblank,

	// Ogni client passa, oltre a req+addr, il `region_id` 3-bit che indica
	// quale region SDRAM contiene i dati (vedi sdram_bridge.sv RID_*).
	input  wire        r0_req,
	input  wire [23:0] r0_addr,
	input  wire [2:0]  r0_region_id,
	output reg  [31:0] r0_data,
	output reg         r0_valid,

	input  wire        r1_req,
	input  wire [23:0] r1_addr,
	input  wire [2:0]  r1_region_id,
	output reg  [31:0] r1_data,
	output reg         r1_valid,

	input  wire        r2_req,
	input  wire [23:0] r2_addr,
	input  wire [2:0]  r2_region_id,
	output reg  [31:0] r2_data,
	output reg         r2_valid,

	input  wire        r3_req,
	input  wire [23:0] r3_addr,
	input  wire [2:0]  r3_region_id,
	output reg  [31:0] r3_data,
	output reg         r3_valid,

	input  wire        r4_req,
	input  wire [23:0] r4_addr,
	input  wire [2:0]  r4_region_id,
	output reg  [31:0] r4_data,
	output reg         r4_valid,

	output reg         tile_req,
	output reg  [23:0] tile_addr,
	output reg  [2:0]  tile_region_id,
	input  wire [31:0] tile_data,
	input  wire        tile_valid
);

// =====================================================================
// Tile ROM cache — 256-entry direct-mapped (M10K, condivisa client)
// =====================================================================
// Cache 256 entry come NinjaWarriors: bilanciamento M10K vs hit-rate.
// 2 arbiter istanze (boogwings_top) = 512 totali.
//
// Index = addr[9:2] (8 bits → 256 entries)
// Tag   = {region_id[2:0], addr[23:10]} (17 bits)
(* ramstyle = "M10K", no_rw_check *) reg [31:0] cache_data [0:255];
(* ramstyle = "M10K", no_rw_check *) reg [16:0] cache_tag  [0:255];
reg [255:0] cache_valid;

wire [7:0]  cache_idx    = tile_addr[9:2];
wire [16:0] cache_tag_in = {tile_region_id, tile_addr[23:10]};
wire        cache_hit    = cache_valid[cache_idx] && (cache_tag[cache_idx] == cache_tag_in);

// Rising edge detection — toggle protocol per tile clients, rising per FG
reg r0_req_prev, r1_req_prev, r2_req_prev, r3_req_prev, r4_req_prev;
reg [4:0] pending;
reg [23:0] r0_addr_lat, r1_addr_lat, r2_addr_lat, r3_addr_lat, r4_addr_lat;
reg [2:0]  r0_rid_lat,  r1_rid_lat,  r2_rid_lat,  r3_rid_lat,  r4_rid_lat;
reg [2:0] next_prio;
reg [2:0] active_client;

localparam ARB_IDLE = 2'd0;
localparam ARB_CHECK= 2'd1;
localparam ARB_WAIT = 2'd2;
reg [1:0] arb_state;

wire r0_rising = r0_req ^ r0_req_prev;
wire r1_rising = r1_req ^ r1_req_prev;
wire r2_rising = r2_req ^ r2_req_prev;
wire r3_rising = r3_req ^ r3_req_prev;
wire r4_rising = r4_req && !r4_req_prev;

reg [2:0] grant_id;
reg       grant_found;
reg [23:0] grant_addr;
reg [2:0]  grant_rid;

// Round-robin srotolato (4 candidati tile + r4 priorità hblank)
wire [2:0] cand0 = next_prio;
wire [2:0] cand1 = (next_prio == 3'd3) ? 3'd0 : next_prio + 3'd1;
wire [2:0] cand2 = (next_prio >= 3'd2) ? (next_prio - 3'd2) : (next_prio + 3'd2);
wire [2:0] cand3 = (next_prio == 3'd0) ? 3'd3 : (next_prio - 3'd1);

always @(*) begin
	grant_found = 0;
	grant_id    = 3'd0;

	if (hblank && pending[4]) begin
		grant_found = 1;
		grant_id    = 3'd4;
	end else if (pending[cand0]) begin
		grant_found = 1;
		grant_id    = cand0;
	end else if (pending[cand1]) begin
		grant_found = 1;
		grant_id    = cand1;
	end else if (pending[cand2]) begin
		grant_found = 1;
		grant_id    = cand2;
	end else if (pending[cand3]) begin
		grant_found = 1;
		grant_id    = cand3;
	end
end

always @(*) begin
	case (grant_id)
		3'd0: begin grant_addr = r0_addr_lat; grant_rid = r0_rid_lat; end
		3'd1: begin grant_addr = r1_addr_lat; grant_rid = r1_rid_lat; end
		3'd2: begin grant_addr = r2_addr_lat; grant_rid = r2_rid_lat; end
		3'd3: begin grant_addr = r3_addr_lat; grant_rid = r3_rid_lat; end
		3'd4: begin grant_addr = r4_addr_lat; grant_rid = r4_rid_lat; end
		default: begin grant_addr = r0_addr_lat; grant_rid = r0_rid_lat; end
	endcase
end

always @(posedge clk) begin
	if (reset) begin
		cache_valid     <= 256'b0;
		r0_req_prev  <= 0;
		r1_req_prev  <= 0;
		r2_req_prev  <= 0;
		r3_req_prev  <= 0;
		r4_req_prev  <= 0;
		pending      <= 5'b00000;
		r0_addr_lat  <= 0;
		r1_addr_lat  <= 0;
		r2_addr_lat  <= 0;
		r3_addr_lat  <= 0;
		r4_addr_lat  <= 0;
		r0_rid_lat   <= 3'd0;
		r1_rid_lat   <= 3'd0;
		r2_rid_lat   <= 3'd0;
		r3_rid_lat   <= 3'd0;
		r4_rid_lat   <= 3'd0;
		next_prio    <= 0;
		active_client <= 0;
		arb_state    <= ARB_IDLE;
		tile_req     <= 0;
		tile_addr    <= 0;
		tile_region_id <= 3'd0;
		r0_data      <= 0;
		r1_data      <= 0;
		r2_data      <= 0;
		r3_data      <= 0;
		r4_data      <= 0;
		r0_valid     <= 0;
		r1_valid     <= 0;
		r2_valid     <= 0;
		r3_valid     <= 0;
		r4_valid     <= 0;
	end else begin
		r0_req_prev <= r0_req;
		r1_req_prev <= r1_req;
		r2_req_prev <= r2_req;
		r3_req_prev <= r3_req;
		r4_req_prev <= r4_req;

		if (r0_rising) begin pending[0] <= 1'b1; r0_addr_lat <= r0_addr; r0_rid_lat <= r0_region_id; end
		if (r1_rising) begin pending[1] <= 1'b1; r1_addr_lat <= r1_addr; r1_rid_lat <= r1_region_id; end
		if (r2_rising) begin pending[2] <= 1'b1; r2_addr_lat <= r2_addr; r2_rid_lat <= r2_region_id; end
		if (r3_rising) begin pending[3] <= 1'b1; r3_addr_lat <= r3_addr; r3_rid_lat <= r3_region_id; end
		if (r4_rising) begin pending[4] <= 1'b1; r4_addr_lat <= r4_addr; r4_rid_lat <= r4_region_id; end

		r0_valid <= 0;
		r1_valid <= 0;
		r2_valid <= 0;
		r3_valid <= 0;
		r4_valid <= 0;
		tile_req <= 0;

		case (arb_state)
			ARB_IDLE: begin
				if (grant_found) begin
					active_client  <= grant_id;
					pending[grant_id] <= 1'b0;
					tile_addr      <= grant_addr;
					tile_region_id <= grant_rid;
					arb_state      <= ARB_CHECK;
				end
			end

			ARB_CHECK: begin
				if (cache_hit && active_client != 3'd4) begin
					case (active_client)
						3'd0: begin r0_data <= cache_data[cache_idx]; r0_valid <= 1'b1; end
						3'd1: begin r1_data <= cache_data[cache_idx]; r1_valid <= 1'b1; end
						3'd2: begin r2_data <= cache_data[cache_idx]; r2_valid <= 1'b1; end
						3'd3: begin r3_data <= cache_data[cache_idx]; r3_valid <= 1'b1; end
						default: ;
					endcase
					next_prio <= (active_client == 3'd3) ? 3'd0 : active_client + 3'd1;
					arb_state <= ARB_IDLE;
				end else begin
					tile_req  <= 1'b1;
					arb_state <= ARB_WAIT;
				end
			end

			ARB_WAIT: begin
				if (tile_valid) begin
					case (active_client)
						3'd0: begin r0_data <= tile_data; r0_valid <= 1'b1; end
						3'd1: begin r1_data <= tile_data; r1_valid <= 1'b1; end
						3'd2: begin r2_data <= tile_data; r2_valid <= 1'b1; end
						3'd3: begin r3_data <= tile_data; r3_valid <= 1'b1; end
						3'd4: begin r4_data <= tile_data; r4_valid <= 1'b1; end
						default: ;
					endcase
					if (active_client <= 3'd3) begin
						cache_data[tile_addr[9:2]]  <= tile_data;
						cache_tag[tile_addr[9:2]]   <= {tile_region_id, tile_addr[23:10]};
						cache_valid[tile_addr[9:2]] <= 1'b1;
					end
					next_prio <= (active_client == 3'd3) ? 3'd0 : active_client + 3'd1;
					arb_state <= ARB_IDLE;
				end
			end

			default: arb_state <= ARB_IDLE;
		endcase
	end
end

endmodule
