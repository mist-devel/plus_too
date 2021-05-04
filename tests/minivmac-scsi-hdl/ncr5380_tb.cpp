#include <limits>
#include "Vncr5380.h"
#include "verilated.h"
#include "verilated_vcd_c.h"

#include "ncr5380_tb.h"

#define DISKS 2
#define NAME "hdd%d.img"

static FILE *disks[2];

extern "C" unsigned long get_cycles();

static unsigned char buffer[512];

void hexdump(void *data, uint16_t size, uint16_t offset) {
  uint8_t i, b2c;
  uint16_t n=0;
  char *ptr = (char*)data;

  if(!size) return;

  while(size>0) {
    printf("%04x: ", n + offset);

    b2c = (size>16)?16:size;
    for(i=0;i<b2c;i++)      printf("%02x ", 0xff&ptr[i]);
    printf("  ");
    for(i=0;i<(16-b2c);i++) printf("   ");
    for(i=0;i<b2c;i++)      printf("%c", isprint(ptr[i])?ptr[i]:'.');
    printf("\n");
    ptr  += b2c;
    size -= b2c;
    n    += b2c;
  }
}

static void init_disks() {
  int i;
  char name[255];
  for (i=0; i<DISKS; i++) {
    snprintf(name, sizeof(name), NAME, i);
    disks[i] = fopen(name, "r+");
    if(!disks[i]) {
      printf("unable to open dsk %d\n", i);
    }
  }
}

static int load_sec(int index, int dno) {

  if (!disks[dno]) {
    printf("No disk %d\n",dno);
    return 0;
  }

  fseek(disks[dno], 512*index, SEEK_SET);
  if(fread(buffer, 512, 1, disks[dno]) != 1) {
    printf("unable to read dsk\n");
    
    return 0;
  }
  
  //  hexdump(buffer, 32, 0);

  return 1;
}

void save_sec(int index, int len, int dno) {
  if (!disks[dno]) {
    printf("No disk %d\n",dno);
    return;
  }

  fseek(disks[dno], 512*index, SEEK_SET);
  if(fwrite(buffer, 512, len, disks[dno]) != len) {
    printf("unable to write dsk\n");
    return;
  }
}

extern "C" void cpu_stat(void);

static Vncr5380* top = NULL;
static VerilatedVcdC* tfp = NULL;
static int clk = 0;
static int ack_delay = 0;
static int byte_cnt = 0;
static char reading, writing;

static void do_clk(unsigned long n) {
  while(n--) {

    // check for io request
    if((top->io_rd)||(top->io_wr)) {
      if(!ack_delay) {
        if((top->io_rd & 1) == 1) {
          printf("IO RD (0) %d @ %d\n", top->io_lba, clk);
          load_sec(top->io_lba, 0);
          reading = 1;
        }
        if((top->io_rd & 2) == 2) {
          printf("IO RD (1) %d @ %d\n", top->io_lba, clk);
          load_sec(top->io_lba, 1);
          reading = 1;
        }
        if((top->io_wr & 1) == 1) {
          printf("IO WR %d @ %d\n", top->io_lba, clk);
          writing = 1;
        }

        byte_cnt = 0;
        ack_delay = 1200;
      }
    }

    top->io_ack = (ack_delay == 1);

    if((ack_delay > 1) || ((ack_delay == 1) && !reading && !writing))
      ack_delay--;

    if(ack_delay == 1) {
      if(reading && !top->sd_buff_wr && (byte_cnt < 512)) {
        top->sd_buff_dout = buffer[byte_cnt];
        top->sd_buff_wr   = 1;
        top->sd_buff_addr = byte_cnt;
      } else if(writing && top->sd_buff_addr != byte_cnt && (byte_cnt < 512)) {
        top->sd_buff_addr = byte_cnt;
      } else {
        top->sd_buff_wr = 0;

        if(byte_cnt != 512) {
          if(writing == 1) {
            buffer[byte_cnt] = top->sd_buff_din;

            if(byte_cnt == 511) {
              // hexdump(buffer, 512, 0);
              save_sec(top->io_lba, 1, 0);
            }
          }
          byte_cnt = byte_cnt + 1;

        } else {
          reading = writing = 0;
        }
      }
    } else {
      top->sd_buff_wr = 0;
    }

    top->eval();
    tfp->dump(clk++);

    top->clk = 0;

    top->eval();
    tfp->dump(clk++);

    top->clk = 1;
#if 0
    // limit run
    if(clk >= 200000) {
      tfp->close();
      exit(0);
    }
#endif
  }
}

static void verilator_init(void) {
  if(top) return;   // already initialized?

  reading = writing = 0;

  init_disks();

  //   Verilated::commandArgs(argc, NULL);
  top = new Vncr5380;
  Verilated::traceEverOn(true);
  tfp = new VerilatedVcdC;
  top->trace (tfp, 99);
  tfp->open ("ncr5380.vcd");

  // reset
  top->reset = 1;
  top->clk = 1;
  top->bus_cs = 0;
  top->iow = 0;
  top->ior = 0;
  top->bus_rs = 5;
  top->io_ack = 0;

  do_clk(10);

  top->reset = 0;

  do_clk(2);

  top->img_mounted = 1;
  top->img_size = 21020672;
  do_clk(2);
  top->img_mounted = 0;
  do_clk(2);
}

// called from minivmac
unsigned int ncr_poll(unsigned int Data, unsigned int WriteMem, unsigned int addr) {
  verilator_init();

#if 0
  if(WriteMem) {
    printf("WR 0x%x, %x @", addr, Data);
    cpu_stat();
  }
#endif
  
#if 0
  do_clk(get_cycles());
#else
  do_clk(2);  // for simplicity only one clock between any two accesses
#endif
  
  top->bus_cs = 1;
  top->iow = WriteMem;
  top->ior = !WriteMem;
  top->dack = (addr >> 9)&1;
  top->bus_rs = (addr >> 4)&7;
  top->wdata = Data;

  // one clock step
  do_clk(2);

  top->bus_cs = 0;

#if 0
  if(!WriteMem) {
    printf("RD 0x%x = %x @", addr, top->rdata);
    cpu_stat();
  }
#endif

  return top->rdata;
}
