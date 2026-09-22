%import textio
%import malloc_platform

;
; implements most of the typical C malloc style
; functions.
;
mem {
    %option no_symbol_prefixing, ignore_unused

    const ubyte MIN_RESIZE = sizeof(Mblock) + 1
    const uword NULL = $0000
    uword mempool
    uword mempool_size
    bool started

    struct Mblock {
        uword size
        bool free
        ^^Mblock prev
        ^^Mblock next
    }

    ; start of the pool linked list
    ^^Mblock g_mempool

    ; initial setup.
    ; calling this init() uses ram from the end of the
    ; program to the start of I/O space.
    sub init() {
        uword temp
        ubyte sys_target
        if started return
        mempool = mempool_platform
        mempool_size = MEMPOOL_SIZE
        started = true
        reinit()
    }

    ; manual init by specifying the memory block directly.
    ; end should be the byte *after* the last expected byte
    ; so $9f00 or $d000 instead of $9eff or $cfff respectively.
    sub initm(uword start, uword end) {
        if started return
        ; don't initialize if no space between start/end.
        ; should signal error?
        if end <= (start + MIN_RESIZE + 1) return
        mempool = start
        mempool_size = end - mempool
        started = true
        reinit()
    }

    ; set or reset mempool to defaults
    sub reinit() {
        if not started return
        ; arguably we could skip this clearing to zero.
        sys.memset(mempool, mempool_size, $00)
        g_mempool = mempool
        g_mempool.size = mempool_size
        g_mempool.free = true
        g_mempool.prev = NULL
        g_mempool.next = NULL
    }

    ; calloc returns a pointer to memory initialized
    ; to zero.
    sub calloc(uword elements, uword size) -> uword {
        uword ptr

        ; we should really check against the actual pool size
        ; but make sure we don't wrap a uword
        if elements != 0 and size > (65535 - sizeof(Mblock)) / elements {
            return NULL
        }

        uword temp = elements * size
        ptr = malloc(temp)
        if ptr != NULL {
            sys.memset(ptr, temp, $00)
        }
        return ptr
    }

    ; frees a block and then attempts to merge free blocks
    ; NOTE: do not call twice on the same pointer.  This will
    ; lead to undefined behavior and likely corruption.
    sub free(uword ptr) {
        ^^Mblock memb

        ; don't free $0000 pointers
        if ptr == NULL return

        memb = ptr - sizeof(Mblock)

        ; don't free if it is not in use
        ; try to avoid undefined behavior if free() is called twice.
        ; we don't keep a free list so can't verify if this was freed
        ; already.
        if memb.free != false {
            return
        }
        memb.free = true

        ; attempt to reduce fragmentation
        merge_free_blocks()
    }

    ;
    ; returns a pointer to a free block of size
    ; or null if we don't have free ram
    ;
    sub malloc(uword size) -> uword {
        ^^Mblock memb
        ; we should really check against the actual pool size
        ; but make sure we don't wrap a uword
        if size >= (65535 - sizeof(Mblock)) return NULL

        uword msize = size + sizeof(Mblock)

        ; look for a free block of the requested size
        memb = scan_mem_pool(msize)

        if memb == NULL {
            return memb
        }

        ; no longer free
        memb.free = false

        ; resize the found block to match requested size
        ; rather than returning a large free block for a small request
        resize_mem(memb, msize)

        ; because memb is a ^^Mblock pointer the +1 adds sizeof(Mblock) here.
        ; so we are returning the pointer to usable memory
        return memb+1
    }

    ; merge smaller adjacent blocks together
    ;
    ; NOTE: nxt/nsize are to simplify some statements. 
    ; Writing the merge as "ptr.size += ptr.next.size"
    ; hits a codegen bug (fixed in v12.3.5+ of the compiler) for pointers
    ; that are not in zeropage.  The calculations used the same temporary
    ; variables and did not actually update ptr.size but ptr.next.size.
    sub merge_free_blocks() {
        ^^Mblock ptr
        ^^Mblock nxt
        uword nsize

        ptr = g_mempool
        while ptr != NULL and ptr.next != NULL {
            nxt = ptr.next
            if ptr.free and nxt.free {
                ; combine
                nsize = nxt.size
                ptr.size += nsize
                ptr.next = nxt.next
                ; Make sure we didn't just merge with
                ; the last block. NULL means done
                if ptr.next == NULL break

                ; remove absorbed block reference from its next
                nxt = ptr.next
                nxt.prev = ptr
                ; do another pass on this *same* newly adjusted block
                ; since the new next might be free also
                continue
            }
            ptr = nxt
        }
    }

    ; expand or shrink an allocation
    ; expanding copies data
    ; returns null if we don't have free ram
    ; in that case ptr is still valid
    sub realloc(uword ptr, uword size) -> uword {
        ^^Mblock memb
        uword new_ptr

        ; "implementation specific" behavior but we will
        ; if size == 0, act like free() and return NULL
        if size == 0 {
            free(ptr)
            return NULL
        }

        ; we should really check against the actual pool size
        ; but make sure we don't wrap a uword
        if size >= (65535 - sizeof(Mblock)) return NULL

        uword new_size = size + sizeof(Mblock)

        ; don't realloc $0000 pointers
        if ptr == NULL return NULL

        ; find Mblock pointer from caller's pointer
        memb = ptr - sizeof(Mblock)

        ; don't realloc if requesting the current size
        if new_size == memb.size return ptr

        ; check if this is a request to shrink the allocation
        if new_size < memb.size {
            ; resize the allocation to the requested smaller size
            resize_mem(memb, new_size)
            return ptr
        }

        ; ask for a new block
        new_ptr = malloc(size)

        ; failed to find larger block
        if new_ptr == NULL {
            ; *caller* must correctly handle
            ; realloc failure. (we don't free(ptr) here!)
            return new_ptr
        }

        ; copy the old user memory (not the struct) to new block
        sys.memcopy(ptr, new_ptr, memb.size - sizeof(Mblock))

        ; free old block now
        free(ptr)

        return new_ptr
    }

    ; this should resize if the resulting free block
    ; is larger than sizeof(Mblock) + some amount
    ; size/msize includes requested size + sizeof(Mblock)
    sub resize_mem(^^Mblock ptr, uword msize) {
        ^^Mblock new_block, curr_prev, curr_next
        if (ptr.size - msize) >= MIN_RESIZE {
            curr_prev = ptr.prev
            curr_next = ptr.next
            new_block = (ptr as uword) + msize
            new_block.size = ptr.size - msize
            new_block.free = true
            new_block.prev = ptr
            new_block.next = curr_next
            ptr.size = msize
            ptr.next = new_block
            if curr_next != NULL {
                curr_next.prev = new_block
                if curr_next.free {
                    ; attempt to reduce fragmentation
                    ; comment out due to test failures
                    merge_free_blocks()
                }
            }
        }
}

    sub scan_mem_pool(uword size) -> uword {
        ^^Mblock scanptr, candidate
        uword temp

        ; start at beginning of memory pool
        scanptr = g_mempool
        candidate = NULL

        ; find the first free block that fits
        while scanptr != NULL {
            if scanptr.free and scanptr.size >= size {
                candidate = scanptr
                break
            }
            scanptr = scanptr.next
        }
        ; didn't find any block that fits
        ; we could just return candidate here (aka first match or NULL)
        ;return candidate
        if candidate == NULL return NULL

        ; now look for any better match
        ; find the free block that is closest in size
        while scanptr != NULL {
            if scanptr.free and scanptr.size >= size {
                if scanptr.size < candidate.size {
                    candidate = scanptr
                }
            }
            scanptr = scanptr.next
        }
        return candidate
    }

    ; dumps the mempool linked list
    ; useful for debugging
    sub dump() {
        ^^Mblock temp

        temp = g_mempool
        txt.nl()

        while temp != NULL {
            txt.print("block: ")
            txt.print_uwhex(temp, true)
            txt.spc()
            txt.print_uwhex(temp.size, true)
            txt.spc()
            txt.print_bool(temp.free)
            txt.spc()
            txt.print_uwhex(temp.prev, true)
            txt.spc()
            txt.print_uwhex(temp.next, true)
            txt.nl()
            temp = temp.next
        }
    }
}
