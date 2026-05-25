`timescale 1ns / 1ps
module key_control_top(
    input  wire       clk_24m,        
    input  wire       hdmi_clk,       
    input  wire       sys_rst_n,      
    input  wire       global_rst_n,   
    
    // 物理按键输入
    input  wire       key_switch,     
    input  wire       key_switch_rot, 
    input  wire       key_switch_zoom,
    
    // 以太网输入 (来自 yitai 模块的 out_bit)
    input  wire       eth_out_bit1,   
    input  wire       eth_out_bit2,   
    input  wire       eth_out_bit3,   
    
    output wire [2:0] mode_flag,      
    output wire       rot_en_raw,     
    output wire [1:0] zoom_state_raw  
);

    // --- 1. 将以太网翻转电平转换为“长按”虚拟按键 ---
    wire vkey_rot_n, vkey_zoom_n, vkey_mode_n;

    // 旋转控制 (24MHz, 展宽至约160ms)
    cdc_toggle_stretcher #(.STRETCH_VAL(21'd4_000_000)) u_vrot (
        .clk(clk_24m), .rst_n(global_rst_n),
        .toggle_bit(eth_out_bit1), .vkey_n(vkey_rot_n)
    );

    // 缩放控制 (24MHz, 使用 sys_rst_n 对齐原有逻辑)
    cdc_toggle_stretcher #(.STRETCH_VAL(21'd4_000_000)) u_vzoom (
        .clk(clk_24m), .rst_n(sys_rst_n),
        .toggle_bit(eth_out_bit2), .vkey_n(vkey_zoom_n)
    );

    // 模式切换 (HDMI_clk 域, 时钟频率不同，设置合适的展宽值)
    cdc_toggle_stretcher #(.STRETCH_VAL(21'd8_000_000)) u_vmode (
        .clk(hdmi_clk), .rst_n(global_rst_n),
        .toggle_bit(eth_out_bit3), .vkey_n(vkey_mode_n)
    );

    // --- 2. 逻辑与：物理按键和虚拟按键任意一个拉低即有效 
    wire final_rot_n  = key_switch_rot  & vkey_rot_n;
    wire final_zoom_n = key_switch_zoom & vkey_zoom_n;
    wire final_mode_n = key_switch      & vkey_mode_n;

    // --- 3. 底层逻辑模块  ---
    key_debounce u_key_deb (
        .clk(hdmi_clk), .rst_n(global_rst_n), .key_in(final_mode_n), .mode_flag(mode_flag)      
    );

    key_debounce_toggle u_key_rot_deb(
        .clk(clk_24m), .rst_n(global_rst_n), .key_in(final_rot_n), .flag_out(rot_en_raw)
    );

    key_zoom_state u_key_zoom_state(
        .clk(clk_24m), .rst_n(sys_rst_n), .key_in(final_zoom_n), .zoom_state(zoom_state_raw)
    );

endmodule