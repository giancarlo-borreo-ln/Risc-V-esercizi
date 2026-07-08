.globl _start

.data        
array: .word 1, 1, 2, 2, 3, 4, 4, 1
x:     .word 0
y:     .word 1
    
.text
_start:
    # chiama equal
    la   a0, array
    la   a1, x
    lw   a1, 0(a1)
    la   a2, y
    lw   a2, 0(a2)
    jal  ra, equal
    
    # exit
    li   a7, 10
    ecall

#***************************************************
# completare la funzione equal nel campo di sotto
equal:
    #Ora dobbiamo calolarci dove nell'array sia il valore x
    #Per fare questo moltiplichiamo il valore di x per 4 e lo 
    #aggiungiamo all'indirizzo dell'array
    slli t1, a1, 2
    add t1, t1, a0

    #Carichiamoci il valore di X in t4
    lw t4, 0(t1)
    
    #Facciamo la stessa cosa per Y
    slli t2, a2, 2
    add t2, t2, a0

    lw t5, 0(t2)
    
    #Ora if array[x] != array[y] va ad end 
    bne t4, t5, not_equal

    #Se è arrivato qui vuole dire che i 2 valori sono uguali allora 
    #return value sarà 1
    li a0, 1
    
    ret
not_equal:
    #Altrimenti il return value sarà 0
    li a0, 0

    ret
    
