`timescale 1ns / 1ps
module ethernet (
    input  wire sys_clk,
    output wire E_GTXC,
    output wire E_TXEN,
    output wire [7:0] E_TXD,
    output wire E_RESET,
    output wire E_TXER,
    input  wire E_RXC,      
    input  wire E_RXDV,     
    input  wire [7:0] E_RXD,
    output wire out_bit1, out_bit2, out_bit3, out_bit4

);

wire clk_125m;
//global模块仅为布线方便，无其他作用
global u_global_eth (
    .in  (E_RXC),
    .out (clk_125m)
);

assign E_GTXC = clk_125m;
reg sys_rst_n = 0;
reg [19:0] rst_cnt = 0;
always @(posedge sys_clk) begin
    if (rst_cnt < 20'd1_000_000) begin 
		rst_cnt <= rst_cnt + 1; 
		sys_rst_n <= 0; 
	end
    else
		sys_rst_n <= 1;
end
assign E_RESET = sys_rst_n;
assign E_TXER = 0;

// [2] 接收逻辑 (保持之前的稳定版本)
reg [15:0] rx_shift;
reg [7:0]  rx_cmd_latch;
reg        rx_trig_raw;
reg [3:0]  led_reg = 0;
reg [15:0] rx_lock_cnt = 0;

always @(posedge clk_125m) begin
    if (!E_RXDV) begin
			rx_shift <= 0; 
			rx_trig_raw <= 0;
        if (rx_lock_cnt > 0) 
			rx_lock_cnt <= rx_lock_cnt - 1;
    end 
	else begin
		if (E_RXDV) begin
			rx_shift <= {rx_shift[7:0], E_RXD};
		end else begin
			rx_shift <= 16'd0; // 没数据时强制静默，极大降低芯片内部的高频辐射
		end
        if (rx_lock_cnt == 0) begin
            if (rx_shift == 16'h3131) begin 
				led_reg[0] <= ~led_reg[0]; 
				rx_trig_raw <= 1; 
				rx_cmd_latch <= 8'h31;
				rx_lock_cnt <= 5000; 
			end
            else if (rx_shift == 16'h3232) begin 
				led_reg[1] <= ~led_reg[1]; 
				rx_trig_raw <= 1; 
				rx_cmd_latch <= 8'h32; 
				rx_lock_cnt <= 5000;
			end
			else if (rx_shift == 16'h3333) begin 
				led_reg[2] <= ~led_reg[2]; 
				rx_trig_raw <= 1; 
				rx_cmd_latch <= 8'h33; 
				rx_lock_cnt <= 5000;
			end
            else begin
				rx_trig_raw <= 0;
			end
        end 
		else begin
            rx_trig_raw <= 0;
            if (rx_lock_cnt > 0) begin
					rx_lock_cnt <= rx_lock_cnt - 1;
			end
        end
    end
end
reg [3:0] out_bit_sync;
always @(posedge sys_clk) begin // 使用稳定的系统时钟(50M)进行同步
    out_bit_sync <= led_reg;
end

assign {out_bit4, out_bit3, out_bit2, out_bit1} = out_bit_sync;

// [3] 发送触发逻辑 (同步化处理)
reg s1, s2;
reg [7:0] tx_cmd_locked;
always @(posedge clk_125m) begin
    s1 <= rx_trig_raw;
    s2 <= s1;
    if (s1 && !s2) begin
        tx_cmd_locked <= rx_cmd_latch;
    end
end
wire tx_start = s1 & ~s2;

// [4] CRC 计算逻辑
reg crc_en, crc_init;
wire [31:0] crc_val;
crc32_gen u_crc (
    .clk(clk_125m), 
    .rst_n(sys_rst_n),
    .data_en(crc_en), 
    .data_in(tx_d_out),
    .crc_init(crc_init),
    .crc_out(crc_val)
);

// [5] 发送状态机
reg [3:0] state = 0;
reg [7:0] cnt = 0;
reg tx_en_out = 0;
reg [7:0] tx_d_out = 0;
assign E_TXEN = tx_en_out;
assign E_TXD  = tx_d_out;

// [6] 发送状态机 (终极修复版：解决最小帧长与使能提前拉低的时序Bug)
always @(posedge clk_125m) begin
    if (!sys_rst_n) begin 
        state <= 0; 
        tx_en_out <= 0; 
        crc_en <= 0;
        crc_init <= 1;
        cnt <= 0;
    end else begin
        case(state)
            0: begin 
                tx_en_out <= 0; 
                cnt <= 0;
                crc_en <= 0;
                crc_init <= 1;
                if (tx_start) 
					state <= 1;
            end

            1: begin // 前导码 + SFD (8B)
                tx_en_out <= 1; 
                tx_d_out <= (cnt < 7) ? 8'h55 : 8'hD5;
                if (cnt == 7) begin 
                    cnt <= 0; 
                    state <= 2; 
                    crc_init <= 0;
                end else begin
                    cnt <= cnt + 1;
                end
            end

2: begin // Eth Header (14B)
                crc_en <= 1;
                case(cnt)
                    0: tx_d_out <= 8'hFF; 
					1: tx_d_out <= 8'hFF;
					2: tx_d_out <= 8'hFF;
                    3: tx_d_out <= 8'hFF; 
					4: tx_d_out <= 8'hFF; 
					5: tx_d_out <= 8'hFF;
                    6: tx_d_out <= 8'h02; 
					7: tx_d_out <= 8'h11; 
					8: tx_d_out <= 8'h22;
                    9: tx_d_out <= 8'h33;
					10: tx_d_out <= 8'h44;
					11: tx_d_out <= 8'h55;
                    12: tx_d_out <= 8'h08;
					13: tx_d_out <= 8'h00;
                endcase
                if (cnt == 13) begin cnt <= 0; state <= 3; end
                else cnt <= cnt + 1;
            end

            3: begin // IP Header (20B)
                crc_en <= 1;
                case(cnt)
                    0:  tx_d_out <= 8'h45;
                    1:  tx_d_out <= 8'h00;
                    2:  tx_d_out <= 8'h00; 
                    3:  tx_d_out <= 8'h2E; // 长度 46
                    4:  tx_d_out <= 8'h00;
                    5:  tx_d_out <= 8'h00;
                    6:  tx_d_out <= 8'h00;
                    7:  tx_d_out <= 8'h00;
                    8:  tx_d_out <= 8'h40;
                    9:  tx_d_out <= 8'h11; 
                    10: tx_d_out <= 8'hB9; // 高字节
                    11: tx_d_out <= 8'h0D; // 低字节
                    12: tx_d_out <= 8'd192; 
                    13: tx_d_out <= 8'd168;
                    14: tx_d_out <= 8'd1;
                    15: tx_d_out <= 8'd10;
                    16: tx_d_out <= 8'hFF; 
                    17: tx_d_out <= 8'hFF;
                    18: tx_d_out <= 8'hFF;
                    19: tx_d_out <= 8'hFF;
                endcase
                if (cnt == 19) begin cnt <= 0; state <= 4; end
                else cnt <= cnt + 1;
            end

            4: begin // UDP Header (8B)
                crc_en <= 1;
                case(cnt)
                    0: tx_d_out <= 8'h1F; 
					1: tx_d_out <= 8'h90; // 源端口 8080
                    2: tx_d_out <= 8'h27;
					3: tx_d_out <= 8'h0F; // 目的端口 9999
                    4: tx_d_out <= 8'h00;
					5: tx_d_out <= 8'h1A; 
                    6: tx_d_out <= 8'h00;
					7: tx_d_out <= 8'h00; // 校验和
                endcase
                if (cnt == 7) begin cnt <= 0; state <= 5; end
                else cnt <= cnt + 1;
            end

            5: begin // UDP Payload (18字节，满足 64B 最小帧长限制)
                crc_en <= 1;
                tx_en_out <= 1; 
                case(cnt)
                    0: tx_d_out <= 8'h41; // A
                    1: tx_d_out <= 8'h43; // C
                    2: tx_d_out <= 8'h4B; // K
                    3: tx_d_out <= 8'h21; // !
                    4: tx_d_out <= tx_cmd_locked;
                    default: tx_d_out <= 8'h00; // 后续补0
                endcase
                if (cnt < 17) begin  
                    cnt <= cnt + 1;
                end else begin       
                    cnt <= 0;
                    state <= 6;
                end
            end

            6: begin // CRC32 (4B)
                crc_en <= 0;
                case(cnt)
                    0: begin 
						tx_en_out <= 1;
						tx_d_out <= crc_val[7:0]; 
						cnt <= 1;
					end
                    1: begin 
						tx_en_out <= 1; 
						tx_d_out <= crc_val[15:8]; 
						cnt <= 2;
					end
                    2: begin
						tx_en_out <= 1;
						tx_d_out <= crc_val[23:16];
						cnt <= 3; 
					end
                    3: begin 
						tx_en_out <= 1; 
						tx_d_out <= crc_val[31:24];
						cnt <= 4;
					end
                    4: begin 
                        // 在这个周期，PHY正在读取[31:24]，此时我们将下一拍的使能拉低即可
                        tx_en_out <= 0; 
                        state <= 0; 
                        cnt <= 0;
                    end
                endcase
            end
        endcase
    end
end
endmodule
