module ov5640_hdmi_img(
    input         sys_clk    ,  
    input         sys_rst_n  ,  
    input  [7:0]  cam_data   ,  
    input  wire   key_switch ,  
    input  wire   key_switch_rot, 
    input  wire   key_switch_zoom,
    output wire   uart_tx    ,  
    
    //摄像头 
    output        cam_xclk   ,
    input         cam_pclk   ,  
    input         cam_href   ,  
    input         cam_vsync  ,  
    output  wire  cam_rst_n  ,
    output        cam_pwdn   ,  
    output        cam_scl    ,  
    inout         cam_sda    ,  
    
    //SDRAM 
    output        sdram_clk  ,  
    output        sdram_cke  ,  
    output        sdram_cs_n ,  
    output        sdram_ras_n,  
    output        sdram_cas_n,  
    output        sdram_we_n ,  
    output [1:0]  sdram_ba   ,  
    output [12:0] sdram_addr ,  
    inout  [15:0] sdram_data ,  
    
    //HDMI接口
    output        hdmi_clk_out,
    output  wire  ddc_scl     ,
    inout   wire  ddc_sda     ,
    output [23:0] hdmi_data   ,
    output        hdmi_hs     ,
    output        hdmi_vs     ,
    output        hdmi_de     ,
	    // === 以太网物理接口 ===
    output wire       E_GTXC,
    output wire       E_TXEN,
    output wire [7:0] E_TXD,
    output wire       E_RESET,
    output wire       E_TXER,
    input  wire       E_RXC,      
    input  wire       E_RXDV,     
    input  wire [7:0] E_RXD
);

parameter   H_PIXEL = 11'd1280;
parameter   V_PIXEL = 11'd720 ;

wire        clk_100m;
wire        clk_100m_shift;
wire        clk_25m;
wire        clk_50m;
wire        clk_24m;
wire        hdmi_clk;

wire        locked;
wire        locked_hdmi;
wire        global_rst_n; 
wire        sdram_rst_n; 

wire        sys_init_done;
wire        cam_init_done;
wire        sdram_init_done;

wire [1:0]  zoom_state_raw; 
wire        rot_en_raw;     
wire [2:0]  current_mode;   

wire        raw_wr_en;
wire [15:0] raw_wr_data;
wire        raw_rd_en;
wire [15:0] rd_data;

wire        final_wr_en;
wire [15:0] final_wr_data;
wire        safe_rd_en;
wire [23:0] safe_sdram_addr;

// 用来连接 SDRAM 的绝对安全旋转信号
wire        rot_en_sync; 

wire        final_vs;
wire        final_hs;
wire        final_de;
wire [23:0] final_rgb;

//** 1. 基础时钟与配置
pll_clk u_pll_clk(
    .areset     (~sys_rst_n),
    .inclk0     (sys_clk),            
    .c0         (clk_100m),
    .c1         (clk_100m_shift), 
    .c2         (clk_24m), 
    .locked     (locked)
);

pll_hdmi pll_hdmi_inst (
    .areset     (~sys_rst_n),
    .inclk0     (sys_clk),
    .c0         (hdmi_clk),
    .c1         (clk_25m),
    .c2         (clk_50m), 
    .locked     (locked_hdmi)
);

assign cam_xclk = clk_24m;
assign cam_pwdn = 1'b0;
assign cam_rst_n = 1'b1;
assign sys_init_done = sdram_init_done & cam_init_done;

wire eth_b1, eth_b2, eth_b3, eth_b4;

// 1. 以太网模块
ethernet u_ethernet (
    .sys_clk   (sys_clk),
    .E_GTXC    (E_GTXC),
    .E_TXEN    (E_TXEN),
    .E_TXD     (E_TXD),
    .E_RESET   (E_RESET),
    .E_TXER    (E_TXER),
    .E_RXC     (E_RXC),      
    .E_RXDV    (E_RXDV),     
    .E_RXD     (E_RXD),
    .out_bit1  (eth_b1), 
    .out_bit2  (eth_b2), 
    .out_bit3  (eth_b3), 
    .out_bit4  (eth_b4)
);

