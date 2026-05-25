`timescale 1ns / 1ps
// 模块：视频同步与路由统一控制器
module video_ctrl #(
    parameter H_PIXEL = 11'd1280,
    parameter V_PIXEL = 11'd720
)(
    input  wire        clk_100m,
    input  wire        sys_rst_n,
    input  wire        locked_all,      
    input  wire [1:0]  zoom_state_raw,
    input  wire        rot_en_raw,
    input  wire        cam_pclk,
    input  wire        cam_vsync,
    input  wire        wr_en_in,        
    input  wire [15:0] wr_data_in,      
    input  wire        hdmi_clk,
    input  wire        hdmi_vs,
    input  wire        rd_en_in,        
    
    output wire        global_rst_n,
    output wire        sdram_rst_n,
    output reg  [23:0] safe_sdram_addr,
    
    output reg         final_wr_en,
    output reg  [15:0] final_wr_data,
    output wire        safe_rd_en,
    
    output wire        rot_en_sync_out  
);

// [1] 100MHz 时钟域复位
reg [1:0] zoom_100m_d1, zoom_100m_d2, zoom_100m_d3;
always @(posedge clk_100m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        zoom_100m_d1 <= 2'd0; zoom_100m_d2 <= 2'd0; zoom_100m_d3 <= 2'd0;
    end else begin
        zoom_100m_d1 <= zoom_state_raw;
        zoom_100m_d2 <= zoom_100m_d1;
        zoom_100m_d3 <= zoom_100m_d2;
    end
end

reg [15:0] soft_rst_cnt;
reg        soft_rst_n;
always @(posedge clk_100m or negedge sys_rst_n) begin
    if (!sys_rst_n) begin
        soft_rst_cnt <= 16'd0; soft_rst_n <= 1'b0;
    end else if (zoom_100m_d2 != zoom_100m_d3) begin
        soft_rst_cnt <= 16'hFFFF; soft_rst_n <= 1'b0;
    end else if (soft_rst_cnt != 16'd0) begin
        soft_rst_cnt <= soft_rst_cnt - 1'b1; soft_rst_n <= 1'b0;
    end else begin
        soft_rst_n <= 1'b1;
    end
end

assign global_rst_n = sys_rst_n & locked_all;
assign sdram_rst_n  = global_rst_n & soft_rst_n;

always @(posedge clk_100m or negedge sdram_rst_n) begin 
    if (!sdram_rst_n) begin
        safe_sdram_addr <= (zoom_100m_d2[0] == 1'b1) ? 24'd230399 : (V_PIXEL*H_PIXEL-1);
    end
end

// [2] cam_pclk 时钟域写与路由
reg cam_vsync_d1;
always @(posedge cam_pclk or negedge global_rst_n) begin
    if (!global_rst_n) cam_vsync_d1 <= 1'b0;
    else               cam_vsync_d1 <= cam_vsync;
end
wire vsync_neg = !cam_vsync && cam_vsync_d1;

reg wr_wait_vsync;
always @(posedge cam_pclk or negedge global_rst_n) begin
    if (!global_rst_n)     wr_wait_vsync <= 1'b0;
    else if (!sdram_rst_n) wr_wait_vsync <= 1'b1; 
    else if (vsync_neg)    wr_wait_vsync <= 1'b0; 
end

wire safe_wr_en = wr_en_in & ~wr_wait_vsync;

reg [1:0] zoom_cam_d1, zoom_cam_d2;
always @(posedge cam_pclk or negedge global_rst_n) begin 
    if (!global_rst_n) begin zoom_cam_d1 <= 2'd0; zoom_cam_d2 <= 2'd0; end 
    else begin zoom_cam_d1 <= zoom_state_raw; zoom_cam_d2 <= zoom_cam_d1; end
end

reg [10:0] pixel_x;
reg [10:0] pixel_y;
always @(posedge cam_pclk or negedge global_rst_n) begin 
    if (!global_rst_n) begin
        pixel_x <= 11'd0; pixel_y <= 11'd0;
    end else if (vsync_neg) begin
        pixel_x <= 11'd0; pixel_y <= 11'd0;
    end else if (safe_wr_en) begin 
        if (pixel_x == H_PIXEL - 11'd1) begin
            pixel_x <= 11'd0; pixel_y <= pixel_y + 1'b1;
        end else begin
            pixel_x <= pixel_x + 1'b1;
        end
    end
end

wire keep_pixel = (pixel_x[0] == 1'b0) && (pixel_y[0] == 1'b0);
wire center_crop = (pixel_x >= 11'd320 && pixel_x < 11'd960) &&
                   (pixel_y >= 11'd180 && pixel_y < 11'd540);

reg wr_en_zoomed;
always @(*) begin
    case(zoom_cam_d2)
        2'd1:    wr_en_zoomed = safe_wr_en && keep_pixel;  
        2'd3:    wr_en_zoomed = safe_wr_en && center_crop; 
        default: wr_en_zoomed = safe_wr_en;                
    endcase
end

// 旋转对齐逻辑 (消除噪点的关键)
reg         rot_en_sync;
wire        wr_en_rev;
wire [15:0] wr_data_rev;
always @(posedge cam_pclk or negedge global_rst_n) begin 
    if (!global_rst_n) rot_en_sync <= 1'b0;
    else if (vsync_neg) rot_en_sync <= rot_en_raw; // 只在帧起点切换
end

//将对齐好的旋转状态输出
assign rot_en_sync_out = rot_en_sync; 

pingpong_burst_reverser u_burst_reverser(
    .clk        (cam_pclk),
    .rst_n      (sdram_rst_n),  
    .din_valid  (wr_en_zoomed), 
    .din        (wr_data_in),
    .dout_valid (wr_en_rev),
    .dout       (wr_data_rev)
);

always @(posedge cam_pclk or negedge global_rst_n) begin 
    if (!global_rst_n) begin final_wr_en <= 1'b0; final_wr_data <= 16'd0; end 
    else begin
        final_wr_en   <= rot_en_sync ? wr_en_rev   : wr_en_zoomed; 
        final_wr_data <= rot_en_sync ? wr_data_rev : wr_data_in;
    end
end

// [3] hdmi_clk 时钟域读门禁
reg hdmi_vs_d1;
always @(posedge hdmi_clk or negedge global_rst_n) begin
    if (!global_rst_n) hdmi_vs_d1 <= 1'b0;
    else               hdmi_vs_d1 <= hdmi_vs;
end
wire hdmi_vs_neg = !hdmi_vs && hdmi_vs_d1;

reg rd_wait_vsync;
always @(posedge hdmi_clk or negedge global_rst_n) begin
    if (!global_rst_n)     rd_wait_vsync <= 1'b0;
    else if (!sdram_rst_n) rd_wait_vsync <= 1'b1;
    else if (hdmi_vs_neg)  rd_wait_vsync <= 1'b0;
end

assign safe_rd_en = rd_en_in & ~rd_wait_vsync;

endmodule