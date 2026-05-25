`timescale 1ns / 1ps
// 模块：基于 YCbCr 阈值的肤色分割
module skin_detector #(
    // 肤色判定阈值 (参数化设计，方便后期如果光线不对可以随时微调)
	parameter CB_MIN = 8'd100,  // 收窄下限
	parameter CB_MAX = 8'd120,  // 收窄上限
	parameter CR_MIN = 8'd140,  // 提高下限
	parameter CR_MAX = 8'd165  // 降低上限
)(
    input  wire        clk,
    input  wire        rst_n,
    
    // 输入 YCbCr 流
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire [7:0]  y_in,
    input  wire [7:0]  cb_in,
    input  wire [7:0]  cr_in,
    
    // 输出 二值化(黑白) 掩码流
    output reg         vs_out,
    output reg         hs_out,
    output reg         de_out,
    output reg  [7:0]  y_out,
    output wire [7:0]  cb_out, // 色度固定为128 (灰度图)
    output wire [7:0]  cr_out  // 色度固定为128 (灰度图)
);

    // 固定输出灰度色偏
    assign cb_out = 8'd128;
    assign cr_out = 8'd128;

    // 肤色判定标志位
    wire is_skin;
    
    // 核心组合逻辑：当 Cb 和 Cr 都在指定范围内时，认为是肤色
    assign is_skin = (cb_in >= CB_MIN && cb_in <= CB_MAX) && 
                     (cr_in >= CR_MIN && cr_in <= CR_MAX);

    // 1级流水线打拍：保证时序收敛
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 0;
            hs_out <= 0;
            de_out <= 0;
            y_out  <= 0;
        end else begin
            vs_out <= vs_in;
            hs_out <= hs_in;
            de_out <= de_in;
            
            // 如果是肤色，输出纯白(235)，否则输出纯黑(16)
            if (is_skin)
                y_out <= 8'd235;
            else
                y_out <= 8'd16;
        end
    end

endmodule