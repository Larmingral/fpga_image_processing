`timescale 1ns / 1ps
module pingpong_burst_reverser(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        din_valid,
    input  wire [15:0] din,
    
    output reg         dout_valid,
    output reg  [15:0] dout
);

    // 标准 RAM 声明，保证被推断为 Block RAM
    reg [15:0] ram_0 [0:511];
    reg [15:0] ram_1 [0:511];

    // --- 1. 写地址与 Bank 控制 ---
    reg        wr_bank;
    reg [8:0]  wr_addr;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_bank <= 1'b0;
            wr_addr <= 9'd0;
        end else if (din_valid) begin
            if (wr_addr == 9'd511) begin
                wr_addr <= 9'd0;
                wr_bank <= ~wr_bank;
            end else begin
                wr_addr <= wr_addr + 1'b1;
            end
        end
    end

    // --- 2. 纯同步写操作 (不带复位信号) ---
    always @(posedge clk) begin
        if (din_valid && wr_bank == 1'b0) ram_0[wr_addr] <= din;
        if (din_valid && wr_bank == 1'b1) ram_1[wr_addr] <= din;
    end

    // --- 3. 读地址与时序控制 ---
    reg        rd_busy;
    reg [8:0]  rd_addr;
    reg        rd_bank;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_busy <= 1'b0;
            rd_addr <= 9'd511;
            rd_bank <= 1'b0;
        end else begin
            // 写满 512 立刻触发读取
            if (din_valid && wr_addr == 9'd511) begin
                rd_busy <= 1'b1;
                rd_addr <= 9'd511;   
                rd_bank <= wr_bank;  
            end else if (rd_busy) begin
                if (rd_addr == 9'd0) begin
                    rd_busy <= 1'b0;
                    rd_addr <= 9'd511;
                end else begin
                    rd_addr <= rd_addr - 1'b1; // 地址递减
                end
            end
        end
    end

    // --- 4. 纯同步读操作 ---
    reg [15:0] dout_raw_0;
    reg [15:0] dout_raw_1;
    always @(posedge clk) begin
        dout_raw_0 <= ram_0[rd_addr];
        dout_raw_1 <= ram_1[rd_addr];
    end

    // --- 5. 拍数对齐 (BRAM读有1拍延迟，有效信号同步延时1拍) ---
    reg rd_busy_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_busy_d1 <= 1'b0;
            dout_valid <= 1'b0;
            dout       <= 16'd0;
        end else begin
            rd_busy_d1 <= rd_busy;
            dout_valid <= rd_busy_d1; // 精准对齐数据有效性
            
            if (rd_bank == 1'b0) dout <= dout_raw_0;
            else                 dout <= dout_raw_1;
        end
    end
endmodule