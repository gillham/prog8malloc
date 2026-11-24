;
; Define platform specific memory block
;
libmem {
%option merge
    const uword MEMPOOL_SIZE  = 2048
    pointer mempool_platform = memory("malloc_pool", MEMPOOL_SIZE, 1)
}
