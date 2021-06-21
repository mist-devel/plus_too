# Makefile to compile minivmac and link it against verilog

PROJECT=ncr5380
#MODEL: plus or se
MODEL=se
mk_COptions = -c -Wall -Wmissing-prototypes -Wno-uninitialized -Wundef -Wstrict-prototypes -Os  -Icfg-$(MODEL)/ -Isrc/

# all: $(PROJECT).vcd

all: obj_dir/V$(PROJECT)

run: obj_dir/V$(PROJECT)
	obj_dir/V$(PROJECT)

bld/OSGLUXWN.o : src/OSGLUXWN.c src/STRCNENG.h cfg-$(MODEL)/STRCONST.h src/INTLCHAR.h src/COMOSGLU.h src/CONTROLM.h src/SGLUALSA.h cfg-$(MODEL)/SOUNDGLU.h cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/OSGLUXWN.c" -o "bld/OSGLUXWN.o" $(mk_COptions)
bld/GLOBGLUE.o : src/GLOBGLUE.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/GLOBGLUE.c" -o "bld/GLOBGLUE.o" $(mk_COptions)
bld/M68KITAB.o : src/M68KITAB.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/M68KITAB.c" -o "bld/M68KITAB.o" $(mk_COptions)
bld/MINEM68K.o : src/MINEM68K.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/MINEM68K.c" -o "bld/MINEM68K.o" $(mk_COptions)
bld/VIAEMDEV.o : src/VIAEMDEV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/VIAEMDEV.c" -o "bld/VIAEMDEV.o" $(mk_COptions)
bld/IWMEMDEV.o : src/IWMEMDEV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/IWMEMDEV.c" -o "bld/IWMEMDEV.o" $(mk_COptions)
bld/SCCEMDEV.o : src/SCCEMDEV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/SCCEMDEV.c" -o "bld/SCCEMDEV.o" $(mk_COptions)
bld/RTCEMDEV.o : src/RTCEMDEV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/RTCEMDEV.c" -o "bld/RTCEMDEV.o" $(mk_COptions)
bld/ROMEMDEV.o : src/ROMEMDEV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/ROMEMDEV.c" -o "bld/ROMEMDEV.o" $(mk_COptions)
bld/SCSIEMDV.o : src/SCSIEMDV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/SCSIEMDV.c" -o "bld/SCSIEMDV.o" $(mk_COptions)
bld/SONYEMDV.o : src/SONYEMDV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/SONYEMDV.c" -o "bld/SONYEMDV.o" $(mk_COptions)
bld/SCRNEMDV.o : src/SCRNEMDV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/SCRNEMDV.c" -o "bld/SCRNEMDV.o" $(mk_COptions)
bld/MOUSEMDV.o : src/MOUSEMDV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/MOUSEMDV.c" -o "bld/MOUSEMDV.o" $(mk_COptions)
bld/KBRDEMDV.o : src/KBRDEMDV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/KBRDEMDV.c" -o "bld/KBRDEMDV.o" $(mk_COptions)
bld/SNDEMDEV.o : src/SNDEMDEV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/SNDEMDEV.c" -o "bld/SNDEMDEV.o" $(mk_COptions)
bld/PROGMAIN.o : src/PROGMAIN.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/PROGMAIN.c" -o "bld/PROGMAIN.o" $(mk_COptions)

bld/ADBEMDEV.o : src/ADBEMDEV.c cfg-$(MODEL)/CNFGGLOB.h
	gcc "src/ADBEMDEV.c" -o "bld/ADBEMDEV.o" $(mk_COptions)

ObjFiles = \
	bld/MINEM68K.o \
	bld/OSGLUXWN.o \
	bld/GLOBGLUE.o \
	bld/M68KITAB.o \
	bld/VIAEMDEV.o \
	bld/IWMEMDEV.o \
	bld/SCCEMDEV.o \
	bld/RTCEMDEV.o \
	bld/ROMEMDEV.o \
	bld/SCSIEMDV.o \
	bld/SONYEMDV.o \
	bld/SCRNEMDV.o \
	bld/MOUSEMDV.o \
	bld/SNDEMDEV.o \
	bld/PROGMAIN.o \

ifeq ($(MODEL),se)
	ObjFiles += bld/ADBEMDEV.o
else ifeq ($(MODEL),plus)
	ObjFiles += bld/KBRDEMDV.o
endif

obj_dir/stamp: $(PROJECT).v $(PROJECT)_tb.cpp $(ObjFiles) scsi.v
	verilator -Wall --cc --trace --exe $(PROJECT).v $(PROJECT)_tb.cpp -LDFLAGS "$(ObjFiles:%=../%) -ldl -L/usr/X11R6/lib -lX11"
	touch obj_dir/stamp

obj_dir/V$(PROJECT): obj_dir/stamp
	make -j -C obj_dir/ -f V$(PROJECT).mk V$(PROJECT)

$(PROJECT).vcd: obj_dir/V$(PROJECT)
	obj_dir/V$(PROJECT) # Disk605.dsk

run_hd: obj_dir/V$(PROJECT)
	obj_dir/V$(PROJECT)

run_dsk: obj_dir/V$(PROJECT)
	obj_dir/V$(PROJECT) ssw_6.0.8-1.dsk

run:
	echo "make run_dsk or run_hd"

clean:
	rm -rf obj_dir
	rm -rf bld/*.o
	rm -f  $(PROJECT).vcd
	rm -f *~ 

view: $(PROJECT).vcd
	gtkwave $< $(PROJECT).sav &
