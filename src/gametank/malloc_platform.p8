;
; Define platform specific memory block
;
mem {
%option merge
    ; General purpose ram is $0600 to $1e00
    ; $1e00 is the start of the banked "highram" reservation.
    const uword MEMPOOL_SIZE  = 1024
    uword mempool_platform = memory("mempool", MEMPOOL_SIZE, 1)
}
