module cpu_module (
	input clk,
	input _cpuReset,
	input cpu_en_p,
	input cpu_en_n,
	input [1:0] cpu,

	input  _cpuDTACK,
	output _cpuRW,
	output _cpuAS,
	output _cpuUDS,
	output _cpuLDS,
	output [2:0] cpuFC,
	output _cpuReset_o,

	input E_div,
	output E_rising,
	output E_falling,
	output _cpuVMA,
	input _cpuVPA,

	input [2:0] _cpuIPL,
	input [15:0] cpuDataIn,
	output [15:0] cpuDataOut,
	output [23:1] cpuAddr
);

	wire        is68000       = cpu == 0;
	assign      _cpuRW        = is68000 ? fx68_rw : tg68_rw;
	assign      _cpuAS        = is68000 ? fx68_as_n : tg68_as_n;
	assign      _cpuUDS       = is68000 ? fx68_uds_n : tg68_uds_n;
	assign      _cpuLDS       = is68000 ? fx68_lds_n : tg68_lds_n;
	assign      E_falling     = is68000 ? fx68_E_falling : tg68_E_falling;
	assign      E_rising      = is68000 ? fx68_E_rising : tg68_E_rising;
	assign      _cpuVMA       = is68000 ? fx68_vma_n : tg68_vma_n;
	assign      cpuFC[0]      = is68000 ? fx68_fc0 : tg68_fc0;
	assign      cpuFC[1]      = is68000 ? fx68_fc1 : tg68_fc1;
	assign      cpuFC[2]      = is68000 ? fx68_fc2 : tg68_fc2;
	assign      cpuAddr[23:1] = is68000 ? fx68_a : tg68_a[23:1];
	assign      cpuDataOut    = is68000 ? fx68_dout : tg68_dout;
	assign      _cpuReset_o   = is68000 ? fx68_reset_n : tg68_reset_n;

	wire        fx68_reset_n;
	wire        fx68_rw;
	wire        fx68_as_n;
	wire        fx68_uds_n;
	wire        fx68_lds_n;
	wire        fx68_E_falling;
	wire        fx68_E_rising;
	wire        fx68_vma_n;
	wire        fx68_fc0;
	wire        fx68_fc1;
	wire        fx68_fc2;
	wire [15:0] fx68_dout;
	wire [23:1] fx68_a;

	fx68k fx68k (
		.clk        ( clk ),
		.extReset   ( !_cpuReset ),
		.pwrUp      ( !_cpuReset ),
		.enPhi1     ( cpu_en_p   ),
		.enPhi2     ( cpu_en_n   ),

		.eRWn       ( fx68_rw    ),
		.ASn        ( fx68_as_n  ),
		.LDSn       ( fx68_lds_n ),
		.UDSn       ( fx68_uds_n ),
		.E          ( ),
		.E_div      ( E_div      ),
		.E_PosClkEn ( fx68_E_falling ),
		.E_NegClkEn ( fx68_E_rising ),
		.VMAn       ( fx68_vma_n ),
		.FC0        ( fx68_fc0   ),
		.FC1        ( fx68_fc1   ),
		.FC2        ( fx68_fc2   ),
		.BGn        ( ),
		.oRESETn    ( fx68_reset_n ),
		.oHALTEDn   ( ),
		.DTACKn     ( _cpuDTACK  ),
		.VPAn       ( _cpuVPA    ),
		.HALTn      ( 1'b1 ),
		.BERRn      ( 1'b1 ),
		.BRn        ( 1'b1 ),
		.BGACKn     ( 1'b1 ),
		.IPL0n      ( _cpuIPL[0] ),
		.IPL1n      ( _cpuIPL[1] ),
		.IPL2n      ( _cpuIPL[2] ),
		.iEdb       ( cpuDataIn  ),
		.oEdb       ( fx68_dout  ),
		.eab        ( fx68_a     )
	);

	wire        tg68_reset_n;
	wire        tg68_rw;
	wire        tg68_as_n;
	wire        tg68_uds_n;
	wire        tg68_lds_n;
	wire        tg68_E_rising;
	wire        tg68_E_falling;
	wire        tg68_vma_n;
	wire        tg68_fc0;
	wire        tg68_fc1;
	wire        tg68_fc2;
	wire [15:0] tg68_dout;
	wire [31:0] tg68_a;

	tg68k tg68k (
		.clk        ( clk        ),
		.reset      ( !_cpuReset ),
		.phi1       ( cpu_en_p   ),
		.phi2       ( cpu_en_n   ),
		.cpu        ( cpu        ),

		.dtack_n    ( _cpuDTACK  ),
		.rw_n       ( tg68_rw    ),
		.as_n       ( tg68_as_n  ),
		.uds_n      ( tg68_uds_n ),
		.lds_n      ( tg68_lds_n ),
		.fc         ( { tg68_fc2, tg68_fc1, tg68_fc0 } ),
		.reset_n    ( tg68_reset_n ),

		.E          (  ),
		.E_div      ( E_div      ),
		.E_PosClkEn ( tg68_E_falling ),
		.E_NegClkEn ( tg68_E_rising  ),
		.vma_n      ( tg68_vma_n ),
		.vpa_n      ( _cpuVPA    ),

		.br_n       ( 1'b1       ),
		.bg_n       (  ),
		.bgack_n    ( 1'b1       ),

		.ipl        ( _cpuIPL    ),
		.berr       ( 1'b0 ),
		.din        ( cpuDataIn  ),
		.dout       ( tg68_dout  ),
		.addr       ( tg68_a     )
	);

endmodule
