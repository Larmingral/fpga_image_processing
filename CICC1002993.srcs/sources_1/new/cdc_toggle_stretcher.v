`timescale 1ns / 1ps
module cdc_toggle_stretcher #(
    parameter STRETCH_VAL = 21'd2_000_000 // 增加到足够长的时间，确保消抖模块必能识别
)(
    input  wire clk,           // 目标时钟 (24M 或 HDMI_clk)
    input  wire rst_n,         // 复位信号
    input  wire toggle_bit,    // 来自以太网模块异步翻转信号 (out_bit)
    output wire vkey_n         // 输出：给消抖模块用的低有效虚拟按键
);

    // 1. 跨时钟域同步 (双寄存器打拍，绝对防止亚稳态)
    reg sync_d1, sync_d2, sync_d3;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync_d1 <= 1'b0; sync_d2 <= 1'b0; sync_d3 <= 1'b0;
        end else begin
            sync_d1 <= toggle_bit;
            sync_d2 <= sync_d1;
            sync_d3 <= sync_d2; 
        end
    end

    // 2. 检测电平翻转 (电平只要变了，就代表以太网收到一次新指令)
    wire changed = sync_d2 ^ sync_d3;

    // 3. 产生长达 100ms+ 的低电平脉冲 (模拟人类按键动作)
    reg [20:0] cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) 
            cnt <= 21'd0;
        else if (changed)
            cnt <= STRETCH_VAL; // 只要有翻转，立即重新计时
        else if (cnt > 0)
            cnt <= cnt - 1'b1;
    end

    // 确保闲置时为 1，触发时为 0
    assign vkey_n = (cnt > 0) ? 1'b0 : 1'b1;

endmodule