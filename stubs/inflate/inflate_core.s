; inflate_core.s - DEFLATE decompression for the execram "inflate"
; backend's depacker stub.
;
; Derived from Keir Fraser's inflate.S:
;   https://github.com/keirf/Amiga-Stuff/blob/master/inflate/inflate.S
;   commit fdf7f28e6eb8e6084581df083d37d363052527fd (audited 2026-09-11,
;   see docs/LICENSES.md #4 - Unlicense/public domain, no conditions).
;
; Original license notice, preserved verbatim:
;
;   Written & released by Keir Fraser <keir.xen@gmail.com>
;
;   This is free and unencumbered software released into the public
;   domain. See the file COPYING for more details, or visit
;   <http://unlicense.org>.
;
; This file is the upstream source mechanically adapted to assemble
; under vasm's std (GNU-as-style) syntax module, which the upstream
; file is itself written for (0x hex, .macro/.endm) but vasm's std
; module doesn't fully implement - see stubs/inflate/README.md for
; exactly what changed and why (options selected via the C
; preprocessor, GNU-as m68k's auto-sizing j<cc> pseudo-branches made
; explicit, two macros using numeric local labels above 9 - unsupported
; by vasm's std module, confirmed by testing - manually inlined at
; their single call site with named labels instead; and, added later
; (2026-09-12) after a vasm package update regressed even single-digit
; numeric locals, every remaining bare `N:`/`Nb`/`Nf` label renamed to
; a unique name - see README.md item 4 for the full story and how the
; rename was verified byte-identical). No logic was changed: same
; instructions, same order, just different spellings of the same
; things plus two macro bodies pasted inline instead of expanded by
; the assembler.
;
; Preprocessed with: cpp -P -DOPT_STORAGE_OFFSTACK=1 -DOPT_INLINE_FUNCTIONS=0
; (all other options at upstream's own defaults - see the options block
; this stripped, preserved in the upstream file linked above).
;
; Entry point used by stub.s's Depack: `inflate` (A4=output, A5=input,
; A6=*end* of a 2928-byte scratch block, all registers preserved).




                                                                           



                                                              



                                                                    



                                                                      



                                             



                                                                             











static_huffman_prefix:
        .byte 0xff, 0x5b, 0x00, 0x6c, 0x03, 0x36, 0xdb
        .byte 0xb6, 0x6d, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6
        .byte 0xcd, 0xdb, 0xb6, 0x6d, 0xdb, 0xb6, 0x6d
        .byte 0xdb, 0xa8, 0x6d, 0xce, 0x8b, 0x6d, 0x3b




                                                


        
        
        
build_code:
        movem.l d0-d7,-(a6)

        
        moveq   #(16 +1)/2,d1
        moveq   #0,d2
.bc1:   move.l  d2,-(a6)
        dbf     d1,.bc1

        
        subq.w  #1,d0
        move.w  d0,d1
        move.l  a0,a2           
.bc2:   move.b  (a2)+,d2        

        add.b   d2,d2
        addq.w  #1,(a6,d2.w)    

        dbf     d1,.bc2

        
        move.l  a6,a2           
        moveq   #16 -1,d1
        moveq   #0,d2           
        move.w  d2,(a6)         
.bc3:   add.w   (a2),d2
        add.w   d2,d2           
        move.w  d2,(a2)+        
        dbf     d1,.bc3

        
        move.w  d0,d1
        moveq   #127,d4         
        move.l  a0,a2           
.bc4:   moveq   #0,d5
        move.b  (a2)+,d5        
        beq.w     .bc11
        subq.w  #1,d5
        move.w  d5,d6

        add.w   d6,d6
        move.w  (a6,d6.w),d3    
        addq.w  #1,(a6,d6.w)
        move.w  d5,d6


        moveq   #0,d2
.bc5:   lsr.w   #1,d3
        roxl.w  #1,d2
        dbf     d6,.bc5           
        move.b  d2,d3
        add.w   d3,d3           
        move.w  d0,d6
        sub.w   d1,d6           
        cmp.w   (((16 +1)/2)+1)*4+6(a6),d6 
        bls.w     .bc6
        lsl.w   #2,d6           
.bc6:   cmp.b   #9-1,d5
        bcc.w     codelen_gt_8

codelen_le_8: 
        lsl.w   #3,d6
        or.b    d5,d6           
        moveq   #0,d2
        addq.b  #2,d5
        bset    d5,d2           
        move.w  d2,d7
        neg.w   d7
        and.w   #511,d7
        or.w    d7,d3           
.bc7:   move.w  d6,(a1,d3.w)
        sub.w   d2,d3
        bcc.w     .bc7
        bra.w     .bc11

codelen_gt_8: 
        lsr.w   #8,d2
        subq.b  #8,d5           
        lea     (a1,d3.w),a3    

