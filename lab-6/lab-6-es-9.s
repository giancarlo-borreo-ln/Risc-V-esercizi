.globl _start
.data
    srcstr: .string  "string to be copied"
    dststr: .string  "destination string is long enough"
.text
_start:
    
    # chiama strcpy    
    la   a0, dststr
    la   a1, srcstr
    jal  ra, strcpy

    #exit
    li   a7, 10
    ecall

#*******************************************************************************
# strlen
# a0 - str
#*******************************************************************************
# usate il vostro codice fatto in precedenza per strlen

#****************************************************
# completare la funzione strcpy nel campo di sotto
strcpy:
    #Andiamo a liberare la memoria per potere inserire
    #il valore dei registri prima della chiamata a questa 
    #funzione
    addi sp, sp, -32
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    sw s3, 12(sp)
    sw s4, 8(sp)

    #Vogliamo salvarci la dststr e la srcstr in modo 
    #che quando andremmo a sovvrascriverle durante la chiamata
    #a funzione non andremmo ad eliminarle
    #Qui dentro c'è la dststr
    mv s0, a0
    #Qui invece la srcstr
    mv s1, a1
    #Questa prima chiamata a funzione controllerà 
    #prima la dststr e quindi il risultato andrà salvato
    #su s3 ovvero m, ho cambiato l'ordine di questa operazione
    #rispetto a il codice fornito in C perché la dststr era già 
    #convenientemente su a0
    jal ra, strlen
    #m = strlen(dst);
    mv s3, a0
    #Ora ci spostiamo in a0 la stringa srcstr così che 
    #possiamo fare la chiamata a funzione con srcstr
    mv a0, s1
    
    jal ra, strlen
    #n = strlen(src)
    mv s2, a0


    #i = 0
    li s4, 0
loop_1:
    #if i >= n goto loop_2
    bge s4, s2, loop_2
    #dst[i] = src[i]
    lbu t0, 0(s1)   
    sb t0, 0(s0)    
    #i++
    addi s4, s4, 1
    #dststr ++ e srcstr ++
    addi s0, s0, 1
    addi s1, s1, 1

    j loop_1
    
loop_2:
    bge s4, s3, end
    
    li t0, 0

    sb t0,0(s0)

    addi s0, s0, 1

    addi s4, s4, 1

    j loop_2
    
end:
    #Restituiamo lo spazio che ci siamo fatti prestare dallo
    #stack prima
    lw ra, 28(sp)
    lw s0, 24(sp)
    lw s1, 20(sp)
    lw s2, 16(sp)
    lw s3, 12(sp)
    lw s4, 8(sp)
    addi sp, sp, 32

    ret

strlen:
    li t0, 0             # t0 farà da contatore (inizializzato a 0)

strlen_loop:
    lbu t1, 0(a0)        # Legge il singolo byte corrente dalla RAM
    beqz t1, strlen_end  # Se il byte è uguale a 0 (terminatore nullo), esce dal ciclo
    
    addi t0, t0, 1       # Incrementa il contatore della lunghezza (+1)
    addi a0, a0, 1       # Sposta il puntatore al byte successivo nella RAM (+1)
    j strlen_loop        # Torna all'inizio del ciclo

strlen_end:
    mv a0, t0            # Sposta la lunghezza finale nel registro di ritorno a0
    ret                  # Ritorna al chiamante (strcpy)
    
