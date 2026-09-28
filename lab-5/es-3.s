.globl _start
.data
    d: .byte '1'
.text
_start:
    # call digit
    la   a0, d
    lbu  a0, 0(a0)
    jal  ra, digit

    #exit
    li   a7, 10
    ecall

#****************************************************
# completare la funzione digit nel campo di sotto
digit:
    li   t0, 48          # Carica in t0 il valore ASCII di '0' (48 in decimale)
    blt  a0, t0, false   # Se il carattere è minore di '0', non è un digit

    li   t0, 57          # Carica in t0 il valore ASCII di '9' (57 in decimale)
    bgt  a0, t0, false   # Se il carattere è maggiore di '9', non è un digit

    li   a0, 1           # Ha superato entrambi i controlli: è un digit
    ret

false:
    li   a0, 0           # Non è un digit
    ret
