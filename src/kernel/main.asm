org 0x7C00
bits 16

%define ENDL 0x0D, 0x0A

start:
    jmp main

;
; Prints a string to the screen.
; Params:
;   - ds:si points to string
puts:
    ; save registers we will modify
    push si
    push ax

.loop:
    lodsb           ; loads next character in al
    or al, al       ; verify if next character is null?
    jz .done

    mov ah, 0x0e    ; call bios interrupt
    int 0x10        ; call WRITE INTerrupt

    jmp .loop

.done:
    pop ax
    pop si
    ret

; Main method for the juos
main:

    ; setup data segment
    mov ax, 0       ; can't write to ds/es directly
    mov ds, ax      ; set ds to 0
    mov es, ax      ; set es to 0

    ; setup stack
    mov ss, ax      ; stack segment is 0 sized
    mov sp, 0x7C00  ; stack grows downwards

    ; print message
    mov si, msg_hello
    call puts

    hlt

.halt:
    jmp .halt

; DATA SECTION
msg_hello: db 'Hello World!', ENDL, 0

; $-$$ is the length of the program in bytes
times 510 - ($-$$) db 0
; Word AA55 expected by the BIOS in the first sector of the code
dw 0AA55h
