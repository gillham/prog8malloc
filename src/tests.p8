%import libmem
%import math
%import textio

;
; Test suite for the mem{} allocator in libmem.p8.
;
; The tests never modify libmem.p8.  They drive the public API and then
; inspect the resulting block list directly (mem.g_mempool / ^^mem.Mblock)
; to check invariants that the API alone cannot show.
;
; Each test starts from a freshly re-initialised private arena so that
; one failing test cannot cascade into the next.
;
tests {
    %option ignore_unused

    const uword ARENA_SIZE = 1024
    const ubyte HDR = sizeof(mem.Mblock)

    ; fence posted either side of the pool.  libmem must never write
    ; outside the range it was handed, so any change here is a bug that
    ; the block list itself cannot show.
    const ubyte GUARD = 16
    const ubyte GUARD_BYTE = $7E

    ; the whole slab, guard bands included
    uword raw

    ; private heap the tests run on, kept away from the real pool
    uword arena

    ; saved state of the caller's pool so we can hand it back untouched
    uword saved_pool
    uword saved_size

    ubyte passed
    ubyte failed

    ; scratch used by several tests
    uword[16] tp
    uword[16] tz
    uword[8] wsizes = [5, 17, 3, 64, 1, 33, 12, 40]


    ; ------------------------------------------------------------------
    ; entry point
    ; ------------------------------------------------------------------
    sub run_all() {
        raw = memory("test_arena", GUARD + ARENA_SIZE + GUARD, 0)
        arena = raw + GUARD
        saved_pool = mem.mempool
        saved_size = mem.mempool_size
        passed = 0
        failed = 0

        txt.print("libmem test suite")
        txt.nl()
        txt.print("arena=")
        txt.print_uwhex(arena, true)
        txt.print(" size=")
        txt.print_uw(ARENA_SIZE)
        txt.print(" hdr=")
        txt.print_ub(HDR)
        txt.print(" min_resize=")
        txt.print_ub(mem.MIN_RESIZE)
        txt.nl()
        txt.nl()

        t_pool_init()
        t_platform_init()
        t_null_block_write()
        t_initm_validation()
        t_malloc_basic()
        t_malloc_distinct()
        t_write_integrity()
        t_calloc_zero()
        t_calloc_overflow()
        t_free_null()
        t_free_reuse()
        t_coalesce_all()
        t_coalesce_middle()
        t_best_fit()
        t_exhaust_exact()
        t_exhaust_offbyone()
        t_malloc_zero()
        t_malloc_overflow()
        t_realloc_null()
        t_realloc_same()
        t_realloc_grow()
        t_realloc_shrink()
        t_realloc_fail_keeps_old()
        t_realloc_overflow()
        t_realloc_zero()
        t_double_free()
        t_prev_links()
        t_leak_cycle()
        t_stress()

        summary()
        restore_pool()
    }


    ; ------------------------------------------------------------------
    ; harness
    ; ------------------------------------------------------------------

    ; point the allocator at a fresh, zeroed slice of our private arena
    ; and fence everything around it.  the trailing fence starts at the
    ; end of the requested pool, not the end of the slab, so a write one
    ; byte past a small pool is caught just as well as a wild one.
    sub use_arena(uword size) {
        sys.memset(raw, GUARD, GUARD_BYTE)
        mem.started = false
        mem.initm(arena, arena + size)
        ; after initm, because reinit() zeroes the pool it was given
        sys.memset(arena + size, ARENA_SIZE - size + GUARD, GUARD_BYTE)
    }

    ; give the caller back the pool it had before we started
    sub restore_pool() {
        mem.started = false
        mem.initm(saved_pool, saved_pool + saved_size)
    }

    sub ok(bool cond, str name) {
        if cond {
            passed++
            txt.print("  ok   ")
        } else {
            failed++
            txt.print("  FAIL ")
        }
        txt.print(name)
        txt.nl()
    }

    ; report a uword mismatch so a failure shows the actual value
    sub ok_uw(uword actual, uword expect, str name) {
        if actual == expect {
            passed++
            txt.print("  ok   ")
            txt.print(name)
            txt.nl()
        } else {
            failed++
            txt.print("  FAIL ")
            txt.print(name)
            txt.print(" (want ")
            txt.print_uw(expect)
            txt.print(", got ")
            txt.print_uw(actual)
            txt.print(")")
            txt.nl()
        }
    }

    ; structural integrity of the block list
    sub ok_heap(str name) {
        ubyte code = heap_check()
        if code == 0 {
            passed++
            txt.print("  ok   heap after ")
            txt.print(name)
            txt.nl()
        } else {
            failed++
            txt.print("  FAIL heap after ")
            txt.print(name)
            txt.print(": ")
            print_heap_err(code)
            txt.nl()
        }
    }

    sub print_heap_err(ubyte code) {
        when code {
            1 -> txt.print("g_mempool is not the pool start")
            2 -> txt.print("blocks are not contiguous")
            3 -> txt.print("block has a bogus size")
            4 -> txt.print("block list runs past the pool")
            5 -> txt.print("block sizes do not sum to the pool size")
            6 -> txt.print("list too long / looped")
            7 -> txt.print("next block does not point back")
            8 -> txt.print("prev block does not point forward")
            9 -> txt.print("only the head block may have a null prev")
            10 -> txt.print("the fence in front of the arena was overwritten")
            11 -> txt.print("the fence past the end of the pool was overwritten")
            else -> txt.print("unknown")
        }
    }

    sub header(str name) {
        txt.print("- ")
        txt.print(name)
        txt.nl()
    }

    sub summary() {
        txt.nl()
        txt.print("passed: ")
        txt.print_ub(passed)
        txt.print("  failed: ")
        txt.print_ub(failed)
        txt.nl()
        if failed == 0
            txt.print("ALL TESTS PASSED")
        else
            txt.print("THERE WERE FAILURES")
        txt.nl()
    }


    ; ------------------------------------------------------------------
    ; heap inspection helpers
    ;
    ; These read the block list the same way libmem does, but only ever
    ; read from it.
    ; ------------------------------------------------------------------

    ; size field of the header belonging to a user pointer
    sub hdr_size(uword ptr) -> uword {
        ^^mem.Mblock b = ptr - HDR
        return b.size
    }

    sub hdr_free(uword ptr) -> bool {
        ^^mem.Mblock b = ptr - HDR
        return b.free
    }

    ; walk the list and check the invariants that must always hold.
    ; returns 0 when the heap is sound, otherwise an error code.
    ; deliberately guards against a looped list so a corrupt heap
    ; cannot hang the test run.
    sub heap_check() -> ubyte {
        ^^mem.Mblock p
        ^^mem.Mblock nxt
        uword addr
        uword total
        uword guard
        ubyte i

        ; nothing may ever touch the fence in front of the arena
        for i in 0 to GUARD - 1 {
            if @(raw + i) != GUARD_BYTE return 10
        }
        ; ...nor the fence just past the pool currently in use.  skipped
        ; when a test has pointed the allocator somewhere else, e.g. at
        ; the platform pool.
        if mem.mempool == arena {
            for i in 0 to GUARD - 1 {
                if @(mem.mempool + mem.mempool_size + i) != GUARD_BYTE return 11
            }
        }

        p = mem.g_mempool
        if p != mem.mempool return 1

        addr = mem.mempool
        total = 0
        guard = 0

        while p != mem.NULL {
            guard++
            if guard > 400 return 6
            if p != addr return 2
            if p.size < HDR return 3
            if p.size > mem.mempool_size return 3
            total += p.size
            addr = (p as uword) + p.size
            if addr > mem.mempool + mem.mempool_size return 4
            ; back links have to agree with forward links, in both
            ; directions, at every step
            if p.prev == mem.NULL {
                if p != mem.g_mempool return 9
            } else {
                if p.prev.next != p return 8
            }
            nxt = p.next
            if nxt != mem.NULL {
                if nxt.prev != p return 7
            }
            p = nxt
        }

        if total != mem.mempool_size return 5
        return 0
    }

    ; number of adjacent free/free pairs still waiting to be coalesced.
    ; tracked separately from heap_check(): it is a quality problem, not
    ; corruption, and lumping it in would mask real damage.
    sub unmerged_pairs() -> ubyte {
        ^^mem.Mblock p
        ubyte count = 0
        uword guard = 0

        p = mem.g_mempool
        while p != mem.NULL {
            guard++
            if guard > 400 break
            if p.next != mem.NULL {
                if p.free and p.next.free
                    count++
            }
            p = p.next
        }
        return count
    }

    ; number of blocks whose next block does not point back at them.
    ; also a soft check: libmem never reads .prev to make a decision,
    ; so a broken back link is latent rather than fatal.
    sub bad_prev_links() -> ubyte {
        ^^mem.Mblock p
        ubyte count = 0
        uword guard = 0

        p = mem.g_mempool
        while p != mem.NULL {
            guard++
            if guard > 400 break
            if p.next != mem.NULL {
                if p.next.prev != p
                    count++
            }
            p = p.next
        }
        return count
    }

    sub free_blocks() -> ubyte {
        ^^mem.Mblock p
        ubyte count = 0
        uword guard = 0

        p = mem.g_mempool
        while p != mem.NULL {
            guard++
            if guard > 400 break
            if p.free
                count++
            p = p.next
        }
        return count
    }

    sub largest_free() -> uword {
        ^^mem.Mblock p
        uword best = 0
        uword guard = 0

        p = mem.g_mempool
        while p != mem.NULL {
            guard++
            if guard > 400 break
            if p.free and p.size > best
                best = p.size
            p = p.next
        }
        return best
    }

    ; the whole requested range must sit inside the pool, and the block
    ; header must be big enough for what was asked for -- but no bigger
    ; than it has any right to be.
    ;
    ; the upper bound matters as much as the lower one: a block that is
    ; too large still looks perfectly healthy to heap_check(), because
    ; the list stays contiguous and still sums to the pool size.  the
    ; only symptom is that the pool runs out far too early.
    sub alloc_sane(uword ptr, uword size) -> bool {
        if ptr == mem.NULL return false
        if ptr < mem.mempool + HDR return false
        if ptr + size > mem.mempool + mem.mempool_size return false
        if hdr_free(ptr) return false
        if hdr_size(ptr) < size + HDR return false
        ; a block is only left unsplit when the leftover would be
        ; smaller than MIN_RESIZE, so this bound is exact
        if hdr_size(ptr) >= size + HDR + mem.MIN_RESIZE return false
        return true
    }

    sub fill(uword ptr, uword size, ubyte pat) {
        if ptr == mem.NULL return
        if size == 0 return
        sys.memset(ptr, size, pat)
    }

    sub verify(uword ptr, uword size, ubyte pat) -> bool {
        uword i
        if ptr == mem.NULL return false
        if size == 0 return true
        for i in 0 to size - 1 {
            if @(ptr + i) != pat return false
        }
        return true
    }

    sub all_zero(uword ptr, uword size) -> bool {
        return verify(ptr, size, 0)
    }


    ; ------------------------------------------------------------------
    ; tests
    ; ------------------------------------------------------------------

    sub t_pool_init() {
        header("pool init")
        use_arena(ARENA_SIZE)

        ok_uw(mem.mempool, arena, "mempool is the arena start")
        ok_uw(mem.mempool_size, ARENA_SIZE, "mempool_size is end-start")
        ok_uw(mem.g_mempool, arena, "list head is the arena start")
        ok(mem.g_mempool.free, "initial block is free")
        ok_uw(mem.g_mempool.size, ARENA_SIZE, "initial block spans the pool")
        ok_uw(mem.g_mempool.next, mem.NULL, "initial block has no next")
        ok_uw(mem.g_mempool.prev, mem.NULL, "initial block has no prev")
        ok_heap("init")
    }

    ; init() picks the pool from the platform module.  the tests cannot
    ; know the address or the size, only that whatever it picked has to
    ; be a working heap.
    sub t_platform_init() {
        uword p

        header("platform pool via init()")
        mem.started = false
        mem.init()

        ok(mem.started, "init() marks the pool started")
        ok(mem.mempool != mem.NULL, "init() picked a pool address")
        ok(mem.mempool_size >= 64, "init() pool is big enough to be useful")
        ok_uw(mem.g_mempool, mem.mempool, "list head is the pool start")
        ok_uw(mem.g_mempool.size, mem.mempool_size, "initial block spans the pool")
        ok(mem.g_mempool.free, "initial block is free")

        p = mem.malloc(16)
        ok(p != mem.NULL, "malloc(16) works on the platform pool")
        ok(alloc_sane(p, 16), "the platform allocation is sane")
        ok_heap("platform init")
        mem.free(p)
    }

    ; A NULL block pointer must never be written through.  An Mblock at
    ; address zero would cover $0000-$0006, so its prev field is the
    ; word at $0003.  Splitting the last block of the list is the case
    ; where next is NULL, so an allocator that forgets to check leaves
    ; the address of the freshly split off tail block sitting there.
    ;
    ; this is the one failure the arena fences cannot see, because the
    ; damage lands in low memory rather than anywhere near the pool.
    sub t_null_block_write() {
        uword p
        uword newtail

        header("no writes through a NULL block pointer")
        use_arena(ARENA_SIZE)

        ; the pool is a single block, so this split has next == NULL
        p = mem.malloc(10)
        newtail = arena + HDR + 10
        ok(peekw($0003) != newtail, "tail split did not write to NULL.prev")
        ok_uw(hdr_size(p), 10 + HDR, "tail split produced the exact size")

        ; and again further in, where the tail block is not the head
        p = mem.malloc(20)
        newtail = arena + 2 * HDR + 30
        ok(peekw($0003) != newtail, "second tail split did not write to NULL.prev")
        ok_uw(hdr_size(p), 20 + HDR, "second tail split produced the exact size")
        ok_heap("null block write")
    }

    sub t_initm_validation() {
        ubyte i
        ubyte bad

        header("initm argument validation")

        ; a zero length range must be refused, and refusing it must not
        ; write a header into memory that was never handed over
        use_arena(ARENA_SIZE)
        sys.memset(arena, 64, $CC)
        mem.started = false
        mem.initm(arena, arena)
        ok(not mem.started, "initm(x,x) is refused")
        bad = 0
        for i in 0 to HDR - 1 {
            if @(arena + i) != $CC
                bad++
        }
        ok_uw(bad, 0, "initm(x,x) writes no header")

        ; an inverted range would wrap the size to nearly 64K
        mem.started = false
        mem.initm(arena + 100, arena + 50)
        ok(not mem.started, "initm(end<start) is refused")

        ; a pool with no room for a header plus a byte is useless
        mem.started = false
        mem.initm(arena, arena + HDR)
        ok(not mem.started, "initm of a header sized pool is refused")

        ; and a small but legal pool still has to work
        use_arena(64)
        ok(mem.started, "initm of a 64 byte pool is accepted")
        ok_uw(mem.mempool_size, 64, "the 64 byte pool has the right size")
        ok_heap("initm validation")
    }

    sub t_malloc_basic() {
        uword p

        header("malloc basics")
        use_arena(ARENA_SIZE)

        p = mem.malloc(10)
        ok(p != mem.NULL, "malloc(10) returns a pointer")
        ok(alloc_sane(p, 10), "malloc(10) block is sane and in range")
        ok_uw(hdr_size(p), 10 + HDR, "malloc(10) block is exactly 10+hdr")
        ok(not hdr_free(p), "malloc(10) block is marked used")
        ok_uw(p, arena + HDR, "first allocation sits right after its header")
        ok_heap("malloc(10)")
    }

    sub t_malloc_distinct() {
        ubyte i
        ubyte j
        bool allok

        header("allocations do not overlap")
        use_arena(ARENA_SIZE)

        for i in 0 to 7 {
            tz[i] = wsizes[i]
            tp[i] = mem.malloc(tz[i])
        }

        allok = true
        for i in 0 to 7 {
            if not alloc_sane(tp[i], tz[i])
                allok = false
        }
        ok(allok, "all 8 allocations are sane")

        ; every pair of user ranges must be disjoint
        allok = true
        for i in 0 to 6 {
            for j in i + 1 to 7 {
                if tp[i] < tp[j] + tz[j] and tp[j] < tp[i] + tz[i]
                    allok = false
            }
        }
        ok(allok, "no two allocations overlap")
        ok_heap("8 allocations")
    }

    sub t_write_integrity() {
        ubyte i
        bool allok

        header("written data survives other allocations")
        use_arena(ARENA_SIZE)

        for i in 0 to 7 {
            tz[i] = wsizes[i]
            tp[i] = mem.malloc(tz[i])
            fill(tp[i], tz[i], i + 1)
        }

        allok = true
        for i in 0 to 7 {
            if not verify(tp[i], tz[i], i + 1)
                allok = false
        }
        ok(allok, "patterns readable right after writing")

        ; punch holes, then reallocate into them
        for i in 0 to 7 {
            if i & 1 == 0 {
                mem.free(tp[i])
                tp[i] = mem.NULL
            }
        }
        for i in 0 to 7 {
            if tp[i] == mem.NULL {
                tz[i] = wsizes[i]
                tp[i] = mem.malloc(tz[i])
                fill(tp[i], tz[i], $80 + i)
            }
        }

        allok = true
        for i in 0 to 7 {
            if i & 1 == 0 {
                if not verify(tp[i], tz[i], $80 + i)
                    allok = false
            } else {
                if not verify(tp[i], tz[i], i + 1)
                    allok = false
            }
        }
        ok(allok, "survivors intact after free+realloc churn")
        ok_heap("churn")
    }

    sub t_calloc_zero() {
        uword p
        uword q
        uword i
        bool allzero

        header("calloc")
        use_arena(ARENA_SIZE)

        ; dirty the arena first so zeroed memory means something
        p = mem.malloc(200)
        fill(p, 200, $AA)
        mem.free(p)

        q = mem.calloc(10, 10)
        ok(q != mem.NULL, "calloc(10,10) returns a pointer")
        ok(alloc_sane(q, 100), "calloc(10,10) block holds 100 bytes")

        allzero = true
        for i in 0 to 99 {
            if @(q + i) != 0
                allzero = false
        }
        ok(allzero, "calloc memory is zeroed")
        ok_heap("calloc")
    }

    sub t_calloc_overflow() {
        uword p

        header("calloc element*size overflow")
        use_arena(ARENA_SIZE)

        ; 256*256 == 65536, which wraps to 0 in a uword.
        ; it cannot possibly be satisfied, so it must fail.
        p = mem.calloc(256, 256)
        use_arena(ARENA_SIZE)
        ok_uw(p, mem.NULL, "calloc(256,256) rejects the 64K request")

        ; 65535*65535 is the case a 32 bit product cannot catch: it
        ; overflows a signed long as well, so a guard written that way
        ; sees a negative number, waves it through, and the uword
        ; multiply then wraps all the way down to 1.
        p = mem.calloc(65535, 65535)
        use_arena(ARENA_SIZE)
        ok_uw(p, mem.NULL, "calloc(65535,65535) rejects the 4G request")

        ; 40000*60000 likewise overflows 32 bits
        p = mem.calloc(40000, 60000)
        use_arena(ARENA_SIZE)
        ok_uw(p, mem.NULL, "calloc(40000,60000) rejects the 2.4G request")

        ; right on the boundary: 2*32764 == 65528 == the largest value
        ; malloc itself refuses, so this has to come back NULL too
        p = mem.calloc(2, 32764)
        use_arena(ARENA_SIZE)
        ok_uw(p, mem.NULL, "calloc(2,32764) lands on the malloc limit -> NULL")

        p = mem.calloc(1, 65528)
        use_arena(ARENA_SIZE)
        ok_uw(p, mem.NULL, "calloc(1,65528) lands on the malloc limit -> NULL")

        ; 200*300 == 60000, no wrap, simply too big for the arena
        p = mem.calloc(200, 300)
        ok_uw(p, mem.NULL, "calloc(200,300) too big for arena -> NULL")
        ok_heap("failed calloc")

        ; a request the guard must *not* reject
        use_arena(ARENA_SIZE)
        p = mem.calloc(20, 10)
        ok(alloc_sane(p, 200), "calloc(20,10) is still allowed through")
        ok_heap("accepted calloc")
    }

    sub t_free_null() {
        uword before

        header("free(NULL)")
        use_arena(ARENA_SIZE)

        before = mem.g_mempool.size
        mem.free(mem.NULL)
        ok_uw(mem.g_mempool.size, before, "free(NULL) leaves the pool alone")
        ok_heap("free(NULL)")
    }

    sub t_free_reuse() {
        uword p
        uword q

        header("free then reallocate")
        use_arena(ARENA_SIZE)

        p = mem.malloc(50)
        mem.free(p)
        q = mem.malloc(50)
        ok_uw(q, p, "same size request reuses the freed block")
        ok_uw(free_blocks(), 1, "one free block remains (the tail)")
        ok_heap("reuse")
    }

    sub t_coalesce_all() {
        ubyte i

        header("coalescing / leak check")
        use_arena(ARENA_SIZE)

        for i in 0 to 5
            tp[i] = mem.malloc(60)
        for i in 0 to 5
            mem.free(tp[i])

        ok_uw(mem.g_mempool.size, ARENA_SIZE, "forward free rebuilds one whole block")
        ok_uw(mem.g_mempool.next, mem.NULL, "forward free leaves a single block")
        ok(mem.g_mempool.free, "the single block is free")
        ok_heap("forward free")

        use_arena(ARENA_SIZE)
        for i in 0 to 5
            tp[i] = mem.malloc(60)
        for i in 5 downto 0
            mem.free(tp[i])

        ok_uw(mem.g_mempool.size, ARENA_SIZE, "reverse free rebuilds one whole block")
        ok_uw(mem.g_mempool.next, mem.NULL, "reverse free leaves a single block")
        ok_heap("reverse free")
    }

    sub t_coalesce_middle() {
        uword a
        uword b
        uword c
        uword d
        uword p

        header("coalescing adjacent holes only")
        use_arena(ARENA_SIZE)

        a = mem.malloc(100)
        b = mem.malloc(100)
        c = mem.malloc(100)
        d = mem.malloc(100)

        mem.free(b)
        mem.free(c)

        ok_uw(free_blocks(), 2, "b+c merge into one hole, tail is the other")
        ok_uw(unmerged_pairs(), 0, "no adjacent free pair left over")

        ; the merged hole is 2*107 bytes, so a 207 byte request fits it
        p = mem.malloc(207)
        ok_uw(p, b, "merged hole is handed back as one block")
        ok_heap("middle coalesce")

        mem.free(a)
        mem.free(d)
        mem.free(p)
        ok_uw(mem.g_mempool.size, ARENA_SIZE, "everything freed returns the whole pool")
    }

    sub t_best_fit() {
        uword a
        uword b
        uword c
        uword d
        uword e
        uword p

        header("best fit selection")
        use_arena(ARENA_SIZE)

        a = mem.malloc(100)
        b = mem.malloc(20)
        c = mem.malloc(100)
        d = mem.malloc(30)
        e = mem.malloc(100)

        mem.free(b)     ; leaves a 20+hdr hole
        mem.free(d)     ; leaves a 30+hdr hole

        ; a 20 byte request fits both holes and the big tail;
        ; best fit has to pick the 20 byte one
        p = mem.malloc(20)
        ok_uw(p, b, "20 byte request picks the 20 byte hole")

        p = mem.malloc(30)
        ok_uw(p, d, "30 byte request picks the 30 byte hole")
        ok_heap("best fit")
    }

    sub t_exhaust_exact() {
        uword p
        uword q

        header("exact fit of the whole pool")
        use_arena(64)

        ; 64 byte pool, 7 byte header -> 57 usable bytes
        p = mem.malloc(64 - HDR)
        ok(p != mem.NULL, "malloc(pool-hdr) succeeds")
        ok(alloc_sane(p, 64 - HDR), "the maximum allocation is sane")
        ok_uw(hdr_size(p), 64, "it consumes the pool exactly")
        ok_uw(mem.g_mempool.next, mem.NULL, "no leftover split block")
        ok_heap("max allocation")

        q = mem.malloc(1)
        ok_uw(q, mem.NULL, "pool is full, malloc(1) -> NULL")

        mem.free(p)
        ok_uw(largest_free(), 64, "freeing it returns the whole pool")
        ok_heap("after free")
    }

    sub t_exhaust_offbyone() {
        uword p

        header("one byte too many")
        use_arena(64)

        ; needs 65 bytes of pool, only 64 exist
        p = mem.malloc(64 - HDR + 1)
        ok_uw(p, mem.NULL, "malloc(pool-hdr+1) -> NULL")
        ok_uw(mem.g_mempool.size, 64, "failed malloc did not touch the pool")
        ok(mem.g_mempool.free, "pool still free after failed malloc")
        ok_heap("failed malloc")

        ; and the pool is still usable afterwards
        p = mem.malloc(64 - HDR)
        ok(p != mem.NULL, "pool still usable after a failed malloc")
    }

    sub t_malloc_zero() {
        uword p
        uword q

        header("malloc(0)")
        use_arena(ARENA_SIZE)

        p = mem.malloc(0)
        ok_heap("malloc(0)")
        if p != mem.NULL {
            ok_uw(hdr_size(p), HDR, "malloc(0) block carries no usable bytes")
            q = mem.malloc(10)
            ok(q != p, "malloc(0) does not alias the next allocation")
            ok(alloc_sane(q, 10), "the next allocation is still sane")
        } else {
            ok(true, "malloc(0) returned NULL")
            ok(true, "malloc(0) returned NULL")
            ok(true, "malloc(0) returned NULL")
        }
    }

    sub t_malloc_overflow() {
        uword p

        header("malloc size+header overflow")
        use_arena(ARENA_SIZE)

        ; no wrap, just far too big
        p = mem.malloc(60000)
        ok_uw(p, mem.NULL, "malloc(60000) in a 1K arena -> NULL")
        ok_heap("oversized malloc")

        ; 65529+7 wraps to 0, so the size check inside malloc sees a
        ; tiny request. reset the arena straight away: if this returned
        ; a pointer the block list is damaged.
        p = mem.malloc(65529)
        use_arena(ARENA_SIZE)
        ok_uw(p, mem.NULL, "malloc(65529) wraps to 0 bytes -> must be NULL")

        ; 65535+7 wraps to 6
        p = mem.malloc(65535)
        use_arena(ARENA_SIZE)
        ok_uw(p, mem.NULL, "malloc(65535) wraps to 6 bytes -> must be NULL")
    }

    sub t_realloc_null() {
        header("realloc(NULL)")
        use_arena(ARENA_SIZE)

        ok_uw(mem.realloc(mem.NULL, 10), mem.NULL, "realloc(NULL,10) -> NULL")
        ok_heap("realloc(NULL)")
    }

    sub t_realloc_same() {
        uword p
        uword q

        header("realloc to the same size")
        use_arena(ARENA_SIZE)

        p = mem.malloc(10)
        fill(p, 10, $5A)
        q = mem.realloc(p, 10)
        ok_uw(q, p, "same size realloc returns the same pointer")
        ok(verify(q, 10, $5A), "contents unchanged")
        ok_heap("realloc same")
    }

    sub t_realloc_grow() {
        uword p
        uword blocker
        uword q

        header("realloc grow")
        use_arena(ARENA_SIZE)

        p = mem.malloc(10)
        fill(p, 10, $5A)
        blocker = mem.malloc(10)        ; stop p from simply expanding in place
        fill(blocker, 10, $99)

        q = mem.realloc(p, 40)
        ok(q != mem.NULL, "grow returns a pointer")
        ok(alloc_sane(q, 40), "grown block holds 40 bytes")
        ok(verify(q, 10, $5A), "the original 10 bytes were copied over")
        ok(verify(blocker, 10, $99), "the neighbour was not disturbed")
        ok(hdr_free(p), "the old block was released")
        ok_heap("realloc grow")
    }

    sub t_realloc_shrink() {
        uword p
        uword q

        header("realloc shrink")
        use_arena(ARENA_SIZE)

        p = mem.malloc(100)
        fill(p, 100, $3C)
        q = mem.realloc(p, 20)

        ok_uw(q, p, "shrink keeps the same pointer")
        ok_uw(hdr_size(q), 20 + HDR, "block was actually shrunk")
        ok(verify(q, 20, $3C), "the kept bytes survived")
        ok_heap("realloc shrink")
        ok_uw(unmerged_pairs(), 0, "shrink coalesces the tail it gave back")
    }

    sub t_realloc_fail_keeps_old() {
        uword p
        uword q

        header("realloc failure keeps the old block")
        use_arena(128)

        p = mem.malloc(50)
        fill(p, 50, $77)

        q = mem.realloc(p, 200)         ; cannot fit in a 128 byte pool
        ok_uw(q, mem.NULL, "impossible grow -> NULL")
        ok(not hdr_free(p), "the old block is still allocated")
        ok(verify(p, 50, $77), "the old contents are still there")
        ok_heap("failed realloc")
    }

    sub t_realloc_overflow() {
        uword p
        uword q

        header("realloc size+header overflow")
        use_arena(ARENA_SIZE)

        p = mem.malloc(10)

        ; 65535+7 wraps to 6, which looks like a shrink request to
        ; realloc. reset the arena before asserting.
        q = mem.realloc(p, 65535)
        use_arena(ARENA_SIZE)
        ok_uw(q, mem.NULL, "realloc(p,65535) wraps -> must be NULL")

        p = mem.malloc(10)
        q = mem.realloc(p, 60000)
        ok_uw(q, mem.NULL, "realloc to 60000 in a 1K arena -> NULL")
        ok(not hdr_free(p), "old block kept after the failed realloc")
        ok_heap("failed realloc")
    }

    sub t_realloc_zero() {
        uword p

        header("realloc to zero frees")
        use_arena(ARENA_SIZE)

        p = mem.malloc(40)
        ok_uw(mem.realloc(p, 0), mem.NULL, "realloc(p,0) returns NULL")
        ok(hdr_free(p), "realloc(p,0) released the block")
        ok_uw(mem.g_mempool.size, ARENA_SIZE, "the pool is whole again")
        ok_uw(free_blocks(), 1, "exactly one free block left")
        ok_uw(mem.realloc(mem.NULL, 0), mem.NULL, "realloc(NULL,0) -> NULL")
        ok_heap("realloc zero")
    }

    ; only the case libmem can actually detect: the block is still a
    ; node in the list, so the second free can see it is already free.
    ; freeing a pointer whose block has since been coalesced away stays
    ; undefined behaviour by design -- there is no free list to check
    ; it against -- so it is deliberately not tested here.
    sub t_double_free() {
        uword a
        uword b
        uword c
        ubyte before

        header("second free of the same pointer is ignored")
        use_arena(ARENA_SIZE)

        a = mem.malloc(50)
        b = mem.malloc(50)
        c = mem.malloc(50)

        mem.free(b)
        before = free_blocks()
        mem.free(b)

        ok_uw(free_blocks(), before, "the second free changes nothing")
        ok_uw(hdr_size(b), 50 + HDR, "the hole keeps its size")
        ok(not hdr_free(a), "the neighbour before it is still allocated")
        ok(not hdr_free(c), "the neighbour after it is still allocated")
        ok_heap("double free")
    }

    sub t_prev_links() {
        uword a
        uword b
        uword c

        header("prev back links")
        use_arena(ARENA_SIZE)

        a = mem.malloc(100)
        b = mem.malloc(100)
        c = mem.malloc(100)
        ok_uw(bad_prev_links(), 0, "back links intact after plain allocation")

        ; free a middle block, then take a smaller bite out of the hole.
        ; that splits a block which has a next, the case where prev
        ; has to be fixed up on the following block.
        mem.free(b)
        void mem.malloc(40)
        ok_uw(bad_prev_links(), 0, "back links intact after splitting a middle hole")
        ok_heap("prev links")
    }

    sub t_leak_cycle() {
        ubyte round
        ubyte i

        header("repeated alloc/free cycles do not leak")
        use_arena(ARENA_SIZE)

        for round in 0 to 9 {
            for i in 0 to 7 {
                tz[i] = wsizes[i]
                tp[i] = mem.malloc(tz[i])
                fill(tp[i], tz[i], i + 1)
            }
            for i in 0 to 7 {
                mem.free(tp[i])
                tp[i] = mem.NULL
            }
        }

        ok_uw(mem.g_mempool.size, ARENA_SIZE, "pool fully recovered after 10 cycles")
        ok_uw(free_blocks(), 1, "exactly one free block left")
        ok_heap("leak cycle")
    }

    sub t_stress() {
        ubyte slot
        uword iter
        ubyte op
        uword newp
        uword sz
        ubyte code
        uword fail_iter
        ubyte fail_kind
        ubyte worst_unmerged
        ubyte u

        header("randomised stress with content verification")
        use_arena(512)

        for slot in 0 to 15 {
            tp[slot] = mem.NULL
            tz[slot] = 0
        }
        fail_iter = 0
        fail_kind = 0
        worst_unmerged = 0

        for iter in 1 to 1000 {
            slot = math.randrange(16)
            if slot > 15
                slot = 15
            op = math.randrange(5)

            when op {
                0 -> {
                    if tp[slot] == mem.NULL {
                        sz = math.randrangew(40) + 1
                        newp = mem.malloc(sz)
                        if newp != mem.NULL {
                            tp[slot] = newp
                            tz[slot] = sz
                            fill(newp, sz, slot + 1)
                        }
                    }
                }
                1 -> {
                    if tp[slot] == mem.NULL {
                        sz = (math.randrangew(20) + 1) * 2
                        newp = mem.calloc(sz / 2, 2)
                        if newp != mem.NULL {
                            ; calloc owes us zeroed memory every time,
                            ; not just out of a pristine pool
                            if not all_zero(newp, sz) {
                                fail_iter = iter
                                fail_kind = 101
                            }
                            tp[slot] = newp
                            tz[slot] = sz
                            fill(newp, sz, slot + 1)
                        }
                    }
                }
                2 -> {
                    if tp[slot] != mem.NULL {
                        mem.free(tp[slot])
                        tp[slot] = mem.NULL
                        tz[slot] = 0
                    }
                }
                3 -> {
                    ; realloc to zero has to behave exactly like free
                    if tp[slot] != mem.NULL {
                        if mem.realloc(tp[slot], 0) != mem.NULL {
                            fail_iter = iter
                            fail_kind = 102
                        }
                        tp[slot] = mem.NULL
                        tz[slot] = 0
                    }
                }
                else -> {
                    if tp[slot] != mem.NULL {
                        sz = math.randrangew(40) + 1
                        newp = mem.realloc(tp[slot], sz)
                        if newp != mem.NULL {
                            tp[slot] = newp
                            ; a grow only preserves the old bytes,
                            ; so stamp the pattern on the new tail
                            if sz > tz[slot]
                                fill(newp + tz[slot], sz - tz[slot], slot + 1)
                            tz[slot] = sz
                        }
                    }
                }
            }

            if fail_iter == 0 {
                code = heap_check()
                if code != 0 {
                    fail_iter = iter
                    fail_kind = code
                } else if not stress_verify() {
                    fail_iter = iter
                    fail_kind = 100
                }
            }
            if fail_iter != 0
                break
            u = unmerged_pairs()
            if u > worst_unmerged
                worst_unmerged = u
        }

        if fail_iter == 0 {
            ok(true, "1000 random operations kept the heap sound")
        } else {
            failed++
            txt.print("  FAIL stress broke at operation ")
            txt.print_uw(fail_iter)
            txt.print(": ")
            when fail_kind {
                100 -> txt.print("allocation contents were corrupted")
                101 -> txt.print("calloc returned memory that was not zeroed")
                102 -> txt.print("realloc(p,0) did not return NULL")
                else -> print_heap_err(fail_kind)
            }
            txt.nl()
        }

        txt.print("       (worst unmerged free pairs seen: ")
        txt.print_ub(worst_unmerged)
        txt.print(")")
        txt.nl()

        ; drain everything and confirm the pool comes back whole
        for slot in 0 to 15 {
            if tp[slot] != mem.NULL {
                mem.free(tp[slot])
                tp[slot] = mem.NULL
            }
        }
        ok_uw(mem.g_mempool.size, 512, "pool fully recovered after the stress run")
        ok_heap("stress")
    }

    ; every live allocation must still hold its pattern, still be marked
    ; used, and still be a sensible size for what was asked
    sub stress_verify() -> bool {
        ubyte i
        for i in 0 to 15 {
            if tp[i] != mem.NULL {
                if not alloc_sane(tp[i], tz[i]) return false
                if not verify(tp[i], tz[i], i + 1) return false
            }
        }
        return true
    }
}
