`timescale 1ns / 1ps
module key_debounce_toggle(
    input  wire clk,
    input  wire rst_n,
    input  wire key_in,
    output reg  flag_out
);
    reg [20:0] cnt;
    reg key_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 21'd0;
            key_reg <= 1'b1;     
            flag_out <= 1'b0;   
        end else begin
            key_reg <= key_in;
            if (key_reg != key_in) begin
                cnt <= 21'd0;
            end else if (cnt < 21'd1_400_000) begin
                cnt <= cnt + 1'b1;
            end else if (cnt == 21'd1_400_000) begin
                if (key_in == 1'b0) begin
                    flag_out <= ~flag_out; // ·­×ª×´Ì¬
                end
                cnt <= cnt + 1'b1;
            end
        end
    end
endmodule