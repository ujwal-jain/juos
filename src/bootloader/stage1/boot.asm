org 0x7C00
bits 16

%define ENDL 0x0D, 0x0A

;
; FAT12 header
;
jmp short start
nop

bdb_oem:                     db 'MSWIN4.1'           ; 8 bytes
bdb_bytes_per_sector:       dw 512
bdb_sectors_per_cluster:    db 1
bdb_reserved_sectors:       dw 1
bdb_fat_count:              db 2
bdb_dir_entries_count:      dw 0E0h                 
bdb_total_sectors:          dw 2880                 ; 2880 * 512 - 1.44MB
bdb_media_descriptor_type:  db 0F0h                 ; F0 = 3.5" floppy disk
bdb_sectors_per_fat:        dw 9                    ; 9 sectors/fat
bdb_sectors_per_track:      dw 18                   ; 18 sectors / track
bdb_heads:                  dw 2
bdb_hidden_sectors:         dd 0
bdb_large_sector_count:     dd 0

; extended boot record
ebr_drive_number:           db 0                    ; 0x00 floppy, 0x80 hdd, useless
                            db 0                    ; reserved
ebr_signature:              db 29h
ebr_volume_id:              db 12h, 34h, 56h, 78h   ; serial number, user-defined
ebr_volume_label:           db '       JUOS'        ; 11 bytes, user-defined
ebr_system_id:              db 'FAT12   '          ; 8 bytes

;
; Code goes here
;

start:
    ; setup data segment
    mov ax, 0                               ; can't write to ds/es directly
    mov ds, ax                              ; set ds to 0
    mov es, ax                              ; set es to 0

    ; setup stack
    mov ss, ax                              ; stack segment is 0 sized
    mov sp, 0x7C00                          ; stack grows downwards

    ; some BIOSes might start us at 07C0:0000 instead of 0000:7C0000
    push es
    push word .after
    retf

