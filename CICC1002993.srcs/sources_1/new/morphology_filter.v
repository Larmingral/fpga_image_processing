`timescale 1ns / 1ps
// 独立的形态学处理分支，绝对不影响原有数据流
module morphology_filter#(
    parameter IMG_WIDTH = 1280
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  mode, // 6:腐蚀 7:膨胀
    
    // 输入原始 YCbCr 流
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire [7:0]  y_in,
    input  wire [7:0]  cb_in,
    input  wire [7:0]  cr_in,
    
    // 输出处理后的流
    output reg         vs_out,
    output reg         hs_out,
    output reg         de_out,
    output reg  [7:0]  y_out,
    output reg  [7:0]  cb_out,
    output reg  [7:0]  cr_out
);

    wire        matrix_vs, matrix_hs, matrix_de;
    wire [7:0]  matrix_cb, matrix_cr;
    wire [7:0]  p11, p12, p13, p21, p22, p23, p31, p32, p33;

    // 内部调用 3x3 矩阵，它带来的延迟全部被锁在这个黑盒子里
    matrix_3x3_gen #( .IMG_WIDTH(IMG_WIDTH) ) u_matrix_3x3 (
        .clk(clk), .rst_n(rst_n),
        .vs_in(vs_in), .hs_in(hs_in), .de_in(de_in),
        .y_in(y_in), .cb_in(cb_in), .cr_in(cr_in),
        .vs_out(matrix_vs), .hs_out(matrix_hs), .de_out(matrix_de),
        .cb_out(matrix_cb), .cr_out(matrix_cr),
        .p11(p11), .p12(p12), .p13(p13),
        .p21(p21), .p22(p22), .p23(p23),
        .p31(p31), .p32(p32), .p33(p33)
    );

    localparam THRESHOLD = 8'd128;
    wire b11 = (p11 > THRESHOLD); wire b12 = (p12 > THRESHOLD); wire b13 = (p13 > THRESHOLD);
    wire b21 = (p21 > THRESHOLD); wire b22 = (p22 > THRESHOLD); wire b23 = (p23 > THRESHOLD);
    wire b31 = (p31 > THRESHOLD); wire b32 = (p32 > THRESHOLD); wire b33 = (p33 > THRESHOLD);

    wire erosion_flag  = b11 & b12 & b13 & b21 & b22 & b23 & b31 & b32 & b33;
    wire dilation_flag = b11 | b12 | b13 | b21 | b22 | b23 | b31 | b32 | b33;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 0; hs_out <= 0; de_out <= 0;
            y_out  <= 0; cb_out <= 0; cr_out <= 0;
        end else begin
            vs_out <= matrix_vs;
            hs_out <= matrix_hs;
            de_out <= matrix_de;
            cb_out <= 8'd128; // 二值化图像，色彩设为灰度基准
            cr_out <= 8'd128;
            
            if (mode == 3'd6)
                y_out <= erosion_flag ? 8'd235 : 8'd16;
            else if (mode == 3'd7)
                y_out <= dilation_flag ? 8'd235 : 8'd16;
            else
                y_out <= p22;
        end
    end
endmodule