// 2. 按键控制模块
key_control_top u_key_control_top (
    .clk_24m         (clk_24m),
    .hdmi_clk        (hdmi_clk),
    .sys_rst_n       (sys_rst_n),
    .global_rst_n    (global_rst_n),
    
    .key_switch      (key_switch),
    .key_switch_rot  (key_switch_rot),
    .key_switch_zoom (key_switch_zoom),
    
    // 直接连接以太网模块的输出位
    .eth_out_bit1    (eth_b1),
    .eth_out_bit2    (eth_b2),
    .eth_out_bit3    (eth_b3),
    
    .mode_flag       (current_mode),
    .rot_en_raw      (rot_en_raw),
    .zoom_state_raw  (zoom_state_raw)
);
//** 3.视频同步与路由大模块
video_ctrl #(
    .H_PIXEL         (H_PIXEL),
    .V_PIXEL         (V_PIXEL)
) u_video_ctrl (
    .clk_100m        (clk_100m),
    .sys_rst_n       (sys_rst_n),
    .locked_all      (locked & locked_hdmi),
    .zoom_state_raw  (zoom_state_raw),
    .rot_en_raw      (rot_en_raw),
    
    // 摄像头写入侧
    .cam_pclk        (cam_pclk),
    .cam_vsync       (cam_vsync),
    .wr_en_in        (raw_wr_en),
    .wr_data_in      (raw_wr_data),
    
    // HDMI读出侧
    .hdmi_clk        (hdmi_clk),
    .hdmi_vs         (hdmi_vs),
    .rd_en_in        (raw_rd_en),
    
    // 输出
    .global_rst_n    (global_rst_n),
    .sdram_rst_n     (sdram_rst_n),
    .safe_sdram_addr (safe_sdram_addr),
    .final_wr_en     (final_wr_en),
    .final_wr_data   (final_wr_data),
    .safe_rd_en      (safe_rd_en),
    
    // 接出安全的同步旋转信号
    .rot_en_sync_out (rot_en_sync)  
);

//** 4. 摄像头驱动源
ov5640_top  ov5640_top_inst(
    .sys_clk         (sys_clk       ),
    .sys_rst_n       (global_rst_n  ), 
    .sys_init_done   (sys_init_done ),
    .cfg_done        (cam_init_done ),
    .ov5640_pclk     (cam_pclk      ),
    .ov5640_href     (cam_href      ),
    .ov5640_vsync    (cam_vsync     ),
    .ov5640_data     (cam_data      ),
    .sccb_scl        (cam_scl       ),
    .sccb_sda        (cam_sda       ),
    .ov5640_wr_en    (raw_wr_en     ),
    .ov5640_data_out (raw_wr_data   )
);

//** 5. 图像缓存中心 (SDRAM)

sdram_top u_sdram_top(
    .ref_clk            (clk_100m),
    .out_clk            (clk_100m_shift),
    .rst_n              (sdram_rst_n),      
    
    .wr_clk             (cam_pclk),
    .wr_en              (final_wr_en),      
    .wr_data            (final_wr_data),    
    .wr_min_addr        (24'd0),
    .wr_max_addr        (safe_sdram_addr),  
    .wr_len             (10'd512),
    .wr_load            (~sdram_rst_n),     
    
    .rot_en             (rot_en_sync),      
    
    .rd_clk             (hdmi_clk),
    .rd_en              (safe_rd_en),       
    .rd_data            (rd_data),
    .rd_min_addr        (24'd0),
    .rd_max_addr        (safe_sdram_addr),  
    .rd_len             (10'd512),
    .rd_load            (~sdram_rst_n),     

    .sdram_read_valid   (1'b1),
    .sdram_pingpang_en  (1'b1),
    .sdram_init_done    (sdram_init_done),

    .sdram_clk          (sdram_clk), .sdram_cke(sdram_cke), .sdram_cs_n(sdram_cs_n),
    .sdram_ras_n        (sdram_ras_n), .sdram_cas_n(sdram_cas_n), .sdram_we_n(sdram_we_n),
    .sdram_ba           (sdram_ba), .sdram_addr(sdram_addr), .sdram_data(sdram_data)
);
//** 6. 图像处理总管线
image_processing_top u_image_processing (
    .clk          (hdmi_clk),
    .rst_n        (global_rst_n),
    .mode         (current_mode),
    .zoom_en      (zoom_state_raw),
    
    // 与 SDRAM 交互
    .rd_data      (rd_data),
    .rd_en        (raw_rd_en),   
    
    // 输出给 PHY 层
    .vs_out       (final_vs),
    .hs_out       (final_hs),
    .de_out       (final_de),
    .rgb_out      (final_rgb)
);
//** 7. HDMI 物理层驱动与外设
hdmi_top u_hdmi_top(
    .hdmi_clk       (hdmi_clk),
    .rst_n          (global_rst_n), 
    .current_mode   (current_mode),   
    
    // 接收最终视频流
    .final_vs       (final_vs),
    .final_hs       (final_hs),
    .final_de       (final_de),
    .final_rgb      (final_rgb),
    
    // 物理层引脚
    .hdmi_clk_out   (hdmi_clk_out),
    .hdmi_data      (hdmi_data),
    .hdmi_hs        (hdmi_hs),
    .hdmi_vs        (hdmi_vs),
    .hdmi_de        (hdmi_de),
    .ddc_scl        (ddc_scl),
    .ddc_sda        (ddc_sda),
    .uart_tx        (uart_tx)  
);

endmodule