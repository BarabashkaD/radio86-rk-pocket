// The APF data slots (package/core/data.json) into the byte-wide memories of the board, only while
// the core is held in reset (machine_quiesced: core_bridge_cmd reset_n low). APF asks to write a
// slot (dataslot_requestwrite): slot 0 (monitor, up to 2048 bytes), 1 (font, up to 1024) and 2 (ROM
// disk, up to 65536) are accepted, other slots and larger sizes refused. romdisk_64k: the ROM disk
// slot asked for more than 32768 bytes (the 64 KB wiring of pocket_cart_ppi); it follows the last
// accepted ROM disk request. Each 32-bit bridge word
// (its first byte in bits 31:24: bridge_endian_little = 0) becomes 4 byte writes in the next 4 clk;
// APF writes at most one word per 88 clk (fpga/apf/io_bridge_peripheral.v). Bytes at or beyond the
// size APF asked for are dropped. No CRC and no coverage check: a file runs as it is. assets_valid
// is set when APF reports all slots loaded (dataslot_allcomplete) and no word is being split; it
// stays set until the power-up reset.
`default_nettype none
module pocket_slot_loader(
    input  wire        clk,
    input  wire        reset_n,           // the power-up reset (pocket_system)
    input  wire        machine_quiesced,  // the core in reset: the slots may be written
    input  wire        request_write,
    input  wire [15:0] request_id,
    input  wire [31:0] request_size,
    output reg         request_ack = 1'b0,
    output reg         request_ok = 1'b0,
    input  wire        allcomplete,
    input  wire        bridge_wr,
    input  wire [31:0] bridge_address,
    input  wire [31:0] bridge_data,
    output reg         assets_valid = 1'b0,
    output wire        monitor_we,        // byte_a[10:0]
    output wire        font_we,           // byte_a[9:0]
    output wire        romdisk_we,        // byte_a[15:0]
    output wire        romdisk_64k,       // the ROM disk image is above 32768 bytes
    output wire [15:0] byte_a,
    output wire  [7:0] byte_d
);
localparam [1:0] MONITOR = 2'd0, FONT = 2'd1, ROMDISK = 2'd2, NONE = 2'd3;
reg [16:0] limit_m = 17'd0, limit_f = 17'd0, limit_c = 17'd0;   // the size APF asked for (0: none)

// the request: ack (with ok) one clk after request_write, held until request_write drops
always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
        request_ack <= 1'b0; request_ok <= 1'b0;
        limit_m <= 17'd0; limit_f <= 17'd0; limit_c <= 17'd0;
    end else if (!request_write) begin
        request_ack <= 1'b0; request_ok <= 1'b0;
    end else if (!request_ack) begin
        request_ack <= 1'b1;
        request_ok <= 1'b0;
        if (machine_quiesced)
            case (request_id)
                16'd0: if (request_size <= 32'd2048) begin request_ok <= 1'b1; limit_m <= request_size[16:0]; end
                16'd1: if (request_size <= 32'd1024) begin request_ok <= 1'b1; limit_f <= request_size[16:0]; end
                16'd2: if (request_size <= 32'd65536) begin request_ok <= 1'b1; limit_c <= request_size[16:0]; end
                default: ;
            endcase
    end

// a bridge word into 4 byte writes, first byte first
wire [1:0] hit = bridge_address[31:16] == 16'h2000 ? MONITOR :
                 bridge_address[31:16] == 16'h2100 ? FONT :
                 bridge_address[31:16] == 16'h2200 ? ROMDISK : NONE;
wire take = bridge_wr && machine_quiesced && hit != NONE;
reg [31:0] word = 32'd0;
reg [16:0] offset = 17'd0;
reg [1:0] target = NONE;
reg [2:0] left = 3'd0;                  // bytes of the word still to write
always @(posedge clk or negedge reset_n)
    if (!reset_n) begin
        word <= 32'd0; offset <= 17'd0; target <= NONE; left <= 3'd0;
    end else if (take) begin
        word <= bridge_data; offset <= {1'b0, bridge_address[15:0]}; target <= hit; left <= 3'd4;
    end else if (left != 3'd0) begin
        word <= {word[23:0], 8'h00}; offset <= offset + 17'd1; left <= left - 3'd1;
    end
// synthesis translate_off
always @(posedge clk)
    if (reset_n && take && left > 3'd1)
        $display("ERROR: pocket_slot_loader: a bridge word at %h while %0d bytes of the last one are left", bridge_address, left);
// synthesis translate_on
wire busy = left != 3'd0;
wire [16:0] limit = target == MONITOR ? limit_m : target == FONT ? limit_f : limit_c;
wire write = busy && offset < limit;
assign monitor_we = write && target == MONITOR;
assign font_we = write && target == FONT;
assign romdisk_we = write && target == ROMDISK;
assign byte_a = offset[15:0];
assign romdisk_64k = limit_c > 17'd32768;
assign byte_d = word[31:24];

always @(posedge clk or negedge reset_n)
    if (!reset_n) assets_valid <= 1'b0;
    else if (allcomplete && !busy) assets_valid <= 1'b1;
endmodule
`default_nettype wire
