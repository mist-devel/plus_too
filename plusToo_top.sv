// PlusToo_top for the MIST FPGA board

module plusToo_top( 
  // clock inputs
  input wire [ 2-1:0]   CLOCK_27, // 27 MHz
  // LED outputs
  output wire           LED, // LED Yellow
  // UART
  output wire           UART_TX, // UART Transmitter (MIDI out)
  input wire            UART_RX, // UART Receiver (MIDI in)
  // VGA
  output wire           VGA_HS, // VGA H_SYNC
  output wire           VGA_VS, // VGA V_SYNC
  output wire [ 6-1:0]  VGA_R, // VGA Red[5:0]
  output wire [ 6-1:0]  VGA_G, // VGA Green[5:0]
  output wire [ 6-1:0]  VGA_B, // VGA Blue[5:0]
  // SDRAM
  inout wire [ 16-1:0]  SDRAM_DQ, // SDRAM Data bus 16 Bits
  output wire [ 13-1:0] SDRAM_A, // SDRAM Address bus 13 Bits
  output wire           SDRAM_DQML, // SDRAM Low-byte Data Mask
  output wire           SDRAM_DQMH, // SDRAM High-byte Data Mask
  output wire           SDRAM_nWE, // SDRAM Write Enable
  output wire           SDRAM_nCAS, // SDRAM Column Address Strobe
  output wire           SDRAM_nRAS, // SDRAM Row Address Strobe
  output wire           SDRAM_nCS, // SDRAM Chip Select
  output wire [ 2-1:0]  SDRAM_BA, // SDRAM Bank Address
  output wire           SDRAM_CLK, // SDRAM Clock
  output wire           SDRAM_CKE, // SDRAM Clock Enable
  // MINIMIG specific
  output wire           AUDIO_L, // sigma-delta DAC output left
  output wire           AUDIO_R, // sigma-delta DAC output right
  // SPI
  inout wire            SPI_DO,
  input wire            SPI_DI,
  input wire            SPI_SCK,
  input wire            SPI_SS2,    // fpga
  input wire            SPI_SS3,    // OSD
  input wire            SPI_SS4,    // "sniff" mode
  input wire            CONF_DATA0  // SPI_SS for user_io
  );

assign LED = ~(dio_download || dio_upload || |(diskAct ^ diskMotor));

localparam SCSI_DEVS = 4;
// ------------------------------ Plus Too Bus Timing ---------------------------------
// for stability and maintainability reasons the whole timing has been simplyfied:
//                00           01             10           11
//    ______ _____________ _____________ _____________ _____________ ___
//    ______X_video_cycle_X__cpu_cycle__X__IO_cycle___X__cpu_cycle__X___
//                        ^      ^    ^                      ^    ^
//                        |      |    |                      |    |
//                      video    | CPU|                      | CPU|
//                       read   write read                  write read

// -------------------------------------------------------------------------
// ------------------------------ data_io ----------------------------------
// -------------------------------------------------------------------------

// include ROM download helper
wire dio_download;
wire dio_upload;
wire dio_write_i;
wire [23:0] dio_addr;
wire [4:0] dio_index;
wire [7:0] dio_data;
wire [7:0] dio_din;

// good floppy image sizes are 819200 bytes and 409600 bytes
reg dsk_int_ds, dsk_ext_ds;  // double sided image inserted
reg dsk_int_ss, dsk_ext_ss;  // single sided image inserted

// any known type of disk image inserted?
wire dsk_int_ins = dsk_int_ds || dsk_int_ss;
wire dsk_ext_ins = dsk_ext_ds || dsk_ext_ss;

// at the end of a download latch file size
// diskEject is set by macos on eject
reg dio_download_d;
always @(posedge clk32) dio_download_d <= dio_download;

always @(posedge clk32) begin
	if(diskEject[0]) begin
		dsk_int_ds <= 1'b0;
		dsk_int_ss <= 1'b0;
	end else if(~dio_download && dio_download_d && dio_index == 1) begin
		dsk_int_ds <= (dio_addr[23:1] == 409599);   // double sides disk, addr counts words, not bytes
		dsk_int_ss <= (dio_addr[23:1] == 204799);   // single sided disk
	end
