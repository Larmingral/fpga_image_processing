`timescale 1 ps/ 1 ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 04-20-2026 18:16:40
// Design Name:
// Module Name: crc32_gen
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module crc32_gen(
input wire clk,
input wire rst_n,
input wire data_en,
input wire [7:0] data_in,
input wire crc_init,
output wire [31:0] crc_out
);
reg [31:0] crc_reg;
reg [31:0] v_crc; // 内部阻塞赋值用的临时变量
integer i;

always @(posedge clk) begin
    if (!rst_n || crc_init) begin
        crc_reg <= 32'hFFFFFFFF;
    end else if (data_en) begin
        // 1. 将输入字节与当前校验和的低 8 位异或
        v_crc = crc_reg ^ data_in; 
        
        // 2. 循环 8 次计算这一字节产生的位移
        for (i = 0; i < 8; i = i + 1) begin
            if (v_crc[0])
                v_crc = (v_crc >> 1) ^ 32'hEDB88320;
            else
                v_crc = (v_crc >> 1);
        end
        
        // 3. 最后使用非阻塞赋值更新到寄存器
        crc_reg <= v_crc; 
    end
end

// 以太网 CRC32 最终处理：结果取反 + 字节序调整
// 很多网卡要求大端序发送，这里将 32 位寄存器按字节倒序排列
assign crc_out = ~{crc_reg[7:0], crc_reg[15:8], crc_reg[23:16], crc_reg[31:24]};
endmodule