.after:

    ; read something from floppy disk
    ; BIOS should set DL to drive number
    mov [ebr_drive_number], dl

    ; print message
    mov si, msg_loading 
    call puts

    ; read drive parameters
    push es
    mov ah, 08h
    int 13h
    jc floppy_error
    pop es

    and cl, 0x3F                            ; remove top 2 bits
    xor ch, ch
    mov [bdb_sectors_per_track], cx         ; sector count

    inc dh                                  ; head count
    mov [bdb_heads], dh

    ; read FAT root directory
    mov ax, [bdb_sectors_per_fat]           ; compute LBA of root directory = reserved + fats * sectors_per_fat 
    mov bl, [bdb_fat_count]
    xor bh, bh
    mul bx                                  
    add ax, [bdb_reserved_sectors]          ; ax = [fats * sectors_per_fat)
    push ax                                 ; ax = LBA of root directory

    ; compuate size of root directory = [32 * # of entries] / bytes_per_sector
    mov ax, [bdb_sectors_per_fat]       
    shl ax, 5                               ; ax *= 32
    xor dx, dx                              ; dx = 0
    div word [bdb_bytes_per_sector]         ; number of sectors we need to read

    test dx, dx                             ; if dx != 0, add 1
    jz .root_dir_after
    inc ax

.root_dir_after:
    
    ; read root directory
    mov cl, al
    pop ax
    mov dl, [ebr_drive_number]
    mov bx, buffer
    call disk_read

    ; search for kernel.bin
    xor bx, bx
    mov di, buffer

.search_kernel:
    mov si, file_kernel_bin
    mov cx, 11                              ; compare 11 characters
    push di
    repe cmpsb
    pop di
    je .found_kernel

    add di, 32
    inc bx
    cmp bx, [bdb_dir_entries_count]
    jl .search_kernel

    ; kernel_not_found error
    jmp kernel_not_found_error

.found_kernel:
    ; di should have the address to the entry
    mov ax, [di + 26]                       ; first logical cluster field
    mov [kernel_cluster], ax

    ; load FAT from disk into memory
    mov ax, [bdb_reserved_sectors]
    mov bx, buffer
    mov cl, [bdb_sectors_per_fat]
    mov dl, [ebr_drive_number]
    call disk_read

    ; read kernel and process FAT chain
    mov bx, KERNEL_LOAD_SEGMENT
    mov es, bx
    mov bx, KERNEL_LOAD_OFFSET

.load_kernel_loop:
    ; Read next cluster
    mov ax, [kernel_cluster]
    add ax, 31

    mov cl, 1
    mov dl, [ebr_drive_number]
    call disk_read

    add bx, [bdb_bytes_per_sector]

    ; compute location of next cluster
    mov ax, [kernel_cluster]
    mov cx, 3
    mul cx
    mov cx, 2
    div cx

    mov si, buffer
    add si, ax
    mov ax, [ds:si]

    or dx, dx
    jz .even

.odd:
    shr ax, 4
    jmp .next_cluster_after

.even:
    and ax, 0x0FFF

.next_cluster_after:
    cmp ax, 0x0FF8
    jae .read_finish

    mov [kernel_cluster], ax
    jmp .load_kernel_loop

.read_finish:
    ; boot defvice in dl
    mov dl, [ebr_drive_number]

    ; set segment registers
    mov ax, KERNEL_LOAD_SEGMENT
    mov ds, ax
    mov es, ax

    jmp KERNEL_LOAD_SEGMENT:KERNEL_LOAD_OFFSET

    jmp wait_key_and_reboot                 ; should never happen

    cli                                     ; disable interrupts, this way we can't get out of "halt" state
    hlt


;
; Error Handlers
;
floppy_error:
    mov si, msg_read_failed
    call puts
    jmp wait_key_and_reboot

kernel_not_found_error:
    mov si, msg_kernel_not_found
    call puts
    jmp wait_key_and_reboot

wait_key_and_reboot:
    mov ah, 0
    int 16h                             ; wait for keypress
    jmp 0FFFFh:0                         ; jump to beginning of BIOS, should reboot

.halt:
    cli                                     ; disable interrupts, this way we can't get out of "halt" state
    hlt

;
; Prints a string to the screen.
; Params:
;   - ds:si points to string
puts:
    ; save registers we will modify
    push si
    push ax
    push bx

.loop:
    lodsb           ; loads next character in al
    or al, al       ; verify if next character is null?
    jz .done

    mov ah, 0x0e    ; call bios interrupt
    mov bh, 0       ; set page number to 0
    int 0x10        ; call WRITE INTerrupt

    jmp .loop

.done:
    pop bx
    pop ax
    pop si
    ret

; 
; Disk Routines
;

;
; Converts an LBA address to a CHS address
; Parameters:
;   - ax: LBA address
; Returns:
;   - cx [bits 0-5]: sector number
;   - cx [bits 6-15]: cylinder
;   - dh: head
;
lba_to_chs:

    push ax
    push dx

    xor dx, dx                          ; dx = 0
    div word [bdb_sectors_per_track]    ; ax = LBA / SectorsPerTrack
                                        ; dx = LBA % SectorsPerTrack
    inc dx                              ; dx = (LBA % SectorsPerTrack + 1) = sector
    mov cx, dx                          ; cx = sector

    xor dx, dx                          ; dx = 0
    div word [bdb_heads]                ; ax = (LBA / SectorsPerTrack) / Heads = cylinder
                                        ; dx = (LBA / SectorsPerTrack) % Heads = head

    mov dh, dl                          ; dh = head
    mov ch, al                          ; ch = cylinder (lower 8 bits)
    shl ah, 6
    or cl, ah                           ; put upper 2 bits of cylinder in CL

    pop ax
    mov dl, al
    pop ax

    ret


; 
; Read sectors from a disk
; Parameters:
;   - ax: LBA address
;   - cl: number of sectors to read (up to 128)
;   - dl: drive number
;   - es:bx: memory address where to store read data
;
disk_read:

    ; Save registers on stack
    push ax 
    push bx
    push cx
    push dx
    push di

    push cx                             ; temporarily save CL (number of sectors to read)
    call lba_to_chs                     ; compute CHS
    pop ax                              ; AL = number of sectors to read

    mov ah, 02h
    mov di, 3                           ; retry count

.retry:
    pusha                               ; save all registers
    stc                                 ; set carry flag, some BIOS don't set it
    int 13h                             ; carrry flag cleared = success
    jnc .done

    ; read failed, reset controller
    popa
    call disk_reset

    dec di
    test di, di
    jnz .retry

.fail:
    ; all attempts are exhausted
    jmp floppy_error

.done:
    popa

    ; Restore registers from stack
    pop di
    pop dx
    pop cx
    pop bx
    pop ax 
    ret

;
; Resets disk controller
; Parameters:
;   dl: drive number
;
disk_reset:
    pusha
    mov ah, 0
    stc
    int 13h
    jc floppy_error
    popa
    ret

; DATA SECTION
msg_loading:            db 'Loading...!', ENDL, 0
msg_read_failed:        db 'Read from disk failed!', ENDL, 0
msg_kernel_not_found    db 'STAGE2.BIN file not found!', ENDL, 0
file_kernel_bin         db 'STAGE2  BIN'
kernel_cluster          dw 0

KERNEL_LOAD_SEGMENT     equ 0x2000
KERNEL_LOAD_OFFSET      equ 0

; $-$$ is the length of the program in bytes
times 510-($-$$) db 0
; Word AA55 expected by the BIOS in the first sector of the code
dw 0AA55h

buffer:
