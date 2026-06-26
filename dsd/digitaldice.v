//=============================================================================
// Top-level module for Digital Dice FPGA Project
//=============================================================================
module digital_dice_top (
    input wire clk_50MHz,           // 50MHz system clock
    input wire reset_n,             // Active low reset
    input wire tilt_sensor,         // Tilt sensor input
    input wire btn_up,
    input wire btn_down,
    input wire btn_roll,
    output wire [6:0] seg,          // 7-segment segments (a-g)
    output wire [3:0] an,           // 7-segment anodes
    output wire dp,                 // Decimal point
    output wire [7:0] led           // Status LEDs
);  // <-- note the required semicolon

    // Internal clock signals
    wire clk_1Hz;
    wire clk_10Hz;
    wire clk_500Hz;

    // Random number generator signals
    wire [31:0] random_number;
    wire [15:0] seed_value;

    // Tilt detection signals
    wire dice_stable;
    wire dice_rolling;

    // Dice control signals
    wire [2:0] dice_type;           // 0: d6, 1: d8, 2: d10, 3: d12, 4: d20, 5: d100
    wire [7:0] dice_result;
    wire result_valid;

    // Display signals
    wire [15:0] display_bcd;

    // Module instantiations
    clock_divider clk_div (
        .clk_in(clk_50MHz),
        .reset_n(reset_n),
        .clk_1Hz(clk_1Hz),
        .clk_10Hz(clk_10Hz),
        .clk_500Hz(clk_500Hz)
    );

    random_seed_gen seed_gen (
        .clk(clk_50MHz),
        .reset_n(reset_n),
        .seed_out(seed_value)
    );

    xorshift_rng rng_inst (
        .clk(clk_50MHz),
        .reset_n(reset_n),
        .seed(seed_value),
        .enable(dice_rolling),
        .random_out(random_number)
    );

    tilt_detector tilt_inst (
        .clk(clk_10Hz),
        .reset_n(reset_n),
        .tilt_sensor(tilt_sensor),
        .stable(dice_stable),
        .rolling(dice_rolling)
    );

    dice_controller dice_ctrl (
        .clk(clk_10Hz),
        .reset_n(reset_n),
        .btn_up(btn_up),
        .btn_down(btn_down),
        .btn_roll(btn_roll),
        .dice_stable(dice_stable),
        .dice_type(dice_type)
    );

    dice_processor dice_proc (
        .clk(clk_50MHz),
        .reset_n(reset_n),
        .random_number(random_number),
        .dice_type(dice_type),
        .dice_stable(dice_stable),
        .dice_result(dice_result),
        .result_valid(result_valid)
    );

    bin_to_bcd bcd_conv (
        .binary_in(dice_result),
        .bcd_out(display_bcd)
    );

    seven_seg_display seg_display (
        .clk(clk_500Hz),
        .reset_n(reset_n),
        .bcd_data(display_bcd),
        .seg(seg),
        .an(an),
        .dp(dp)
    );

    assign led[0] = dice_stable;
    assign led[1] = dice_rolling;
    assign led[2] = result_valid;
    assign led[5:3] = dice_type;
    assign led[7:6] = 2'b00;

endmodule

