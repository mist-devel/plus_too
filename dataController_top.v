module dataController_top(
	// clocks:
	input clk32,					// 32.5 MHz pixel clock
	input clk8_en_p,
	input clk8_en_n,
	input E_rising,
	input E_falling,
	
	// system control:
	input machineType, // 0 - Mac Plus, 1 - Mac SE
	input _systemReset,

	// 68000 CPU control:
	output _cpuReset,
	output [2:0] _cpuIPL,

	// 68000 CPU memory interface:
	input [15:0] cpuDataIn,
	input [3:0] cpuAddrRegHi, // A12-A9
	input [2:0] cpuAddrRegMid, // A6-A4
	input [1:0] cpuAddrRegLo, // A2-A1
	input _cpuUDS,
	input _cpuLDS,	
	input _cpuRW,
	output [15:0] cpuDataOut,
	
	// peripherals:
	input selectSCSI,
	input selectSCC,
	input selectIWM,
	input selectVIA,
	input selectSEOverlay,
	input _cpuVMA,
	
	// RAM/ROM:
	input videoBusControl,	
	input cpuBusControl,	
	input [15:0] memoryDataIn,
	output [15:0] memoryDataOut,
	input memoryLatch,
	
	// keyboard:
	input keyClk, 
	input keyData, 
	 
	// mouse:
	input mouseClk, 
	input mouseData,
	
	// serial:
	input serialIn, 
	output serialOut,	

	// RTC
	input [63:0] rtc,

	// video:
	output pixelOut,	
	input _hblank,
	input _vblank,
	input loadPixels,
	output vid_alt,

	// audio
	output [10:0] audioOut,  // 8 bit audio + 3 bit volume
	output snd_alt,
	input loadSound,
	
	// misc
	output memoryOverlayOn,
	input [1:0] insertDisk,
	input [1:0] diskSides,
	output [1:0] diskEject,
	output [1:0] diskMotor,
	output [1:0] diskAct,

	output [21:0] dskReadAddrInt,
	input dskReadAckInt,
	output [21:0] dskReadAddrExt,
	input dskReadAckExt,

	// connections to io controller
	input   [1:0] img_mounted,
	input  [31:0] img_size,
	output [31:0] io_lba,
	output  [1:0] io_rd,
	output  [1:0] io_wr,
	input         io_ack,
	input   [8:0] sd_buff_addr,
	input   [7:0] sd_buff_dout,
	output  [7:0] sd_buff_din,
	input         sd_buff_wr,

	// PRAM upload
	input   [7:0] pramA,
	input   [7:0] pramDin,
	output  [7:0] pramDout,
	input         pramWr
);
	
	// add binary volume levels according to volume setting
	assign audioOut = 
		(snd_vol[0]?audio_x1:11'd0) +
		(snd_vol[1]?audio_x2:11'd0) +
		(snd_vol[2]?audio_x4:11'd0);

	// three binary volume levels *1, *2 and *4, sign expanded
	wire [10:0] audio_x1 = { {3{audio_latch[7]}}, audio_latch };
	wire [10:0] audio_x2 = { {2{audio_latch[7]}}, audio_latch, 1'b0 };
	wire [10:0] audio_x4 = {    audio_latch[7]  , audio_latch, 2'b00};
	
	reg loadSoundD;
	always @(posedge clk32)
		if (clk8_en_n) loadSoundD <= loadSound;

	// read audio data and convert to signed for further volume adjustment
	reg [7:0] audio_latch;
	always @(posedge clk32) begin
		if(clk8_en_p && loadSoundD) begin
			if(snd_ena) audio_latch <= 8'h00;
			else  	 	audio_latch <= memoryDataIn[15:8] - 8'd128;
		end
	end
	
	// CPU reset generation
	// For initial CPU reset, RESET and HALT must be asserted for at least 100ms = 800,000 clocks of clk8
	reg [19:0] resetDelay; // 20 bits = 1 million
	wire isResetting = resetDelay != 0;

	initial begin
		// force a reset when the FPGA configuration is completed
		resetDelay <= 20'hFFFFF;
	end
	
	always @(posedge clk32 or negedge _systemReset) begin
		if (_systemReset == 1'b0) begin
			resetDelay <= 20'hFFFFF;
		end
		else if (clk8_en_p && isResetting) begin
			resetDelay <= resetDelay - 1'b1;
		end
	end
	assign _cpuReset = isResetting ? 1'b0 : 1'b1;
	
	// interconnects
	wire SEL;
	wire _viaIrq, _sccIrq, sccWReq;
	wire [15:0] viaDataOut;
	wire [15:0] iwmDataOut;
	wire [7:0] sccDataOut;
	wire [7:0] scsiDataOut;
	wire mouseX1, mouseX2, mouseY1, mouseY2, mouseButton, mouseStrobe;
	wire [8:0] mouseX, mouseY;
	
	// interrupt control
	assign _cpuIPL = 
		!_viaIrq?3'b110:
		!_sccIrq?3'b101:
		3'b111;
		
	// Serial port
	assign serialOut = 0;

	reg [15:0] cpu_data;
	always @(posedge clk32) if (cpuBusControl && memoryLatch) cpu_data <= memoryDataIn;

	// CPU-side data output mux
	assign cpuDataOut = selectIWM ? iwmDataOut :
							  selectVIA ? viaDataOut :
							  selectSCC ? { sccDataOut, 8'hEF } :
							  selectSCSI ? { scsiDataOut, 8'hEF } :
							  (cpuBusControl && memoryLatch) ? memoryDataIn : cpu_data;
	
	// Memory-side
	assign memoryDataOut = cpuDataIn;

	// SCSI
	ncr5380 scsi(
		.clk(clk32),
		.reset(!_cpuReset),
		.bus_cs(selectSCSI),
		.bus_rs(cpuAddrRegMid),
		.ior(!_cpuUDS),
		.iow(!_cpuLDS),
		.dack(cpuAddrRegHi[0]),   // A9
		.wdata(cpuDataIn[15:8]),
		.rdata(scsiDataOut),

		// connections to io controller
		.img_mounted( img_mounted ),
		.img_size( img_size ),
		.io_lba ( io_lba ),
		.io_rd ( io_rd ),
		.io_wr ( io_wr ),
		.io_ack ( io_ack ),

		.sd_buff_addr(sd_buff_addr),
		.sd_buff_dout(sd_buff_dout),
		.sd_buff_din(sd_buff_din),
		.sd_buff_wr(sd_buff_wr)
	);

	// count vblanks, and set 1 second interrupt after 60 vblanks
	reg [5:0] vblankCount;
	reg _lastVblank;
	always @(posedge clk32) begin
		if (clk8_en_n) begin
			_lastVblank <= _vblank;
			if (_vblank == 1'b0 && _lastVblank == 1'b1) begin
				if (vblankCount != 59) begin
					vblankCount <= vblankCount + 1'b1;
				end
				else begin
					vblankCount <= 6'h0;
				end
			end
		end
	end
	wire onesec = vblankCount == 59;

	// Mac SE ROM overlay switch
	reg  SEOverlay;
	always @(posedge clk32) begin
		if (!_cpuReset)
			SEOverlay <= 1;
		else if (selectSEOverlay)
			SEOverlay <= 0;
	end

	// VIA
	wire [2:0] snd_vol;
	wire snd_ena;
	wire driveSel; // internal drive select, 0 - upper, 1 - lower

	wire [7:0] via_pa_i, via_pa_o, via_pa_oe;
	wire [7:0] via_pb_i, via_pb_o, via_pb_oe;
	wire viaIrq;

	assign _viaIrq = ~viaIrq;

	//port A
	assign via_pa_i = {sccWReq, ~via_pa_oe[6:0] | via_pa_o[6:0]};
	assign snd_vol = ~via_pa_oe[2:0] | via_pa_o[2:0];
	assign snd_alt = machineType ? 1'b0 : ~(~via_pa_oe[3] | via_pa_o[3]);
	assign driveSel = machineType ? ~via_pa_oe[4] | via_pa_o[4] : 1'b1;
	assign memoryOverlayOn = machineType ? SEOverlay : ~via_pa_oe[4] | via_pa_o[4];
	assign SEL = ~via_pa_oe[5] | via_pa_o[5];
	assign vid_alt = ~via_pa_oe[6] | via_pa_o[6];

	//port B
	assign via_pb_i = {1'b1, {3{machineType}} | {_hblank, mouseY2, mouseX2}, machineType ? _ADBint : mouseButton, 2'b11, rtcdat_o};
	assign snd_ena = ~via_pb_oe[7] | via_pb_o[7];

	assign viaDataOut[7:0] = 8'hEF;

	via6522 via(
		.clock      (clk32),
		.rising     (E_rising),
		.falling    (E_falling),
		.reset      (!_cpuReset),

		.addr       (cpuAddrRegHi),
		.wen        (selectVIA && !_cpuVMA && !_cpuRW),
		.ren        (selectVIA && !_cpuVMA &&  _cpuRW),
		.data_in    (cpuDataIn[15:8]),
		.data_out   (viaDataOut[15:8]),

		.phi2_ref   (),

		//-- pio --
		.port_a_o   (via_pa_o),
		.port_a_t   (via_pa_oe),
		.port_a_i   (via_pa_i),

		.port_b_o   (via_pb_o),
		.port_b_t   (via_pb_oe),
		.port_b_i   (via_pb_i),

		//-- handshake pins
		.ca1_i      (_vblank),
		.ca2_i      (onesec),

		.cb1_i      (VIAShiftClk),
		.cb2_i      (cb2_i),
		.cb2_o      (cb2_o),
		.cb2_t      (cb2_t),

		.irq        (viaIrq)
	);

	wire _rtccs   = ~via_pb_oe[2] | via_pb_o[2];
	wire rtcck    = ~via_pb_oe[1] | via_pb_o[1];
	wire rtcdat_i = ~via_pb_oe[0] | via_pb_o[0];
	wire rtcdat_o;

	rtc pram (
		.clk        (clk32),
		.reset      (!_cpuReset),
		.xpram      (machineType),
		.rtc        (rtc),
		._cs        (_rtccs),
		.ck         (rtcck),
		.dat_i      (rtcdat_i),
		.dat_o      (rtcdat_o),
		.pramA      (pramA),
		.pramDin    (pramDin),
		.pramDout   (pramDout),
		.pramWr     (pramWr)
	);

	wire _ADBint;
	wire ADBST0 = ~via_pb_oe[4] | via_pb_o[4];
	wire ADBST1 = ~via_pb_oe[5] | via_pb_o[5];
	wire ADBListen;

	reg VIAShiftClk;
	reg [10:0] VIAShiftClkCount;
	reg VIATransmitting, VIAWaitReceiving, VIAReceiving;
	reg [2:0] VIAShiftBitcnt;

	wire cb2_i = kbddata_o;
	wire cb2_o, cb2_t;
	wire kbddat_i = ~cb2_t | cb2_o /* synthesis keep */;
	reg kbddata_o;
	reg  [7:0] kbd_to_mac;
	reg kbd_data_valid;

	// Keyboard transmitter-receiver
	always @(posedge clk32) begin
		if (clk8_en_p) begin
			if ((VIATransmitting && !VIAWaitReceiving) || VIAReceiving) begin
				VIAShiftClkCount <= VIAShiftClkCount + 1'd1;
				if (VIAShiftClkCount == (machineType ? 8'd127 : 12'd1300)) begin // ~165usec - Mac Plus / faster - ADB
					VIAShiftClk <= ~VIAShiftClk;
					VIAShiftClkCount <= 0;
					if (VIAShiftClk) begin 
						// shift before the falling edge
						if (VIATransmitting) kbd_out_data <= { kbd_out_data[6:0], kbddat_i };
						if (VIAReceiving) kbddata_o <= kbd_to_mac[7-VIAShiftBitcnt]; // VIA receives
					end
				end
			end else begin
				VIAShiftClkCount <= 0;
				VIAShiftClk <= 1;
			end
		end
	end

	// Keyboard/ADB control
	always @(posedge clk32) begin
		reg VIAShiftClkD;
		reg ADBListenD;
		if (!_cpuReset) begin
			VIAShiftBitcnt <= 0;
			VIATransmitting <= 0;
			VIAWaitReceiving <= 0;
			kbd_data_valid <= 0;
			ADBListenD <= 0;
		end else if (clk8_en_p) begin
			if (kbd_in_strobe && !machineType) begin
				kbd_to_mac <= kbd_in_data;
				kbd_data_valid <= 1;
			end

			if (adb_dout_strobe && machineType) begin
				kbd_to_mac <= adb_dout;
				VIAReceiving <= 1;
			end

			kbd_out_strobe <= 0;
			adb_din_strobe <= 0;

			VIAShiftClkD <= VIAShiftClk;

			// Only the Macintosh can initiate communication over the keyboard lines. On
			// power-up of either the Macintosh or the keyboard, the Macintosh is in
			// charge, and the external device is passive. The Macintosh signals that it's
			// ready to begin communication by pulling the keyboard data line low.
			if (!machineType && !VIATransmitting && !VIAReceiving && !kbddat_i) begin
				VIATransmitting <= 1;
				VIAShiftBitcnt <= 0;
			end

			// ADB transmission start
			if (machineType && !VIATransmitting && !VIAReceiving) begin
				ADBListenD <= ADBListen;
				if (!ADBListenD && ADBListen) begin
					VIATransmitting <= 1;
					VIAShiftBitcnt <= 0;
				end
			end

			// The last bit of the command leaves the keyboard data line low; the
			// Macintosh then indicates it's ready to receive the keyboard's response by
			// setting the data line high. 
			if (VIAWaitReceiving && kbddat_i && kbd_data_valid) begin
				VIAWaitReceiving <= 0;
				VIAReceiving <= 1;
				VIATransmitting <= 0;
			end

			// send/receive bits at rising edge of the keyboard/ADB clock
			if (~VIAShiftClkD & VIAShiftClk) begin
				VIAShiftBitcnt <= VIAShiftBitcnt + 1'd1;

				if (VIAShiftBitcnt == 3'd7) begin
					if (VIATransmitting) begin
						if (!machineType) begin
							kbd_out_strobe <= 1;
							VIAWaitReceiving <= 1;
						end else begin
							adb_din_strobe <= 1;
							adb_din <= kbd_out_data;
							VIATransmitting <= 0;
						end
					end
					if (VIAReceiving) begin
						VIAReceiving <= 0;
						kbd_data_valid <= 0;
					end
				end
			end
		end
	end

	// IWM
	iwm i(
		.clk(clk32),
		.cep(clk8_en_p),
		.cen(clk8_en_n),
		._reset(_cpuReset),
		.selectIWM(selectIWM),
		._cpuRW(_cpuRW),
		._cpuLDS(_cpuLDS),
		.dataIn(cpuDataIn),
		.cpuAddrRegHi(cpuAddrRegHi),
		.SEL(SEL),
		.dataOut(iwmDataOut),
		.insertDisk(insertDisk),
		.diskSides(diskSides),
		.diskEject(diskEject),
		.diskMotor(diskMotor),
		.diskAct(diskAct),

		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.dskReadData(memoryDataIn[7:0])
	);

	// SCC
	scc s(
		.clk(clk32),
		.cep(clk8_en_p),
		.cen(clk8_en_n),
		.reset_hw(~_cpuReset),
		.cs(selectSCC && (_cpuLDS == 1'b0 || _cpuUDS == 1'b0)),
//		.cs(selectSCC && (_cpuLDS == 1'b0 || _cpuUDS == 1'b0) && cpuBusControl),
//		.we(!_cpuRW),
		.we(!_cpuLDS),
		.rs(cpuAddrRegLo), 
		.wdata(cpuDataIn[15:8]),
		.rdata(sccDataOut),
		._irq(_sccIrq),
		.dcd_a(mouseX1),
		.dcd_b(mouseY1),
		.wreq(sccWReq));
		
	// Video
	videoShifter vs(
		.clk32(clk32), 
		.memoryLatch(memoryLatch),
		.dataIn(memoryDataIn),
		.loadPixels(loadPixels), 
		.pixelOut(pixelOut));
	
	// Mouse
	ps2_mouse mouse(
		.sysclk(clk32),
		.clk_en(clk8_en_p),
		.reset(~_cpuReset),
		.ps2dat(mouseData),
		.ps2clk(mouseClk),
		.x1(mouseX1),
		.y1(mouseY1),
		.x2(mouseX2),
		.y2(mouseY2),
		.strobe(mouseStrobe),
		.mouseX(mouseX),
		.mouseY(mouseY),
		.button(mouseButton));

	wire [7:0] kbd_in_data;
	wire kbd_in_strobe;
	reg  [7:0] kbd_out_data;
	reg  kbd_out_strobe;

	wire adbKeyStrobe;
	wire [7:0] adbKeyData;

	// Keyboard
	ps2_kbd kbd(
		.sysclk(clk32),
		.clk_en(clk8_en_p),
		.reset(~_cpuReset),
		.ps2dat(keyData),
		.ps2clk(keyClk),
		.data_out(kbd_out_data),              // data from mac
		.strobe_out(kbd_out_strobe),
		.data_in(kbd_in_data),         // data to mac
		.strobe_in(kbd_in_strobe),
		.adbStrobe(adbKeyStrobe),
		.adbKey(adbKeyData)
	);

	reg  [7:0] adb_din;
	reg        adb_din_strobe;
	wire [7:0] adb_dout;
	wire       adb_dout_strobe;

	adb adb(
		.clk(clk32),
		.clk_en(clk8_en_p),
		.reset(~_cpuReset),
		.st({ADBST1, ADBST0}),
		._int(_ADBint),
		.viaBusy(VIATransmitting || VIAReceiving),
		.listen(ADBListen),
		.adb_din(adb_din),
		.adb_din_strobe(adb_din_strobe),
		.adb_dout(adb_dout),
		.adb_dout_strobe(adb_dout_strobe),

		.mouseStrobe(mouseStrobe),
		.mouseX(mouseX),
		.mouseY(mouseY),
		.mouseButton(mouseButton),

		.keyStrobe(adbKeyStrobe),
		.keyData(adbKeyData)
	);

endmodule
