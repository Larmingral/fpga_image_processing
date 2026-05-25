`timescale 1ns / 1ps
// 模块：HDMI物理层驱动 
module hdmi_top( 
    input         hdmi_clk,      
    input         rst_n,         
    input  [2:0]  current_mode,  // UART所需 
	
    // 从图像处理管线传来的完美同步视频流
    input         final_vs,
    input         final_hs,
    input         final_de,
    input  [23:0] final_rgb,
    
    // 物理层引脚接口
    output        hdmi_clk_out,  
    output [23:0] hdmi_data,     
    output        hdmi_hs,       
    output        hdmi_vs,       
    output        hdmi_de,       
    output wire   ddc_scl,
    inout  wire   ddc_sda,      
    output wire   uart_tx        
);


reg        hdmi_vs_reg;
reg        hdmi_hs_reg;
reg        hdmi_de_reg;
reg [23:0] hdmi_data_reg;

always @(posedge hdmi_clk or negedge rst_n) begin
    if (!rst_n) begin
        hdmi_vs_reg   <= 1'b0;
        hdmi_hs_reg   <= 1'b0;
        hdmi_de_reg   <= 1'b0;
        hdmi_data_reg <= 24'd0;
    end else begin
        hdmi_vs_reg   <= final_vs;
        hdmi_hs_reg   <= final_hs;
        hdmi_de_reg   <= final_de;
        hdmi_data_reg <= final_rgb;
    end
end

assign hdmi_data   = hdmi_data_reg;
assign hdmi_hs     = hdmi_hs_reg;
assign hdmi_vs     = hdmi_vs_reg;
assign hdmi_de     = hdmi_de_reg;
assign hdmi_clk_out= hdmi_clk;

// --- 底层外设驱动芯片配置 ---

// sil9134 I2C 初始化配置
sil9134_dri u_sil9134_dri (
    .clk            (hdmi_clk),
    .rst_n          (rst_n),
    .hdmi_cfg_done  (),
    .hdmi_cfg_scl   (ddc_scl),
    .hdmi_cfg_sda   (ddc_sda)
);


endmodule