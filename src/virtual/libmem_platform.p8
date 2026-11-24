;
; Define platform specific memory block
;
libmem {
%option merge
    const uword MEMPOOL_SIZE  = 2048
    uword mempool_platform = memory("malloc_pool", MEMPOOL_SIZE, 1)
}
