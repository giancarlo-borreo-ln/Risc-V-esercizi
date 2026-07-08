#mcm(a,b) = (a*b) / mcd(a,b)
.globl _start
.data
    num1: .word 24
    num2: .word 30
.text
_start:
    # call mcm
    la    a0, num1
    la    a1, num2
    lw    a0, 0(a0)
    lw    a1, 0(a1)     
    jal   ra, mcm

    
    
    #exit
    li    a7, 10
    ecall
mcm:
    #Decrementiamo lo stack pointer
    addi sp, sp, -16
    #Inseriamo il return address e i nostri 2 parametri nello stack
    sw ra, 12(sp)
    sw a0, 8(sp)
    sw a1, 4(sp)

    #Chiamiamo mcd e ci facciamo salvare l'esito in a0
    jal ra, mcd

    #Poi spostiamo in t0 il valore di a0 per la regola dei registri volatili
    mv t0, a0
    #Ora ci carichiamo le 2 word in formato originale in dei registri temporanei
    lw t0, 8(sp)
    lw t1, 4(sp)

    #Ora abbiamo i dati per potere fare questa operazione qui 
    #mcm(a,b) = (a*b) / mcd(a,b)
    mul t3, t0, t1
    div a0, t3, a0

    #Ora ci carichiamo il ra originale per tornare alla posizione giusta
    lw ra, 12(sp)

    #E restituiamo lo spazio allo stack
    addi sp, sp, 16

    #Poi torniamo indietro
    ret

    
    
    
mcd:
mcd_while:
    beq a0, a1, end

    bgt a0, a1, greater_than

    bgt a1, a0, lower_than

    j mcd_while
greater_than:
    sub a0, a0, a1

    j mcd_while
lower_than:
    sub a1, a1, a0 
    
    j mcd_while
end:
    ret

    
