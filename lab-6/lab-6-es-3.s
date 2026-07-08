.globl _start
.data
    size:  .word 8
    array: .word 1,5,3,7,2,6,4,8
    x:     .word 0
    y:     .word 1
    
.text
_start:
    # chiama swap
    la   a0, array
    la   a1, x
    lw   a1, 0(a1)
    la   a2, y
    lw   a2, 0(a2)
    jal  ra, swap
    
    #exit
    li   a7, 10
    ecall

#***************************************************
# completare la funzione swap nel campo di sotto
swap:
    #Per calcolare la posizione di X moltiplico 
    #l'indirizzo di X per 4 e lo aggiungo
    #all'indirizzo dell'array.
    slli t1, a1, 2
    add t2, a0, t1

    #Poi mi carico la word che si trova nella posizione X 
    lw t3, 0(t2)

    #Faccio lo stesso poi anche per Y
    slli t1, a2, 2
    add t4, a0, t1

    lw t5, 0(t4)

    #Poi faccio lo swap
    sw t3, 0(t4)
    sw t5, 0(t2)

    ret
