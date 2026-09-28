.globl _start
.data
    str: .string  "My string"
.text
_start:
    # call strlen
    la   a0, str
    jal  ra, strlen

    #exit
    li   a7, 10
    ecall

#****************************************************
# completare la funzione strlen nel campo di sotto
strlen:
    li t0, 0
loop:
    add t1, a0, t0
    lbu t2, 0(t1)
    beqz t2, end
    addi t0, t0, 1

    j loop
end:
    mv a0, t0
    ret
