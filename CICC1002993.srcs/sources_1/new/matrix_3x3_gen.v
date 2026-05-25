`timescale 1ns / 1ps
// 模块：利用两个双口 RAM 生成 3x3 像素窗口
module matrix_3x3_gen #(
    parameter IMG_WIDTH  = 1280 // 必须和你的图像宽度一致 (HDMI 是 1280x720)
)(
    input  wire        clk,
    input  wire        rst_n,

    // 上游视频流输入
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire [7:0]  y_in,
    input  wire [7:0]  cb_in,
    input  wire [7:0]  cr_in,

    // 同步对齐的输出控制信号
    output reg         vs_out,
    output reg         hs_out,
    output reg         de_out,
    output reg  [7:0]  cb_out,
    output reg  [7:0]  cr_out,

    // 3x3 矩阵输出 (p_行_列)
    output reg  [7:0]  p11, p12, p13, // 第 1 行 (上)
    output reg  [7:0]  p21, p22, p23, // 第 2 行 (中)
    output reg  [7:0]  p31, p32, p33  // 第 3 行 (下 - 当前输入行)
);

    // 行缓存 RAM 读写控制
    reg [10:0] col_cnt; // 列计数器
    
    // 行计数器，用来追踪当前是第几行有效数据
    reg [10:0] row_cnt; 

    // 生成 BRAM 读写地址
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            col_cnt <= 11'd0;
            row_cnt <= 11'd0;
        end else if (vs_in == 1'b0) begin 
            // 场同步期间清零
            col_cnt <= 11'd0;
            row_cnt <= 11'd0;
        end else if (de_in) begin
            if (col_cnt == IMG_WIDTH - 1) begin
                col_cnt <= 11'd0;
                row_cnt <= row_cnt + 1'b1;
            end else begin
                col_cnt <= col_cnt + 1'b1;
            end
        end
    end

    // BRAM 实例化 (推断为 Block RAM)
    (* ram_style = "block" *) reg [7:0] line_buf_1 [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg [7:0] line_buf_2 [0:IMG_WIDTH-1];

    reg [7:0] row1_data; // line_buf_2 读出的数据 (最老的一行)
    reg [7:0] row2_data; // line_buf_1 读出的数据 (上一行)

    // BRAM 的读操作 (带有 1 拍延迟)
    always @(posedge clk) begin
        if (de_in) begin
            row1_data <= line_buf_2[col_cnt];
            row2_data <= line_buf_1[col_cnt];
        end
    end

    // BRAM 的写操作
    always @(posedge clk) begin
        if (de_in) begin
            // 当前行写入 buf_1，buf_1 的旧数据写入 buf_2
            line_buf_1[col_cnt] <= y_in;
            line_buf_2[col_cnt] <= row2_data; 
        end
    end

    // 3x3 矩阵打拍生成
    reg [7:0] row1_d1, row1_d2; // 第一行的列打拍
    reg [7:0] row2_d1, row2_d2; // 第二行的列打拍
    reg [7:0] row3_d1, row3_d2; // 第三行的列打拍 (当前输入行)

    // 所有的打拍和输出都在有效期间进行，且因为 BRAM 读取有 1 拍延迟，
    // 需要在 de_in 延迟 1 拍后的信号 (de_d1) 下更新矩阵。
    reg de_d1, de_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d1 <= 1'b0;
            de_d2 <= 1'b0;
        end else begin
            de_d1 <= de_in;
            de_d2 <= de_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row1_d1 <= 8'd0; row1_d2 <= 8'd0;
            row2_d1 <= 8'd0; row2_d2 <= 8'd0;
            row3_d1 <= 8'd0; row3_d2 <= 8'd0;
            p11 <= 0; p12 <= 0; p13 <= 0;
            p21 <= 0; p22 <= 0; p23 <= 0;
            p31 <= 0; p32 <= 0; p33 <= 0;
        end else if (de_d1) begin
            // 移位寄存器更新
            row1_d1 <= row1_data; row1_d2 <= row1_d1;
            row2_d1 <= row2_data; row2_d2 <= row2_d1;
            row3_d1 <= y_in;      row3_d2 <= row3_d1; // 注意这里是用当前输入打拍

            // 矩阵赋值
            p11 <= row1_d2; p12 <= row1_d1; p13 <= row1_data;
            p21 <= row2_d2; p22 <= row2_d1; p23 <= row2_data;
            p31 <= row3_d2; p32 <= row3_d1; p33 <= y_in;
        end
    end

    // 控制信号与伴随数据对齐 (核心边界处理)
    // 因为 3x3 矩阵在第 3 行输入时才完整，
    // 且 BRAM 读出延迟 1 拍，列寄存器打拍延迟 2 拍，
    // 所以，整体有效输出相对于输入，整整延迟了 2 行 + 3 拍！
    // Cb, Cr 需要被缓存 2 行，再加 3 拍，才能和中心的 p22 像素完全对齐。
    (* ram_style = "block" *) reg [15:0] cbcr_buf_1 [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg [15:0] cbcr_buf_2 [0:IMG_WIDTH-1];
    
    reg [15:0] cbcr_row1_data;
    reg [15:0] cbcr_row2_data;
    reg [15:0] cbcr_d1, cbcr_d2, cbcr_d3; // 3 拍延迟对齐

    always @(posedge clk) begin
        if (de_in) begin
            cbcr_row1_data <= cbcr_buf_2[col_cnt];
            cbcr_row2_data <= cbcr_buf_1[col_cnt];
            cbcr_buf_1[col_cnt] <= {cb_in, cr_in};
            cbcr_buf_2[col_cnt] <= cbcr_row2_data;
        end
    end

    // 同步输出信号
    reg vs_d1, vs_d2, vs_d3;
    reg hs_d1, hs_d2, hs_d3;
    reg de_d3;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cbcr_d1 <= 0; cbcr_d2 <= 0; cbcr_d3 <= 0;
            vs_d1 <= 0; vs_d2 <= 0; vs_d3 <= 0;
            hs_d1 <= 0; hs_d2 <= 0; hs_d3 <= 0;
            de_d3 <= 0;
            vs_out <= 0; hs_out <= 0; de_out <= 0;
            cb_out <= 0; cr_out <= 0;
        end else begin
            // CbCr 打 3 拍对齐 p22
            cbcr_d1 <= cbcr_row1_data;
            cbcr_d2 <= cbcr_d1;
            cbcr_d3 <= cbcr_d2;
            
            // 同步信号只负责打 3 拍，不再做行延迟（因为显示器扫描也是连贯的，只要内部流对齐即可）
            vs_d1 <= vs_in; vs_d2 <= vs_d1; vs_d3 <= vs_d2;
            hs_d1 <= hs_in; hs_d2 <= hs_d1; hs_d3 <= hs_d2;
            de_d3 <= de_d2; // de_d2 在上面生成了
            
            // 最终输出：只有当 row_cnt >= 2 时，矩阵才算真正吃饱了，开始吐出有效数据
            // 为了简化显示器时序控制，只要 de 有效我们就认为矩阵可用（最顶部和边缘两行会有一点点瑕疵，但不影响整体效果）
            vs_out <= vs_d3;
            hs_out <= hs_d3;
            de_out <= de_d3;
            cb_out <= cbcr_d3[15:8];
            cr_out <= cbcr_d3[7:0];
        end
    end

endmodule