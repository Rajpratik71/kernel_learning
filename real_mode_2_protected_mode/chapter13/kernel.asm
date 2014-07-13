;kernel.asm
;
;内核程序
;
;主要做的事：
;   1. 提供若干可供用户程序调用的例程
;   2. 加载及重定位用户程序并执行用户程序
;   3. 执行完用户程序后控制权回到内核
;
;要点技巧：
;   1. salt
;

video_ram_seg_sel       equ 0x10    ;显存段选择子
mem_0_4_gb_seg_sel      equ 0x08    ;0-4G内存数据段选择子
kernel_data_seg_sel     equ 0x30    ;内核数据段选择子
kernel_code_seg_sel     equ 0x38    ;内核代码段选择子
kernel_stack_seg_sel    equ 0x20    ;内核栈段选择子
kernel_sysroute_seg_sel equ 0x28    ;内核系统例程段选择子

kernel_len      dd  kernel_end
kenerl_section  dd  section.sys_routine.start 
                dd  section.kernel_data.start
                dd  section.kernel_code.start
kernel_entry    dd  start
                dw  kernel_code_seg_sel

[bits 32]
;系统例程段
SECTION sys_routine vstart=0

;putstr函数
;功能：
;   打印一个字符串，以0为结束符
;参数：
;   ds:ebx = 要打印的字符串地址
;输出：
;   无
putstr:
    pushad

.nextchar:
    mov cl,[ebx]
    cmp cl,0
    jz .exit
    call putchar
    inc ebx
    jmp .nextchar

.exit:
    popad
    retf

;putchar函数
;功能：
;   打印单个字符
;参数： 
;   cl = 要打印的字符
;输出：
;   无
putchar:
    pushad

    ;获取当前光标位置
    ;光标位置是一个16位的数值，需要分别获取其高8位与低8位
    ;获取光标位置的高8位
    ;   向显卡的索引寄存器0x3d4端口写入0x0e，从索引寄存器的0x3d5端口读8位数据，
    ;获取光标位置的低8位
    ;   向显卡的索引寄存器0x3d4端口写入0x0f，从索引寄存器的0x3d5端口读8位数据，
    mov dx,0x3d4
    mov al,0x0e
    out dx,al
    mov dx,0x3d5
    in  al,dx
    mov ah,al

    mov dx,0x3d4
    mov al,0x0f
    out dx,al
    mov dx,0x3d5
    in  al,dx       ;当前光标位置已保存到ax中
    mov bx,ax       ;ax将用于接下来的div运算

    ;打印字符cl，要特殊处理\r:0x0d,\n:0x0a

    ;处理\r（0x0d，回车，将光标位置移到当前行第一列）
    ;处理：
    ;   将光标位置 / 80 得到当前光标行号（每行80列）
    ;   当前光标行 * 80 为当前行首列位置，将该位置设为当前光标位置
    cmp cl,0x0d
    jnz .line_feed
    xor dx,dx
    mov bl,80
    div bl          ;div r/m16   dx:ax / r/m16 => ax ... dx
    mul bl          ;mul r/m16   ax * r/m16 => dx:ax
    mov bx,ax
    jmp .roll_screen

    ;处理\n（0x0a，换行，将光标位置移到当前列下一行）
    ;处理：
    ;   将光标位置 + 80 （每行80列）
.line_feed:
    cmp cl,0x0a
    jnz .normal_char
    add bx,80
    jmp .roll_screen

    ;打印普通字符并将光标移向下一个位置
    ;将光标位置*2得到当前光标的显存地址，往该地址写字符即可显示
    ;每个字符占两个字节，第一个字节用于存储字符ascii码，第二个字节用于控制字符属性
    ;|--------------------------------|
    ;|15               7 6 5 4 3 2 1 0|
    ;|--------------------------------|
    ;|    ascii 15:8   k r g b i r g b|
    ;                  \     / \     /
    ;                     bg      fg
    ;
    ; k : 0 - blink, 1 - no-blink