//=============================================================================
// Clock Divider
//=============================================================================
module clock_divider (
    input wire clk_in,             // 50MHz
    input wire reset_n,
    output reg clk_1Hz,
    output reg clk_10Hz,
    output reg clk_500Hz
);
    reg [25:0] cnt_1Hz;
    reg [22:0] cnt_10Hz;
    reg [16:0] cnt_500Hz;
    always @(posedge clk_in or negedge reset_n) begin
        if (!reset_n) begin
            cnt_1Hz <= 0;
            cnt_10Hz <= 0;
            cnt_500Hz <= 0;
            clk_1Hz <= 0;
            clk_10Hz <= 0;
            clk_500Hz <= 0;
        end else begin
            if (cnt_1Hz >= 26'd24999999) begin cnt_1Hz <= 0; clk_1Hz <= ~clk_1Hz; end
            else cnt_1Hz <= cnt_1Hz + 1;
            if (cnt_10Hz >= 23'd2499999) begin cnt_10Hz <= 0; clk_10Hz <= ~clk_10Hz; end
            else cnt_10Hz <= cnt_10Hz + 1;
            if (cnt_500Hz >= 17'd49999) begin cnt_500Hz <= 0; clk_500Hz <= ~clk_500Hz; end
            else cnt_500Hz <= cnt_500Hz + 1;
        end
    end
endmodule

//=============================================================================
// Random Seed Generator
//=============================================================================
module random_seed_gen(
    input wire clk,
    input wire reset_n,
    output reg [15:0] seed_out
);
    reg [15:0] lfsr_seed;
    reg [23:0] counter;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin lfsr_seed <= 16'hACE1; seed_out <= 0; counter <= 0; end
        else begin
            counter <= counter + 1;
            if (counter[15:0] == 16'hFFFF) begin
                lfsr_seed <= {lfsr_seed[14:0], lfsr_seed[15]^lfsr_seed[13]^lfsr_seed[12]^lfsr_seed[10]};
                seed_out <= lfsr_seed ^ counter[15:0];
            end
        end
    end
endmodule

//=============================================================================
// XORshift Random Number Generator
//=============================================================================
module xorshift_rng (
    input wire clk,
    input wire reset_n,
    input wire [15:0] seed,
    input wire enable,
    output reg [31:0] random_out
);
    reg [31:0] state;
    reg [31:0] temp1, temp2, temp3;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin state <= 32'h12345678; random_out <= 0; end
        else if (enable) begin
            if (seed != 0) state[15:0] <= state[15:0] ^ seed;
            temp1 = state ^ (state << 13);
            temp2 = temp1 ^ (temp1 >> 17);
            temp3 = temp2 ^ (temp2 << 5);
            state <= temp3;
            random_out <= temp3;
        end
    end
endmodule

//=============================================================================
// Tilt Detector
//=============================================================================
module tilt_detector (
    input wire clk,
    input wire reset_n,
    input wire tilt_sensor,
    output reg stable,
    output reg rolling
);
    reg [7:0] tilt_history;
    reg [3:0] stable_count;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin tilt_history <= 0; stable_count <= 0; stable <= 0; rolling <= 0; end
        else begin
            tilt_history <= {tilt_history[6:0], tilt_sensor};
            stable_count <= tilt_history[7] + tilt_history[6] + tilt_history[5] + 
                                tilt_history[4] + tilt_history[3] + tilt_history[2] +
                                tilt_history[1] + tilt_sensor;
            if (stable_count >= 4'd6) begin stable <= 1'b1; rolling <= 1'b0; end
            else begin stable <= 1'b0; rolling <= 1'b1; end
        end
    end
endmodule

//=============================================================================
// Dice Controller
//=============================================================================
module dice_controller (
    input wire clk,
    input wire reset_n,
    input wire btn_up,
    input wire btn_down,
    input wire btn_roll,
    input wire dice_stable,
    output reg [2:0] dice_type
);
    reg btn_up_prev, btn_down_prev;
    wire btn_up_edge, btn_down_edge;
    assign btn_up_edge = btn_up & ~btn_up_prev;
    assign btn_down_edge = btn_down & ~btn_down_prev;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin dice_type <= 0; btn_up_prev <= 0; btn_down_prev <= 0; end
        else begin
            btn_up_prev <= btn_up; btn_down_prev <= btn_down;
            if (dice_stable) begin
                if (btn_up_edge)
                    if (dice_type == 5) dice_type <= 0; else dice_type <= dice_type + 1;
                if (btn_down_edge)
                    if (dice_type == 0) dice_type <= 5; else dice_type <= dice_type - 1;
            end
        end
    end
endmodule

//=============================================================================
// Dice Processor
//=============================================================================
module dice_processor (
    input wire clk,
    input wire reset_n,
    input wire [31:0] random_number,
    input wire [2:0] dice_type,
    input wire dice_stable,
    output reg [7:0] dice_result,
    output reg result_valid
);
    reg [7:0] dice_max;
    reg dice_stable_prev;
    wire dice_stable_edge;
    assign dice_stable_edge = dice_stable & ~dice_stable_prev;

    always @(*) begin
        case (dice_type)
            3'd0: dice_max = 8'd6;
            3'd1: dice_max = 8'd8;
            3'd2: dice_max = 8'd10;
            3'd3: dice_max = 8'd12;
            3'd4: dice_max = 8'd20;
            3'd5: dice_max = 8'd100;
            default: dice_max = 8'd6;
        endcase
    end

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin dice_result <= 1; result_valid <= 0; dice_stable_prev <= 0; end
        else begin
            dice_stable_prev <= dice_stable;
            if (dice_stable_edge) begin
                dice_result <= (random_number % dice_max) + 1;
                result_valid <= 1'b1;
            end else if (!dice_stable) begin
                result_valid <= 1'b0;
            end
        end
    end
endmodule

//=============================================================================
// Binary to BCD Converter
//=============================================================================
module bin_to_bcd (
    input wire [7:0] binary_in,
    output wire [15:0] bcd_out
);
    reg [3:0] hundreds, tens, ones;
    always @(*) begin
        if (binary_in >= 8'd100) begin
            hundreds = binary_in / 100;
            tens = (binary_in % 100) / 10;
            ones = binary_in % 10;
        end else if (binary_in >= 8'd10) begin
            hundreds = 0; tens = binary_in / 10; ones = binary_in % 10;
        end else begin
            hundreds = 0; tens = 0; ones = binary_in;
        end
    end
    assign bcd_out = {4'b0000, hundreds, tens, ones};
endmodule

//=============================================================================
// 7-Segment Display Controller
//=============================================================================
module seven_seg_display (
    input wire clk,              // 500Hz refresh clock
    input wire reset_n,
    input wire [15:0] bcd_data,
    output reg [6:0] seg,
    output reg [3:0] an,
    output reg dp
);
    reg [1:0] digit_select;
    reg [3:0] current_digit;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) digit_select <= 0;
        else digit_select <= digit_select + 1;
    end
    always @(*) begin
        case (digit_select)
            2'b00: begin current_digit = bcd_data[3:0];   an = 4'b1110; end
            2'b01: begin current_digit = bcd_data[7:4];   an = 4'b1101; end
            2'b10: begin current_digit = bcd_data[11:8];  an = 4'b1011; end
            2'b11: begin current_digit = bcd_data[15:12]; an = 4'b0111; end
        endcase
        dp = 1'b1;
    end
    always @(*) begin
        case (current_digit)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            default: seg = 7'b1111111;
        endcase
    end
endmodule
