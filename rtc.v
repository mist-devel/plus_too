/* PRAM - RTC implementation for plus_too */

module rtc (
	input         clk,
	input         reset,
	input         xpram, // 0 - 20 byte PRAM, 1 - 256 byte XPRAM

	input  [63:0] rtc, // sec, min, hour, date, month, year, day (BCD)
	input         _cs,
	input         ck,
	input         dat_i,
	output reg    dat_o,

	input   [7:0] pramA,
	input   [7:0] pramDin,
	output reg [7:0] pramDout,
	input         pramWr
);

function [7:0] bcd2bin;
	input [7:0] bcd;
	begin
		bcd2bin = 10*bcd[7:4] + bcd[3:0];
	end
endfunction

reg   [2:0] bit_cnt;
reg         ck_d;
reg   [7:0] din;
reg         wp;
reg   [7:0] cmd /* synthesis noprune */;
reg   [7:0] dout;
reg         cmd_mode;
reg   [1:0] xcmd_mode;
reg   [2:0] xsector;
reg   [7:0] xaddr;
reg         receiving;
reg  [31:0] secs;

// internal RAM
reg   [7:0] ram[256];
reg   [7:0] ram_addr;
reg   [7:0] ram_din, ram_dout;
reg         ram_wr;
reg         ram_dout_strobe, ram_dout_strobeD;

always @(posedge clk) begin
	ram_dout <= ram[ram_addr];
	if (ram_wr) ram[ram_addr] <= ram_din;
	pramDout <= ram[pramA];
	if (pramWr) ram[pramA] <= pramDin;
end

initial begin
	$readmemh("pram.hex", ram);
end

//

integer     sec_cnt;

wire  [7:0] year =  bcd2bin(rtc[47:40]);
wire  [3:0] month = rtc[35:32] + (rtc[36] ? 4'd10 : 4'd0);
wire  [4:0] day   = bcd2bin(rtc[29:24]);
reg   [8:0] yoe; // year of era
reg  [10:0] doy; // day of year
reg  [20:0] doe; // day of era
reg  [23:0] days;

always @(*) begin
	//    Days from epoch (01/01/1904)
	//    y -= m <= 2;
	//    const Int era = (y >= 0 ? y : y-399) / 400;
	//    const unsigned yoe = static_cast<unsigned>(y - era * 400);      // [0, 399]
	//    const unsigned doy = (153*(m + (m > 2 ? -3 : 9)) + 2)/5 + d-1;  // [0, 365]
	//    const unsigned doe = yoe * 365 + yoe/4 - yoe/100 + doy;         // [0, 146096]
	//    return era * 146097 + static_cast<Int>(doe) - 719468;
	yoe = (month <= 2) ? year - 1'd1 : year;
	doy = (8'd153*(month + ((month > 2) ? -3 : 9)) + 4'd2)/4'd5 + day-1'd1;
	doe = yoe * 9'd365 + yoe/4 - yoe/100 + doy;
	days = 5 * 146097 + doe - 719468 + 24107;
end

always @(posedge clk) begin
	if (reset) begin
		bit_cnt <= 0;
		receiving <= 1;
		cmd_mode <= 1;
		xcmd_mode <= 0;
		dat_o <= 1;
		sec_cnt <= 0;
		ram_dout_strobe <= 0;
		wp <= 0;
		ram_wr <= 0;
	end 
	else begin

//		sec_cnt <= sec_cnt + 1'd1;
//		if (sec_cnt == 31999999) begin
//			sec_cnt <= 0;
//			secs <= secs + 1'd1;
//		end

		secs <= bcd2bin(rtc[7:0]) +
		        bcd2bin(rtc[15:8]) * 60 +
		        bcd2bin(rtc[23:16]) * 3600 +
	          days * 3600*24;

		ram_dout_strobe <= 0;
		ram_dout_strobeD <= ram_dout_strobe;
		if (ram_dout_strobeD) dout <= ram_dout;

		ram_wr <= 0;

		if (_cs) begin
			bit_cnt <= 0;
			receiving <= 1;
			cmd_mode <= 1;
			dat_o <= 1;
			xcmd_mode <= 0;
		end
		else begin
			ck_d <= ck;

			// transmit at the falling edge
			if (ck_d & ~ck & !receiving)
				dat_o <= dout[7-bit_cnt];
			// receive at the rising edge of ck
			if (~ck_d & ck) begin
				bit_cnt <= bit_cnt + 1'd1;
				if (receiving || xcmd_mode == 1)
					din <= {din[6:0], dat_i};

				if (bit_cnt == 7) begin
					if (receiving && cmd_mode) begin
						// command byte received
						cmd_mode <= 0;
						xcmd_mode <= 0;
						receiving <= ~din[6];
						cmd <= {din[6:0], dat_i};
						casez ({din[5:0], dat_i})
							7'b00?0001: dout <= secs[7:0];
							7'b00?0101: dout <= secs[15:8];
							7'b00?1001: dout <= secs[23:16];
							7'b00?1101: dout <= secs[31:24];
							// 20 byte PRAM mapped to 10h-1fh and 08h-0bh
							7'b010??01: begin ram_addr <= {3'b010, din[2:1]}; ram_dout_strobe <= 1; end
							7'b1????01: begin ram_addr <= {1'b1, din[4:1]}; ram_dout_strobe <= 1; end
							7'b0111???: xcmd_mode <= xpram ? 2'd1 : 2'd0; // XPRAM extended command
							default: ;
						endcase
					end

					if (xcmd_mode == 1) begin
						if (receiving) begin
							xcmd_mode <= 2;
							xaddr <= {cmd[2:0], din[5:1]};
						end else begin
							ram_addr <= {cmd[2:0], din[5:1]};
							ram_dout_strobe <= 1;
							xcmd_mode <= 0;
						end
					end else if (xcmd_mode == 2) begin
						ram_addr <= xaddr;
						ram_din <= {din[6:0], dat_i};
						ram_wr <= !wp;
					end else if (receiving && !cmd_mode) begin
						// data byte received
						casez (cmd[6:0])
							7'b0000001: secs[7:0] <= {din[6:0], dat_i};
							7'b0000101: secs[15:8] <= {din[6:0], dat_i};
							7'b0001001: secs[23:16] <= {din[6:0], dat_i};
							7'b0001101: secs[31:24] <= {din[6:0], dat_i};
							7'b0110101: wp <= din[6];
							// 20 byte PRAM mapped to 10h-1fh and 08h-0bh
							7'b010??01: begin ram_addr <= {3'b010, cmd[3:2]}; ram_din <= {din[6:0], dat_i}; ram_wr <= !wp; end
							7'b1????01: begin ram_addr <= {1'b1, cmd[5:2]}; ram_din <= {din[6:0], dat_i}; ram_wr <= !wp; end
							default: ;
						endcase
					end
				end
			end
		end
	end
end

endmodule
