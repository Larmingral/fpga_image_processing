`timescale 1ns / 1ps
// 模块：超轻量级形态学处理器 (修复版：严格 4 级流水线时序对齐)
module morphology_lite #(
    parameter IMG_WIDTH = 1280
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [2:0]  mode,   // 6:腐蚀 7:膨胀
    
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire [7:0]  y_in,
    
    output reg         vs_out,
    output reg         hs_out,
    output reg         de_out,
    output reg  [7:0]  y_out,
    output wire [7:0]  cb_out,
    output wire [7:0]  cr_out
);

    // =======================================================
    // 1. 列地址复位与生成
    // =======================================================
    reg [10:0] col_cnt;
    always @(posedge clk) begin
        if (!rst_n) col_cnt <= 11'd0;
        else if (!de_in) col_cnt <= 11'd0;
        else col_cnt <= col_cnt + 1'b1;
    end

    // =======================================================
    // 2. 行缓存 BRAM
    // =======================================================
    (* ram_style = "block" *) reg [7:0] line_buf_1 [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg [7:0] line_buf_2 [0:IMG_WIDTH-1];

    // =======================================================
    // 3. 核心修复：绝对平行的 4 级同步信号流水线
    // =======================================================
    reg vs_d1, vs_d2, vs_d3, vs_d4;
    reg hs_d1, hs_d2, hs_d3, hs_d4;
    reg de_d1, de_d2, de_d3, de_d4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d1<=0; vs_d2<=0; vs_d3<=0; vs_d4<=0;
            hs_d1<=0; hs_d2<=0; hs_d3<=0; hs_d4<=0;
            de_d1<=0; de_d2<=0; de_d3<=0; de_d4<=0;
        end else begin
            vs_d1 <= vs_in; vs_d2 <= vs_d1; vs_d3 <= vs_d2; vs_d4 <= vs_d3;
            hs_d1 <= hs_in; hs_d2 <= hs_d1; hs_d3 <= hs_d2; hs_d4 <= hs_d3;
            de_d1 <= de_in; de_d2 <= de_d1; de_d3 <= de_d2; de_d4 <= de_d3;
        end
    end

    // =======================================================
    // 4. 数据获取 (Stage 1)
    // =======================================================
    reg [7:0] row1_data, row2_data, row3_data;
    always @(posedge clk) begin
        if (de_in) begin
            row1_data <= line_buf_2[col_cnt];
            row2_data <= line_buf_1[col_cnt];
            row3_data <= y_in;

            line_buf_1[col_cnt] <= y_in;
            line_buf_2[col_cnt] <= row2_data;
        end
    end

    // =======================================================
    // 5. 3x3 矩阵移位寄存器 (Stage 2 & 3)
    // =======================================================
    reg [7:0] p11, p12, p13;
    reg [7:0] p21, p22, p23;
    reg [7:0] p31, p32, p33;

    always @(posedge clk) begin
        if (de_d1) begin
            p13 <= row1_data; p12 <= p13; p11 <= p12;
            p23 <= row2_data; p22 <= p23; p21 <= p22;
            p33 <= row3_data; p32 <= p33; p31 <= p32;
        end
    end

    // =======================================================
    // 6. 形态学组合逻辑计算 (在 Stage 3 准备好)
    // =======================================================
    localparam THRESHOLD = 8'd128;
    wire b11 = (p11 > THRESHOLD); wire b12 = (p12 > THRESHOLD); wire b13 = (p13 > THRESHOLD);
    wire b21 = (p21 > THRESHOLD); wire b22 = (p22 > THRESHOLD); wire b23 = (p23 > THRESHOLD);
    wire b31 = (p31 > THRESHOLD); wire b32 = (p32 > THRESHOLD); wire b33 = (p33 > THRESHOLD);

    wire erosion_flag  = b11 & b12 & b13 & b21 & b22 & b23 & b31 & b32 & b33;
    wire dilation_flag = b11 | b12 | b13 | b21 | b22 | b23 | b31 | b32 | b33;

    // =======================================================
    // 7. 终极输出打包 (统一在 Stage 4 触发)
    // =======================================================
    assign cb_out = 8'd128; // 固定灰阶色彩，不耗费额外资源
    assign cr_out = 8'd128;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 0; hs_out <= 0; de_out <= 0; y_out <= 0;
        end else begin
            // 绝不允许偏差！全部严格使用 d4 延迟信号
            vs_out <= vs_d4;
            hs_out <= hs_d4;
            de_out <= de_d4;
            
            if (mode == 3'd6)
                y_out <= erosion_flag ? 8'd235 : 8'd16;
            else if (mode == 3'd7)
                y_out <= dilation_flag ? 8'd235 : 8'd16;
            else
                y_out <= p22; // 如果处于中间态，输出原图中心像素
        end
    end

endmodule