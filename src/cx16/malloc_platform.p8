;
; Define platform specific memory block
;
mem {
%option merge
    ; I/O starts at $9f00
    uword MEMPOOL_SIZE  = $9f00 - sys.progend()
    uword mempool_platform = sys.progend()
}
