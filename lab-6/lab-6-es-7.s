.globl _start
.data
    buffer: .string  "test string"
    low:    .byte  'A'
    high:   .byte  'Z'

.text
_start:
    # call contains
    la   a0, buffer
    la   a1, low
    la   a2, high
    lbu  a1, 0(a1)
    lbu  a2, 0(a2)
    jal  ra, contains

    # exit
    li   a7, 10
    ecall

#******************************************
# completare la funzione nel campo di sotto
contains:
    mv t0, a0
loop:
    #Carichiamoci la string nella prima posizione
    lbu t1, 0(t0)
    #if a0 >= zero goto not_found
    beqz t1, not_found
    #if str[i]<low goto next_char
    blt t1, a1, next_char
    #if str[i]>high goto next_char
    bgt t1, a2, next_char

    li a0, 1

    ret
    
next_char:
    addi t0, t0, 1

    j loop
    
not_found:
    li a0, 0
    
    ret

