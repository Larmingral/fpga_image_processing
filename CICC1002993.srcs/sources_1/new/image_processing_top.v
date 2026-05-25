`timescale 1ns / 1ps
// 模块：图像处理总管线
module image_processing_top(
input  wire        clk,          // hdmi_clk
input  wire        rst_n,
input  wire [2:0]  mode,         // 0:原图 1:灰度 2:二值 3:反相 4:均衡化 5:双边滤波
input  wire [1:0]  zoom_en,
input  wire [15:0] rd_data,      
output wire        rd_en,        

output wire        vs_out,
output wire        hs_out,
output wire        de_out,
output wire [23:0] rgb_out
);
// --- 阶段0：跨时钟同步 ---
reg [1:0] zoom_hdmi_d2;
always @(posedge clk) zoom_hdmi_d2 <= zoom_en;
// --- 阶段1：时序生成 ---
wire video_hs, video_vs, video_de, driver_rd_en;
wire [10:0] pixel_xpos, pixel_ypos;
video_driver u_video_driver(
.pixel_clk(clk),
.sys_rst_n(rst_n),
.video_hs(video_hs),
.video_vs(video_vs),
.video_de(video_de),
.data_req(driver_rd_en),
.pixel_xpos(pixel_xpos),
.pixel_ypos(pixel_ypos),
.pixel_data(16'd0)
);
// --- 阶段2：缩放处理 ---
wire zoom_vs, zoom_hs, zoom_de;
wire [15:0] zoom_rgb;
wire zoom_sdram_rd_en;
wire in_zoom_window = (pixel_xpos >= 11'd320 && pixel_xpos < 11'd960) && (pixel_ypos >= 11'd180 && pixel_ypos < 11'd540);
wire [15:0] masked_rd_data = (zoom_hdmi_d2 == 2'd1 && !in_zoom_window) ? 16'd0 : rd_data;
video_zoom_in u_zoom_in(
.clk(clk),
.rst_n(rst_n),
.zoom_state(zoom_hdmi_d2),
.vs_in(video_vs),
.hs_in(video_hs),
.de_in(video_de),
.data_req_in(driver_rd_en),
.sdram_rd_data(masked_rd_data),
.vs_out(zoom_vs),
.hs_out(zoom_hs),
.de_out(zoom_de),
.rgb_out(zoom_rgb),
.sdram_rd_en(zoom_sdram_rd_en)
);
assign rd_en = (zoom_hdmi_d2 == 2'd3) ? zoom_sdram_rd_en : ((zoom_hdmi_d2 == 2'd1) ? (driver_rd_en && in_zoom_window) : driver_rd_en);
// --- 阶段3：色彩空间转换 ---
wire ycbcr_hs, ycbcr_vs, ycbcr_de;
wire [7:0] ycbcr_y, ycbcr_cb, ycbcr_cr;
rgb2ycbcr u_rgb2ycbcr(
.clk(clk),
.rst_n(rst_n),
.vs_i(zoom_vs),
.hs_i(zoom_hs),
.de_i(zoom_de),
.r_i({zoom_rgb[15:11],3'b0}),
.g_i({zoom_rgb[10:5],2'b0}),
.b_i({zoom_rgb[4:0],3'b0}),
.vs_o(ycbcr_vs),
.hs_o(ycbcr_hs),
.de_o(ycbcr_de),
.y_o(ycbcr_y),
.cb_o(ycbcr_cb),
.cr_o(ycbcr_cr)
);
// --- 阶段4A：直方图均衡化 (旁路模式) ---
wire hist_frame_done, hist_rd_en, lut_ready;
wire [7:0] hist_rd_addr, y_eq_val;
wire [23:0] hist_rd_data;
reg is_first_pixel;
always @(posedge clk or negedge rst_n) begin
if (!rst_n) is_first_pixel <= 1'b0;
else if (!ycbcr_vs) is_first_pixel <= 1'b1;
else if (ycbcr_de) is_first_pixel <= 1'b0;
end
histogram_statistic #(.IMG_WIDTH(1280), .IMG_HEIGHT(720)) u_hist_stat (
.clk(clk),
.rst_n(rst_n),
.s_axis_tdata(ycbcr_y),
.s_axis_tvalid(ycbcr_de),
.s_axis_tready(),
.s_axis_tuser(ycbcr_de & is_first_pixel),
.s_axis_tlast(1'b0),
.i_ram_read_en(hist_rd_en),
.i_ram_read_addr(hist_rd_addr),
.o_ram_read_data(hist_rd_data),
.o_frame_done(hist_frame_done)
);
cdf_lut_generator #(.IMG_WIDTH(1280), .IMG_HEIGHT(720)) u_cdf_lut (
.clk(clk),
.rst_n(rst_n),
.i_frame_done(hist_frame_done),
.o_hist_rd_en(hist_rd_en),
.o_hist_rd_addr(hist_rd_addr),
.i_hist_rd_data(hist_rd_data),
.i_lut_rd_en(1'b1),
.i_lut_rd_addr(ycbcr_y),
.o_lut_rd_data(y_eq_val),
.o_lut_ready(lut_ready)
);
// --- 阶段4B：基础算法处理核心 (Mode 0-4) ---
wire proc_vs, proc_hs, proc_de;
wire [7:0] proc_y, proc_cb, proc_cr;
video_processor u_vid_proc (
.clk(clk),
.rst_n(rst_n),
.mode(mode),
.vs_in(ycbcr_vs),
.hs_in(ycbcr_hs),
.de_in(ycbcr_de),
.y_in(ycbcr_y),
.cb_in(ycbcr_cb),
.cr_in(ycbcr_cr),
.y_eq_in(y_eq_val),
.lut_ready(lut_ready),
.vs_out(proc_vs),
.hs_out(proc_hs),
.de_out(proc_de),
.y_out(proc_y),
.cb_out(proc_cb),
.cr_out(proc_cr)
);
// --- 阶段4C：双边滤波处理核心 (Mode 5) ---
wire bf_vs, bf_hs, bf_de;
wire [7:0] bf_y, bf_cb, bf_cr;
bilateral_filter #(.IMG_WIDTH(1280)) u_bf (
.clk(clk),
.rst_n(rst_n),
.vs_in(ycbcr_vs),
.hs_in(ycbcr_hs),
.de_in(ycbcr_de),
.y_in(ycbcr_y),
.cb_in(ycbcr_cb),
.cr_in(ycbcr_cr),
.vs_out(bf_vs),
.hs_out(bf_hs),
.de_out(bf_de),
.y_out(bf_y),
.cb_out(bf_cb),
.cr_out(bf_cr)
);
// ====== 仅仅在这里加入一段独立外挂代码，绝不碰你上面的任何功能 ======

// --- 阶段4D：新增超轻量级形态学分支 (Mode 6:腐蚀, 7:膨胀) ---
wire morph_vs, morph_hs, morph_de;
wire [7:0] morph_y, morph_cb, morph_cr;

morphology_lite #(.IMG_WIDTH(1280)) u_morphology (
    .clk    (clk),
    .rst_n  (rst_n),
    .mode   (mode),
    
    // 只接 Y 分量和同步信号进去
    .vs_in  (ycbcr_vs), 
    .hs_in  (ycbcr_hs), 
    .de_in  (ycbcr_de), 
    .y_in   (ycbcr_y), 
    
    .vs_out (morph_vs),
    .hs_out (morph_hs), 
    .de_out (morph_de), 
    .y_out  (morph_y), 
    .cb_out (morph_cb), 
    .cr_out (morph_cr)
);

// --- 阶段4E：手部红框追踪测试 (继续霸占 Mode 3) ---
wire roi_vs, roi_hs, roi_de;
wire [7:0] roi_y, roi_cb, roi_cr;

roi_bounding_box #(
    .CB_MIN(8'd77), .CB_MAX(8'd127),
    .CR_MIN(8'd133), .CR_MAX(8'd173)
) u_roi_box (
    .clk    (clk),
    .rst_n  (rst_n),
    .vs_in  (ycbcr_vs), 
    .hs_in  (ycbcr_hs), 
    .de_in  (ycbcr_de), 
    .y_in   (ycbcr_y),    // 注意！这里把原图送进去了，所以出来的是原图叠红框
    .cb_in  (ycbcr_cb), 
    .cr_in  (ycbcr_cr),
    .vs_out (roi_vs),
    .hs_out (roi_hs), 
    .de_out (roi_de), 
    .y_out  (roi_y), 
    .cb_out (roi_cb), 
    .cr_out (roi_cr)
);

// --- 阶段4F：支线任务 - 智能美颜测试 (临时霸占 Mode 2) ---
wire beauty_vs, beauty_hs, beauty_de;
wire [7:0] beauty_y, beauty_cb, beauty_cr;

smart_beauty_filter #(
    .CB_MIN(8'd85), .CB_MAX(8'd115),
    .CR_MIN(8'd135), .CR_MAX(8'd160)
) u_beauty (
    .clk    (clk),
    .rst_n  (rst_n),
    .vs_in  (ycbcr_vs), 
    .hs_in  (ycbcr_hs), 
    .de_in  (ycbcr_de), 
    .y_in   (ycbcr_y),    
    .cb_in  (ycbcr_cb), 
    .cr_in  (ycbcr_cr),
    .vs_out (beauty_vs),
    .hs_out (beauty_hs), 
    .de_out (beauty_de), 
    .y_out  (beauty_y), 
    .cb_out (beauty_cb), 
    .cr_out (beauty_cr)
);

// --- 最终信号选择 MUX ---
// 我们把 Mode 2 换成 beauty_vs，其他一切不变！
wire sel_vs = (mode == 3'd2) ? beauty_vs : ((mode == 3'd3) ? roi_vs : ((mode == 3'd6 || mode == 3'd7) ? morph_vs : ((mode == 3'd5) ? bf_vs : proc_vs)));
wire sel_hs = (mode == 3'd2) ? beauty_hs : ((mode == 3'd3) ? roi_hs : ((mode == 3'd6 || mode == 3'd7) ? morph_hs : ((mode == 3'd5) ? bf_hs : proc_hs)));
wire sel_de = (mode == 3'd2) ? beauty_de : ((mode == 3'd3) ? roi_de : ((mode == 3'd6 || mode == 3'd7) ? morph_de : ((mode == 3'd5) ? bf_de : proc_de)));
wire [7:0] sel_y  = (mode == 3'd2) ? beauty_y  : ((mode == 3'd3) ? roi_y  : ((mode == 3'd6 || mode == 3'd7) ? morph_y  : ((mode == 3'd5) ? bf_y  : proc_y)));
wire [7:0] sel_cb = (mode == 3'd2) ? beauty_cb : ((mode == 3'd3) ? roi_cb : ((mode == 3'd6 || mode == 3'd7) ? morph_cb : ((mode == 3'd5) ? bf_cb : proc_cb)));
wire [7:0] sel_cr = (mode == 3'd2) ? beauty_cr : ((mode == 3'd3) ? roi_cr : ((mode == 3'd6 || mode == 3'd7) ? morph_cr : ((mode == 3'd5) ? bf_cr : proc_cr)));

// ====================================================================

// --- 阶段5：后处理遮罩与输出 ---
reg [10:0] px_x, px_y;
reg de_d1;
always @(posedge clk) begin
de_d1 <= sel_de;
if (!sel_de) begin px_x <= 0; if (vs_out) px_y <= 0; end
else begin px_x <= px_x + 1'b1; if (!sel_de && de_d1) px_y <= px_y + 1'b1; end
end
ycbcr2rgb u_ycbcr2rgb(
.clk(clk),
.rst_n(rst_n),
.vs_i(sel_vs),
.hs_i(sel_hs),
.de_i(sel_de),
.y_i(sel_y),
.cb_i(sel_cb),
.cr_i(sel_cr),
.vs_o(vs_out),
.hs_o(hs_out),
.de_o(de_out),
.r_o(rgb_out[23:16]),
.g_o(rgb_out[15:8]),
.b_o(rgb_out[7:0])
);
endmodule