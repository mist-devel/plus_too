`timescale 1ns / 100ps

/*
 * PS2 Keyboard to Mac interface module
 */
module ps2_kbd(
	input			sysclk,
	input  clk_en,
	input  reset,

	inout  ps2dat,
	inout  ps2clk,

	// Mac Plus
	input [7:0] data_out,
	input strobe_out,
	output [7:0] data_in,
	output strobe_in,

	//ADB
	output reg adbStrobe,
	output reg [7:0] adbKey
);

	reg [9:0] 		keymac;
	reg			key_pending;
	reg [19:0] pacetimer;
	reg			inquiry_active;
	reg 			extended;
	reg 			keybreak;
	reg			capslock;
	reg			haskey;
	wire 			got_key;
	wire 			got_break;
	wire 			got_extend;
	wire			tick_short;
	wire			tick_long;
	wire			pop_key;	
	reg 			cmd_inquiry;
	reg 			cmd_instant;
	reg 			cmd_model;
	reg 			cmd_test;
	reg[1:0]		state;
	reg[1:0]		next;
	reg			nreq;
	reg[7:0]		nbyte;
	
	/* PS2 interface signals */
	wire			istrobe;
	wire [7:0] 		ibyte;
	reg			oreq;
	reg [7:0] 		obyte;
	wire			oack;
	wire			timeout;
	wire [1:0] 		dbg_lowstate;
	
	ps2 ps20(.sysclk(sysclk),
		.clk_en(clk_en),
		.reset(reset),
		.ps2dat(ps2dat),
		.ps2clk(ps2clk),
		.istrobe(istrobe),
		.ibyte(ibyte),
		.oreq(oreq),
		.obyte(obyte),
		.oack(oack),
		.timeout(timeout),
		.dbg_state(dbg_lowstate));
	
	/* --- PS2 side State machine ---
	 *
	 *  - at state_init: wait for BAT reply
	 *     * 0xaa      -> send 0xed -> state_led1
	 *     * bad reply -> send 0xff -> state_init
	 *     * timeout   -> send 0xff -> state_init
	 * 
	 *  - at state_led1: wait for ack, send LED state
	 *     * 0xfa      -> send 0xYY -> state_led2 YY=LED
	 *     * bad reply -> send 0xff -> state_init
	 *     * timeout   -> send 0xff -> state_init
	 * 
	 *  - at state_led2: wait for ack, go wait data
	 *     * 0xfa                   -> state_wait
	 *     * bad reply -> send 0xff -> state_init
	 *     * timeout   -> send 0xff -> state_init
	 * 
	 *  - at state_wait: wait for data byte
	 *     * capslock  -> send 0xed -> state_led1
	 *     * other                  -> state_wait
	 * 
	 * Works fine with my logitech USB/PS2 keyboard, but fails
	 * miserably with an old HP PS2 keyboard (which also behaves
	 * oddly with minimig as an amiga). Will eventually investigate...
	 */
	localparam ps2k_state_init	= 0;
	localparam ps2k_state_led1	= 1;
	localparam ps2k_state_led2	= 2;
	localparam ps2k_state_wait	= 3;


	/* Unlike my other modules, here I'll play with a big fat
	 * combo logic. The outputs are:
	 *  - oreq   : triggers sending of a byte. Set based on either
	 *             timeout or istrobe, and as such only set for a
	 *             clock.
	 *  - next   : next state
	 *  - obyte  : next byte to send
	 */
	always@(timeout or state or istrobe or ibyte or capslock) begin
		nreq = 0;
		next = state;
		nbyte = 8'hff;

		if (istrobe || timeout)
		  case(state)
			  ps2k_state_init: begin
				  if (istrobe && ibyte == 8'haa) begin
					  nbyte = 8'hed;
					  nreq = 1;
					  next = ps2k_state_led1;
				  end else if (ibyte != 8'hfa)
				    nreq = 1;
			  end
			  ps2k_state_led1: begin
				  nreq = 1;
				  if (istrobe && ibyte == 8'hfa) begin
					  nbyte = { 5'b00000, capslock, 1'b1, 1'b0 };
					  next = ps2k_state_led2;
				  end else
				    next = ps2k_state_init;
			  end
			  ps2k_state_led2: begin
				  if (istrobe && ibyte == 8'hfa)
				    next = ps2k_state_wait;
				  else begin
					  nreq = 1;
					  next = ps2k_state_init;
				  end
			  end
			  ps2k_state_wait: begin
				  /* Update LEDs */
//				  if (istrobe && ibyte == 8'h58) begin
//					  nbyte = 8'hed;
//					  nreq = 1;
//					  next = ps2k_state_led1;
//				  end
			  end			  
		  endcase
	end

	/* State related latches. We latch oreq and obyte, we don't
	 * necessarily have to but that avoids back to back
	 * receive/send at the low level which can upset things
	 */
	always@(posedge sysclk or posedge reset)
	  if (reset)
	    state <= ps2k_state_wait;  // ps2k_state_init
	  else if (clk_en)
	    state <= next;	
	always@(posedge sysclk or posedge reset)
	  if (reset)
	    oreq <= 0;
	  else if (clk_en)
	    oreq <= nreq;
	always@(posedge sysclk or posedge reset)
	  if (reset)
	    obyte <= 0;
	  else if (clk_en)
	    obyte <= nbyte;

	assign got_key = (state == ps2k_state_wait) && istrobe;
	assign got_break = { ibyte[7:1], 1'b0 } == 8'hf0; 
	assign got_extend = { ibyte[7:1], 1'b0 } == 8'he0; 
	assign ignore_capslock = {extended,ibyte} == 9'h058 && capslock;
	
	/* Latch key info from PS2, handle capslock state */
	always@(posedge sysclk or posedge reset)
	  if (reset) begin
		  extended <= 0;
		  keybreak <= 0;	
		  capslock <= 0;
	  end else if (clk_en && got_key) begin
		  if (got_break)
		    keybreak <= 1;
		  else if (got_extend)
		    extended <= 1;
		  else begin
			  keybreak <= 0;
			  extended <= 0;

			  /* Capslock handling */
			  if (ibyte == 8'h58 && !keybreak)
			    capslock <= ~capslock;
		  end
	  end
	
	/* --- Mac side --- */

	/* Latch commands from Mac */
	always@(posedge sysclk or posedge reset)
	  if (reset) begin
		  cmd_inquiry <= 0;
		  cmd_instant <= 0;
		  cmd_model <= 0;
		  cmd_test <= 0;
	  end else if (clk_en) begin
		  if (strobe_out) begin
			  cmd_inquiry <= 0;
			  cmd_instant <= 0;
			  cmd_model <= 0;
			  cmd_test <= 0;
			  case(data_out)
				  8'h10: cmd_inquiry <= 1;
				  8'h14: cmd_instant <= 1;
				  8'h16: cmd_model   <= 1;
				  8'h36: cmd_test    <= 1;
			  endcase
		  end
	  end

	/* Divide our clock to pace our responses to the Mac. tick_short ticks
	 * when we can respond to a command, and tick_long ticks when an inquiry
	 * command shall timeout
	 */
	always@(posedge sysclk or posedge reset)
	  if (reset)
	    pacetimer <= 0;
	  else if (clk_en) begin
		  /* reset counter on command from Mac */
		  if (strobe_out)
		    pacetimer <= 0;		  
		  else if (!tick_long)
		    pacetimer <= pacetimer + 1'd1;
	  end
	assign tick_long  = pacetimer == 20'hfffff;
	assign tick_short = pacetimer == 20'h00fff;

	/* Delay inquiry responses to after tick_short */
	always@(posedge sysclk or posedge reset)
	  if (reset)
	    inquiry_active <= 0;
	  else if (clk_en) begin
		  if (strobe_out | strobe_in)
		    inquiry_active <= 0;
		  else if (tick_short)
		    inquiry_active <= cmd_inquiry;		  
	  end	

	/* Key answer to the mac */
	assign pop_key = (cmd_instant & tick_short) |
			 (inquiry_active & tick_long) |
			 (inquiry_active & key_pending);

	/* Reply to Mac */
	assign strobe_in = ((cmd_model | cmd_test) & tick_short) | pop_key;	

	/* Handle key_pending, and multi-byte keypad responses */
	reg keypad_byte2;
	reg keypad_byte3;
	always @(posedge sysclk or posedge reset)
		if (reset) begin
			key_pending <= 0;
			keypad_byte2 <= 0;
			keypad_byte3 <= 0;
		end
		else if (clk_en) begin
			if (cmd_model | cmd_test)
				key_pending <= 0;
			else if (pop_key) begin
				if(key_pending & keymac[9] && !keypad_byte3) begin
					keypad_byte3 <= 1;
				end else if (key_pending & keymac[8] & !keypad_byte2) begin
					keypad_byte2 <= 1;
				end else begin
					key_pending <= 0;
					keypad_byte2 <= 0;
					keypad_byte3 <= 0;
				end
			end
			else if (!key_pending & got_key && !got_break && !got_extend && !ignore_capslock)
				key_pending <= 1;
		end
	
	/* Data to Mac */
	assign data_in = cmd_test 	? 8'h7d :
			 cmd_model	? 8'h0b :
			              key_pending ? (keymac[9] & !keypad_byte3 ? {keymac[7],7'h71} :
			                                                         ((keymac[8] & !keypad_byte2) ? 8'h79 : keymac[7:0])) :
			                            8'h7b;	

	/* Keymap. XXX add option to assign ctrl/alt/windows to cmd/option
	 * differently
	 */
	always @(posedge sysclk)
	  if (clk_en && got_key && !key_pending) begin
		  keymac[9]<=1'b0;
		  case({extended,ibyte}) // Scan Code Set 2
			  9'h000:		keymac[8:0] <= 9'h07b;
			  9'h001:		keymac[8:0] <= 9'h07b;	//F9
			  9'h002:		keymac[8:0] <= 9'h07b;
			  9'h003:		keymac[8:0] <= 9'h07b;	//F5
			  9'h004:		keymac[8:0] <= 9'h07b;	//F3
			  9'h005:		keymac[8:0] <= 9'h07b;	//F1
			  9'h006:		keymac[8:0] <= 9'h07b;	//F2
			  9'h007:		keymac[8:0] <= 9'h07b;	//F12 <OSD>
			  9'h008:		keymac[8:0] <= 9'h07b;
			  9'h009:		keymac[8:0] <= 9'h07b;	//F10
			  9'h00a:		keymac[8:0] <= 9'h07b;	//F8
			  9'h00b:		keymac[8:0] <= 9'h07b;	//F6
			  9'h00c:		keymac[8:0] <= 9'h07b;	//F4
			  9'h00d:		keymac[8:0] <= 9'h061;	//TAB
			  9'h00e:		keymac[8:0] <= 9'h065;	//~ (`)
			  9'h00f:		keymac[8:0] <= 9'h07b;
			  9'h010:		keymac[8:0] <= 9'h07b;
			  9'h011:		keymac[8:0] <= 9'h06f;	//LEFT ALT (command)
			  9'h012:		keymac[8:0] <= 9'h071;	//LEFT SHIFT
			  9'h013:		keymac[8:0] <= 9'h07b;
			  9'h014:		keymac[8:0] <= 9'h07b;	//CTRL (not mapped)
			  9'h015:		keymac[8:0] <= 9'h019;	//q
			  9'h016:		keymac[8:0] <= 9'h025;	//1
			  9'h017:		keymac[8:0] <= 9'h07b;
			  9'h018:		keymac[8:0] <= 9'h07b;
			  9'h019:		keymac[8:0] <= 9'h07b;
			  9'h01a:		keymac[8:0] <= 9'h00d;	//z
			  9'h01b:		keymac[8:0] <= 9'h003;	//s
			  9'h01c:		keymac[8:0] <= 9'h001;	//a
			  9'h01d:		keymac[8:0] <= 9'h01b;	//w
			  9'h01e:		keymac[8:0] <= 9'h027;	//2
			  9'h01f:		keymac[8:0] <= 9'h07b;
			  9'h020:		keymac[8:0] <= 9'h07b;
			  9'h021:		keymac[8:0] <= 9'h011;	//c
			  9'h022:		keymac[8:0] <= 9'h00f;	//x
			  9'h023:		keymac[8:0] <= 9'h005;	//d
			  9'h024:		keymac[8:0] <= 9'h01d;	//e
			  9'h025:		keymac[8:0] <= 9'h02b;	//4
			  9'h026:		keymac[8:0] <= 9'h029;	//3
			  9'h027:		keymac[8:0] <= 9'h07b;
			  9'h028:		keymac[8:0] <= 9'h07b;
			  9'h029:		keymac[8:0] <= 9'h063;	//SPACE
			  9'h02a:		keymac[8:0] <= 9'h013;	//v
			  9'h02b:		keymac[8:0] <= 9'h007;	//f
			  9'h02c:		keymac[8:0] <= 9'h023;	//t
			  9'h02d:		keymac[8:0] <= 9'h01f;	//r
			  9'h02e:		keymac[8:0] <= 9'h02f;	//5
			  9'h02f:		keymac[8:0] <= 9'h07b;
			  9'h030:		keymac[8:0] <= 9'h07b;
			  9'h031:		keymac[8:0] <= 9'h05b;	//n
			  9'h032:		keymac[8:0] <= 9'h017;	//b
			  9'h033:		keymac[8:0] <= 9'h009;	//h
			  9'h034:		keymac[8:0] <= 9'h00b;	//g
			  9'h035:		keymac[8:0] <= 9'h021;	//y
			  9'h036:		keymac[8:0] <= 9'h02d;	//6
			  9'h037:		keymac[8:0] <= 9'h07b;
			  9'h038:		keymac[8:0] <= 9'h07b;
			  9'h039:		keymac[8:0] <= 9'h07b;
			  9'h03a:		keymac[8:0] <= 9'h05d;	//m
			  9'h03b:		keymac[8:0] <= 9'h04d;	//j
			  9'h03c:		keymac[8:0] <= 9'h041;	//u
			  9'h03d:		keymac[8:0] <= 9'h035;	//7
			  9'h03e:		keymac[8:0] <= 9'h039;	//8
			  9'h03f:		keymac[8:0] <= 9'h07b;
			  9'h040:		keymac[8:0] <= 9'h07b;
			  9'h041:		keymac[8:0] <= 9'h057;	//<,
			  9'h042:		keymac[8:0] <= 9'h051;	//k
			  9'h043:		keymac[8:0] <= 9'h045;	//i
			  9'h044:		keymac[8:0] <= 9'h03f;	//o
			  9'h045:		keymac[8:0] <= 9'h03b;	//0
			  9'h046:		keymac[8:0] <= 9'h033;	//9
			  9'h047:		keymac[8:0] <= 9'h07b;
			  9'h048:		keymac[8:0] <= 9'h07b;
			  9'h049:		keymac[8:0] <= 9'h05f;	//>.
			  9'h04a:		keymac[8:0] <= 9'h059;	//FORWARD SLASH
			  9'h04b:		keymac[8:0] <= 9'h04b;	//l
			  9'h04c:		keymac[8:0] <= 9'h053;	//;
			  9'h04d:		keymac[8:0] <= 9'h047;	//p
			  9'h04e:		keymac[8:0] <= 9'h037;	//-
			  9'h04f:		keymac[8:0] <= 9'h07b;
			  9'h050:		keymac[8:0] <= 9'h07b;
			  9'h051:		keymac[8:0] <= 9'h07b;
			  9'h052:		keymac[8:0] <= 9'h04f;	//'"
			  9'h053:		keymac[8:0] <= 9'h07b;
			  9'h054:		keymac[8:0] <= 9'h043;	//[
			  9'h055:		keymac[8:0] <= 9'h031;	// = 
			  9'h056:		keymac[8:0] <= 9'h07b;
			  9'h057:		keymac[8:0] <= 9'h07b;
			  9'h058:		keymac[8:0] <= 9'h073;	//CAPSLOCK
			  9'h059:		keymac[8:0] <= 9'h071;	//RIGHT SHIFT
			  9'h05a:		keymac[8:0] <= 9'h049;	//ENTER
			  9'h05b:		keymac[8:0] <= 9'h03d;	//]
			  9'h05c:		keymac[8:0] <= 9'h07b;
			  9'h05d:		keymac[8:0] <= 9'h055;	//BACKSLASH
			  9'h05e:		keymac[8:0] <= 9'h07b;
			  9'h05f:		keymac[8:0] <= 9'h07b;
			  9'h060:		keymac[8:0] <= 9'h07b;
			  9'h061:		keymac[8:0] <= 9'h071;	//international left shift cut out (German '<>' key), 0x56 Set#1 code
			  9'h062:		keymac[8:0] <= 9'h07b;
			  9'h063:		keymac[8:0] <= 9'h07b;
			  9'h064:		keymac[8:0] <= 9'h07b;
			  9'h065:		keymac[8:0] <= 9'h07b;
			  9'h066:		keymac[8:0] <= 9'h067;	//BACKSPACE
			  9'h067:		keymac[8:0] <= 9'h07b;
			  9'h068:		keymac[8:0] <= 9'h07b;
			  9'h069:		keymac[8:0] <= 9'h127;	//KP 1
			  9'h06a:		keymac[8:0] <= 9'h07b;
			  9'h06b:		keymac[8:0] <= 9'h12d;	//KP 4
			  9'h06c:		keymac[8:0] <= 9'h133;	//KP 7
			  9'h06d:		keymac[8:0] <= 9'h07b;
			  9'h06e:		keymac[8:0] <= 9'h07b;
			  9'h06f:		keymac[8:0] <= 9'h07b;
			  9'h070:		keymac[8:0] <= 9'h125;	//KP 0
			  9'h071:		keymac[8:0] <= 9'h103;	//KP .
			  9'h072:		keymac[8:0] <= 9'h129;	//KP 2
			  9'h073:		keymac[8:0] <= 9'h12f;	//KP 5
			  9'h074:		keymac[8:0] <= 9'h131;	//KP 6
			  9'h075:		keymac[8:0] <= 9'h137;	//KP 8
			  9'h076:		keymac[8:0] <= 9'h07b;	//ESCAPE
			  9'h077:		keymac[8:0] <= 9'h07b;	//NUMLOCK (Mac keypad clear?)
			  9'h078:		keymac[8:0] <= 9'h07b;	//F11 <OSD>
			  9'h079:		keymac[9:0] <=10'h30d;	//KP +
			  9'h07a:		keymac[8:0] <= 9'h12b;	//KP 3
			  9'h07b:		keymac[8:0] <= 9'h11d;	//KP -
			  9'h07c:		keymac[9:0] <=10'h305;	//KP *
			  9'h07d:		keymac[8:0] <= 9'h139;	//KP 9
			  9'h07e:		keymac[8:0] <= 9'h07b;	//SCROLL LOCK / KP )
			  9'h07f:		keymac[8:0] <= 9'h07b;
			  9'h080:		keymac[8:0] <= 9'h07b;
			  9'h081:		keymac[8:0] <= 9'h07b;
			  9'h082:		keymac[8:0] <= 9'h07b;
			  9'h083:		keymac[8:0] <= 9'h07b;	//F7
			  9'h084:		keymac[8:0] <= 9'h07b;
			  9'h085:		keymac[8:0] <= 9'h07b;
			  9'h086:		keymac[8:0] <= 9'h07b;
			  9'h087:		keymac[8:0] <= 9'h07b;
			  9'h088:		keymac[8:0] <= 9'h07b;
			  9'h089:		keymac[8:0] <= 9'h07b;
			  9'h08a:		keymac[8:0] <= 9'h07b;
			  9'h08b:		keymac[8:0] <= 9'h07b;
			  9'h08c:		keymac[8:0] <= 9'h07b;
			  9'h08d:		keymac[8:0] <= 9'h07b;
			  9'h08e:		keymac[8:0] <= 9'h07b;
			  9'h08f:		keymac[8:0] <= 9'h07b;
			  9'h090:		keymac[8:0] <= 9'h07b;
			  9'h091:		keymac[8:0] <= 9'h07b;
			  9'h092:		keymac[8:0] <= 9'h07b;
			  9'h093:		keymac[8:0] <= 9'h07b;
			  9'h094:		keymac[8:0] <= 9'h07b;
			  9'h095:		keymac[8:0] <= 9'h07b;
			  9'h096:		keymac[8:0] <= 9'h07b;
			  9'h097:		keymac[8:0] <= 9'h07b;
			  9'h098:		keymac[8:0] <= 9'h07b;
			  9'h099:		keymac[8:0] <= 9'h07b;
			  9'h09a:		keymac[8:0] <= 9'h07b;
			  9'h09b:		keymac[8:0] <= 9'h07b;
			  9'h09c:		keymac[8:0] <= 9'h07b;
			  9'h09d:		keymac[8:0] <= 9'h07b;
			  9'h09e:		keymac[8:0] <= 9'h07b;
			  9'h09f:		keymac[8:0] <= 9'h07b;
			  9'h0a0:		keymac[8:0] <= 9'h07b;
			  9'h0a1:		keymac[8:0] <= 9'h07b;
			  9'h0a2:		keymac[8:0] <= 9'h07b;
			  9'h0a3:		keymac[8:0] <= 9'h07b;
			  9'h0a4:		keymac[8:0] <= 9'h07b;
			  9'h0a5:		keymac[8:0] <= 9'h07b;
			  9'h0a6:		keymac[8:0] <= 9'h07b;
			  9'h0a7:		keymac[8:0] <= 9'h07b;
			  9'h0a8:		keymac[8:0] <= 9'h07b;
			  9'h0a9:		keymac[8:0] <= 9'h07b;
			  9'h0aa:		keymac[8:0] <= 9'h07b;
			  9'h0ab:		keymac[8:0] <= 9'h07b;
			  9'h0ac:		keymac[8:0] <= 9'h07b;
			  9'h0ad:		keymac[8:0] <= 9'h07b;
			  9'h0ae:		keymac[8:0] <= 9'h07b;
			  9'h0af:		keymac[8:0] <= 9'h07b;
			  9'h0b0:		keymac[8:0] <= 9'h07b;
			  9'h0b1:		keymac[8:0] <= 9'h07b;
			  9'h0b2:		keymac[8:0] <= 9'h07b;
			  9'h0b3:		keymac[8:0] <= 9'h07b;
			  9'h0b4:		keymac[8:0] <= 9'h07b;
			  9'h0b5:		keymac[8:0] <= 9'h07b;
			  9'h0b6:		keymac[8:0] <= 9'h07b;
			  9'h0b7:		keymac[8:0] <= 9'h07b;
			  9'h0b8:		keymac[8:0] <= 9'h07b;
			  9'h0b9:		keymac[8:0] <= 9'h07b;
			  9'h0ba:		keymac[8:0] <= 9'h07b;
			  9'h0bb:		keymac[8:0] <= 9'h07b;
			  9'h0bc:		keymac[8:0] <= 9'h07b;
			  9'h0bd:		keymac[8:0] <= 9'h07b;
			  9'h0be:		keymac[8:0] <= 9'h07b;
			  9'h0bf:		keymac[8:0] <= 9'h07b;
			  9'h0c0:		keymac[8:0] <= 9'h07b;
			  9'h0c1:		keymac[8:0] <= 9'h07b;
			  9'h0c2:		keymac[8:0] <= 9'h07b;
			  9'h0c3:		keymac[8:0] <= 9'h07b;
			  9'h0c4:		keymac[8:0] <= 9'h07b;
			  9'h0c5:		keymac[8:0] <= 9'h07b;
			  9'h0c6:		keymac[8:0] <= 9'h07b;
			  9'h0c7:		keymac[8:0] <= 9'h07b;
			  9'h0c8:		keymac[8:0] <= 9'h07b;
			  9'h0c9:		keymac[8:0] <= 9'h07b;
			  9'h0ca:		keymac[8:0] <= 9'h07b;
			  9'h0cb:		keymac[8:0] <= 9'h07b;
			  9'h0cc:		keymac[8:0] <= 9'h07b;
			  9'h0cd:		keymac[8:0] <= 9'h07b;
			  9'h0ce:		keymac[8:0] <= 9'h07b;
			  9'h0cf:		keymac[8:0] <= 9'h07b;
			  9'h0d0:		keymac[8:0] <= 9'h07b;
			  9'h0d1:		keymac[8:0] <= 9'h07b;
			  9'h0d2:		keymac[8:0] <= 9'h07b;
			  9'h0d3:		keymac[8:0] <= 9'h07b;
			  9'h0d4:		keymac[8:0] <= 9'h07b;
			  9'h0d5:		keymac[8:0] <= 9'h07b;
			  9'h0d6:		keymac[8:0] <= 9'h07b;
			  9'h0d7:		keymac[8:0] <= 9'h07b;
			  9'h0d8:		keymac[8:0] <= 9'h07b;
			  9'h0d9:		keymac[8:0] <= 9'h07b;
			  9'h0da:		keymac[8:0] <= 9'h07b;
			  9'h0db:		keymac[8:0] <= 9'h07b;
			  9'h0dc:		keymac[8:0] <= 9'h07b;
			  9'h0dd:		keymac[8:0] <= 9'h07b;
			  9'h0de:		keymac[8:0] <= 9'h07b;
			  9'h0df:		keymac[8:0] <= 9'h07b;
			  9'h0e0:		keymac[8:0] <= 9'h07b;	//ps2 extended key
			  9'h0e1:		keymac[8:0] <= 9'h07b;
			  9'h0e2:		keymac[8:0] <= 9'h07b;
			  9'h0e3:		keymac[8:0] <= 9'h07b;
			  9'h0e4:		keymac[8:0] <= 9'h07b;
			  9'h0e5:		keymac[8:0] <= 9'h07b;
			  9'h0e6:		keymac[8:0] <= 9'h07b;
			  9'h0e7:		keymac[8:0] <= 9'h07b;
			  9'h0e8:		keymac[8:0] <= 9'h07b;
			  9'h0e9:		keymac[8:0] <= 9'h07b;
			  9'h0ea:		keymac[8:0] <= 9'h07b;
			  9'h0eb:		keymac[8:0] <= 9'h07b;
			  9'h0ec:		keymac[8:0] <= 9'h07b;
			  9'h0ed:		keymac[8:0] <= 9'h07b;
			  9'h0ee:		keymac[8:0] <= 9'h07b;
			  9'h0ef:		keymac[8:0] <= 9'h07b;
			  9'h0f0:		keymac[8:0] <= 9'h07b;	//ps2 release code
			  9'h0f1:		keymac[8:0] <= 9'h07b;
			  9'h0f2:		keymac[8:0] <= 9'h07b;
			  9'h0f3:		keymac[8:0] <= 9'h07b;
			  9'h0f4:		keymac[8:0] <= 9'h07b;
			  9'h0f5:		keymac[8:0] <= 9'h07b;
			  9'h0f6:		keymac[8:0] <= 9'h07b;
			  9'h0f7:		keymac[8:0] <= 9'h07b;
			  9'h0f8:		keymac[8:0] <= 9'h07b;
			  9'h0f9:		keymac[8:0] <= 9'h07b;
			  9'h0fa:		keymac[8:0] <= 9'h07b;	//ps2 ack code
			  9'h0fb:		keymac[8:0] <= 9'h07b;
			  9'h0fc:		keymac[8:0] <= 9'h07b;
			  9'h0fd:		keymac[8:0] <= 9'h07b;
			  9'h0fe:		keymac[8:0] <= 9'h07b;
			  9'h0ff:		keymac[8:0] <= 9'h07b;
			  9'h100:		keymac[8:0] <= 9'h07b;
			  9'h101:		keymac[8:0] <= 9'h07b;
			  9'h102:		keymac[8:0] <= 9'h07b;
			  9'h103:		keymac[8:0] <= 9'h07b;
			  9'h104:		keymac[8:0] <= 9'h07b;
			  9'h105:		keymac[8:0] <= 9'h07b;
			  9'h106:		keymac[8:0] <= 9'h07b;
			  9'h107:		keymac[8:0] <= 9'h07b;
			  9'h108:		keymac[8:0] <= 9'h07b;
			  9'h109:		keymac[8:0] <= 9'h07b;
			  9'h10a:		keymac[8:0] <= 9'h07b;
			  9'h10b:		keymac[8:0] <= 9'h07b;
			  9'h10c:		keymac[8:0] <= 9'h07b;
			  9'h10d:		keymac[8:0] <= 9'h07b;
			  9'h10e:		keymac[8:0] <= 9'h07b;
			  9'h10f:		keymac[8:0] <= 9'h07b;
			  9'h110:		keymac[8:0] <= 9'h07b;
			  9'h111:		keymac[8:0] <= 9'h06f;	//RIGHT ALT (command)
			  9'h112:		keymac[8:0] <= 9'h07b;
			  9'h113:		keymac[8:0] <= 9'h07b;
			  9'h114:		keymac[8:0] <= 9'h07b;
			  9'h115:		keymac[8:0] <= 9'h07b;
			  9'h116:		keymac[8:0] <= 9'h07b;
			  9'h117:		keymac[8:0] <= 9'h07b;
			  9'h118:		keymac[8:0] <= 9'h07b;
			  9'h119:		keymac[8:0] <= 9'h07b;
			  9'h11a:		keymac[8:0] <= 9'h07b;
			  9'h11b:		keymac[8:0] <= 9'h07b;
			  9'h11c:		keymac[8:0] <= 9'h07b;
			  9'h11d:		keymac[8:0] <= 9'h07b;
			  9'h11e:		keymac[8:0] <= 9'h07b;
			  9'h11f:		keymac[8:0] <= 9'h075;	//WINDOWS OR APPLICATION KEY (option)
			  9'h120:		keymac[8:0] <= 9'h07b;
			  9'h121:		keymac[8:0] <= 9'h07b;
			  9'h122:		keymac[8:0] <= 9'h07b;
			  9'h123:		keymac[8:0] <= 9'h07b;
			  9'h124:		keymac[8:0] <= 9'h07b;
			  9'h125:		keymac[8:0] <= 9'h07b;
			  9'h126:		keymac[8:0] <= 9'h07b;
			  9'h127:		keymac[8:0] <= 9'h07b;
			  9'h128:		keymac[8:0] <= 9'h07b;
			  9'h129:		keymac[8:0] <= 9'h07b;
			  9'h12a:		keymac[8:0] <= 9'h07b;
			  9'h12b:		keymac[8:0] <= 9'h07b;
			  9'h12c:		keymac[8:0] <= 9'h07b;
			  9'h12d:		keymac[8:0] <= 9'h07b;
			  9'h12e:		keymac[8:0] <= 9'h07b;
			  9'h12f:		keymac[8:0] <= 9'h07b;	
			  9'h130:		keymac[8:0] <= 9'h07b;
			  9'h131:		keymac[8:0] <= 9'h07b;
			  9'h132:		keymac[8:0] <= 9'h07b;
			  9'h133:		keymac[8:0] <= 9'h07b;
			  9'h134:		keymac[8:0] <= 9'h07b;
			  9'h135:		keymac[8:0] <= 9'h07b;
			  9'h136:		keymac[8:0] <= 9'h07b;
			  9'h137:		keymac[8:0] <= 9'h07b;
			  9'h138:		keymac[8:0] <= 9'h07b;
			  9'h139:		keymac[8:0] <= 9'h07b;
			  9'h13a:		keymac[8:0] <= 9'h07b;
			  9'h13b:		keymac[8:0] <= 9'h07b;
			  9'h13c:		keymac[8:0] <= 9'h07b;
			  9'h13d:		keymac[8:0] <= 9'h07b;
			  9'h13e:		keymac[8:0] <= 9'h07b;
			  9'h13f:		keymac[8:0] <= 9'h07b;
			  9'h140:		keymac[8:0] <= 9'h07b;
			  9'h141:		keymac[8:0] <= 9'h07b;
			  9'h142:		keymac[8:0] <= 9'h07b;
			  9'h143:		keymac[8:0] <= 9'h07b;
			  9'h144:		keymac[8:0] <= 9'h07b;
			  9'h145:		keymac[8:0] <= 9'h07b;
			  9'h146:		keymac[8:0] <= 9'h07b;
			  9'h147:		keymac[8:0] <= 9'h07b;
			  9'h148:		keymac[8:0] <= 9'h07b;
			  9'h149:		keymac[8:0] <= 9'h07b;
			  9'h14a:		keymac[9:0] <=10'h31b;	//KP /
			  9'h14b:		keymac[8:0] <= 9'h07b;
			  9'h14c:		keymac[8:0] <= 9'h07b;
			  9'h14d:		keymac[8:0] <= 9'h07b;
			  9'h14e:		keymac[8:0] <= 9'h07b;
			  9'h14f:		keymac[8:0] <= 9'h07b;
			  9'h150:		keymac[8:0] <= 9'h07b;
			  9'h151:		keymac[8:0] <= 9'h07b;
			  9'h152:		keymac[8:0] <= 9'h07b;
			  9'h153:		keymac[8:0] <= 9'h07b;
			  9'h154:		keymac[8:0] <= 9'h07b;
			  9'h155:		keymac[8:0] <= 9'h07b;
			  9'h156:		keymac[8:0] <= 9'h07b;
			  9'h157:		keymac[8:0] <= 9'h07b;
			  9'h158:		keymac[8:0] <= 9'h07b;
			  9'h159:		keymac[8:0] <= 9'h07b;
			  9'h15a:		keymac[8:0] <= 9'h119;	//KP ENTER
			  9'h15b:		keymac[8:0] <= 9'h07b;
			  9'h15c:		keymac[8:0] <= 9'h07b;
			  9'h15d:		keymac[8:0] <= 9'h07b;
			  9'h15e:		keymac[8:0] <= 9'h07b;
			  9'h15f:		keymac[8:0] <= 9'h07b;
			  9'h160:		keymac[8:0] <= 9'h07b;
			  9'h161:		keymac[8:0] <= 9'h07b;
			  9'h162:		keymac[8:0] <= 9'h07b;
			  9'h163:		keymac[8:0] <= 9'h07b;
			  9'h164:		keymac[8:0] <= 9'h07b;
			  9'h165:		keymac[8:0] <= 9'h07b;
			  9'h166:		keymac[8:0] <= 9'h07b;
			  9'h167:		keymac[8:0] <= 9'h07b;
			  9'h168:		keymac[8:0] <= 9'h07b;
			  9'h169:		keymac[8:0] <= 9'h07b;	//END
			  9'h16a:		keymac[8:0] <= 9'h07b;
			  9'h16b:		keymac[8:0] <= 9'h10d;	//ARROW LEFT
			  9'h16c:		keymac[8:0] <= 9'h07b;	//HOME
			  9'h16d:		keymac[8:0] <= 9'h07b;
			  9'h16e:		keymac[8:0] <= 9'h07b;
			  9'h16f:		keymac[8:0] <= 9'h07b;
			  9'h170:		keymac[8:0] <= 9'h07b;	//INSERT = HELP
			  9'h171:		keymac[8:0] <= 9'h10f;	//DELETE (KP clear?)
			  9'h172:		keymac[8:0] <= 9'h111;	//ARROW DOWN
			  9'h173:		keymac[8:0] <= 9'h07b;
			  9'h174:		keymac[8:0] <= 9'h105;	//ARROW RIGHT
			  9'h175:		keymac[8:0] <= 9'h11b;	//ARROW UP
			  9'h176:		keymac[8:0] <= 9'h07b;
			  9'h177:		keymac[8:0] <= 9'h07b;
			  9'h178:		keymac[8:0] <= 9'h07b;
			  9'h179:		keymac[8:0] <= 9'h07b;
			  9'h17a:		keymac[8:0] <= 9'h07b;	//PGDN <OSD>
			  9'h17b:		keymac[8:0] <= 9'h07b;
			  9'h17c:		keymac[8:0] <= 9'h07b;	//PRTSCR <OSD>
			  9'h17d:		keymac[8:0] <= 9'h07b;	//PGUP <OSD>
			  9'h17e:		keymac[8:0] <= 9'h07b;	//ctrl+break
			  9'h17f:		keymac[8:0] <= 9'h07b;
			  9'h180:		keymac[8:0] <= 9'h07b;
			  9'h181:		keymac[8:0] <= 9'h07b;
			  9'h182:		keymac[8:0] <= 9'h07b;
			  9'h183:		keymac[8:0] <= 9'h07b;
			  9'h184:		keymac[8:0] <= 9'h07b;
			  9'h185:		keymac[8:0] <= 9'h07b;
			  9'h186:		keymac[8:0] <= 9'h07b;
			  9'h187:		keymac[8:0] <= 9'h07b;
			  9'h188:		keymac[8:0] <= 9'h07b;
			  9'h189:		keymac[8:0] <= 9'h07b;
			  9'h18a:		keymac[8:0] <= 9'h07b;
			  9'h18b:		keymac[8:0] <= 9'h07b;
			  9'h18c:		keymac[8:0] <= 9'h07b;
			  9'h18d:		keymac[8:0] <= 9'h07b;
			  9'h18e:		keymac[8:0] <= 9'h07b;
			  9'h18f:		keymac[8:0] <= 9'h07b;
			  9'h190:		keymac[8:0] <= 9'h07b;
			  9'h191:		keymac[8:0] <= 9'h07b;
			  9'h192:		keymac[8:0] <= 9'h07b;
			  9'h193:		keymac[8:0] <= 9'h07b;
			  9'h194:		keymac[8:0] <= 9'h07b;
			  9'h195:		keymac[8:0] <= 9'h07b;
			  9'h196:		keymac[8:0] <= 9'h07b;
			  9'h197:		keymac[8:0] <= 9'h07b;
			  9'h198:		keymac[8:0] <= 9'h07b;
			  9'h199:		keymac[8:0] <= 9'h07b;
			  9'h19a:		keymac[8:0] <= 9'h07b;
			  9'h19b:		keymac[8:0] <= 9'h07b;
			  9'h19c:		keymac[8:0] <= 9'h07b;
			  9'h19d:		keymac[8:0] <= 9'h07b;
			  9'h19e:		keymac[8:0] <= 9'h07b;
			  9'h19f:		keymac[8:0] <= 9'h07b;
			  9'h1a0:		keymac[8:0] <= 9'h07b;
			  9'h1a1:		keymac[8:0] <= 9'h07b;
			  9'h1a2:		keymac[8:0] <= 9'h07b;
			  9'h1a3:		keymac[8:0] <= 9'h07b;
			  9'h1a4:		keymac[8:0] <= 9'h07b;
			  9'h1a5:		keymac[8:0] <= 9'h07b;
			  9'h1a6:		keymac[8:0] <= 9'h07b;
			  9'h1a7:		keymac[8:0] <= 9'h07b;
			  9'h1a8:		keymac[8:0] <= 9'h07b;
			  9'h1a9:		keymac[8:0] <= 9'h07b;
			  9'h1aa:		keymac[8:0] <= 9'h07b;
			  9'h1ab:		keymac[8:0] <= 9'h07b;
			  9'h1ac:		keymac[8:0] <= 9'h07b;
			  9'h1ad:		keymac[8:0] <= 9'h07b;
			  9'h1ae:		keymac[8:0] <= 9'h07b;
			  9'h1af:		keymac[8:0] <= 9'h07b;
			  9'h1b0:		keymac[8:0] <= 9'h07b;
			  9'h1b1:		keymac[8:0] <= 9'h07b;
			  9'h1b2:		keymac[8:0] <= 9'h07b;
			  9'h1b3:		keymac[8:0] <= 9'h07b;
			  9'h1b4:		keymac[8:0] <= 9'h07b;
			  9'h1b5:		keymac[8:0] <= 9'h07b;
			  9'h1b6:		keymac[8:0] <= 9'h07b;
			  9'h1b7:		keymac[8:0] <= 9'h07b;
			  9'h1b8:		keymac[8:0] <= 9'h07b;
			  9'h1b9:		keymac[8:0] <= 9'h07b;
			  9'h1ba:		keymac[8:0] <= 9'h07b;
			  9'h1bb:		keymac[8:0] <= 9'h07b;
			  9'h1bc:		keymac[8:0] <= 9'h07b;
			  9'h1bd:		keymac[8:0] <= 9'h07b;
			  9'h1be:		keymac[8:0] <= 9'h07b;
			  9'h1bf:		keymac[8:0] <= 9'h07b;
			  9'h1c0:		keymac[8:0] <= 9'h07b;
			  9'h1c1:		keymac[8:0] <= 9'h07b;
			  9'h1c2:		keymac[8:0] <= 9'h07b;
			  9'h1c3:		keymac[8:0] <= 9'h07b;
			  9'h1c4:		keymac[8:0] <= 9'h07b;
			  9'h1c5:		keymac[8:0] <= 9'h07b;
			  9'h1c6:		keymac[8:0] <= 9'h07b;
			  9'h1c7:		keymac[8:0] <= 9'h07b;
			  9'h1c8:		keymac[8:0] <= 9'h07b;
			  9'h1c9:		keymac[8:0] <= 9'h07b;
			  9'h1ca:		keymac[8:0] <= 9'h07b;
			  9'h1cb:		keymac[8:0] <= 9'h07b;
			  9'h1cc:		keymac[8:0] <= 9'h07b;
			  9'h1cd:		keymac[8:0] <= 9'h07b;
			  9'h1ce:		keymac[8:0] <= 9'h07b;
			  9'h1cf:		keymac[8:0] <= 9'h07b;
			  9'h1d0:		keymac[8:0] <= 9'h07b;
			  9'h1d1:		keymac[8:0] <= 9'h07b;
			  9'h1d2:		keymac[8:0] <= 9'h07b;
			  9'h1d3:		keymac[8:0] <= 9'h07b;
			  9'h1d4:		keymac[8:0] <= 9'h07b;
			  9'h1d5:		keymac[8:0] <= 9'h07b;
			  9'h1d6:		keymac[8:0] <= 9'h07b;
			  9'h1d7:		keymac[8:0] <= 9'h07b;
			  9'h1d8:		keymac[8:0] <= 9'h07b;
			  9'h1d9:		keymac[8:0] <= 9'h07b;
			  9'h1da:		keymac[8:0] <= 9'h07b;
			  9'h1db:		keymac[8:0] <= 9'h07b;
			  9'h1dc:		keymac[8:0] <= 9'h07b;
			  9'h1dd:		keymac[8:0] <= 9'h07b;
			  9'h1de:		keymac[8:0] <= 9'h07b;
			  9'h1df:		keymac[8:0] <= 9'h07b;
			  9'h1e0:		keymac[8:0] <= 9'h07b;	//ps2 extended key(duplicate, see $e0)
			  9'h1e1:		keymac[8:0] <= 9'h07b;
			  9'h1e2:		keymac[8:0] <= 9'h07b;
			  9'h1e3:		keymac[8:0] <= 9'h07b;
			  9'h1e4:		keymac[8:0] <= 9'h07b;
			  9'h1e5:		keymac[8:0] <= 9'h07b;
			  9'h1e6:		keymac[8:0] <= 9'h07b;
			  9'h1e7:		keymac[8:0] <= 9'h07b;
			  9'h1e8:		keymac[8:0] <= 9'h07b;
			  9'h1e9:		keymac[8:0] <= 9'h07b;
			  9'h1ea:		keymac[8:0] <= 9'h07b;
			  9'h1eb:		keymac[8:0] <= 9'h07b;
			  9'h1ec:		keymac[8:0] <= 9'h07b;
			  9'h1ed:		keymac[8:0] <= 9'h07b;
			  9'h1ee:		keymac[8:0] <= 9'h07b;
			  9'h1ef:		keymac[8:0] <= 9'h07b;
			  9'h1f0:		keymac[8:0] <= 9'h07b;	//ps2 release code(duplicate, see $f0)
			  9'h1f1:		keymac[8:0] <= 9'h07b;
			  9'h1f2:		keymac[8:0] <= 9'h07b;
			  9'h1f3:		keymac[8:0] <= 9'h07b;
			  9'h1f4:		keymac[8:0] <= 9'h07b;
			  9'h1f5:		keymac[8:0] <= 9'h07b;
			  9'h1f6:		keymac[8:0] <= 9'h07b;
			  9'h1f7:		keymac[8:0] <= 9'h07b;
			  9'h1f8:		keymac[8:0] <= 9'h07b;
			  9'h1f9:		keymac[8:0] <= 9'h07b;
			  9'h1fa:		keymac[8:0] <= 9'h07b;	//ps2 ack code(duplicate see $fa)
			  9'h1fb:		keymac[8:0] <= 9'h07b;
			  9'h1fc:		keymac[8:0] <= 9'h07b;
			  9'h1fd:		keymac[8:0] <= 9'h07b;
			  9'h1fe:		keymac[8:0] <= 9'h07b;
			  9'h1ff:		keymac[8:0] <= 9'h07b;
	 	  endcase // case ({extended,ps2key[7:0]})
		  keymac[7] <= keybreak;
	  end

	// ADB keycodes
	always @(posedge sysclk)
		if (clk_en && got_key) begin
			case({extended,ibyte}) // Scan Code Set 2
			  9'h000:		adbKey[6:0] <= 7'h7F;
			  9'h001:		adbKey[6:0] <= 7'h65;	//F9
			  9'h002:		adbKey[6:0] <= 7'h7F;
			  9'h003:		adbKey[6:0] <= 7'h60;	//F5
			  9'h004:		adbKey[6:0] <= 7'h63;	//F3
			  9'h005:		adbKey[6:0] <= 7'h7A;	//F1
			  9'h006:		adbKey[6:0] <= 7'h78;	//F2
			  9'h007:		adbKey[6:0] <= 7'h7F;//7'h6F;	//F12 <OSD>
			  9'h008:		adbKey[6:0] <= 7'h7F;
			  9'h009:		adbKey[6:0] <= 7'h6D;	//F10
			  9'h00a:		adbKey[6:0] <= 7'h64;	//F8
			  9'h00b:		adbKey[6:0] <= 7'h61;	//F6
			  9'h00c:		adbKey[6:0] <= 7'h76;	//F4
			  9'h00d:		adbKey[6:0] <= 7'h30;	//TAB
			  9'h00e:		adbKey[6:0] <= 7'h32;	//~ (`)
			  9'h00f:		adbKey[6:0] <= 7'h7F;
			  9'h010:		adbKey[6:0] <= 7'h7F;
			  9'h011:		adbKey[6:0] <= 7'h37;	//LEFT ALT (command)
			  9'h012:		adbKey[6:0] <= 7'h38;	//LEFT SHIFT
			  9'h013:		adbKey[6:0] <= 7'h7F;
			  9'h014:		adbKey[6:0] <= 7'h36;	//CTRL
			  9'h015:		adbKey[6:0] <= 7'h0C;	//q
			  9'h016:		adbKey[6:0] <= 7'h12;	//1
			  9'h017:		adbKey[6:0] <= 7'h7F;
			  9'h018:		adbKey[6:0] <= 7'h7F;
			  9'h019:		adbKey[6:0] <= 7'h7F;
			  9'h01a:		adbKey[6:0] <= 7'h06;	//z
			  9'h01b:		adbKey[6:0] <= 7'h01;	//s
			  9'h01c:		adbKey[6:0] <= 7'h00;	//a
			  9'h01d:		adbKey[6:0] <= 7'h0D;	//w
			  9'h01e:		adbKey[6:0] <= 7'h13;	//2
			  9'h01f:		adbKey[6:0] <= 7'h7F;
			  9'h020:		adbKey[6:0] <= 7'h7F;
			  9'h021:		adbKey[6:0] <= 7'h08;	//c
			  9'h022:		adbKey[6:0] <= 7'h07;	//x
			  9'h023:		adbKey[6:0] <= 7'h02;	//d
			  9'h024:		adbKey[6:0] <= 7'h0E;	//e
			  9'h025:		adbKey[6:0] <= 7'h15;	//4
			  9'h026:		adbKey[6:0] <= 7'h14;	//3
			  9'h027:		adbKey[6:0] <= 7'h7F;
			  9'h028:		adbKey[6:0] <= 7'h7F;
			  9'h029:		adbKey[6:0] <= 7'h31;	//SPACE
			  9'h02a:		adbKey[6:0] <= 7'h09;	//v
			  9'h02b:		adbKey[6:0] <= 7'h03;	//f
			  9'h02c:		adbKey[6:0] <= 7'h11;	//t
			  9'h02d:		adbKey[6:0] <= 7'h0F;	//r
			  9'h02e:		adbKey[6:0] <= 7'h17;	//5
			  9'h02f:		adbKey[6:0] <= 7'h7F;
			  9'h030:		adbKey[6:0] <= 7'h7F;
			  9'h031:		adbKey[6:0] <= 7'h2D;	//n
			  9'h032:		adbKey[6:0] <= 7'h0B;	//b
			  9'h033:		adbKey[6:0] <= 7'h04;	//h
			  9'h034:		adbKey[6:0] <= 7'h05;	//g
			  9'h035:		adbKey[6:0] <= 7'h10;	//y
			  9'h036:		adbKey[6:0] <= 7'h16;	//6
			  9'h037:		adbKey[6:0] <= 7'h7F;
			  9'h038:		adbKey[6:0] <= 7'h7F;
			  9'h039:		adbKey[6:0] <= 7'h7F;
			  9'h03a:		adbKey[6:0] <= 7'h2E;	//m
			  9'h03b:		adbKey[6:0] <= 7'h26;	//j
			  9'h03c:		adbKey[6:0] <= 7'h20;	//u
			  9'h03d:		adbKey[6:0] <= 7'h1A;	//7
			  9'h03e:		adbKey[6:0] <= 7'h1C;	//8
			  9'h03f:		adbKey[6:0] <= 7'h7F;
			  9'h040:		adbKey[6:0] <= 7'h7F;
			  9'h041:		adbKey[6:0] <= 7'h2B;	//<,
			  9'h042:		adbKey[6:0] <= 7'h28;	//k
			  9'h043:		adbKey[6:0] <= 7'h22;	//i
			  9'h044:		adbKey[6:0] <= 7'h1F;	//o
			  9'h045:		adbKey[6:0] <= 7'h1D;	//0
			  9'h046:		adbKey[6:0] <= 7'h19;	//9
			  9'h047:		adbKey[6:0] <= 7'h7F;
			  9'h048:		adbKey[6:0] <= 7'h7F;
			  9'h049:		adbKey[6:0] <= 7'h2F;	//>.
			  9'h04a:		adbKey[6:0] <= 7'h2C;	//FORWARD SLASH
			  9'h04b:		adbKey[6:0] <= 7'h25;	//l
			  9'h04c:		adbKey[6:0] <= 7'h29;	//;
			  9'h04d:		adbKey[6:0] <= 7'h23;	//p
			  9'h04e:		adbKey[6:0] <= 7'h1B;	//-
			  9'h04f:		adbKey[6:0] <= 7'h7F;
			  9'h050:		adbKey[6:0] <= 7'h7F;
			  9'h051:		adbKey[6:0] <= 7'h7F;
			  9'h052:		adbKey[6:0] <= 7'h27;	//'"
			  9'h053:		adbKey[6:0] <= 7'h7F;
			  9'h054:		adbKey[6:0] <= 7'h21;	//[
			  9'h055:		adbKey[6:0] <= 7'h18;	// = 
			  9'h056:		adbKey[6:0] <= 7'h7F;
			  9'h057:		adbKey[6:0] <= 7'h7F;
			  9'h058:		adbKey[6:0] <= 7'h39;	//CAPSLOCK
			  9'h059:		adbKey[6:0] <= 7'h7B;	//RIGHT SHIFT
			  9'h05a:		adbKey[6:0] <= 7'h24;	//ENTER
			  9'h05b:		adbKey[6:0] <= 7'h1E;	//]
			  9'h05c:		adbKey[6:0] <= 7'h7F;
			  9'h05d:		adbKey[6:0] <= 7'h2A;	//BACKSLASH
			  9'h05e:		adbKey[6:0] <= 7'h7F;
			  9'h05f:		adbKey[6:0] <= 7'h7F;
			  9'h060:		adbKey[6:0] <= 7'h7F;
			  9'h061:		adbKey[6:0] <= 7'h7F;	//international left shift cut out (German '<>' key), 0x56 Set#1 code
			  9'h062:		adbKey[6:0] <= 7'h7F;
			  9'h063:		adbKey[6:0] <= 7'h7F;
			  9'h064:		adbKey[6:0] <= 7'h7F;
			  9'h065:		adbKey[6:0] <= 7'h7F;
			  9'h066:		adbKey[6:0] <= 7'h33;	//BACKSPACE
			  9'h067:		adbKey[6:0] <= 7'h7F;
			  9'h068:		adbKey[6:0] <= 7'h7F;
			  9'h069:		adbKey[6:0] <= 7'h53;	//KP 1
			  9'h06a:		adbKey[6:0] <= 7'h7F;
			  9'h06b:		adbKey[6:0] <= 7'h56;	//KP 4
			  9'h06c:		adbKey[6:0] <= 7'h59;	//KP 7
			  9'h06d:		adbKey[6:0] <= 7'h7F;
			  9'h06e:		adbKey[6:0] <= 7'h7F;
			  9'h06f:		adbKey[6:0] <= 7'h7F;
			  9'h070:		adbKey[6:0] <= 7'h52;	//KP 0
			  9'h071:		adbKey[6:0] <= 7'h41;	//KP .
			  9'h072:		adbKey[6:0] <= 7'h54;	//KP 2
			  9'h073:		adbKey[6:0] <= 7'h57;	//KP 5
			  9'h074:		adbKey[6:0] <= 7'h58;	//KP 6
			  9'h075:		adbKey[6:0] <= 7'h5B;	//KP 8
			  9'h076:		adbKey[6:0] <= 7'h35;	//ESCAPE
			  9'h077:		adbKey[6:0] <= 7'h47;	//NUMLOCK (Mac keypad clear?)
			  9'h078:		adbKey[6:0] <= 7'h67;	//F11 <OSD>
			  9'h079:		adbKey[6:0] <= 7'h45;	//KP +
			  9'h07a:		adbKey[6:0] <= 7'h55;	//KP 3
			  9'h07b:		adbKey[6:0] <= 7'h4E;	//KP -
			  9'h07c:		adbKey[6:0] <= 7'h43;	//KP *
			  9'h07d:		adbKey[6:0] <= 7'h5C;	//KP 9
			  9'h07e:		adbKey[6:0] <= 7'h7F;	//SCROLL LOCK / KP )
			  9'h07f:		adbKey[6:0] <= 7'h7F;
			  9'h080:		adbKey[6:0] <= 7'h7F;
			  9'h081:		adbKey[6:0] <= 7'h7F;
			  9'h082:		adbKey[6:0] <= 7'h7F;
			  9'h083:		adbKey[6:0] <= 7'h62;	//F7
			  9'h084:		adbKey[6:0] <= 7'h7F;
			  9'h085:		adbKey[6:0] <= 7'h7F;
			  9'h086:		adbKey[6:0] <= 7'h7F;
			  9'h087:		adbKey[6:0] <= 7'h7F;
			  9'h088:		adbKey[6:0] <= 7'h7F;
			  9'h089:		adbKey[6:0] <= 7'h7F;
			  9'h08a:		adbKey[6:0] <= 7'h7F;
			  9'h08b:		adbKey[6:0] <= 7'h7F;
			  9'h08c:		adbKey[6:0] <= 7'h7F;
			  9'h08d:		adbKey[6:0] <= 7'h7F;
			  9'h08e:		adbKey[6:0] <= 7'h7F;
			  9'h08f:		adbKey[6:0] <= 7'h7F;
			  9'h090:		adbKey[6:0] <= 7'h7F;
			  9'h091:		adbKey[6:0] <= 7'h7F;
			  9'h092:		adbKey[6:0] <= 7'h7F;
			  9'h093:		adbKey[6:0] <= 7'h7F;
			  9'h094:		adbKey[6:0] <= 7'h7F;
			  9'h095:		adbKey[6:0] <= 7'h7F;
			  9'h096:		adbKey[6:0] <= 7'h7F;
			  9'h097:		adbKey[6:0] <= 7'h7F;
			  9'h098:		adbKey[6:0] <= 7'h7F;
			  9'h099:		adbKey[6:0] <= 7'h7F;
			  9'h09a:		adbKey[6:0] <= 7'h7F;
			  9'h09b:		adbKey[6:0] <= 7'h7F;
			  9'h09c:		adbKey[6:0] <= 7'h7F;
			  9'h09d:		adbKey[6:0] <= 7'h7F;
			  9'h09e:		adbKey[6:0] <= 7'h7F;
			  9'h09f:		adbKey[6:0] <= 7'h7F;
			  9'h0a0:		adbKey[6:0] <= 7'h7F;
			  9'h0a1:		adbKey[6:0] <= 7'h7F;
			  9'h0a2:		adbKey[6:0] <= 7'h7F;
			  9'h0a3:		adbKey[6:0] <= 7'h7F;
			  9'h0a4:		adbKey[6:0] <= 7'h7F;
			  9'h0a5:		adbKey[6:0] <= 7'h7F;
			  9'h0a6:		adbKey[6:0] <= 7'h7F;
			  9'h0a7:		adbKey[6:0] <= 7'h7F;
			  9'h0a8:		adbKey[6:0] <= 7'h7F;
			  9'h0a9:		adbKey[6:0] <= 7'h7F;
			  9'h0aa:		adbKey[6:0] <= 7'h7F;
			  9'h0ab:		adbKey[6:0] <= 7'h7F;
			  9'h0ac:		adbKey[6:0] <= 7'h7F;
			  9'h0ad:		adbKey[6:0] <= 7'h7F;
			  9'h0ae:		adbKey[6:0] <= 7'h7F;
			  9'h0af:		adbKey[6:0] <= 7'h7F;
			  9'h0b0:		adbKey[6:0] <= 7'h7F;
			  9'h0b1:		adbKey[6:0] <= 7'h7F;
			  9'h0b2:		adbKey[6:0] <= 7'h7F;
			  9'h0b3:		adbKey[6:0] <= 7'h7F;
			  9'h0b4:		adbKey[6:0] <= 7'h7F;
			  9'h0b5:		adbKey[6:0] <= 7'h7F;
			  9'h0b6:		adbKey[6:0] <= 7'h7F;
			  9'h0b7:		adbKey[6:0] <= 7'h7F;
			  9'h0b8:		adbKey[6:0] <= 7'h7F;
			  9'h0b9:		adbKey[6:0] <= 7'h7F;
			  9'h0ba:		adbKey[6:0] <= 7'h7F;
			  9'h0bb:		adbKey[6:0] <= 7'h7F;
			  9'h0bc:		adbKey[6:0] <= 7'h7F;
			  9'h0bd:		adbKey[6:0] <= 7'h7F;
			  9'h0be:		adbKey[6:0] <= 7'h7F;
			  9'h0bf:		adbKey[6:0] <= 7'h7F;
			  9'h0c0:		adbKey[6:0] <= 7'h7F;
			  9'h0c1:		adbKey[6:0] <= 7'h7F;
			  9'h0c2:		adbKey[6:0] <= 7'h7F;
			  9'h0c3:		adbKey[6:0] <= 7'h7F;
			  9'h0c4:		adbKey[6:0] <= 7'h7F;
			  9'h0c5:		adbKey[6:0] <= 7'h7F;
			  9'h0c6:		adbKey[6:0] <= 7'h7F;
			  9'h0c7:		adbKey[6:0] <= 7'h7F;
			  9'h0c8:		adbKey[6:0] <= 7'h7F;
			  9'h0c9:		adbKey[6:0] <= 7'h7F;
			  9'h0ca:		adbKey[6:0] <= 7'h7F;
			  9'h0cb:		adbKey[6:0] <= 7'h7F;
			  9'h0cc:		adbKey[6:0] <= 7'h7F;
			  9'h0cd:		adbKey[6:0] <= 7'h7F;
			  9'h0ce:		adbKey[6:0] <= 7'h7F;
			  9'h0cf:		adbKey[6:0] <= 7'h7F;
			  9'h0d0:		adbKey[6:0] <= 7'h7F;
			  9'h0d1:		adbKey[6:0] <= 7'h7F;
			  9'h0d2:		adbKey[6:0] <= 7'h7F;
			  9'h0d3:		adbKey[6:0] <= 7'h7F;
			  9'h0d4:		adbKey[6:0] <= 7'h7F;
			  9'h0d5:		adbKey[6:0] <= 7'h7F;
			  9'h0d6:		adbKey[6:0] <= 7'h7F;
			  9'h0d7:		adbKey[6:0] <= 7'h7F;
			  9'h0d8:		adbKey[6:0] <= 7'h7F;
			  9'h0d9:		adbKey[6:0] <= 7'h7F;
			  9'h0da:		adbKey[6:0] <= 7'h7F;
			  9'h0db:		adbKey[6:0] <= 7'h7F;
			  9'h0dc:		adbKey[6:0] <= 7'h7F;
			  9'h0dd:		adbKey[6:0] <= 7'h7F;
			  9'h0de:		adbKey[6:0] <= 7'h7F;
			  9'h0df:		adbKey[6:0] <= 7'h7F;
			  9'h0e0:		adbKey[6:0] <= 7'h7F;	//ps2 extended key
			  9'h0e1:		adbKey[6:0] <= 7'h7F;
			  9'h0e2:		adbKey[6:0] <= 7'h7F;
			  9'h0e3:		adbKey[6:0] <= 7'h7F;
			  9'h0e4:		adbKey[6:0] <= 7'h7F;
			  9'h0e5:		adbKey[6:0] <= 7'h7F;
			  9'h0e6:		adbKey[6:0] <= 7'h7F;
			  9'h0e7:		adbKey[6:0] <= 7'h7F;
			  9'h0e8:		adbKey[6:0] <= 7'h7F;
			  9'h0e9:		adbKey[6:0] <= 7'h7F;
			  9'h0ea:		adbKey[6:0] <= 7'h7F;
			  9'h0eb:		adbKey[6:0] <= 7'h7F;
			  9'h0ec:		adbKey[6:0] <= 7'h7F;
			  9'h0ed:		adbKey[6:0] <= 7'h7F;
			  9'h0ee:		adbKey[6:0] <= 7'h7F;
			  9'h0ef:		adbKey[6:0] <= 7'h7F;
			  9'h0f0:		adbKey[6:0] <= 7'h7F;	//ps2 release code
			  9'h0f1:		adbKey[6:0] <= 7'h7F;
			  9'h0f2:		adbKey[6:0] <= 7'h7F;
			  9'h0f3:		adbKey[6:0] <= 7'h7F;
			  9'h0f4:		adbKey[6:0] <= 7'h7F;
			  9'h0f5:		adbKey[6:0] <= 7'h7F;
			  9'h0f6:		adbKey[6:0] <= 7'h7F;
			  9'h0f7:		adbKey[6:0] <= 7'h7F;
			  9'h0f8:		adbKey[6:0] <= 7'h7F;
			  9'h0f9:		adbKey[6:0] <= 7'h7F;
			  9'h0fa:		adbKey[6:0] <= 7'h7F;	//ps2 ack code
			  9'h0fb:		adbKey[6:0] <= 7'h7F;
			  9'h0fc:		adbKey[6:0] <= 7'h7F;
			  9'h0fd:		adbKey[6:0] <= 7'h7F;
			  9'h0fe:		adbKey[6:0] <= 7'h7F;
			  9'h0ff:		adbKey[6:0] <= 7'h7F;
			  9'h100:		adbKey[6:0] <= 7'h7F;
			  9'h101:		adbKey[6:0] <= 7'h7F;
			  9'h102:		adbKey[6:0] <= 7'h7F;
			  9'h103:		adbKey[6:0] <= 7'h7F;
			  9'h104:		adbKey[6:0] <= 7'h7F;
			  9'h105:		adbKey[6:0] <= 7'h7F;
			  9'h106:		adbKey[6:0] <= 7'h7F;
			  9'h107:		adbKey[6:0] <= 7'h7F;
			  9'h108:		adbKey[6:0] <= 7'h7F;
			  9'h109:		adbKey[6:0] <= 7'h7F;
			  9'h10a:		adbKey[6:0] <= 7'h7F;
			  9'h10b:		adbKey[6:0] <= 7'h7F;
			  9'h10c:		adbKey[6:0] <= 7'h7F;
			  9'h10d:		adbKey[6:0] <= 7'h7F;
			  9'h10e:		adbKey[6:0] <= 7'h7F;
			  9'h10f:		adbKey[6:0] <= 7'h7F;
			  9'h110:		adbKey[6:0] <= 7'h7F;
			  9'h111:		adbKey[6:0] <= 7'h37;	//RIGHT ALT (command)
			  9'h112:		adbKey[6:0] <= 7'h7F;
			  9'h113:		adbKey[6:0] <= 7'h7F;
			  9'h114:		adbKey[6:0] <= 7'h7F;
			  9'h115:		adbKey[6:0] <= 7'h7F;
			  9'h116:		adbKey[6:0] <= 7'h7F;
			  9'h117:		adbKey[6:0] <= 7'h7F;
			  9'h118:		adbKey[6:0] <= 7'h7F;
			  9'h119:		adbKey[6:0] <= 7'h7F;
			  9'h11a:		adbKey[6:0] <= 7'h7F;
			  9'h11b:		adbKey[6:0] <= 7'h7F;
			  9'h11c:		adbKey[6:0] <= 7'h7F;
			  9'h11d:		adbKey[6:0] <= 7'h7F;
			  9'h11e:		adbKey[6:0] <= 7'h7F;
			  9'h11f:		adbKey[6:0] <= 7'h3A;	//WINDOWS OR APPLICATION KEY (option)
			  9'h120:		adbKey[6:0] <= 7'h7F;
			  9'h121:		adbKey[6:0] <= 7'h7F;
			  9'h122:		adbKey[6:0] <= 7'h7F;
			  9'h123:		adbKey[6:0] <= 7'h7F;
			  9'h124:		adbKey[6:0] <= 7'h7F;
			  9'h125:		adbKey[6:0] <= 7'h7F;
			  9'h126:		adbKey[6:0] <= 7'h7F;
			  9'h127:		adbKey[6:0] <= 7'h7F;
			  9'h128:		adbKey[6:0] <= 7'h7F;
			  9'h129:		adbKey[6:0] <= 7'h7F;
			  9'h12a:		adbKey[6:0] <= 7'h7F;
			  9'h12b:		adbKey[6:0] <= 7'h7F;
			  9'h12c:		adbKey[6:0] <= 7'h7F;
			  9'h12d:		adbKey[6:0] <= 7'h7F;
			  9'h12e:		adbKey[6:0] <= 7'h7F;
			  9'h12f:		adbKey[6:0] <= 7'h7F;	
			  9'h130:		adbKey[6:0] <= 7'h7F;
			  9'h131:		adbKey[6:0] <= 7'h7F;
			  9'h132:		adbKey[6:0] <= 7'h7F;
			  9'h133:		adbKey[6:0] <= 7'h7F;
			  9'h134:		adbKey[6:0] <= 7'h7F;
			  9'h135:		adbKey[6:0] <= 7'h7F;
			  9'h136:		adbKey[6:0] <= 7'h7F;
			  9'h137:		adbKey[6:0] <= 7'h7F;
			  9'h138:		adbKey[6:0] <= 7'h7F;
			  9'h139:		adbKey[6:0] <= 7'h7F;
			  9'h13a:		adbKey[6:0] <= 7'h7F;
			  9'h13b:		adbKey[6:0] <= 7'h7F;
			  9'h13c:		adbKey[6:0] <= 7'h7F;
			  9'h13d:		adbKey[6:0] <= 7'h7F;
			  9'h13e:		adbKey[6:0] <= 7'h7F;
			  9'h13f:		adbKey[6:0] <= 7'h7F;
			  9'h140:		adbKey[6:0] <= 7'h7F;
			  9'h141:		adbKey[6:0] <= 7'h7F;
			  9'h142:		adbKey[6:0] <= 7'h7F;
			  9'h143:		adbKey[6:0] <= 7'h7F;
			  9'h144:		adbKey[6:0] <= 7'h7F;
			  9'h145:		adbKey[6:0] <= 7'h7F;
			  9'h146:		adbKey[6:0] <= 7'h7F;
			  9'h147:		adbKey[6:0] <= 7'h7F;
			  9'h148:		adbKey[6:0] <= 7'h7F;
			  9'h149:		adbKey[6:0] <= 7'h7F;
			  9'h14a:		adbKey[6:0] <= 7'h4B;	//KP /
			  9'h14b:		adbKey[6:0] <= 7'h7F;
			  9'h14c:		adbKey[6:0] <= 7'h7F;
			  9'h14d:		adbKey[6:0] <= 7'h7F;
			  9'h14e:		adbKey[6:0] <= 7'h7F;
			  9'h14f:		adbKey[6:0] <= 7'h7F;
			  9'h150:		adbKey[6:0] <= 7'h7F;
			  9'h151:		adbKey[6:0] <= 7'h7F;
			  9'h152:		adbKey[6:0] <= 7'h7F;
			  9'h153:		adbKey[6:0] <= 7'h7F;
			  9'h154:		adbKey[6:0] <= 7'h7F;
			  9'h155:		adbKey[6:0] <= 7'h7F;
			  9'h156:		adbKey[6:0] <= 7'h7F;
			  9'h157:		adbKey[6:0] <= 7'h7F;
			  9'h158:		adbKey[6:0] <= 7'h7F;
			  9'h159:		adbKey[6:0] <= 7'h7F;
			  9'h15a:		adbKey[6:0] <= 7'h4C;	//KP ENTER
			  9'h15b:		adbKey[6:0] <= 7'h7F;
			  9'h15c:		adbKey[6:0] <= 7'h7F;
			  9'h15d:		adbKey[6:0] <= 7'h7F;
			  9'h15e:		adbKey[6:0] <= 7'h7F;
			  9'h15f:		adbKey[6:0] <= 7'h7F;
			  9'h160:		adbKey[6:0] <= 7'h7F;
			  9'h161:		adbKey[6:0] <= 7'h7F;
			  9'h162:		adbKey[6:0] <= 7'h7F;
			  9'h163:		adbKey[6:0] <= 7'h7F;
			  9'h164:		adbKey[6:0] <= 7'h7F;
			  9'h165:		adbKey[6:0] <= 7'h7F;
			  9'h166:		adbKey[6:0] <= 7'h7F;
			  9'h167:		adbKey[6:0] <= 7'h7F;
			  9'h168:		adbKey[6:0] <= 7'h7F;
			  9'h169:		adbKey[6:0] <= 7'h77;	//END
			  9'h16a:		adbKey[6:0] <= 7'h7F;
			  9'h16b:		adbKey[6:0] <= 7'h3B;	//ARROW LEFT
			  9'h16c:		adbKey[6:0] <= 7'h73;	//HOME
			  9'h16d:		adbKey[6:0] <= 7'h7F;
			  9'h16e:		adbKey[6:0] <= 7'h7F;
			  9'h16f:		adbKey[6:0] <= 7'h7F;
			  9'h170:		adbKey[6:0] <= 7'h72;	//INSERT = HELP
			  9'h171:		adbKey[6:0] <= 7'h75;	//DELETE (KP clear?)
			  9'h172:		adbKey[6:0] <= 7'h3D;	//ARROW DOWN
			  9'h173:		adbKey[6:0] <= 7'h7F;
			  9'h174:		adbKey[6:0] <= 7'h3C;	//ARROW RIGHT
			  9'h175:		adbKey[6:0] <= 7'h3E;	//ARROW UP
			  9'h176:		adbKey[6:0] <= 7'h7F;
			  9'h177:		adbKey[6:0] <= 7'h7F;
			  9'h178:		adbKey[6:0] <= 7'h7F;
			  9'h179:		adbKey[6:0] <= 7'h7F;
			  9'h17a:		adbKey[6:0] <= 7'h79;	//PGDN <OSD>
			  9'h17b:		adbKey[6:0] <= 7'h7F;
			  9'h17c:		adbKey[6:0] <= 7'h69;	//PRTSCR (F13)
			  9'h17d:		adbKey[6:0] <= 7'h74;	//PGUP <OSD>
			  9'h17e:		adbKey[6:0] <= 7'h71;	//ctrl+break (F15)
			  9'h17f:		adbKey[6:0] <= 7'h7F;
			  9'h180:		adbKey[6:0] <= 7'h7F;
			  9'h181:		adbKey[6:0] <= 7'h7F;
			  9'h182:		adbKey[6:0] <= 7'h7F;
			  9'h183:		adbKey[6:0] <= 7'h7F;
			  9'h184:		adbKey[6:0] <= 7'h7F;
			  9'h185:		adbKey[6:0] <= 7'h7F;
			  9'h186:		adbKey[6:0] <= 7'h7F;
			  9'h187:		adbKey[6:0] <= 7'h7F;
			  9'h188:		adbKey[6:0] <= 7'h7F;
			  9'h189:		adbKey[6:0] <= 7'h7F;
			  9'h18a:		adbKey[6:0] <= 7'h7F;
			  9'h18b:		adbKey[6:0] <= 7'h7F;
			  9'h18c:		adbKey[6:0] <= 7'h7F;
			  9'h18d:		adbKey[6:0] <= 7'h7F;
			  9'h18e:		adbKey[6:0] <= 7'h7F;
			  9'h18f:		adbKey[6:0] <= 7'h7F;
			  9'h190:		adbKey[6:0] <= 7'h7F;
			  9'h191:		adbKey[6:0] <= 7'h7F;
			  9'h192:		adbKey[6:0] <= 7'h7F;
			  9'h193:		adbKey[6:0] <= 7'h7F;
			  9'h194:		adbKey[6:0] <= 7'h7F;
			  9'h195:		adbKey[6:0] <= 7'h7F;
			  9'h196:		adbKey[6:0] <= 7'h7F;
			  9'h197:		adbKey[6:0] <= 7'h7F;
			  9'h198:		adbKey[6:0] <= 7'h7F;
			  9'h199:		adbKey[6:0] <= 7'h7F;
			  9'h19a:		adbKey[6:0] <= 7'h7F;
			  9'h19b:		adbKey[6:0] <= 7'h7F;
			  9'h19c:		adbKey[6:0] <= 7'h7F;
			  9'h19d:		adbKey[6:0] <= 7'h7F;
			  9'h19e:		adbKey[6:0] <= 7'h7F;
			  9'h19f:		adbKey[6:0] <= 7'h7F;
			  9'h1a0:		adbKey[6:0] <= 7'h7F;
			  9'h1a1:		adbKey[6:0] <= 7'h7F;
			  9'h1a2:		adbKey[6:0] <= 7'h7F;
			  9'h1a3:		adbKey[6:0] <= 7'h7F;
			  9'h1a4:		adbKey[6:0] <= 7'h7F;
			  9'h1a5:		adbKey[6:0] <= 7'h7F;
			  9'h1a6:		adbKey[6:0] <= 7'h7F;
			  9'h1a7:		adbKey[6:0] <= 7'h7F;
			  9'h1a8:		adbKey[6:0] <= 7'h7F;
			  9'h1a9:		adbKey[6:0] <= 7'h7F;
			  9'h1aa:		adbKey[6:0] <= 7'h7F;
			  9'h1ab:		adbKey[6:0] <= 7'h7F;
			  9'h1ac:		adbKey[6:0] <= 7'h7F;
			  9'h1ad:		adbKey[6:0] <= 7'h7F;
			  9'h1ae:		adbKey[6:0] <= 7'h7F;
			  9'h1af:		adbKey[6:0] <= 7'h7F;
			  9'h1b0:		adbKey[6:0] <= 7'h7F;
			  9'h1b1:		adbKey[6:0] <= 7'h7F;
			  9'h1b2:		adbKey[6:0] <= 7'h7F;
			  9'h1b3:		adbKey[6:0] <= 7'h7F;
			  9'h1b4:		adbKey[6:0] <= 7'h7F;
			  9'h1b5:		adbKey[6:0] <= 7'h7F;
			  9'h1b6:		adbKey[6:0] <= 7'h7F;
			  9'h1b7:		adbKey[6:0] <= 7'h7F;
			  9'h1b8:		adbKey[6:0] <= 7'h7F;
			  9'h1b9:		adbKey[6:0] <= 7'h7F;
			  9'h1ba:		adbKey[6:0] <= 7'h7F;
			  9'h1bb:		adbKey[6:0] <= 7'h7F;
			  9'h1bc:		adbKey[6:0] <= 7'h7F;
			  9'h1bd:		adbKey[6:0] <= 7'h7F;
			  9'h1be:		adbKey[6:0] <= 7'h7F;
			  9'h1bf:		adbKey[6:0] <= 7'h7F;
			  9'h1c0:		adbKey[6:0] <= 7'h7F;
			  9'h1c1:		adbKey[6:0] <= 7'h7F;
			  9'h1c2:		adbKey[6:0] <= 7'h7F;
			  9'h1c3:		adbKey[6:0] <= 7'h7F;
			  9'h1c4:		adbKey[6:0] <= 7'h7F;
			  9'h1c5:		adbKey[6:0] <= 7'h7F;
			  9'h1c6:		adbKey[6:0] <= 7'h7F;
			  9'h1c7:		adbKey[6:0] <= 7'h7F;
			  9'h1c8:		adbKey[6:0] <= 7'h7F;
			  9'h1c9:		adbKey[6:0] <= 7'h7F;
			  9'h1ca:		adbKey[6:0] <= 7'h7F;
			  9'h1cb:		adbKey[6:0] <= 7'h7F;
			  9'h1cc:		adbKey[6:0] <= 7'h7F;
			  9'h1cd:		adbKey[6:0] <= 7'h7F;
			  9'h1ce:		adbKey[6:0] <= 7'h7F;
			  9'h1cf:		adbKey[6:0] <= 7'h7F;
			  9'h1d0:		adbKey[6:0] <= 7'h7F;
			  9'h1d1:		adbKey[6:0] <= 7'h7F;
			  9'h1d2:		adbKey[6:0] <= 7'h7F;
			  9'h1d3:		adbKey[6:0] <= 7'h7F;
			  9'h1d4:		adbKey[6:0] <= 7'h7F;
			  9'h1d5:		adbKey[6:0] <= 7'h7F;
			  9'h1d6:		adbKey[6:0] <= 7'h7F;
			  9'h1d7:		adbKey[6:0] <= 7'h7F;
			  9'h1d8:		adbKey[6:0] <= 7'h7F;
			  9'h1d9:		adbKey[6:0] <= 7'h7F;
			  9'h1da:		adbKey[6:0] <= 7'h7F;
			  9'h1db:		adbKey[6:0] <= 7'h7F;
			  9'h1dc:		adbKey[6:0] <= 7'h7F;
			  9'h1dd:		adbKey[6:0] <= 7'h7F;
			  9'h1de:		adbKey[6:0] <= 7'h7F;
			  9'h1df:		adbKey[6:0] <= 7'h7F;
			  9'h1e0:		adbKey[6:0] <= 7'h7F;	//ps2 extended key(duplicate, see $e0)
			  9'h1e1:		adbKey[6:0] <= 7'h7F;
			  9'h1e2:		adbKey[6:0] <= 7'h7F;
			  9'h1e3:		adbKey[6:0] <= 7'h7F;
			  9'h1e4:		adbKey[6:0] <= 7'h7F;
			  9'h1e5:		adbKey[6:0] <= 7'h7F;
			  9'h1e6:		adbKey[6:0] <= 7'h7F;
			  9'h1e7:		adbKey[6:0] <= 7'h7F;
			  9'h1e8:		adbKey[6:0] <= 7'h7F;
			  9'h1e9:		adbKey[6:0] <= 7'h7F;
			  9'h1ea:		adbKey[6:0] <= 7'h7F;
			  9'h1eb:		adbKey[6:0] <= 7'h7F;
			  9'h1ec:		adbKey[6:0] <= 7'h7F;
			  9'h1ed:		adbKey[6:0] <= 7'h7F;
			  9'h1ee:		adbKey[6:0] <= 7'h7F;
			  9'h1ef:		adbKey[6:0] <= 7'h7F;
			  9'h1f0:		adbKey[6:0] <= 7'h7F;	//ps2 release code(duplicate, see $f0)
			  9'h1f1:		adbKey[6:0] <= 7'h7F;
			  9'h1f2:		adbKey[6:0] <= 7'h7F;
			  9'h1f3:		adbKey[6:0] <= 7'h7F;
			  9'h1f4:		adbKey[6:0] <= 7'h7F;
			  9'h1f5:		adbKey[6:0] <= 7'h7F;
			  9'h1f6:		adbKey[6:0] <= 7'h7F;
			  9'h1f7:		adbKey[6:0] <= 7'h7F;
			  9'h1f8:		adbKey[6:0] <= 7'h7F;
			  9'h1f9:		adbKey[6:0] <= 7'h7F;
			  9'h1fa:		adbKey[6:0] <= 7'h7F;	//ps2 ack code(duplicate see $fa)
			  9'h1fb:		adbKey[6:0] <= 7'h7F;
			  9'h1fc:		adbKey[6:0] <= 7'h7F;
			  9'h1fd:		adbKey[6:0] <= 7'h7F;
			  9'h1fe:		adbKey[6:0] <= 7'h7F;
			  9'h1ff:		adbKey[6:0] <= 7'h7F;
			endcase // case ({extended,ps2key[7:0]})
			if ({extended, ibyte} == 9'h058) begin
				// CAPS LOCK
				if (!keybreak) begin
					adbKey[7] <= capslock;
					adbStrobe <= 1;
				end
			end else begin
				adbKey[7] <= keybreak;
				adbStrobe <= 1;
			end
		end else if (clk_en)
			adbStrobe <= 0;

endmodule
