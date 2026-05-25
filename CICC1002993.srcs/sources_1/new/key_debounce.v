// 模块1：按键消抖与模式切换 (终极版：支持6种模式)
module key_debounce(
    input  wire clk,       
    input  wire rst_n,     
    input  wire key_in,    
    output reg [2:0] mode_flag 
);

reg [20:0] cnt;
reg key_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cnt <= 21'd0;
        key_reg <= 1'b1;     
        mode_flag <= 3'd0;   
    end else begin
        key_reg <= key_in;   
        
        if (key_reg != key_in) begin
            cnt <= 21'd0;
        end else if (cnt < 21'd1_400_000) begin
            cnt <= cnt + 1'b1;
        end else if (cnt == 21'd1_400_000) begin
            if (key_in == 1'b0) begin
                if (mode_flag == 3'd7)       
                    mode_flag <= 3'd0;
                else 
                    mode_flag <= mode_flag + 1'b1; 
            end
            cnt <= cnt + 1'b1; 
        end
    end
end

endmodule