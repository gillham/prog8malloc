;
; Define platform specific memory block
;
mem {
%option merge
    ; I/O starts at $d000, then subtract 32 for CX16 virtual registers
    uword MEMPOOL_SIZE  = $cfe0 - sys.progend()
    uword mempool_platform = sys.progend()
}
