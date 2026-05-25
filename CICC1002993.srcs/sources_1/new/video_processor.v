`timescale 1ns / 1ps
// 模块：视频算法处理核心
module video_processor(
input  wire        clk,
input  wire        rst_n,
input  wire [2:0]  mode,      // 0:原图 1:灰度 2:二值化 3:反相 4:直方图均衡化
// 输入 YCbCr 流
input  wire        vs_in,
input  wire        hs_in,
input  wire        de_in,
input  wire [7:0]  y_in,
input  wire [7:0]  cb_in,
input  wire [7:0]  cr_in,

// 接口：来自外挂直方图 LUT 的查表结果与状态
input  wire [7:0]  y_eq_in,   
input  wire        lut_ready, 

// 输出 YCbCr 流
output reg         vs_out,
output reg         hs_out,
output reg         de_out,
output reg  [7:0]  y_out,
output reg  [7:0]  cb_out,
output reg  [7:0]  cr_out
);

// 算法阈值
localparam THRESHOLD = 8'd128; 

// --- 阶段 1 寄存器 ---
reg        vs_d1, hs_d1, de_d1;
reg [7:0]  y_d1, cb_d1, cr_d1;
reg [7:0]  y_bin;
reg [7:0]  y_inv, cb_inv, cr_inv; 

// --- MUX 组合逻辑变量 ---
reg [7:0]  y_mux, cb_mux, cr_mux;

// 1. 算法多路选择器 (基于 D1 拍数据进行组合逻辑选择)
always @(*) begin
    if (de_d1) begin 
        case(mode)
            3'd0: begin // 模式0: 原图
                y_mux  = y_d1; 
                cb_mux = cb_d1; 
                cr_mux = cr_d1; 
            end
            3'd1: begin // 模式1: 灰度 (Cb/Cr 设为 128)
                y_mux  = y_d1; 
                cb_mux = 8'd128; 
                cr_mux = 8'd128; 
            end
            3'd2: begin // 模式2: 二值化
                y_mux  = y_bin; 
                cb_mux = 8'd128; 
                cr_mux = 8'd128; 
            end
            3'd3: begin // 模式3: 色彩反相
                y_mux  = y_inv; 
                cb_mux = cb_inv; 
                cr_mux = cr_inv; 
            end
            3'd4: begin // 模式4: 直方图均衡化
                // 核心逻辑：如果建表完成，用查表结果；如果还没建好(比如第一帧)，先输出原图保护画面不黑屏
                y_mux  = lut_ready ? y_eq_in : y_d1; 
                cb_mux = cb_d1; 
                cr_mux = cr_d1; 
            end
            default: begin 
                y_mux  = y_d1; 
                cb_mux = cb_d1; 
                cr_mux = cr_d1; 
            end
        endcase
    end else begin
        // 消隐区强制输出标准安全黑 (Y:16, Cb/Cr:128)
        y_mux  = 8'd16; 
        cb_mux = 8'd128; 
        cr_mux = 8'd128; 
    end
end

// 2. 流水线驱动与算法并行计算
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // 阶段 1 复位
        vs_d1 <= 0; hs_d1 <= 0; de_d1 <= 0;
        y_d1  <= 0; cb_d1 <= 0; cr_d1 <= 0;
        y_bin <= 0; y_inv <= 0; cb_inv <= 0; cr_inv <= 0;
        // 阶段 2 复位
        vs_out <= 0; hs_out <= 0; de_out <= 0;
        y_out  <= 0; cb_out <= 0; cr_out <= 0;
    end else begin
        // --- [流水线阶段 1] ---
        vs_d1 <= vs_in;
        hs_d1 <= hs_in;
        de_d1 <= de_in;
        y_d1  <= y_in;
        cb_d1 <= cb_in;
        cr_d1 <= cr_in;

        // 预计算算法：二值化
        if (y_in > THRESHOLD) y_bin <= 8'd235; else y_bin <= 8'd16;
        // 预计算算法：反相
        y_inv  <= 8'd255 - y_in;
        cb_inv <= 8'd255 - cb_in;
        cr_inv <= 8'd255 - cr_in;

        // --- [流水线阶段 2] ---
        vs_out <= vs_d1;
        hs_out <= hs_d1;
        de_out <= de_d1;

        // 限幅器
        // 确保 Y 在 16-235 范围内，Cb/Cr 在 16-240 范围内
        // 能够有效防止 YCbCr 转 RGB 过程中的数学溢出，消除画面噪点
        y_out  <= (y_mux  < 16) ? 8'd16  : ((y_mux  > 235) ? 8'd235 : y_mux);
        cb_out <= (cb_mux < 16) ? 8'd16  : ((cb_mux > 240) ? 8'd240 : cb_mux);
        cr_out <= (cr_mux < 16) ? 8'd16  : ((cr_mux > 240) ? 8'd240 : cr_mux);
    end
end
endmodule