.globl _start
.data
    array: .word  1,2,3,4,5,6,7,8,9,10
    size:  .word  10
    
.text
_start:
    # chiama sumarray
    la   a0, array
    la   a1, size
    lw   a1, 0(a1)
    jal  ra, sumarray
    
    #exit
    li   a7, 10
    ecall

#****************************************************
# completare la funzione sumarray nel campo di sotto
sumarray:
    addi sp, sp, -16
    sw ra, 12(sp)
    sw a0, 8(sp)
    #if size==0 goto caso base
    beqz a1, base
    #Chiamata ricorsiva
    addi a1, a1, -1
    addi a0, a0, 4
    jal ra, sumarray
    
    #Fase di risalita e di calcolo
    lw t1, 8(sp)
    lw t2, 0(t1)
    add a0, a0, t2
    
    j end
base:
    li a0, 0
end:	
    lw ra, 12(sp)
    addi sp, sp, 16
    ret
