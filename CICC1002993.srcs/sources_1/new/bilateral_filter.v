`timescale 1ns / 1ps

// 模块名称: 3x3 空间二维双边滤波核心
module bilateral_filter #(
    parameter IMG_WIDTH  = 1280
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

    // 滤波后对齐输出的视频流
    output wire        vs_out,
    output wire        hs_out,
    output wire        de_out,
    output wire [7:0]  y_out,
    output wire [7:0]  cb_out,
    output wire [7:0]  cr_out
);

    // 1. 调用“散件1”：3x3 窗口生成器
    wire        mat_vs, mat_hs, mat_de;
    wire [7:0]  mat_cb, mat_cr;
    wire [7:0]  p11, p12, p13;
    wire [7:0]  p21, p22, p23;
    wire [7:0]  p31, p32, p33;

    matrix_3x3_gen #(
        .IMG_WIDTH (IMG_WIDTH)
    ) u_matrix_3x3 (
        .clk    (clk),
        .rst_n  (rst_n),
        .vs_in  (vs_in), 
		.hs_in  (hs_in), 
		.de_in  (de_in),
        .y_in   (y_in),  
		.cb_in  (cb_in), 
		.cr_in  (cr_in),
        .vs_out (mat_vs), 
		.hs_out (mat_hs),
		.de_out (mat_de),
        .cb_out (mat_cb), 
		.cr_out (mat_cr),
        .p11(p11), 
		.p12(p12), 
		.p13(p13),
        .p21(p21), 
		.p22(p22), 
		.p23(p23),
        .p31(p31), 
		.p32(p32), 
		.p33(p33)
    );

    // 伴随控制信号的 8 级流水线延迟打拍
    reg [7:0] pipe_vs, pipe_hs, pipe_de;
    reg [7:0] pipe_cb [0:7];
    reg [7:0] pipe_cr [0:7];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pipe_vs <= 8'd0; pipe_hs <= 8'd0; pipe_de <= 8'd0;
            for (i=0; i<8; i=i+1) begin
                pipe_cb[i] <= 8'd0; pipe_cr[i] <= 8'd0;
            end
        end else begin
            pipe_vs <= {pipe_vs[6:0], mat_vs};
            pipe_hs <= {pipe_hs[6:0], mat_hs};
            pipe_de <= {pipe_de[6:0], mat_de};
            
            pipe_cb[0] <= mat_cb; pipe_cr[0] <= mat_cr;
            for (i=1; i<8; i=i+1) begin
                pipe_cb[i] <= pipe_cb[i-1];
                pipe_cr[i] <= pipe_cr[i-1];
            end
        end
    end

    assign vs_out = pipe_vs[7];
    assign hs_out = pipe_hs[7];
    assign de_out = pipe_de[7];
    assign cb_out = pipe_cb[7];
    assign cr_out = pipe_cr[7];

    // 开启双边滤波 8 级极速流水线
    // --- Stage 1: 计算周围 8 个像素与中心像素(p22)的绝对差值 ---
    reg [7:0] d11, d12, d13, d21, d23, d31, d32, d33;
    reg [7:0] s1_p11, s1_p12, s1_p13, s1_p21, s1_p22, s1_p23, s1_p31, s1_p32, s1_p33;

    always @(posedge clk) begin
        d11 <= (p11 > p22) ? (p11 - p22) : (p22 - p11);
        d12 <= (p12 > p22) ? (p12 - p22) : (p22 - p12);
        d13 <= (p13 > p22) ? (p13 - p22) : (p22 - p13);
        d21 <= (p21 > p22) ? (p21 - p22) : (p22 - p21);
        d23 <= (p23 > p22) ? (p23 - p22) : (p22 - p23);
        d31 <= (p31 > p22) ? (p31 - p22) : (p22 - p31);
        d32 <= (p32 > p22) ? (p32 - p22) : (p22 - p32);
        d33 <= (p33 > p22) ? (p33 - p22) : (p22 - p33);
        // 像素陪跑
        s1_p11<=p11; s1_p12<=p12; s1_p13<=p13;
        s1_p21<=p21; s1_p22<=p22; s1_p23<=p23;
        s1_p31<=p31; s1_p32<=p32; s1_p33<=p33;
    end

    // --- Stage 2: 调用“散件2” - 色差权重 ROM 查表 (耗时 1 拍) ---
    wire [3:0] w11, w12, w13, w21, w23, w31, w32, w33;
    color_weight_rom u_rom11 (.clk(clk), .addr(d11), .data(w11));
    color_weight_rom u_rom12 (.clk(clk), .addr(d12), .data(w12));
    color_weight_rom u_rom13 (.clk(clk), .addr(d13), .data(w13));
    color_weight_rom u_rom21 (.clk(clk), .addr(d21), .data(w21));
    color_weight_rom u_rom23 (.clk(clk), .addr(d23), .data(w23));
    color_weight_rom u_rom31 (.clk(clk), .addr(d31), .data(w31));
    color_weight_rom u_rom32 (.clk(clk), .addr(d32), .data(w32));
    color_weight_rom u_rom33 (.clk(clk), .addr(d33), .data(w33));
    // p22 的差值永远是 0，查表结果固定是最大值 15

    reg [7:0] s2_p11, s2_p12, s2_p13, s2_p21, s2_p22, s2_p23, s2_p31, s2_p32, s2_p33;
    always @(posedge clk) begin
        s2_p11<=s1_p11; s2_p12<=s1_p12; s2_p13<=s1_p13;
        s2_p21<=s1_p21; s2_p22<=s1_p22; s2_p23<=s1_p23;
        s2_p31<=s1_p31; s2_p32<=s1_p32; s2_p33<=s1_p33;
    end

    // --- Stage 3: 计算总权重 (空间权重 x 色差权重) ---
    // 空间权重写死：中心=4，十字=2，对角=1 (使用移位替代乘法极度省资源)
    reg [7:0] cw11, cw12, cw13, cw21, cw22, cw23, cw31, cw32, cw33;
    reg [7:0] s3_p11, s3_p12, s3_p13, s3_p21, s3_p22, s3_p23, s3_p31, s3_p32, s3_p33;

    always @(posedge clk) begin
        cw11 <= {4'd0, w11};       cw12 <= {3'd0, w12, 1'b0}; cw13 <= {4'd0, w13};       // 乘1, 乘2, 乘1
        cw21 <= {3'd0, w21, 1'b0}; cw22 <= 8'd60;             cw23 <= {3'd0, w23, 1'b0}; // 乘2, 15*4, 乘2
        cw31 <= {4'd0, w31};       cw32 <= {3'd0, w32, 1'b0}; cw33 <= {4'd0, w33};       // 乘1, 乘2, 乘1
        
        s3_p11<=s2_p11; s3_p12<=s2_p12; s3_p13<=s2_p13;
        s3_p21<=s2_p21; s3_p22<=s2_p22; s3_p23<=s2_p23;
        s3_p31<=s2_p31; s3_p32<=s2_p32; s3_p33<=s2_p33;
    end

    // --- Stage 4: 权重乘加树 (Level 1) ---
    reg [15:0] val11, val12, val13, val21, val22, val23, val31, val32, val33;
    reg [7:0]  w_sum_row1, w_sum_row2, w_sum_row3;

    always @(posedge clk) begin
        val11 <= s3_p11 * cw11; val12 <= s3_p12 * cw12; val13 <= s3_p13 * cw13;
        val21 <= s3_p21 * cw21; val22 <= s3_p22 * cw22; val23 <= s3_p23 * cw23;
        val31 <= s3_p31 * cw31; val32 <= s3_p32 * cw32; val33 <= s3_p33 * cw33;
        
        w_sum_row1 <= cw11 + cw12 + cw13;
        w_sum_row2 <= cw21 + cw22 + cw23;
        w_sum_row3 <= cw31 + cw32 + cw33;
    end

    // --- Stage 5: 权重乘加树 (Level 2) ---
    reg [15:0] sum_v_row1, sum_v_row2, sum_v_row3;
    reg [7:0]  w_sum_total_s5;

    always @(posedge clk) begin
        sum_v_row1 <= val11 + val12 + val13;
        sum_v_row2 <= val21 + val22 + val23;
        sum_v_row3 <= val31 + val32 + val33;
        w_sum_total_s5 <= w_sum_row1 + w_sum_row2 + w_sum_row3;
    end

    // --- Stage 6: 权重乘加树 (Level 3 - 获得总和) ---
    reg [15:0] sum_v_total_s6;
    reg [7:0]  w_sum_total_s6; // 继续打拍送给 ROM

    always @(posedge clk) begin
        sum_v_total_s6 <= sum_v_row1 + sum_v_row2 + sum_v_row3;
        w_sum_total_s6 <= w_sum_total_s5;
    end

    // --- Stage 7: 调用“散件3” - 倒数除法 ROM 查表 (耗时 1 拍) ---
    wire [16:0] inv_w;
    reg  [15:0] sum_v_total_s7; // 陪跑等待查表结果

    inverse_weight_rom u_inv_rom (.clk(clk), .addr(w_sum_total_s6), .data(inv_w));

    always @(posedge clk) begin
        sum_v_total_s7 <= sum_v_total_s6;
    end

    // --- Stage 8: 终极除法转乘法映射 ---
    reg [32:0] final_mult;
    always @(posedge clk) begin
        final_mult <= sum_v_total_s7 * inv_w;
    end

    // 最后的输出 (>> 16 位即是结果，对应 final_mult[23:16])
    assign y_out = final_mult[23:16];

endmodule