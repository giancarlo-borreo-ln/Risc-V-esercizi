.globl _start
.data
    str1: .string  "first."
    str2: .string  "second."
.text
_start:
    # call strcmp
    la   a0, str1
    la   a1, str2
    jal  ra, strcmp

    #exit
    li   a7, 10
    ecall

#****************************************************
# completare la funzione strcmp nel campo di sotto
strcmp:
loop:
    lbu  t1, 0(a0)
    lbu  t2, 0(a1)

    bne  t1, t2, not_equal
    beqz t1, equal

    addi a0, a0, 1
    addi a1, a1, 1
    j    loop

not_equal:
    li a0, 1
    ret

equal:
    li a0, 0
    ret