.bc8:
        move.w  (a3),d7         
        bne.w     .bc9
        
        addq.w  #1,d4
        move.w  d4,d7
        bset    #15,d7
        move.w  d7,(a3)         
.bc9:
        lsr.b   #1,d2
        addx.w  d7,d7

        add.w   d7,d7
        lea     (a1,d7.w),a3    

.bc10:  dbf     d5,.bc8

        
        move.w  d6,(a3)         
.bc11:  dbf     d1,.bc4

        lea     (((16 +1)/2)+1)*4(a6),a6
        movem.l (a6)+,d0-d7
        rts

        
        



        
        



stream_next_bits:
SNB_L1: moveq   #0,d0
        cmp.b   d1,d6
        bcc.w     SNB_L2
        move.b  (a5)+,d0
        lsl.l   d6,d0
        or.l    d0,d5           
        addq.b  #8,d6           
        bra.w     SNB_L1
SNB_L2: bset    d1,d0
        subq.w  #1,d0           
        and.w   d5,d0           
        lsr.l   d1,d5           
        sub.b   d1,d6           
        rts

        
        
uncompressed_block:

        
        lsr.w   #3,d6
        sub.w   d6,a5

        
        moveq   #0,d5
        moveq   #0,d6
        
        moveq   #16,d1
        bsr.w    stream_next_bits 
        addq.w  #2,a5           
        bra.w     .ub2              
.ub1:   move.b  (a5)+,(a4)+
.ub2:   dbf     d0,.ub1
        rts





        
        
static_huffman:
        movem.l d5-d6/a5,-(a6)
        moveq   #0,d5
        moveq   #0,d6
        lea     static_huffman_prefix(pc),a5
        move.w  #((((2 +2)+288 +32)+(256*2+((288)-9)*4))+(256*2+((32)-9)*4))/4-2,d0
        bra.w     .dh1

        
        
dynamic_huffman:
        
        move.w  #(((((2 +2)+288 +32)+(256*2+((288)-9)*4))+(256*2+((32)-9)*4))+3*4)/4-2,d0
.dh1:   moveq   #0,d1
.dh2:   move.l  d1,-(a6)
        dbf     d0,.dh2
        
        moveq   #5,d1
        bsr.w    stream_next_bits
        add.w   #257,d0
        move.w  d0,-(a6)
        
        moveq   #5,d1
        bsr.w    stream_next_bits
        addq.w  #1,d0
        move.w  d0,-(a6)
        
        moveq   #4,d1
        bsr.w    stream_next_bits
        addq.w  #4-1,d0         
        
        lea     codelen_order(pc),a1
        lea     (2 +2)(a6),a0   
        moveq   #0,d2
        move.w  d0,d3
.dh3:   moveq   #3,d1
        bsr.w    stream_next_bits
        move.b  (a1)+,d2
        move.b  d0,(a0,d2.w)    
        dbf     d3,.dh3
        
        lea     ((2 +2)+288 +32)(a6),a1
        moveq   #19,d0

        moveq   #127,d1         

        bsr.w    build_code      
        
        move.w  2(a6),d2
        add.w   (a6),d2
        subq.w  #1,d2           
        move.l  a0,a2           
        move.l  a1,a0           
.dh4:   bsr.w stream_next_symbol
        cmp.b   #16,d0
        bcs.w     c_lit
        beq.w     c_16
        cmp.b   #17,d0
        beq.w     c_17
c_18:   
        moveq   #7,d1
        bsr.w    stream_next_bits
        addq.w  #11-3,d0
        bra.w     .dh5
c_17:   
        moveq   #3,d1
        bsr.w    stream_next_bits
.dh5:   moveq   #0,d1
        bra.w     .dh6
c_16:   
        moveq   #2,d1
        bsr.w    stream_next_bits
        move.b  -1(a2),d1
.dh6:   addq.w  #3-1,d0
        sub.w   d0,d2
.dh7:   move.b  d1,(a2)+
        dbf     d0,.dh7
        bra.w     .dh8
c_lit:  
        move.b  d0,(a2)+
.dh8:   dbf     d2,.dh4
        

        
        
        moveq   #0,d0
        move.w  #(256*2+((19)-9)*4)/4-1,d1
.dh9:   move.l  d0,(a0)+
        dbf     d1,.dh9
        

        lea     (2 +2)(a6),a0
        move.w  2(a6),d0

        move.w  #256,d1
        move.w  d1,d4           

        bsr.w    build_code      
        add.w   d0,a0
        lea     (((2 +2)+288 +32)+(256*2+((288)-9)*4))(a6),a1
        move.w  (a6),d0

        moveq   #0,d1           

        bsr.w    build_code      
        
        tst.l   ((((2 +2)+288 +32)+(256*2+((288)-9)*4))+(256*2+((32)-9)*4))+8(a6)
        beq.w     decode_loop
        movem.l ((((2 +2)+288 +32)+(256*2+((288)-9)*4))+(256*2+((32)-9)*4))(a6),d5-d6/a5
        
