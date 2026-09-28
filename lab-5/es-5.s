.globl _start
.data
    str:  .string "my long string"
    c:    .byte 'g'
.text
_start:
    # call strchridx
    la   a0, str
    la   a1, c
    lb   a1, 0(a1)
    jal  ra, strchridx

    #exit
    li   a7, 10
    ecall

#****************************************************
# completare la funzione strchr nel campo di sotto
# completare la funzione strchr nel campo di sotto
strchridx:
    #i = 0
    li t0, 0
while:
    #str[i]
    lbu t2, 0(a0)
    #if(str[i] == '\0') return -1 perché siamo al fondo
    beqz t2, does_not_exist
    #str++
    addi a0, a0, 1

    #if(str[i] != c) return i
    beq t2, a1, found 

    #if(str[i] != c) i++
    bne t2, a1, not_found 
    
    j while
found: 
    j end
not_found:
    addi t0, t0, 1

    j while
does_not_exist:
    li t0, -1
    
    j end
end:
    mv a0, t0
    ret
