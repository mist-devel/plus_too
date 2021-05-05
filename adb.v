/* ADB implementation for plus_too */

module adb(
	input            clk,
	input            clk_en,
	input            reset,
	input      [1:0] st,
	output           _int,
	input            viaBusy,
	output reg       listen,
	input      [7:0] adb_din,
	input            adb_din_strobe,
	output reg [7:0] adb_dout,
	output reg       adb_dout_strobe,

	input            mouseStrobe,
	input      [8:0] mouseX,
	input      [8:0] mouseY,
	input            mouseButton,

	input            keyStrobe,
	input      [7:0] keyData
	);

localparam TALKINTERVAL = 17'd8000*4'd11; // 11 ms

reg   [3:0] cmd_r;
reg   [1:0] st_r;
wire  [1:0] r_r = cmd_r[1:0];
reg   [3:0] addr_r;
reg   [3:0] respCnt;
reg  [16:0] talkTimer;
reg         idleActive;

wire  [3:0] cmd = adb_din[3:0];
wire  [3:0] addr = adb_din[7:4];

reg  [15:0] adbReg;

wire  [3:0] addrKeyboard = kbdReg3[11:8];
wire  [3:0] addrMouse = mouseReg3[11:8];

always @(posedge clk) begin
	if (reset) begin
		respCnt <= 0;
		idleActive <= 0;
		cmd_r <= 0;
		listen <= 0;
	end else if (clk_en) begin
		st_r <= st;
		adb_dout_strobe <= 0;

		case (st)
		2'b00: // new command
		begin
			if (st_r != 2'b00)
				listen <= 1;

			respCnt <= 0;
			if (adb_din_strobe) begin
				idleActive <= 1;
				cmd_r <= cmd;
				addr_r <= addr;
				listen <= 0;

				if (addr_r != addr || cmd_r != cmd)
					talkTimer <= 0;
				else
					talkTimer <= TALKINTERVAL;

			end
		end

		2'b01, 2'b10: // even byte, odd byte
		begin
			// Reset, flush, talk
			if (!viaBusy && (cmd_r[3:1] == 0 || cmd_r[3:2] == 2'b11) && respCnt[0] == st[1]) begin
				adb_dout <= respCnt[0] ? adbReg[7:0] : adbReg[15:8]; // simplification: only two bytes supported (enough for keyboard/mouse)
				adb_dout_strobe <= 1;
				respCnt <= respCnt + 1'd1;
			end
			if (st_r != st) listen <= cmd_r[3:2] == 2'b10;
			if (cmd_r[3:2] == 2'b10 && respCnt[0] == st[1]) begin
				if (adb_din_strobe) begin
					listen <= 0;
					respCnt <= respCnt + 1'd1;
					// Listen : it's handled in the device specific part
					// The Listen command is to write to registers, some use cases:
					// - device ID and device handler writes
					// - LED status for the keyboard
				end
			end
		end

		2'b11: // idle
		begin
			if (cmd_r[3:2] == 2'b11 && idleActive) begin
				if (talkTimer != 0)
					talkTimer <= talkTimer - 1'd1;
				else begin
					adb_dout <= 8'hFF;
					adb_dout_strobe <= 1;
					talkTimer <= TALKINTERVAL;
					idleActive <= 0;
				end
			end
		end
		default: ;
		endcase
	end
end

wire   mouseInt = (addr_r != addrMouse && mouseValid == 2'b01) || (addr_r == addrMouse && respCnt >= 3 && cmd_r == 4'b1100);
wire   keyboardInt = (addr_r != addrKeyboard && keyboardValid == 2'b01) || (addr_r == addrKeyboard && respCnt >= 3 && cmd_r == 4'b1100);
wire   irq = mouseInt | keyboardInt | (addr_r != addrKeyboard && addr_r != addrMouse);
wire   int_inhibit = respCnt < 3 && 
                     ((addr_r == addrMouse && mouseValid == 2'b01) ||
					  (addr_r == addrKeyboard && keyboardValid == 2'b01));
assign _int = ~(irq && (st == 2'b01 || st == 2'b10)) | int_inhibit;

// Mouse handler
reg  [15:0] mouseReg3;
reg   [6:0] X,Y;
reg         button;
reg   [1:0] mouseValid;

always @(posedge clk) begin
	if (reset || cmd_r == 0) begin
		mouseReg3 <= 16'h6301; // device id: 3 device handler id: 1
		X <= 0;
		Y <= 0;
		mouseValid <= 0;
	end else if (clk_en) begin

		if (mouseStrobe) begin
			if (~mouseX[8] & |mouseX[7:6]) X <= 7'h3F;
			else if (mouseX[8] & ~mouseX[6]) X <= 7'h40;
			else X <= mouseX[6:0];

			if (~mouseY[8] & |mouseY[7:6]) Y <= 7'h40;
			else if (mouseY[8] & ~mouseY[6]) Y <= 7'h3F;
			else Y <= -mouseY[6:0];

			button <= mouseButton;
			mouseValid <= 2'b01;
		end

		if (addr_r == addrMouse) begin

			if (mouseValid == 2'b01 && respCnt == 3)
				// mouse data sent
				mouseValid <= 2'b10;

			if ((mouseValid == 2'b10 && st == 2'b00) || cmd_r == 4'b0001) begin
				// Flush mouse data after read or flush command
				mouseValid <= 0;
				X <= 0;
				Y <= 0;
			end
		end

	end
end

// Keyboard handler
reg   [1:0] keyboardValid;
reg  [15:0] kbdReg0;
reg  [15:0] kbdReg2;
reg  [15:0] kbdReg3;
reg   [7:0] kbdFifo[8];
reg   [2:0] kbdFifoRd, kbdFifoWr;

always @(posedge clk) begin
	if (reset || cmd_r == 0) begin
		kbdReg0 <= 16'hFFFF;
		kbdReg2 <= 16'hFFFF;
		kbdReg3 <= 16'h6202; // device id: 2 device handler id: 2
		keyboardValid <= 0;
		kbdFifoRd <= 0;
		kbdFifoWr <= 0;
	end else if (clk_en) begin

		if (keyStrobe && keyData[6:0] != 7'h7F) begin
			// Store the keypress in the FIFO
			kbdFifo[kbdFifoWr] <= keyData;
			kbdFifoWr <= kbdFifoWr + 1'd1;
		end

		if (kbdFifoWr != kbdFifoRd && keyboardValid == 0) begin
			// Read the FIFO when no other key processing in progress
			if (kbdReg0[6:0] == kbdFifo[kbdFifoRd][6:0])
				kbdReg0[7:0] <= kbdFifo[kbdFifoRd];
			else if (kbdReg0[14:8] == kbdFifo[kbdFifoRd][6:0])
				kbdReg0[15:8] <= kbdFifo[kbdFifoRd];
			else if (kbdReg0[7:0] == 8'hFF)
				kbdReg0[7:0] <= kbdFifo[kbdFifoRd];
			else
				kbdReg0[15:8] <= kbdFifo[kbdFifoRd];

			// kbdReg0 has a valid key
			keyboardValid <= 2'b01;
			kbdFifoRd <= kbdFifoRd + 1'd1;
		end

		if (addr_r == addrKeyboard)	begin
			if (cmd_r == 4'b1010 && adb_din_strobe && st[1]^st[0]) begin
				// write into reg2 (keyboard LEDs)
				if (respCnt == 1) kbdReg2[2:0] <= adb_din[2:0];
			end

			if (keyboardValid == 2'b01 && respCnt == 2)
				// Beginning of keyboard data read
				keyboardValid <= 2'b10;

			if ((keyboardValid == 2'b10 && st == 2'b00) || cmd_r == 4'b0001) begin
				// Flush keyboard data after read or flush command
				keyboardValid <= 0;
				kbdReg0 <= 16'hFFFF;
				if (cmd_r == 4'b0001) begin
					// Flush
					kbdFifoRd <= 0;
					kbdFifoWr <= 0;
				end
			end
		end

	end
end

// Register 0 in the Apple Standard Mouse
// Bit   Meaning
// 15    Button status; 0 = down
// 14-8  Y move counts'
// 7     Not used (always 1)
// 6-0   X move counts

// Register 0 in the Apple Standard Keyboard
// Bit   Meaning
// 15    Key status for first key; 0 = down
// 14-8  Key code for first key; a 7-bit ASCII value
// 7     Key status for second key; 0 = down
// 6-0   Key code for second key; a 7-bit ASCII value

// Register 2 in the Apple Extended Keyboard
// Bit   Key
// 15    None (reserved)
// 14    Delete
// 13    Caps Lock
// 12    Reset
// 11    Control
// 10    Shift
// 9     Option
// 8     Command
// 7     Num Lock/Clear
// 6     Scroll Lock
// 5-3   None (reserved)
// 2     LED 3 (Scroll Lock) *
// 1     LED 2 (Caps Lock) *
// 0     LED 1 (Num Lock) *
//
// *Changeable via Listen Register 2

// Register 3 (common for all devices):
// Bit   Description
// 15    Reserved; must be 0
// 14    Exceptional event, device specific; always 1 if not used
// 13    Service Request enable; 1 = enabled
// 12    Reserved; must be 0
// 11-8  Device address
// 7-0   Device Handler ID

always @(*) begin
	adbReg = 16'hFFFF;
	if (addr_r == addrKeyboard) begin
		case (r_r)
		2'b00: adbReg = kbdReg0;
		2'b10: adbReg = kbdReg2;
		2'b11: adbReg = kbdReg3;
		default: ;
		endcase
	end else if (addr_r == addrMouse) begin
		case (r_r)
		2'b00: adbReg = { button, Y, 1'b1, X };
		2'b11: adbReg = mouseReg3;
		default: ;
		endcase
	end
end

endmodule
