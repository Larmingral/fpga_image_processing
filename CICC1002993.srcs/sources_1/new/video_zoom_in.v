
// 核心：视频放大与 Line Buffer 节流模块
`timescale 1ns / 1ps
module video_zoom_in(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  zoom_state,
    input  wire        vs_in,
    input  wire        hs_in,
    input  wire        de_in,
    input  wire        data_req_in,   // 提前1拍的请求信号
    input  wire [15:0] sdram_rd_data, // SDRAM 返回数据

    output reg         vs_out,
    output reg         hs_out,
    output reg         de_out,
    output reg  [15:0] rgb_out,
    output wire        sdram_rd_en    // 截流后的读请求
);

    // --- 1. 时序整体打 2 拍以对齐 BRAM 的读取潜伏期 ---
    reg vs_d1, hs_d1, de_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vs_d1 <= 0; hs_d1 <= 0; de_d1 <= 0;
            vs_out <= 0; hs_out <= 0; de_out <= 0;
        end else begin
            vs_d1 <= vs_in; hs_d1 <= hs_in; de_d1 <= de_in;
            vs_out <= vs_d1; hs_out <= hs_d1; de_out <= de_d1;
        end
    end

    // --- 2. 基于数据请求 (data_req_in) 的预取坐标计算 ---
    reg [10:0] req_x, req_y;
    reg data_req_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_x <= 0; req_y <= 0; data_req_d1 <= 0;
        end else begin
            data_req_d1 <= data_req_in;
            if (vs_in && !vs_d1) begin // 场同步复位
                req_x <= 0; req_y <= 0;
            end else if (data_req_in) begin
                if (req_x == 11'd1279) req_x <= 0;
                else req_x <= req_x + 1'b1;
            end else if (!data_req_in && data_req_d1) begin // 行消隐期
                req_y <= req_y + 1'b1;
            end
        end
    end

    // --- 3. 基于数据有效 (de_in) 的像素输出坐标计算 ---
    reg [10:0] x_de, y_de;
    reg de_in_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x_de <= 0; y_de <= 0; de_in_d1 <= 0;
        end else begin
            de_in_d1 <= de_in;
            if (vs_in && !vs_d1) begin
                x_de <= 0; y_de <= 0;
            end else if (de_in) begin
                if (x_de == 11'd1279) x_de <= 0;
                else x_de <= x_de + 1'b1;
            end else if (!de_in && de_in_d1) begin
                y_de <= y_de + 1'b1;
            end
        end
    end

    // --- 4. SDRAM 请求节流：只在偶数行的偶数列发起读请求 ---
    assign sdram_rd_en = (zoom_state == 2'd3) ? 
                         (data_req_in && (req_x[0] == 1'b0) && (req_y[0] == 1'b0)) : 1'b0;

    // --- 5. BRAM Line Buffer 与双路数据分发 ---
    (* ramstyle = "M9K" *) reg [15:0] line_buf [0:639];
    reg [15:0] bram_rd_data;
    reg [15:0] pixel_bypass;
    reg [15:0] passthrough_data;
    reg        y_de_is_even_d1;

    always @(posedge clk) begin
        // 写入缓存 仅在偶数行、偶数列的 DE 期间写入
        if (zoom_state == 2'd3 && de_in && (y_de[0] == 1'b0) && (x_de[0] == 1'b0)) begin
            line_buf[x_de[10:1]] <= sdram_rd_data;
            pixel_bypass         <= sdram_rd_data; // 截留当前最新像素供偶数行使用
        end

        // 读出缓存 供奇数行重复利用
        bram_rd_data <= line_buf[x_de[10:1]];

        // 透传数据 供正常模式与缩小模式使用
        passthrough_data <= sdram_rd_data;

        // 流水线对齐行奇偶标志
        y_de_is_even_d1 <= (y_de[0] == 1'b0);
    end

    // --- 6. 终极像素路由与 2x2 复制算法 ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rgb_out <= 16'd0;
        else begin
            if (de_d1) begin
                if (zoom_state == 2'd3) begin
                    // 偶数行使用刚到达的鲜活数据，奇数行复用 BRAM 里的旧数据
                    // 非阻塞赋值固有的 1 拍延迟在此处完美充当了水平方向的 1 像素复制器
                    rgb_out <= y_de_is_even_d1 ? pixel_bypass : bram_rd_data;
                end else begin
                    // 保持整体延迟严格一致的透明直通
                    rgb_out <= passthrough_data;
                end
            end else begin
                rgb_out <= 16'd0;
            end
        end
    end
endmodule