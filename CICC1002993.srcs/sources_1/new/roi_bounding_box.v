`timescale 1ns / 1ps
// 模块：手部 ROI 边框追踪与叠加显示 (带 2D 腐蚀抗噪与 IIR 平滑追踪)
module roi_bounding_box #(
    // 收紧的肤色阈值
    parameter CB_MIN = 8'd85,
    parameter CB_MAX = 8'd115,
    parameter CR_MIN = 8'd135,
    parameter CR_MAX = 8'd160
)(
    input  wire        clk,
    input  wire        rst_n,
    
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire [7:0]  y_in,
    input  wire [7:0]  cb_in,
    input  wire [7:0]  cr_in,
    
    output reg         vs_out,
    output reg         hs_out,
    output reg         de_out,
    output reg  [7:0]  y_out,
    output reg  [7:0]  cb_out,
    output reg  [7:0]  cr_out
);

    // =========================================================
    // 1. 坐标与场同步检测
    // =========================================================
    reg de_d1, vs_d1;
    reg is_first_pixel;
    reg [10:0] px_x, px_y;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            de_d1 <= 0; vs_d1 <= 0;
            is_first_pixel <= 0;
            px_x <= 0; px_y <= 0;
        end else begin
            de_d1 <= de_in; vs_d1 <= vs_in;
            
            if (vs_in != vs_d1) is_first_pixel <= 1'b1;  
            else if (de_in)     is_first_pixel <= 1'b0; 
                
            if (de_in && is_first_pixel) px_y <= 0;
            else if (!de_in && de_d1)    px_y <= px_y + 1'b1;
            
            if (de_in) px_x <= px_x + 1'b1;
            else       px_x <= 0;
        end
    end
    wire frame_start_trigger = (de_in && is_first_pixel);

    // =========================================================
    // 2. 肤色检测与 2D 二值形态学滤波 (1-bit 超低资源)
    // =========================================================
    // 初始肤色二值化
    wire is_skin_raw = (cb_in >= CB_MIN && cb_in <= CB_MAX) && (cr_in >= CR_MIN && cr_in <= CR_MAX);
    
    // 1-bit 行缓存 (分布式或块RAM均可，非常省资源)
    reg line_buf_1 [0:1279];
    reg line_buf_2 [0:1279];
    reg r1, r2, r3;
    
    always @(posedge clk) begin
        if (de_in) begin
            r1 <= line_buf_2[px_x];
            r2 <= line_buf_1[px_x];
            r3 <= is_skin_raw;
            line_buf_1[px_x] <= is_skin_raw;
            line_buf_2[px_x] <= r2;
        end
    end

    // 3x3 移位寄存器
    reg p11, p12, p13;
    reg p21, p22, p23;
    reg p31, p32, p33;
    always @(posedge clk) begin
        if (de_in) begin
            p13 <= r1; p12 <= p13; p11 <= p12;
            p23 <= r2; p22 <= p23; p21 <= p22;
            p33 <= r3; p32 <= p33; p31 <= p32;
        end
    end

    // 强大的 2D 腐蚀：必须 3x3 窗口内全为肤色，中心才被承认为手！
    // 哪怕是一个 2x2 的块状噪点，也会在这里被无情抹杀！
    wire is_skin_eroded = p11 & p12 & p13 & 
                          p21 & p22 & p23 & 
                          p31 & p32 & p33;

    // =========================================================
    // 3. 极值统计与 IIR 平滑追踪 (滤除闪烁跳变)
    // =========================================================
    wire safe_zone = (px_x > 11'd20 && px_x < 11'd1260) && (px_y > 11'd20 && px_y < 11'd700);
    
    reg [10:0] min_x, max_x, min_y, max_y;
    reg [10:0] draw_min_x, draw_max_x, draw_min_y, draw_max_y;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            min_x <= 11'd2047; max_x <= 0; min_y <= 11'd2047; max_y <= 0;
            draw_min_x <= 0; draw_max_x <= 0; draw_min_y <= 0; draw_max_y <= 0;
        end else if (frame_start_trigger) begin
            
            // 只有当框出来的面积足够大（比如边长大于 40 像素），我们才认为是真的手，而不是一小撮顽固噪点
            if (max_x > min_x + 11'd40 && max_y > min_y + 11'd40) begin
                // 【核心魔法：IIR 低通滤波】
                // 新位置 = 旧位置 * 0.75 + 新测量值 * 0.25
                // 这样画出的框带有惯性，绝不闪烁，丝滑追踪！
                draw_min_x <= draw_min_x - (draw_min_x >> 2) + (min_x >> 2);
                draw_max_x <= draw_max_x - (draw_max_x >> 2) + (max_x >> 2);
                draw_min_y <= draw_min_y - (draw_min_y >> 2) + (min_y >> 2);
                draw_max_y <= draw_max_y - (draw_max_y >> 2) + (max_y >> 2);
            end
            // 如果这一帧没找到足够大的手，保留上一帧的框（短暂停留），避免框突然消失闪烁
            
            // 变量复位，迎接下一帧
            min_x <= 11'd2047; max_x <= 0; min_y <= 11'd2047; max_y <= 0;
            
        end else if (de_in && is_skin_eroded && safe_zone) begin
            // 打擂台：用【已经被腐蚀去噪】的像素更新坐标
            if (px_x < min_x) min_x <= px_x;
            if (px_x > max_x) max_x <= px_x;
            if (px_y < min_y) min_y <= px_y;
            if (px_y > max_y) max_y <= px_y;
        end
    end

    // =========================================================
    // 4. 三级流水线画框
    // =========================================================
    reg [2:0] vs_p, hs_p, de_p;
    reg [7:0] y_p [2:0], cb_p [2:0], cr_p [2:0];
    reg x_in_range, y_in_range, x_is_edge, y_is_edge;
    reg draw_box_p2;

    always @(posedge clk) begin
        vs_p <= {vs_p[1:0], vs_in}; hs_p <= {hs_p[1:0], hs_in}; de_p <= {de_p[1:0], de_in};
        y_p[0] <= y_in; y_p[1] <= y_p[0]; y_p[2] <= y_p[1];
        cb_p[0] <= cb_in; cb_p[1] <= cb_p[0]; cb_p[2] <= cb_p[1];
        cr_p[0] <= cr_in; cr_p[1] <= cr_p[0]; cr_p[2] <= cr_p[1];

        x_in_range <= (px_x >= draw_min_x) && (px_x <= draw_max_x);
        y_in_range <= (px_y >= draw_min_y) && (px_y <= draw_max_y);
        
        // 线宽 3 个像素
        x_is_edge <= (px_x >= draw_min_x && px_x <= draw_min_x + 11'd2) || 
                     (px_x + 11'd2 >= draw_max_x && px_x <= draw_max_x);
        y_is_edge <= (px_y >= draw_min_y && px_y <= draw_min_y + 11'd2) || 
                     (px_y + 11'd2 >= draw_max_y && px_y <= draw_max_y);

        draw_box_p2 <= (x_is_edge && y_in_range) || (y_is_edge && x_in_range);
    end

    // =========================================================
    // 5. 最终输出
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 0; hs_out <= 0; de_out <= 0;
            y_out <= 0; cb_out <= 0; cr_out <= 0;
        end else begin
            vs_out <= vs_p[2]; hs_out <= hs_p[2]; de_out <= de_p[2];
            
            if (de_p[2]) begin
                if (draw_box_p2 && draw_max_x > draw_min_x && draw_max_y > draw_min_y) begin
                    y_out <= 8'd81; cb_out <= 8'd90; cr_out <= 8'd240; // 纯红框
                end else begin
                    y_out <= y_p[2]; cb_out <= cb_p[2]; cr_out <= cr_p[2];
                end
            end else begin
                y_out <= 8'd16; cb_out <= 8'd128; cr_out <= 8'd128;
            end
        end
    end

endmodule