decode_loop:
        lea     ((2 +2)+288 +32)(a6),a0
        
.dl1:   bsr.w stream_next_symbol 

        cmp.w   d4,d0    

        bcc.w     .dl3       
        
        move.b  d0,(a4)+ 
        bra.w     .dl1       
        
.dl2:
        lea     (((((2 +2)+288 +32)+(256*2+((288)-9)*4))+(256*2+((32)-9)*4))+3*4)(a6),a6
        rts
.dl3:   beq.w     .dl2
        

        lea     ((((((((2 +2)+288 +32)+(256*2+((288)-9)*4))+(256*2+((32)-9)*4))+3*4))+4)+30*4)-257*4(a6),a2
        add.w   d0,a2
        move.w  (a2)+,d1
        bsr.w stream_next_bits
        add.w   (a2),d0
        move.w  d0,d3           
        lea     (((2 +2)+288 +32)+(256*2+((288)-9)*4))(a6),a0
        bsr.w stream_next_symbol 

        lea     (((((((2 +2)+288 +32)+(256*2+((288)-9)*4))+(256*2+((32)-9)*4))+3*4))+4)(a6),a2
        add.w   d0,a2
        move.w  (a2)+,d1
        bsr.w stream_next_bits
        add.w   (a2),d0         
        move.l  a4,a0
        sub.w   d0,a0           

        lsr.w   #1,d3
        bcs.w     .dl5
        subq.w  #1,d3
.dl4:   move.b  (a0)+,(a4)+
.dl5:   move.b  (a0)+,(a4)+

        dbf     d3,.dl4
        bra.w     decode_loop


stream_next_symbol:
        moveq   #0,d0   
        moveq   #7,d1   
        cmp.b   d1,d6   
        bhi.w     SNS_L1     
        
        move.b  (a5)+,d0 
        lsl.w   d6,d0   
        or.w    d0,d5    
        addq.b  #8,d6    
        moveq   #0,d0   
SNS_L1:     
        move.b  d5,d0   

        add.w   d0,d0   
        move.w  (a0,d0.w),d0 

        bpl.w     SNS_L4     
        
        lsr.w   #8,d5
        subq.b  #8,d6           
SNS_L2:     
        subq.b  #1,d6           
        bcc.w     SNS_L3             
        move.b  (a5)+,d5        
        moveq   #7,d6           
SNS_L3: lsr.w   #1,d5           
        addx.w  d0,d0           

        add.w   d0,d0           
        move.w  (a0,d0.w),d0    

        bmi.w     SNS_L2             
        bra.w     SNS_L5             
SNS_L4:     
        and.b   d0,d1   
        addq.b  #1,d1   
        lsr.w   d1,d5    
        sub.b   d1,d6   
        lsr.w   #3,d0     
SNS_L5:                     
        rts


        
                                                                         
build_base_extrabits:

.bbe1:  move.w  d0,d3
        lsr.w   d4,d3
        subq.w  #1,d3
        bcc.w     .bbe2
        moveq   #0,d3
.bbe2:  moveq   #0,d1
        bset    d3,d1    
        sub.w   d1,d2    
        move.w  d2,-(a6)
        move.w  d3,-(a6)
        dbf     d0,.bbe1

        rts


dispatch: 
        .byte uncompressed_block - uncompressed_block
        .byte static_huffman - uncompressed_block
        .byte dynamic_huffman - uncompressed_block

codelen_order: 
        .byte 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15

        
                                                                       
inflate:
        movem.l d0-d6/a0-a5,-(a6)

        
        move.l  #258,d2
        move.l  d2,-(a6)
        addq.w  #1,d2
        moveq   #27,d0
        moveq   #2,d4
        bsr.w    build_base_extrabits

        
        move.w  #32769,d2
        moveq   #29,d0
        moveq   #1,d4
        bsr.w    build_base_extrabits

        
        moveq   #0,d5           
        moveq   #0,d6           

.infl1:
        moveq   #3,d1
        bsr.w    stream_next_bits
        move.l  d0,-(a6)
        
        lsr.b   #1,d0
        move.b  dispatch(pc,d0.w),d0
        lea     uncompressed_block(pc),a0
        jsr     (a0,d0.w)
        
        move.l  (a6)+,d0
        lsr.b   #1,d0
        bcc.w     .infl1

        
        lea     (30+29)*4(a6),a6

        movem.l (a6)+,d0-d6/a0-a5
        rts




