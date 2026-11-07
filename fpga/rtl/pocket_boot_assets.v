// APF addressed loading for the exact existing donor bring-up fixtures.
// CRC detects corruption, not authenticity. Production asset selection remains open.
`default_nettype none
module pocket_boot_assets(
    input wire clk,reset_n,machine_quiesced,
    input wire request_write,
    input wire [15:0] request_id,
    input wire [31:0] request_size,
    output reg request_ack,request_ok,
    input wire allcomplete,
    input wire bridge_wr,
    input wire [31:0] bridge_address,bridge_data,
    output wire assets_valid,asset_error,cartridge_valid,
    output wire [31:0] status,monitor_crc,font_crc,cartridge_crc,
    input wire [10:0] monitor_address,
    output wire [7:0] monitor_data,
    output reg [10:0] monitor_tag,
    input wire [9:0] font_address,
    output wire [7:0] font_data,
    input wire [14:0] cartridge_address,
    output reg [14:0] cartridge_tag,
    output wire [7:0] cartridge_data
);
    reg [2:0] state;
    localparam IDLE=0,INVALIDATE=1,BEGIN_LOAD=2,WAIT_READY=3,ACK=4;
    reg [1:0] selected;
    reg seen_m,seen_f,seen_c,finish_m,finish_f,finish_c,previous_complete,complete;
    reg begin_m,begin_f,begin_c,invalidate_m,invalidate_f,invalidate_c,end_m,end_f,end_c;
    reg [3:0] protocol_error;
    wire ready_m,ready_f,ready_c,busy_m,busy_f,busy_c,loading_m,loading_f,loading_c,valid_m,valid_f,valid_c;
    wire [3:0] error_m,error_f,error_c;
    wire [31:0] words_m,words_f,words_c,read_m,read_f,read_c;
    reg [1:0] lane_m,lane_f,lane_c;
    wire write_m=bridge_wr && bridge_address[31:12]==20'h20000;
    wire write_f=bridge_wr && bridge_address[31:12]==20'h21000;
    wire write_c=bridge_wr && bridge_address[31:16]==16'h2200;
    // The ROM disk slot is optional (spec D12): without it the window reads FF.
    assign assets_valid=complete && valid_m && valid_f && (valid_c || !seen_c);
    assign cartridge_valid=valid_c;
    assign asset_error=(error_m!=0)||(error_f!=0)||(error_c!=0)||(protocol_error!=0);
    assign status={8'b0,error_c,protocol_error,error_f,error_m,1'b0,loading_c,loading_f,loading_m,1'b0,valid_c,valid_f,valid_m};
    function [7:0] byte_lane;
        input [31:0] word_data;
        input [1:0] lane;
        begin case(lane)0:byte_lane=word_data[31:24];1:byte_lane=word_data[23:16];2:byte_lane=word_data[15:8];3:byte_lane=word_data[7:0];endcase end
    endfunction
    assign monitor_data=byte_lane(read_m,lane_m);
    assign font_data=byte_lane(read_f,lane_f);
    // Tail 7E00..7FFF is a defined FF open-ROM fill, never uninitialized RAM.
    assign cartridge_data=cartridge_tag>=15'h7e00 ? 8'hff : byte_lane(read_c,lane_c);
    always @(posedge clk) begin
        lane_m<=monitor_address[1:0];monitor_tag<=monitor_address;
        lane_f<=font_address[1:0];
        lane_c<=cartridge_address[1:0];cartridge_tag<=cartridge_address;
    end
    pocket_asset_store #(.WORDS(512),.PAYLOAD_BYTES(2048),.EXPECTED_CRC(32'hBF1CEEA5),.IDENTITY_APPROVED(1)) monitor_store(
        .clk(clk),.reset_n(reset_n),.invalidate(invalidate_m),.machine_quiesced(machine_quiesced),
        .load_begin(begin_m),.load_finish(end_m),.declared_size(32'd2048),
        .write_valid(write_m),.write_byte_address({20'b0,bridge_address[11:0]}),.write_data(bridge_data),
        .write_ready(ready_m),.busy(busy_m),.loading(loading_m),.valid(valid_m),.error_code(error_m),
        .computed_crc(monitor_crc),.unique_words(words_m),.write_accepted(),
        .read_enable(valid_m),.read_word_address(monitor_address[10:2]),.read_data(read_m),.read_fault());
    pocket_asset_store #(.WORDS(256),.PAYLOAD_BYTES(1024),.EXPECTED_CRC(32'h21E9ED84),.IDENTITY_APPROVED(1)) font_store(
        .clk(clk),.reset_n(reset_n),.invalidate(invalidate_f),.machine_quiesced(machine_quiesced),
        .load_begin(begin_f),.load_finish(end_f),.declared_size(32'd1024),
        .write_valid(write_f),.write_byte_address({20'b0,bridge_address[11:0]}),.write_data(bridge_data),
        .write_ready(ready_f),.busy(busy_f),.loading(loading_f),.valid(valid_f),.error_code(error_f),
        .computed_crc(font_crc),.unique_words(words_f),.write_accepted(),
        .read_enable(valid_f),.read_word_address(font_address[9:2]),.read_data(read_f),.read_fault());
    pocket_asset_store #(.WORDS(8192),.PAYLOAD_BYTES(32256),.EXPECTED_CRC(32'h4B1C86D6),.IDENTITY_APPROVED(1)) cartridge_store(
        .clk(clk),.reset_n(reset_n),.invalidate(invalidate_c),.machine_quiesced(machine_quiesced),
        .load_begin(begin_c),.load_finish(end_c),.declared_size(32'd32256),
        .write_valid(write_c),.write_byte_address({16'b0,bridge_address[15:0]}),.write_data(bridge_data),
        .write_ready(ready_c),.busy(busy_c),.loading(loading_c),.valid(valid_c),.error_code(error_c),
        .computed_crc(cartridge_crc),.unique_words(words_c),.write_accepted(),
        .read_enable(valid_c && cartridge_address<15'h7e00),.read_word_address(cartridge_address[14:2]),.read_data(read_c),.read_fault());
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n)begin
            state<=IDLE;selected<=0;seen_m<=0;seen_f<=0;seen_c<=0;finish_m<=0;finish_f<=0;finish_c<=0;previous_complete<=0;complete<=0;
            begin_m<=0;begin_f<=0;begin_c<=0;invalidate_m<=0;invalidate_f<=0;invalidate_c<=0;end_m<=0;end_f<=0;end_c<=0;
            protocol_error<=0;request_ack<=0;request_ok<=0;
        end else begin
            begin_m<=0;begin_f<=0;begin_c<=0;invalidate_m<=0;invalidate_f<=0;invalidate_c<=0;end_m<=0;end_f<=0;end_c<=0;
            previous_complete<=allcomplete;
            if(allcomplete && !previous_complete)begin
                complete<=1;
                if(seen_m)finish_m<=1;else protocol_error<=4'hb;
                if(seen_f)finish_f<=1;else protocol_error<=4'hb;
                if(seen_c)finish_c<=1;
            end
            if(finish_m && ready_m)begin end_m<=1;finish_m<=0;end
            if(finish_f && ready_f)begin end_f<=1;finish_f<=0;end
            if(finish_c && ready_c)begin end_c<=1;finish_c<=0;end
            case(state)
            IDLE:begin
                request_ack<=0;request_ok<=0;
                if(request_write)begin
                    if(!machine_quiesced || request_id>2 ||
                        (request_id==0 && (request_size!=2048 || seen_m)) ||
                        (request_id==1 && (request_size!=1024 || seen_f)) ||
                        (request_id==2 && (request_size!=32256 || seen_c)))begin
                        request_ok<=0;request_ack<=1;state<=ACK;
                    end else begin
                        selected<=request_id[1:0];protocol_error<=0;state<=INVALIDATE;
                        if(request_id!=0 && seen_m && loading_m)finish_m<=1;
                        if(request_id!=1 && seen_f && loading_f)finish_f<=1;
                        if(request_id!=2 && seen_c && loading_c)finish_c<=1;
                    end
                end
            end
            INVALIDATE:begin
                case(selected)0:invalidate_m<=1;1:invalidate_f<=1;2:invalidate_c<=1;endcase
                state<=BEGIN_LOAD;
            end
            BEGIN_LOAD:begin
                case(selected)
                    0:begin begin_m<=1;seen_m<=1;end
                    1:begin begin_f<=1;seen_f<=1;end
                    2:begin begin_c<=1;seen_c<=1;end
                endcase
                state<=WAIT_READY;
            end
            WAIT_READY:if(selected==0 ? ready_m : selected==1 ? ready_f : ready_c)begin request_ok<=1;request_ack<=1;state<=ACK;end
            ACK:if(!request_write)begin request_ack<=0;state<=IDLE;end
            default:state<=IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
