`timescale 1ns / 1ps
// 模块名称: 累加分布函数生成与LUT 映射表构建
module cdf_lut_generator #(
    parameter IMG_WIDTH   = 1280,
    parameter IMG_HEIGHT  = 720,
    parameter DIV_LATENCY = 20   
)(
    input  wire        clk,
    input  wire        rst_n,

    // 触发使能信号
    input  wire        i_frame_done,    

    // RAM 数据搬运接口
    output wire        o_hist_rd_en,    
    output wire [7:0]  o_hist_rd_addr,  
    input  wire [23:0] i_hist_rd_data,  

    // LUT 映射表查询接口
    input  wire        i_lut_rd_en,
    input  wire [7:0]  i_lut_rd_addr,
    output reg  [7:0]  o_lut_rd_data,

    // 操作完成标志
    output wire        o_lut_ready      
);

    localparam TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;

    // 状态机声明 
    localparam SM_SLEEP  = 3'd0;       
    localparam SM_ACCUM  = 3'd1;   
    localparam SM_WAIT   = 3'd2;   
    localparam SM_BUILD  = 3'd3;   
    localparam SM_FINISH = 3'd4;    

    reg [2:0] state;
    reg [2:0] next_state;

    reg [8:0] loop_cnt;
    reg [7:0] timer_div;      

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= SM_SLEEP;
        else        state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            SM_SLEEP: 
                if (i_frame_done)               next_state = SM_ACCUM;
            SM_ACCUM: 
                if (loop_cnt == 9'd256)         next_state = SM_WAIT;
            SM_WAIT: 
                if (timer_div == DIV_LATENCY)   next_state = SM_BUILD;
            SM_BUILD: 
                if (loop_cnt == 9'd258)         next_state = SM_FINISH;
            SM_FINISH:                        
                                                next_state = SM_SLEEP;
            default:                            next_state = SM_SLEEP;
        endcase
    end

    // 迭代变量控制
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_cnt  <= 9'd0;
            timer_div <= 8'd0;
        end else begin
            case (state)
               SM_ACCUM: begin
                    if (loop_cnt < 9'd256) loop_cnt <= loop_cnt + 1'b1;
                    timer_div <= 8'd0;
                end
                SM_BUILD: begin
                    if (loop_cnt < 9'd258) loop_cnt <= loop_cnt + 1'b1;
                    timer_div <= 8'd0;
                end
                SM_WAIT: begin
                    loop_cnt  <= 9'd0;
                    timer_div <= timer_div + 1'b1;
                end
                default: begin
                    loop_cnt  <= 9'd0;
                    timer_div <= 8'd0;
                end
            endcase
        end
    end

    // CDF 累加流水线
    (* ram_style = "distributed" *) reg [23:0] cdf_ram [0:255];
    
    assign o_hist_rd_en   = (state == SM_ACCUM) && (loop_cnt < 9'd256);
    assign o_hist_rd_addr = loop_cnt[7:0];
    
    reg       o_hist_rd_en_d1;
    reg [8:0] loop_cnt_d1, loop_cnt_d2, loop_cnt_d3;
    
    // 对齐流水线级数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_hist_rd_en_d1 <= 1'b0;
            loop_cnt_d1     <= 9'd0;
            loop_cnt_d2     <= 9'd0;
            loop_cnt_d3     <= 9'd0;
        end else begin       
            o_hist_rd_en_d1 <= o_hist_rd_en;
            loop_cnt_d1     <= loop_cnt;
            loop_cnt_d2     <= loop_cnt_d1;
            loop_cnt_d3     <= loop_cnt_d2;
        end
    end

    reg [31:0] cdf_acc;
    reg [31:0] cdf_min;       
    reg        found_min;
    wire [31:0] next_cdf;
    
    assign next_cdf = cdf_acc + i_hist_rd_data;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cdf_acc   <= 32'd0;
            cdf_min   <= 32'd0;
            found_min <= 1'b0;
        end 
        else if (state == SM_SLEEP) begin
            cdf_acc   <= 32'd0;
            cdf_min   <= 32'd0;
            found_min <= 1'b0;
        end 
        else if (state == SM_ACCUM && o_hist_rd_en_d1) begin
            cdf_acc <= next_cdf;
            // 捕获最小值
            if (!found_min && (next_cdf > 0)) begin
                cdf_min   <= next_cdf;
                found_min <= 1'b1;
            end
        end
    end
    
    always @(posedge clk) begin   
        if (state == SM_ACCUM && o_hist_rd_en_d1) begin
            cdf_ram[loop_cnt_d1[7:0]] <= next_cdf[23:0];
        end
    end

    // 除法器模块例化与常量参数提取
    wire [25:0] div_numer;
    wire [20:0] div_denom;
    wire [25:0] div_quotient;
    
    reg [25:0] scale_factor;

    assign div_numer = 26'd16711680;
    assign div_denom = (TOTAL_PIXELS[20:0] == cdf_min[20:0]) ? 21'd1 : (TOTAL_PIXELS[20:0] - cdf_min[20:0]);
    
    hist_divide u_divider (
        .clock   (clk),
        .denom   (div_denom),
        .numer   (div_numer),
        .quotient(div_quotient),
        .remain  ()
    );
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scale_factor <= 26'd0;
        end else if (state == SM_WAIT && timer_div == DIV_LATENCY) begin
            scale_factor <= div_quotient;
        end
    end

    // LUT 表格生成映射核心
    reg [7:0]  lut_ram [0:255];
    reg [23:0] cdf_rd_data;
    
    reg [31:0] cur_cdf_diff;
    reg [63:0] mult_res;  
    reg [7:0]  final_lut_val;
    
    always @(posedge clk) begin
        if (state == SM_BUILD && loop_cnt < 9'd256) begin
            cdf_rd_data <= cdf_ram[loop_cnt[7:0]];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cur_cdf_diff <= 32'd0;
        else if (state == SM_BUILD) begin
            if (cdf_rd_data > cdf_min) cur_cdf_diff <= cdf_rd_data - cdf_min;
            else                       cur_cdf_diff <= 32'd0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mult_res <= 64'd0;
        else if (state == SM_BUILD) begin
            mult_res <= cur_cdf_diff * scale_factor;
        end
    end

    always @(*) begin
        if ((mult_res >> 16) > 255) final_lut_val = 8'd255;
        else                        final_lut_val = mult_res[23:16];
    end

    always @(posedge clk) begin
        if (state == SM_BUILD && loop_cnt_d3 < 9'd256) begin
            lut_ram[loop_cnt_d3[7:0]] <= final_lut_val;
        end
    end

    always @(posedge clk) begin
        if (i_lut_rd_en) begin
            o_lut_rd_data <= lut_ram[i_lut_rd_addr];
        end
    end

    // 握手信号缓冲
    reg lut_ready_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lut_ready_reg <= 1'b0;
        end else if (i_frame_done) begin
            lut_ready_reg <= 1'b0;
        end else if (state == SM_FINISH) begin
            lut_ready_reg <= 1'b1;
        end
    end

    assign o_lut_ready = lut_ready_reg;

endmodule