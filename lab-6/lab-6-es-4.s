# completare la funzione invert nel campo di sotto
invert:
    #Andiamo a liberare della memoria nello stack per inserire 
    #le nostre variabili
    addi sp, sp, -32

    #Andiamo ad inserire i registri che restiuiremo nello stack
    sw   ra, 28(sp)
    sw   s0, 24(sp)
    sw   s1, 20(sp)
    sw   s2, 16(sp)
    sw   s3, 12(sp)
    
    mv s0, a0 #Qui dentro ci sarà l'array
    mv s1, a1 #Qui dentro ci sarà la size
    srli s2, s1, 1 #Qui dentro ci sarà la size/2

    #i = 0
    li s3, 0

loop:
    #if i>size/2 goto end
    bge s3, s2, end
    #Qui sposto l'indirizzo dell'array e size nei registri 
    #che contengono i parametri a0, a1 e a2
    mv a0, s0
    mv a1, s3

    #Calcolo direttamente il size-i-1 e lo salvo in a2
    sub a2, s1, s3
    addi a2, a2, -1

    #Ora che ho tutti i parametri pronti posso fare la chiamata
    #alla funzione swap
    jal ra, swap

    addi s3, s3, 1

    j loop
    
end:
    #Ripristiniamo i valori originali dei registri dallo stack
    lw   ra, 28(sp)
    lw   s0, 24(sp)
    lw   s1, 20(sp)
    lw   s2, 16(sp)
    lw   s3, 12(sp)
    #Liberiamo lo stack e torniamo indietro
    addi sp, sp, 32
    ret
