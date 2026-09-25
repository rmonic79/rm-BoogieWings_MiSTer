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

// cpu68000_wrapper — Wrapper generico 68000.
// Interfaccia uniforme con clock enable, bus interface e interrupt handling.
// Usato da darius2_cpu_node per isolare i dettagli del core FX68K sottostante.

module cpu68000_wrapper
#(
	parameter [0:0] CPU_ID = 1'b0,
	parameter [1:0] CORE_IMPL = 2'd1
)
(
	input  wire       clk,
	input  wire       reset,
	input  wire       ce_cpu,
	input  wire       ce_cpub,
	input  wire [15:0] bus_rdata,
	input  wire       bus_dtackn,
	input  wire [2:0] irq_level,

	output wire       active,
	output wire [31:0] cycles,
	output wire [23:0] bus_addr,
	output wire       bus_rd,
	output wire       bus_wr,
	output wire [15:0] bus_wdata,
	output wire [1:0] bus_dsn_out,
	output wire       fx_asn,
	output wire [1:0] fx_dsn,
	output wire [15:0] last_read,
	output wire [23:0] dbg_pc,
	output wire       iack,
	output wire [2:0] fc
);

// FX68K bridge istanziato direttamente (rimossa branch else identica + generate).
cpu68000_fx68k_bridge #(.CPU_ID(CPU_ID)) engine
(
	.clk(clk),
	.reset(reset),
	.ce_cpu(ce_cpu),
	.ce_cpub(ce_cpub),
	.bus_rdata(bus_rdata),
	.bus_dtackn(bus_dtackn),
	.irq_level(irq_level),
	.active(active),
	.cycles(cycles),
	.bus_addr(bus_addr),
	.bus_rd(bus_rd),
	.bus_wr(bus_wr),
	.bus_wdata(bus_wdata),
	.bus_dsn_out(bus_dsn_out),
	.fx_asn(fx_asn),
	.fx_dsn(fx_dsn),
	.last_read(last_read),
	.dbg_pc(dbg_pc),
	.iack(iack),
	.fc(fc),
	.dbg_d6(), .dbg_d7(), .dbg_d0(), .dbg_a0(), .dbg_a1()
);

endmodule
