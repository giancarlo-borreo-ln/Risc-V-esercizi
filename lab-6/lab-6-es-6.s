.globl _start

.data
array: .word 1,2,3,4,5,4,3,2,1
size:  .word 9
    
.text
_start:
    # chiama palindrome
    la   a0, array
    la   a1, size
    lw   a1, 0(a1)
    jal  ra, palindrome
    
    # exit
    li   a7, 10
    ecall

#*********************************************************
# completare la funzione palindrome nel campo di sotto
palindrome:
    #Andiamo a liberare della memoria nello stack
    addi sp, sp, -32

    #Andiamo ad inserire i valori attuali di 
    #s0, s1 e s2
    sw ra, 28(sp)
    sw s0, 24(sp)
    sw s1, 20(sp)
    sw s2, 16(sp)
    sw s3, 12(sp)
    sw s4, 8(sp)
    #Spostiamo i valori contenuti in a0 e a1
    #in s0 e s1
    mv s0, a0 #Carichiamo l'array in s0
    mv s1, a1 #Carichiamo la dimensione dell'array in s1
    li s2, 0 #i = 0
    #j = 0
    li s3, 0
    #j = size
    add s3, s3, s1
    #j = size - 1
    addi s3, s3, -1
    #Result = 1
    li s4, 1
loop:
    #if i>=j goto end
    bge s2, s3, end

    #Ci spostiamo i valori nei parametri
    mv a0, s0
    mv a1, s2
    mv a2, s3

    jal ra, equal

    and s4, s4, a0

    addi s2, s2, 1
    
    addi s3, s3, -1
    
    j loop
    
end:
    #Liberiamo la memoria
    lw ra, 28(sp)
    lw s0, 24(sp)
    lw s1, 20(sp)
    lw s2, 16(sp)
    lw s3, 12(sp)
    lw s4, 8(sp)

    addi sp, sp, 32

    ret 

# int equal(int array[], int i, int j)
# a0 = indirizzo base dell'array
# a1 = indice i
# a2 = indice j
# Ritorna: 1 in a0 se uguali, 0 in a0 se diversi

equal:
    # --- FASE 1: Calcolo degli offset in parallelo ---
    # Moltiplichiamo gli indici per 4 (dimensione di una word in byte)
    # Usiamo lo shift logico a sinistra (slli) perché è fulmineo.
    slli t0, a1, 2      # t0 = i * 4
    slli t1, a2, 2      # t1 = j * 4

    # --- FASE 2: Calcolo degli indirizzi assoluti ---
    # Sommiamo l'offset all'indirizzo base dell'array.
    add  t0, a0, t0     # t0 punta a array[i]
    add  t1, a0, t1     # t1 punta a array[j]

    # --- FASE 3: Lettura dalla memoria ---
    # Mettiamo le due lw vicine per lanciare le richieste alla RAM simultaneamente
    # riducendo i tempi di stallo (Load-Use Hazard).
    lw   t2, 0(t0)      # t2 = valore di array[i]
    lw   t3, 0(t1)      # t3 = valore di array[j]

    # --- FASE 4: Logica di diramazione (Branch) ---
    # bne (Branch if Not Equal) è perfetto per una "early exit".
    # Se i valori sono diversi, saltiamo subito all'etichetta 'diversi'.
    bne  t2, t3, diversi  

    # Se la CPU non ha saltato, significa che i valori sono UGUALI.
    li   a0, 1          # Scrivo 1 nel vassoio di ritorno
    ret                 # Torno immediatamente al chiamante

diversi:
    # Se la CPU è saltata qui, significa che i valori sono DIVERSI.
    li   a0, 0          # Scrivo 0 nel vassoio di ritorno
    ret                 # Torno al chiamante    
    

