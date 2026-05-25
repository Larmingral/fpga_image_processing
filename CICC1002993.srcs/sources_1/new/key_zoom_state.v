`timescale 1ns / 1ps
//按键消抖 (缩放控制)
module key_zoom_state(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,
    output reg  [1:0] zoom_state // 2-bit 状态输出 (0->1->2->3)
);
    reg [20:0] cnt;
    reg key_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 21'd0;
            key_reg <= 1'b1;     
            zoom_state <= 2'd0;   
        end else begin
            key_reg <= key_in;
            if (key_reg != key_in) begin
                cnt <= 21'd0;
            end else if (cnt < 21'd1_400_000) begin
                cnt <= cnt + 1'b1;
            end else if (cnt == 21'd1_400_000) begin
                if (key_in == 1'b0) begin
                    zoom_state <= zoom_state + 1'b1; // 自动溢出循环
                end
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule