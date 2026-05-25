// 模块：YCbCr 转 RGB 
module ycbcr2rgb(
    input  wire        clk,
    input  wire        rst_n,
    
    // 输入 YCbCr 信号
    input  wire        vs_i,
    input  wire        hs_i,
    input  wire        de_i,
    input  wire [7:0]  y_i,
    input  wire [7:0]  cb_i,
    input  wire [7:0]  cr_i,
    
    // 输出 RGB 信号
    output reg         vs_o,
    output reg         hs_o,
    output reg         de_o,
    output reg  [7:0]  r_o,
    output reg  [7:0]  g_o,
    output reg  [7:0]  b_o
);


// --- 第 1 级流水线：计算偏移量 (转为有符号数计算) ---
reg signed [9:0] y_val;
reg signed [9:0] cb_diff;
reg signed [9:0] cr_diff;
reg vs_d1, hs_d1, de_d1;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        y_val <= 0; cb_diff <= 0; cr_diff <= 0;
        vs_d1 <= 0; hs_d1 <= 0; de_d1 <= 0;
    end else begin
        vs_d1 <= vs_i; hs_d1 <= hs_i; de_d1 <= de_i;
        y_val   <= {2'b00, y_i};
        cb_diff <= {1'b0, cb_i} - 10'd128;
        cr_diff <= {1'b0, cr_i} - 10'd128;
    end
end

// --- 第 2 级流水线：乘法 ---
reg signed [19:0] mult_r_cr, mult_g_cb, mult_g_cr, mult_b_cb;
reg vs_d2, hs_d2, de_d2;
reg signed [9:0] y_val_d2; // Y 需要延迟一拍匹配乘法器

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        mult_r_cr <= 0; mult_g_cb <= 0; mult_g_cr <= 0; mult_b_cb <= 0;
        y_val_d2 <= 0;
        vs_d2 <= 0; hs_d2 <= 0; de_d2 <= 0;
    end else begin
        vs_d2 <= vs_d1; hs_d2 <= hs_d1; de_d2 <= de_d1;
        y_val_d2  <= y_val;
        mult_r_cr <= cr_diff * 20'sd359;
        mult_g_cb <= cb_diff * 20'sd88;
        mult_g_cr <= cr_diff * 20'sd183;
        mult_b_cb <= cb_diff * 20'sd454;
    end
end

// --- 第 3 级流水线：加减法与防溢出截断 (Clamp) ---
wire signed [19:0] y_scaled = y_val_d2 * 20'sd256;
wire signed [19:0] r_result = y_scaled + mult_r_cr;
wire signed [19:0] g_result = y_scaled - mult_g_cb - mult_g_cr;
wire signed [19:0] b_result = y_scaled + mult_b_cb;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        r_o <= 0; g_o <= 0; b_o <= 0;
        vs_o <= 0; hs_o <= 0; de_o <= 0;
    end else begin
        vs_o <= vs_d2; hs_o <= hs_d2; de_o <= de_d2;
        
        // R 通道溢出保护
        if(r_result[19] == 1'b1) r_o <= 8'd0; // 负数变0
        else if(r_result > 20'sd65280) r_o <= 8'd255; // 超过255截断
        else r_o <= r_result[15:8];
        
        // G 通道溢出保护
        if(g_result[19] == 1'b1) g_o <= 8'd0; 
        else if(g_result > 20'sd65280) g_o <= 8'd255; 
        else g_o <= g_result[15:8];
        
        // B 通道溢出保护
        if(b_result[19] == 1'b1) b_o <= 8'd0; 
        else if(b_result > 20'sd65280) b_o <= 8'd255; 
        else b_o <= b_result[15:8];
    end
end

endmodule