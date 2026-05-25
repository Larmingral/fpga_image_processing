// 模块：RGB 转 YCbCr 
module rgb2ycbcr(
    input  wire        clk,
    input  wire        rst_n,
    
    // 输入 RGB 信号
    input  wire        vs_i,
    input  wire        hs_i,
    input  wire        de_i,
    input  wire [7:0]  r_i,
    input  wire [7:0]  g_i,
    input  wire [7:0]  b_i,
    
    // 输出 YCbCr 信号
    output reg         vs_o,
    output reg         hs_o,
    output reg         de_o,
    output reg  [7:0]  y_o,
    output reg  [7:0]  cb_o,
    output reg  [7:0]  cr_o
);

// --- 第 1 级流水线：乘法 ---
reg [15:0] mult_r_y, mult_g_y, mult_b_y;
reg [15:0] mult_r_cb, mult_g_cb, mult_b_cb;
reg [15:0] mult_r_cr, mult_g_cr, mult_b_cr;
reg vs_d1, hs_d1, de_d1;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        mult_r_y <= 0; mult_g_y <= 0; mult_b_y <= 0;
        mult_r_cb<= 0; mult_g_cb<= 0; mult_b_cb<= 0;
        mult_r_cr<= 0; mult_g_cr<= 0; mult_b_cr<= 0;
        vs_d1 <= 0; hs_d1 <= 0; de_d1 <= 0;
    end else begin
        vs_d1 <= vs_i; hs_d1 <= hs_i; de_d1 <= de_i;
        mult_r_y  <= r_i * 8'd66;  mult_g_y  <= g_i * 8'd129; mult_b_y  <= b_i * 8'd25;
        mult_r_cb <= r_i * 8'd38;  mult_g_cb <= g_i * 8'd74;  mult_b_cb <= b_i * 8'd112;
        mult_r_cr <= r_i * 8'd112; mult_g_cr <= g_i * 8'd94;  mult_b_cr <= b_i * 8'd18;
    end
end

// --- 第 2 级流水线：加减法 ---
reg [15:0] add_y, add_cb, add_cr;
reg vs_d2, hs_d2, de_d2;

always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        add_y <= 0; add_cb <= 0; add_cr <= 0;
        vs_d2 <= 0; hs_d2 <= 0; de_d2 <= 0;
    end else begin
        vs_d2 <= vs_d1; hs_d2 <= hs_d1; de_d2 <= de_d1;
        add_y  <= mult_r_y + mult_g_y + mult_b_y + 16'd4096;
        add_cb <= mult_b_cb - mult_r_cb - mult_g_cb + 16'd32768;
        add_cr <= mult_r_cr - mult_g_cr - mult_b_cr + 16'd32768;
    end
end

// --- 第 3 级流水线：移位与输出 ---
always @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
        y_o <= 0; cb_o <= 0; cr_o <= 0;
        vs_o <= 0; hs_o <= 0; de_o <= 0;
    end else begin
        vs_o <= vs_d2; hs_o <= hs_d2; de_o <= de_d2;
        y_o  <= add_y[15:8];
        cb_o <= add_cb[15:8];
        cr_o <= add_cr[15:8];
    end
end

endmodule