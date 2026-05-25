`timescale 1ns / 1ps
// 模块名称: 灰度直方图分布实时统计模块
module histogram_statistic #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720
)(
    input  wire        clk,          
    input  wire        rst_n,        

    // AXI4-Stream 视频流接收 (数据输入端)
    input  wire [7:0]  s_axis_tdata,  
    input  wire        s_axis_tvalid, 
    output wire        s_axis_tready, 
    input  wire        s_axis_tuser,  
    input  wire        s_axis_tlast,

    // BRAM 读通道 (供下一级 CDF 累加使用)
    input  wire        i_ram_read_en,   
    input  wire [7:0]  i_ram_read_addr, 
    output reg  [23:0] o_ram_read_data, 

    // 全局同步与握手
    output wire        o_frame_done   
);

    // FSM 状态机宏定义 
    localparam FSM_INIT  = 3'd0; 
    localparam FSM_WIPE  = 3'd1; 
    localparam FSM_WORK  = 3'd2; 
    localparam FSM_OVER  = 3'd3; 
    localparam FSM_IDLE  = 3'd4; 
    
    reg [2:0] state;
    reg [2:0] next_state;
    
    reg [10:0] x_cnt; 
    reg [10:0] y_cnt; 
    reg [9:0]  st_cnt;
    
    // 提取有效握手条件
    wire pipe_en_in;
    assign pipe_en_in = s_axis_tvalid && s_axis_tready;

    // 第一段：状态流转
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= FSM_INIT;
        else        state <= next_state;
    end

    // 第二段：状态跳转逻辑
    always @(*) begin
        next_state = state;
        case (state)
            FSM_INIT: 
                next_state = FSM_WIPE;
                
            FSM_WIPE: 
                if (st_cnt == 10'd255) 
                    next_state = FSM_WORK;
                    
            FSM_WORK: 
                if (pipe_en_in && (x_cnt == IMG_WIDTH - 1) && (y_cnt == IMG_HEIGHT - 1)) 
                    next_state = FSM_OVER;
                    
            FSM_OVER: 
                next_state = FSM_IDLE;
                
            FSM_IDLE: 
                if (st_cnt == 10'd1000) 
                    next_state = FSM_WIPE;
                    
            default: next_state = FSM_INIT;
        endcase
    end

    assign s_axis_tready = (state == FSM_WORK);
    assign o_frame_done  = (state == FSM_OVER);

    // 时序控制与坐标生成
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_cnt <= 10'd0;
            x_cnt  <= 11'd0;
            y_cnt  <= 11'd0;
        end else begin
            // 等待周期与擦除周期计数
            if (state == FSM_WIPE || state == FSM_IDLE) begin
                st_cnt <= st_cnt + 1'b1;
            end else begin
                st_cnt <= 10'd0;
            end
            
            // 基于 AXI 的二维坐标追踪
            if (state == FSM_WORK && pipe_en_in) begin
                if (s_axis_tuser) begin
                    x_cnt <= 11'd1;
                    y_cnt <= 11'd0;
                end else if (x_cnt == IMG_WIDTH - 1) begin
                    x_cnt <= 11'd0;
                    y_cnt <= y_cnt + 1'b1;
                end else begin
                    x_cnt <= x_cnt + 1'b1;
                end
            end
        end
    end

    // BRAM 资源例化与读操作
    (* ram_style = "block" *) reg [23:0] hist_ram [0:255];
    
    always @(posedge clk) begin
        if (i_ram_read_en) begin
            o_ram_read_data <= hist_ram[i_ram_read_addr];
        end
    end

    // 核心算法：带冲突检测的读改写 
    reg [7:0]  tdata_d1;
    reg        valid_d1;            
    reg [23:0] ram_read_data;
    
    wire valid_pixel_in;
    assign valid_pixel_in = (state == FSM_WORK) && pipe_en_in;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tdata_d1 <= 8'd0;
            valid_d1 <= 1'b0;
        end else begin
            tdata_d1 <= s_axis_tdata;
            valid_d1 <= valid_pixel_in;
        end
    end

    always @(posedge clk) begin
        if (valid_pixel_in) begin
            ram_read_data <= hist_ram[s_axis_tdata];
        end
    end

    // 冲突保护连线与寄存器
    reg [7:0]  last_write_addr;
    reg [23:0] last_write_data;
    reg        last_write_en;    
    reg [23:0] write_data_temp;
    
    // 发生连续相同灰度输入时的直通逻辑
    always @(*) begin
        if (last_write_en && (tdata_d1 == last_write_addr)) begin
            write_data_temp = last_write_data + 1'b1;
        end else begin
            write_data_temp = ram_read_data + 1'b1;
        end
    end

    // 状态保持
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            last_write_en   <= 1'b0;
            last_write_addr <= 8'd0;
            last_write_data <= 24'd0;
        end 
        else if (state == FSM_WIPE) begin
            last_write_en <= 1'b0;
        end 
        else if (valid_d1) begin
            last_write_addr <= tdata_d1;
            last_write_data <= write_data_temp;
            last_write_en   <= 1'b1;
        end 
        else begin
            last_write_en <= 1'b0;
        end
    end
    
    // BRAM 的写操作，利用循环遍历完成复位
    always @(posedge clk) begin
        if (state == FSM_WIPE) begin
            if (st_cnt < 10'd256) begin
                hist_ram[st_cnt[7:0]] <= 24'd0;
            end
        end 
        else if (valid_d1) begin
            hist_ram[tdata_d1] <= write_data_temp;
        end 
    end

endmodule