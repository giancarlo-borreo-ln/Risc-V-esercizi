.globl _start
.data
      buffer: .string  "BADPass4"
.text
_start:
    # call passrules
    la   a0, buffer
    jal  ra, passrules

    #exit
    li   a7, 10
    ecall

#****************************************************
# completare la funzione passrules nel campo di sotto
passrules:
    #Allochiamoci la memoria ed inseriamo le nostre variabili
    addi sp, sp, -32
    #Il return address ci serve per sapere dove tornare dopo
    sw ra, 28(sp)
    #s0 ci servirà per salvare la nostra stringa
    sw s0, 24(sp)
    #s1 ci servirà per contenere l'esito degli uppercase
    sw s1, 20(sp)
    #s2 ci servirà per contenere l'esito dei numeri
    sw s2, 16(sp)
    #Ci salviamo l'indirizzo della stringa in s0 per poterla 
    #recuperare dopo avere fatto la prima chiamata a funzionae
    mv s0, a0
    #a1 = 'A'
    li a1, 0x41
    #a2 = 'Z'
    li a2, 0x5a
    
    #Facciamo la chiamata alla funzione contains
    jal ra, contains

    #Ci salviamo l'esito nel registro s1
    mv s1, a0
    #Ripristiniamo a0 con l'indirizzo della nostra stringa
    mv a0, s0
    #a1 = '0'
    li a1, 0x30
    #a2 = '9'
    li a2, 0x39

    #Facciamo la chiamata alla funzione contains usando 
    #come parametri il buffer originale di prima con la 
    #differenza che ora in a1 e a2 ci sono i due nuovi range
    #ovvero ['0','9']
    jal ra, contains

    
    mv s2, a0
    #return upercase && numbers
    and a0, s1, s2


    #Liberiamo lo stack e ricarichiamo i registri con i loro
    #valori iniziali
    lw ra, 28(sp)
    lw s0, 24(sp)
    lw s1, 20(sp)
    lw s2, 16(sp)

    addi sp, sp, 32

    ret
contains:
    mv t0, a0
loop:
    #Carichiamoci la string nella prima posizione
    lbu t1, 0(t0)
    #if a0 >= zero goto not_found
    beqz t1, not_found
    #if str[i]<low goto next_char
    blt t1, a1, next_char
    #if str[i]>low goto next_char
    bgt t1, a2, next_char

    li a0, 1

    ret
    
next_char:
    addi t0, t0, 1

    j loop
    
not_found:
    li a0, 0
    
    ret

    
    

    
    

    
