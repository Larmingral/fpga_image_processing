`timescale 1ns / 1ps
// 模块：智能美颜滤镜 (升级版：5x5 超大视野形态学，强力去闪烁、去麻子)
module smart_beauty_filter #(
    // 保持相对宽容的阈值，让 5x5 形态学去负责去噪
    parameter CB_MIN = 8'd75,
    parameter CB_MAX = 8'd125,
    parameter CR_MIN = 8'd133,
    parameter CR_MAX = 8'd173,
    parameter BRIGHT_BOOST = 8'd40, // 增亮幅度
    parameter IMG_WIDTH = 1280
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

    // =======================================================
    // 0. 同步信号的 7 级长流水线延迟
    // =======================================================
    reg [6:0] vs_p, hs_p, de_p;
    always @(posedge clk) begin
        vs_p <= {vs_p[5:0], vs_in};
        hs_p <= {hs_p[5:0], hs_in};
        de_p <= {de_p[5:0], de_in};
    end

    // =======================================================
    // 1. 列计数与 5x5 行缓存体系 (Stage 0 -> Stage 1)
    // =======================================================
    reg [10:0] col_cnt;
    always @(posedge clk) begin
        if (!rst_n) col_cnt <= 11'd0;
        else if (!de_in) col_cnt <= 11'd0;
        else col_cnt <= col_cnt + 1'b1;
    end

    wire is_skin_raw = (cb_in >= CB_MIN && cb_in <= CB_MAX) && (cr_in >= CR_MIN && cr_in <= CR_MAX);

    // 为了 5x5 窗口，我们需要 4 行 1-bit 肤色缓存，和 2 行 24-bit 视频缓存(用来对齐中心)
    (* ram_style = "block" *) reg        mask_l1 [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg        mask_l2 [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg        mask_l3 [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg        mask_l4 [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg [23:0] vid_l1  [0:IMG_WIDTH-1];
    (* ram_style = "block" *) reg [23:0] vid_l2  [0:IMG_WIDTH-1];

    reg m1, m2, m3, m4;
    reg [23:0] v1, v2;

    always @(posedge clk) begin
        if (de_in) begin
            // 读出历史行
            m1 <= mask_l1[col_cnt]; m2 <= mask_l2[col_cnt]; 
            m3 <= mask_l3[col_cnt]; m4 <= mask_l4[col_cnt];
            v1 <= vid_l1[col_cnt];  v2 <= vid_l2[col_cnt];
            
            // 写入当前行
            mask_l1[col_cnt] <= is_skin_raw;
            mask_l2[col_cnt] <= m1;
            mask_l3[col_cnt] <= m2;
            mask_l4[col_cnt] <= m3;
            
            vid_l1[col_cnt] <= {y_in, cb_in, cr_in};
            vid_l2[col_cnt] <= v1;
        end
    end

    // =======================================================
    // 2. 5x5 窗口移位寄存器 (Stage 2)
    // =======================================================
    reg [4:0] r1, r2, r3, r4, r5;
    reg [23:0] center_vid;

    always @(posedge clk) begin
        if (de_p[0]) begin
            r1 <= {r1[3:0], m4}; // 最老的一行 (上)
            r2 <= {r2[3:0], m3};
            r3 <= {r3[3:0], m2}; // 中心行
            r4 <= {r4[3:0], m1};
            r5 <= {r5[3:0], is_skin_raw}; // 最新的一行 (下)
            
            // 视频像素取中心行 (v2) 作为目标
            center_vid <= v2;
        end
    end

    // =======================================================
    // 3. 统计 5x5 内肤色像素个数 (25个像素并行相加) (Stage 3 & 4)
    // =======================================================
    reg [3:0] s1, s2, s3, s4, s5; // 每行的和 (0~5)
    reg [23:0] vid_d3, vid_d4;
    reg [7:0] y_tgt, cb_tgt, cr_tgt;

    // Stage 3: 计算每行的和，并预计算美白目标值
    always @(posedge clk) begin
        if (de_p[1]) begin
            s1 <= r1[4]+r1[3]+r1[2]+r1[1]+r1[0];
            s2 <= r2[4]+r2[3]+r2[2]+r2[1]+r2[0];
            s3 <= r3[4]+r3[3]+r3[2]+r3[1]+r3[0];
            s4 <= r4[4]+r4[3]+r4[2]+r4[1]+r4[0];
            s5 <= r5[4]+r5[3]+r5[2]+r5[1]+r5[0];
            
            vid_d3 <= center_vid;
            
            // 预计算美白值 (带最高值保护)
            y_tgt  <= (center_vid[23:16] + BRIGHT_BOOST > 9'd235) ? 8'd235 : center_vid[23:16] + BRIGHT_BOOST;
            cb_tgt <= {1'b0, center_vid[15:9]} + 8'd64; 
            cr_tgt <= {1'b0, center_vid[7:1]}  + 8'd64; 
        end
    end

    // Stage 4: 汇总 25 个像素的总和
    reg [4:0] total_skin; // 最大值为 25
    always @(posedge clk) begin
        if (de_p[2]) begin
            total_skin <= s1 + s2 + s3 + s4 + s5;
            vid_d4 <= vid_d3;
        end
    end

    // =======================================================
    // 4. 超级膨胀/腐蚀 映射权重 (Stage 5)
    // =======================================================
    reg [3:0] alpha; // 0~8
    reg [23:0] vid_d5;
    reg [7:0] yt_d5, cbt_d5, crt_d5;

    always @(posedge clk) begin
        if (de_p[3]) begin
            vid_d5 <= vid_d4;
            yt_d5  <= y_tgt; cbt_d5 <= cb_tgt; crt_d5 <= cr_tgt;
            
            // 【这是抗闪烁的魔法核心逻辑】: 带有空间惯性的阈值
            if (total_skin <= 5'd4) 
                alpha <= 4'd0; // 强力腐蚀：少于4个点绝对是噪点，抹杀！
            else if (total_skin >= 5'd13) 
                alpha <= 4'd8; // 强力膨胀：过半是肤色，那中间绝对不可能是洞，强行填满100%美白！
            else if (total_skin >= 5'd10)
                alpha <= 4'd6; // 75% 渐变
            else if (total_skin >= 5'd7)
                alpha <= 4'd4; // 50% 渐变
            else 
                alpha <= 4'd2; // 25% 渐变
        end
    end

    // =======================================================
    // 5. Alpha 混叠计算 (Stage 6)
    // =======================================================
    reg [11:0] y_blend, cb_blend, cr_blend;
    always @(posedge clk) begin
        if (de_p[4]) begin
            y_blend  <= (yt_d5  * alpha + vid_d5[23:16] * (4'd8 - alpha)) >> 3;
            cb_blend <= (cbt_d5 * alpha + vid_d5[15:8]  * (4'd8 - alpha)) >> 3;
            cr_blend <= (crt_d5 * alpha + vid_d5[7:0]   * (4'd8 - alpha)) >> 3;
        end
    end

    // =======================================================
    // 6. 最终输出 (Stage 7)
    // =======================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_out <= 0; hs_out <= 0; de_out <= 0;
            y_out <= 0; cb_out <= 0; cr_out <= 0;
        end else begin
            vs_out <= vs_p[6];
            hs_out <= hs_p[6];
            de_out <= de_p[6];
            
            if (de_p[6]) begin
                y_out  <= y_blend[7:0];
                cb_out <= cb_blend[7:0];
                cr_out <= cr_blend[7:0];
            end else begin
                y_out <= 8'd16; cb_out <= 8'd128; cr_out <= 8'd128;
            end
        end
    end

endmodule