.normal_char:
    push es
    mov ax,video_ram_seg_sel    ;显存段 
    mov es,ax
    shl bx,1
    mov [es:bx],cl
    mov byte [es:bx+1],00000010B    ;00000010B - 黑底绿字
    shr bx,1
    pop es

    add bx,1        ;光标推后一个位置

    ;滚屏，每行字符往上移一行并清空最后一行
.roll_screen:
    cmp bx,2000     ;80*25=2000, 表示光标超出屏幕，需要滚屏
    jl  .set_cursor
    push ds
    push es
    mov ax,video_ram_seg_sel    ;显存段
    mov ds,ax
    mov es,ax
    cld
    mov edi,0
    mov esi,80      ;80
    mov ecx,1920    ;2000-80
    rep movsw       ;每行字符往上移一行

    ;以黑底白字的空格符填充最后一行
    mov bx,3840     ;1920*2
    mov cx,80
.clr_char:
    mov word [es:edi],0x0720
    add edi,2
    loop .clr_char
    mov bx,1920

    pop es
    pop ds

    ;设置bx为下一光标位置
.set_cursor:
    mov dx,0x3d4
    mov al,0x0e
    out dx,al
    mov dx,0x3d5
    mov al,bh
    out dx,al

    mov dx,0x3d4
    mov al,0x0f
    out dx,al
    mov dx,0x3d5
    mov al,bl
    out dx,al

    popad
    ret

;read_one_disk_sector函数
;功能：
;   从硬盘读取一个扇区（512字节）
;参数：
;   eax = 逻辑扇区号
;   ds:ebx = 目标缓冲区地址
;输出：
;   ebx += 512

