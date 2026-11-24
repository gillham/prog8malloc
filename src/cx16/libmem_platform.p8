;
; Define platform specific memory block
;
libmem {
%option merge
    ; I/O starts at $9f00
    uword MEMPOOL_SIZE  = top() - sys.progend()
    uword mempool_platform = sys.progend()

    asmsub top() -> uword @XY {
        %asm {{
            ldx  #$0
            ldy  #$0
            sec
            jsr cbm.MEMTOP
            rts
        }}
    }
}