end	

always @(posedge clk32) begin
	if(diskEject[1]) begin
		dsk_ext_ds <= 1'b0;
		dsk_ext_ss <= 1'b0;
	end else if(~dio_download && dio_download_d && dio_index == 2) begin
		dsk_ext_ds <= (dio_addr[23:1] == 409599);   // double sided disk, addr counts words, not bytes
		dsk_ext_ss <= (dio_addr[23:1] == 204799);   // single sided disk
	end
end

// disk images are being stored right after os rom at word offset 0x80000 and 0x100000 
wire [21:1] dio_a = 
	(dio_index == 0)?dio_addr[21:1]:                 // os rom
	(dio_index == 1)?{21'h80000 + dio_addr[21:1]}:   // first dsk image at 512k word addr
	{21'h100000 + dio_addr[21:1]};                   // second dsk image at 1M word addr
   
data_io data_io (
	.clk_sys  ( clk32   ),
   // io controller spi interface
   .SPI_SCK ( SPI_SCK ),
   .SPI_SS2 ( SPI_SS2 ),
   .SPI_DI  ( SPI_DI  ),
   .SPI_DO  ( SPI_DO  ),

   .ioctl_upload   ( dio_upload ),
   .ioctl_download ( dio_download ),  // signal indicating an active rom download
   .ioctl_index    ( dio_index ),     // 0=rom download, 1=disk image

   // external ram interface
   .clkref_n   ( dio_clkref_n ),
   .ioctl_wr   ( dio_write_i ),
   .ioctl_addr ( dio_addr  ),
   .ioctl_dout ( dio_data  ),
   .ioctl_din  ( dio_din   )
);

wire dio_clkref_n = ~(~download_cycle & download_cycle_d) & ~dio_upload;
reg dio_write;
reg download_cycle_d;
always @(posedge clk32) begin
	download_cycle_d <= download_cycle;
	if (~dio_clkref_n) dio_write <= 0;
	if (dio_write_i && dio_index != 5'h1F) begin
		dio_write <= 1;
		if (dio_index == 0)
			configROMSize <= {|dio_addr[18:17], dio_addr[18] | (dio_addr[16] & !dio_addr[17])};
	end
end

// keys and switches are dummies as the mist doesn't have any ...
wire [9:0] sw = 10'd0;
wire [3:0] key = 4'd0;

	// synthesize a 32.5 MHz clock
	wire clk64;
	wire pll_locked;
	wire clk32;

	pll cs0(
		.inclk0	( CLOCK_27[0]	),
		.c0		( clk64			),
		.c1     ( clk32         ),
		.locked	( pll_locked	)
	);

	assign SDRAM_CLK = clk64;
	// the configuration string is returned to the io controller to allow
	// it to control the menu on the OSD

	parameter CONF_STR = {
		"PLUS_TOO;;",
		"F1,DSK;",
		"F2,DSK;",
		"S0,IMGVHDHD?,Mount SCSI6;",
		"S1,IMGVHDHD?,Mount SCSI5;",
		"S2,IMGVHDHD?,Mount SCSI4;",
		"S3,IMGVHDHD?,Mount SCSI3;",
		"O4,Memory,1MB,4MB;",
		"O5,Speed,8MHz,16MHz;",
		"O67,CPU,FX68K-68000,TG68K-68010,TG68K-68020;",
		"R256,Save PRAM;",
		"T0,Reset"
	};

	wire status_mem = status[4];
	wire status_turbo = status[5];
	wire [1:0] status_cpu = status[7:6];
	wire status_reset = status[0];

	// the status register is controlled by the on screen display (OSD)
	wire [7:0] status;
	wire [1:0] buttons;
	wire       ypbpr;
	// ps2 interface for mouse, to be mapped into user_io
	wire mouseClk;
	wire mouseData;
	wire keyClk;
	wire keyData;
	wire [63:0] rtc;

	wire [31:0] io_lba;
	wire [SCSI_DEVS-1:0] io_rd;
	wire [SCSI_DEVS-1:0] io_wr;
	wire       io_ack;
	wire [SCSI_DEVS-1:0] img_mounted;
	wire [63:0] img_size;
	wire [7:0] sd_buff_dout;
	wire       sd_buff_wr;
	wire [8:0] sd_buff_addr;
	wire [7:0] sd_buff_din;

	// include user_io module for arm controller communication
	user_io #(.STRLEN($size(CONF_STR)>>3), .SD_IMAGES(SCSI_DEVS)) user_io (
		.clk_sys        ( clk32          ),
		.clk_sd         ( clk32          ),
		.conf_str       ( CONF_STR       ),

		.SPI_CLK        ( SPI_SCK        ),	
		.SPI_SS_IO      ( CONF_DATA0     ),
		.SPI_MISO       ( SPI_DO         ),
		.SPI_MOSI       ( SPI_DI         ),

		.status         ( status         ),
		.buttons        ( buttons        ),
		.ypbpr          ( ypbpr          ),

		.rtc            ( rtc            ),

		// ps2 interface
		.ps2_kbd_clk    ( keyClk         ),
		.ps2_kbd_data   ( keyData        ),
		.ps2_mouse_clk  ( mouseClk       ),
		.ps2_mouse_data ( mouseData	     ),

		// SD/block device interface
		.img_mounted    ( img_mounted    ),
		.img_size       ( img_size       ),
		.sd_lba         ( io_lba         ),
		.sd_rd          ( io_rd          ),
		.sd_wr          ( io_wr          ),
		.sd_ack         ( io_ack         ),
		.sd_conf        ( 1'b0           ),
		.sd_sdhc        ( 1'b1           ),
		.sd_dout        ( sd_buff_dout   ),
		.sd_dout_strobe ( sd_buff_wr     ),
		.sd_buff_addr   ( sd_buff_addr   ),
		.sd_din         ( sd_buff_din    )
	);

	// set the real-world inputs to sane defaults
	localparam serialIn = 1'b0;

	wire [1:0] configRAMSize = status_mem?2'b11:2'b10; // 1MB/4MB
	reg  [1:0] configROMSize; // 64/128/256/512K
	wire       machineType = configROMSize[1]; // 0 - Mac Plus, 1 - Mac SE

	// interconnects
	// CPU
	wire clk8, _cpuReset, _cpuReset_o, _cpuUDS, _cpuLDS, _cpuRW, _cpuAS;
	wire clk8_en_p, clk8_en_n;
	wire clk16_en_p, clk16_en_n;
	wire _cpuVMA, _cpuVPA, _cpuDTACK;
	wire E_CPU_p, E_CPU_n;
	wire [2:0] _cpuIPL;
	wire [2:0] cpuFC;
	wire [7:0] cpuAddrHi;
	wire [23:0] cpuAddr;
	wire [15:0] cpuDataOut;
	
	// RAM/ROM
	wire _romOE;
	wire _ramOE, _ramWE;
	wire _memoryUDS, _memoryLDS;
	wire videoBusControl;
	wire dioBusControl;
	wire cpuBusControl;
	wire [21:0] memoryAddr;
	wire [15:0] memoryDataOut;
	wire memoryLatch;
	
	// peripherals
	wire vid_alt, loadPixels, pixelOut, _hblank, _vblank, hsync, vsync;
	wire memoryOverlayOn, selectSCSI, selectSCC, selectIWM, selectVIA, selectRAM, selectROM, selectSEOverlay;
	wire [15:0] dataControllerDataOut;
	
	// audio
	wire snd_alt;
	wire loadSound;

	// floppy disk image interface
	wire dskReadAckInt;
	wire [21:0] dskReadAddrInt;
	wire dskReadAckExt;
	wire [21:0] dskReadAddrExt;

	// dtack generation in turbo mode
	reg  turbo_dtack_en, cpuBusControl_d;
	reg  speed;
	always @(posedge clk32) begin
		if (!_cpuReset) begin
			turbo_dtack_en <= 0;
			speed <= status_turbo;
		end
		else begin
			cpuBusControl_d <= cpuBusControl;
			if (_cpuAS) turbo_dtack_en <= 0;
			if (!_cpuAS & ((!cpuBusControl_d & cpuBusControl) | (!selectROM & !selectRAM))) turbo_dtack_en <= 1;

			if (speed != status_turbo && _cpuAS && clk8_en_n && clk16_en_n) speed <= status_turbo;
		end
	end

	// artificial E clock and VIA dtack generation for turbo mode
	reg [4:0] E_cnt;
	wire E_GLUE_p = clk16_en_n & E_cnt == 10;
	wire E_GLUE_n = clk16_en_n & E_cnt == 18;
	reg  dtackVIA;

	always @(posedge clk32) begin
		if (!_cpuReset) begin
			E_cnt <= 0;
			dtackVIA <= 0;
		end
		else begin
			if (_cpuAS) dtackVIA <= 0;
			if (clk16_en_n) begin
				E_cnt <= E_cnt + 1'd1;
				if (E_cnt == 19) E_cnt <= 0;
				if (!_cpuAS && cpuAddr[23:21] == 3'b111 && E_cnt == 17 && speed) dtackVIA <= 1;
			end
		end
	end

	// VPA is asserted on interrupt acknowledge or VIA select in non-turbo mode
	assign      _cpuVPA = (cpuFC == 3'b111) ? 1'b0 : ~(!_cpuAS && cpuAddr[23:21] == 3'b111 && !speed);
	assign      _cpuDTACK = ~(!_cpuAS && (cpuAddr[23:21] != 3'b111 || dtackVIA)) | (speed & !turbo_dtack_en);

	wire        _VMA = speed ? !dtackVIA : _cpuVMA;

	wire        cpu_en_p      = speed ? clk16_en_p : clk8_en_p;
	wire        cpu_en_n      = speed ? clk16_en_n : clk8_en_n;

	wire        E_rising  = speed ? E_GLUE_p : E_CPU_p;
	wire        E_falling = speed ? E_GLUE_n : E_CPU_n;

	cpu_module cpu_module (
		.clk         ( clk32        ),
		._cpuReset   ( _cpuReset    ),
		.cpu_en_p    ( cpu_en_p     ),
		.cpu_en_n    ( cpu_en_n     ),
		.cpu         ( {status_cpu[1], |status_cpu} ),

		._cpuDTACK   ( _cpuDTACK    ),
		._cpuRW      ( _cpuRW       ),
		._cpuAS      ( _cpuAS       ),
		._cpuUDS     ( _cpuUDS      ),
		._cpuLDS     ( _cpuLDS      ),
		.cpuFC       ( cpuFC        ),
		._cpuReset_o ( _cpuReset_o  ),

		.E_rising    ( E_CPU_p      ),
		.E_falling   ( E_CPU_n      ),
		._cpuVMA     ( _cpuVMA      ),
		._cpuVPA     ( _cpuVPA      ),

		._cpuIPL     ( _cpuIPL      ),
		.cpuDataIn   ( dataControllerDataOut ),
		.cpuDataOut  ( cpuDataOut   ),
		.cpuAddr     ( cpuAddr[23:1])
	);

	addrController_top ac0(
		.clk(clk32),
		.clk8(clk8),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.clk16_en_p(clk16_en_p),
		.clk16_en_n(clk16_en_n),
		.cpuAddr(cpuAddr), 
		._cpuUDS(_cpuUDS),
		._cpuLDS(_cpuLDS),
		._cpuRW(_cpuRW),
		._cpuAS(_cpuAS),
		.turbo (speed),
		.configROMSize(configROMSize), 
		.configRAMSize(configRAMSize), 
		.memoryAddr(memoryAddr),
		.memoryLatch(memoryLatch),
		._memoryUDS(_memoryUDS),
		._memoryLDS(_memoryLDS),
		._romOE(_romOE), 
		._ramOE(_ramOE), 
		._ramWE(_ramWE),
		.videoBusControl(videoBusControl),	
		.dioBusControl(dioBusControl),	
		.cpuBusControl(cpuBusControl),	
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectRAM(selectRAM),
		.selectROM(selectROM),
		.selectSEOverlay(selectSEOverlay),
		.hsync(hsync), 
		.vsync(vsync),
		._hblank(_hblank),
		._vblank(_vblank),
		.loadPixels(loadPixels),
		.vid_alt(vid_alt),
		.memoryOverlayOn(memoryOverlayOn),

		.snd_alt(snd_alt),
		.loadSound(loadSound),

		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt)
	);

	wire [1:0] diskEject;
	wire [1:0] diskMotor, diskAct;

	// addional ~8ms delay in reset
	wire rom_download = dio_download && (dio_index == 0);
	wire n_reset = (rst_cnt == 0);
	reg [15:0] rst_cnt;
	reg last_mem_config;
	reg [1:0] last_cpu_config;
	always @(posedge clk32) begin
		if (clk8_en_p) begin
			last_mem_config <= status_mem;
			last_cpu_config <= status_cpu;
	
			// various sources can reset the mac
			if(!pll_locked || status_reset || buttons[1] || 
				rom_download || (last_mem_config != status_mem) || (last_cpu_config != status_cpu) || !_cpuReset_o)
				rst_cnt <= 16'd65535;
			else if(rst_cnt != 0)
				rst_cnt <= rst_cnt - 16'd1;
		end
	end

	wire [10:0] audio;
	sigma_delta_dac dac (
		.clk ( clk32 ),
		.ldatasum ( { audio, 4'h0 } ),
		.rdatasum ( { audio, 4'h0 } ),
		.left ( AUDIO_L ),
		.right ( AUDIO_R )
	);

	dataController_top #(SCSI_DEVS) dc0(
		.clk32(clk32),
		.clk8_en_p(clk8_en_p),
		.clk8_en_n(clk8_en_n),
		.E_rising(E_rising),
		.E_falling(E_falling),
		.machineType(machineType),
		._systemReset(n_reset),
		._cpuReset(_cpuReset), 
		._cpuIPL(_cpuIPL),
		._cpuUDS(_cpuUDS), 
		._cpuLDS(_cpuLDS), 
		._cpuRW(_cpuRW), 
		._cpuVMA(_VMA),
		.cpuDataIn(cpuDataOut),
		.cpuDataOut(dataControllerDataOut), 	
		.cpuAddrRegHi(cpuAddr[12:9]),
		.cpuAddrRegMid(cpuAddr[6:4]),  // for SCSI
		.cpuAddrRegLo(cpuAddr[2:1]),		
		.selectSCSI(selectSCSI),
		.selectSCC(selectSCC),
		.selectIWM(selectIWM),
		.selectVIA(selectVIA),
		.selectSEOverlay(selectSEOverlay),
		.cpuBusControl(cpuBusControl),
		.videoBusControl(videoBusControl),
		.memoryDataOut(memoryDataOut),
		.memoryDataIn(sdram_do),
		.memoryLatch(memoryLatch),

		// peripherals
		.keyClk(keyClk), 
		.keyData(keyData), 
		.mouseClk(mouseClk),
		.mouseData(mouseData),
		.serialIn(serialIn),
		.rtc(rtc),

		// video
		._hblank(_hblank),
		._vblank(_vblank), 
		.pixelOut(pixelOut),
		.loadPixels(loadPixels),
		.vid_alt(vid_alt),

		.memoryOverlayOn(memoryOverlayOn),

		.audioOut(audio),
		.snd_alt(snd_alt),
		.loadSound(loadSound),

		// floppy disk interface
		.insertDisk( { dsk_ext_ins, dsk_int_ins} ),
		.diskSides( { dsk_ext_ds, dsk_int_ds} ),
		.diskEject(diskEject),
		.dskReadAddrInt(dskReadAddrInt),
		.dskReadAckInt(dskReadAckInt),
		.dskReadAddrExt(dskReadAddrExt),
		.dskReadAckExt(dskReadAckExt),
		.diskMotor(diskMotor),
		.diskAct(diskAct),

		// block device interface for scsi disk
		.img_mounted  ( img_mounted    ),
		.img_size     ( img_size[40:9] ),
		.io_lba       ( io_lba         ),
		.io_rd        ( io_rd          ),
		.io_wr        ( io_wr          ),
		.io_ack       ( io_ack         ),
		.sd_buff_addr ( sd_buff_addr   ),
		.sd_buff_dout ( sd_buff_dout   ),
		.sd_buff_din  ( sd_buff_din    ),
		.sd_buff_wr   ( sd_buff_wr     ),

		// PRAM upload
		.pramA        ( dio_addr[7:0]  ),
		.pramDin      ( dio_data       ),
		.pramDout     ( dio_din        ),
		.pramWr       ( dio_write_i && dio_index == 5'h1F )
	);

// video output
mist_video #(.COLOR_DEPTH(1)) mist_video (
	.clk_sys     ( clk32      ),

	// OSD SPI interface
	.SPI_SCK     ( SPI_SCK    ),
	.SPI_SS3     ( SPI_SS3    ),
	.SPI_DI      ( SPI_DI     ),

	// 0 = HVSync 31KHz, 1 = CSync 15KHz
	// no scandoubler for plus_too
	.scandoubler_disable ( 1'b1 ),
	// disable csync without scandoubler
	.no_csync    ( 1'b1       ),
	// YPbPr always uses composite sync
	.ypbpr       ( ypbpr      ),
	// Rotate OSD [0] - rotate [1] - left or right
	.rotate      ( 2'b00      ),
	// composite-like blending
	.blend       ( 1'b0       ),

	// video in
	.R           ( pixelOut   ),
	.G           ( pixelOut   ),
	.B           ( pixelOut   ),

	.HSync       ( hsync      ),
	.VSync       ( vsync      ),

	// MiST video output signals
	.VGA_R       ( VGA_R      ),
	.VGA_G       ( VGA_G      ),
	.VGA_B       ( VGA_B      ),
	.VGA_VS      ( VGA_VS     ),
	.VGA_HS      ( VGA_HS     )
);

// sdram used for ram/rom maps directly into 68k address space
wire download_cycle = dio_download && dioBusControl;

wire [24:0] sdram_addr = download_cycle?{ 4'b0001, dio_a[21:1] }:{ 3'b000, ~_romOE, memoryAddr[21:1] };

wire [15:0] sdram_din = download_cycle?{dio_data,dio_data}:memoryDataOut;
wire [1:0] sdram_ds = download_cycle?{~dio_addr[0], dio_addr[0]}:{ !_memoryUDS, !_memoryLDS };
wire sdram_we = download_cycle?dio_write:!_ramWE;
wire sdram_oe = download_cycle?1'b0:(!_ramOE || !_romOE);

// during rom/disk download ffff is returned so the screen is black during download
// "extra rom" is used to hold the disk image. It's expected to be byte wide and
// we thus need to properly demultiplex the word returned from sdram in that case
wire [15:0] extra_rom_data_demux = memoryAddr[0]?
	{sdram_out[7:0],sdram_out[7:0]}:{sdram_out[15:8],sdram_out[15:8]};
wire [15:0] sdram_do = download_cycle?16'hffff:
	(dskReadAckInt || dskReadAckExt)?extra_rom_data_demux:
	sdram_out;

wire [15:0] sdram_out;

assign SDRAM_CKE         = 1'b1;

sdram sdram (
	// interface to the MT48LC16M16 chip
	.sd_data        ( SDRAM_DQ                 ),
	.sd_addr        ( SDRAM_A                  ),
	.sd_dqm         ( {SDRAM_DQMH, SDRAM_DQML} ),
	.sd_cs          ( SDRAM_nCS                ),
	.sd_ba          ( SDRAM_BA                 ),
	.sd_we          ( SDRAM_nWE                ),
	.sd_ras         ( SDRAM_nRAS               ),
	.sd_cas         ( SDRAM_nCAS               ),

	// system interface
	.clk_64         ( clk64                    ),
	.clk_8          ( clk8                     ),
	.init           ( !pll_locked              ),

	// cpu/chipset interface
	// map rom to sdram word address $200000 - $20ffff
	.din            ( sdram_din                ),
	.addr           ( sdram_addr               ),
	.ds             ( sdram_ds                 ),
	.we             ( sdram_we                 ),
	.oe             ( sdram_oe                 ),
	.dout           ( sdram_out                )
);

endmodule