;硬盘的读写单位是一个扇区
;主硬盘控制器被分配到了八个端口：0x1f0 - 0x0f7
;用LBA28方式读写硬盘:
;   1. 往0x1f2端口(8bit)写入要读取的扇区数目
;   2. 将28位起始LBA扇区号写入0x1f3,0x1f4,0x1f5,0x1f6端口(均为8big)
;           ---------------------------------------------------------------------    
;           31 30 29 28 27      23              16              7               0
;           ---------------------------------------------------------------------    
;           |       0x1f6       |     0x1f5     |     0x1f4     |     0x1f3     | 
;           ---------------------------------------------------------------------    
;            1  |  1 |   \                                                     /
;               |    |    `````````````````````````````````````````````````````
;               |    |                           LBA28
;       0: CHS _|    |_ 0: 主硬盘(master)
;       1: LBA          1: 从硬盘(slave)
;   3. 往0x1f7端口(8bit)写入0x20，请求硬盘读
;   4. 等待硬盘准备好读写, 0x1f7既是命令端口也是状态端口，此时为状态端口，含义如下：
;       -----------------------------
;       7   6   5   4   3   2   1   0
;       -----------------------------
;       |               |           |           
;       |_ 0: 硬盘闲    |           |_ 0: 前一个命令执行成功
;          1: 硬盘忙    |              1: 前一个命令执行失败，具体原因查看0x1f1
;                       |_ 0: 硬盘未准备好与主机交换数据
;                          1: 硬盘已准备好与主机交换数据
;       当bit7为0且bit3为1时，表示可以进行读硬盘了
;   5. 从0x1f0端口(16bit)读取数据

read_one_disk_sector:
    push eax
    push ecx
    push dx
    
    mov ecx,eax

    mov dx,0x1f2    ;1. 读取1个扇区
    mov al,1
    out dx,al

    inc dx          ;2.1 0x1f3 <= eax 7:0
    mov eax,ecx
    out dx,al

    inc dx          ;2.2 0x1f4 <= eax 15:8
    shr eax,8
    out dx,al

    inc dx          ;2.3 0x1f5 <= eax 23:16
    shr eax,8
    out dx,al

    inc dx          ;2.4 0x1f6 <= eax 27:24
    shr eax,8
    and al,0x0f
    or  al,0xe0     ;主硬盘+LBA方式
    out dx,al

    inc dx          ;3. 发送硬盘读命令
    mov al,0x20 
    out dx,al

.wait:              ;4. 等待硬盘准备好可读
    in  al,dx
    and al,0x88
    or  al,0x08
    jnz .wait
    
    mov ecx,256     ;5. 读取硬盘
    mov dx,0x1f0
.rw:
    in  ax,dx 
    mov [ebx],ax
    add ebx,2
    loop .rw

    pop dx
    pop ecx
    pop eax

    retf

;make_seg_descriptor函数
;功能：
;   构造段描述符
;参数：
;   eax = 段线性基地址（32位）
;   ebx = 段界限（20位）
;   ecx = 属性（各属性位都在原始位置，没用到的位为0）
;输出：
;   edx:eax 完整的段描述符
make_seg_descriptor:
    mov edx,eax
    rol eax,16      ;Set Base 15:0
    mov ax,bx       ;Set Limit 15:0

    and edx,0xffff0000
    rol edx,8
    bswap edx       ;Set Base 31:24 and Base 23:16

    and ebx,0x000f0000
    or  edx,ebx     ;Set Limit 19:16

    or  edx,ecx     ;Set Prop.

    retf

;install_gdt_descriptor函数
;功能：
;   安装段描述符到GDT并返回段选择子
;参数：
;   edx:eax = 完整的段描述符
;输出：
;   cx = 段选择子
install_gdt_descriptor:
    push ebx
    push ds
    push es

    mov ebx,kernel_data_seg_sel
    mov ds,ebx

    mov ebx,mem_0_4_gb_seg_sel
    mov es,ebx

    sgdt [pgdt]

    ;写入段描述符
    push ecx
    movzx ecx,word [pgdt]       
    inc cx
    add ecx,[pgdt+0x02]
    mov [es:ecx],eax
    mov [es:ecx+0x04],edx
    pop ecx

    ;更新GDT界限
    add word [pgdt],8           
    lgdt [pgdt]

    ;构造段选择子
    push dx
    push ax
    mov ax,[pgdt]               
    or dx,dx
    mov cx,8
    div cx
    mov cx,ax
    shl cx,3                    ;左移三位将索引移到正确位置
                                ;同时腾出了TI,RPL三位(填充0)
    pop ax
    pop dx

    pop es
    pop ds
    pop ebx

    retf

;allocate_memory函数
;功能：
;   分配指定大小的内存区域
;参数：
;   ecx = 希望分配的字节数
;输出：
;   ecx = 分配的内存起始线性地址
allocate_memory:
    push eax
    push ebx
    push ds

    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov eax,[memory]
    add eax,ecx         ;让下一个地址4字节对齐
    mov ebx,eax
    and ebx,0xfffffffc
    add ebx,4
    test eax,0x3
    cmovnz eax,ebx

    mov ecx,[memory]

    mov [memory],eax

    pop ds
    pop ebx
    pop eax

    retf

;put_hex_dword函数
;功能：
;   在当前光标位置以字符形式（0xABCD）打印一个双字，并推进光标位置
;参数：
;   edx = 要打印的双字
;输出：
;   无
put_hex_dword:
    push eax
    push ebx
    push edx
    push ds
    
    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov ecx,8
    mov ebx,hex_table
.print_4bits:
    rol edx,4
    mov al,dl
    xlatb
    push cx
    mov cl,al
    call putchar
    pop cx
    loop .print_4bits

    pop ds
    pop edx
    pop ebx
    pop eax

    retf

sys_routine_end

;内核数据段
SECTION kernel_data vstart=0

;install_gdt_descriptor函數需要內存临时保存GDT
pgdt    dw  0
        dd  0
;allocate_memory函数用来存储下一个分配地址
memory  dd  0x00100000
;put_hex_dword函数用的十六进制表
hex_table   db  '0123456789abcdef'

msg_1   db  'in kernel, prepare to load user program', 0

kernel_data_end

;内核代码段
SECTION kernel_code vstart=0

load_relocate_user_program:
    ret

start:
    mov eax,kernel_data_seg_sel
    mov ds,eax

    mov ebx,msg_1
    call putstr
    jmp $

kernel_code_end

SECTION kernel_tail
kernel_end

; vim: set syntax=nasm:
