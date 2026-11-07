// Addressed word store / validator. Canonical byte order is MSB-first per word.
// Real ROM identity must be approved separately; the diagnostic shell disables it.
`default_nettype none
module pocket_asset_store #(
    parameter integer WORDS = 16,
    parameter integer PAYLOAD_BYTES = 64,
    parameter [31:0] EXPECTED_CRC = 32'h100ECE8C,
    parameter IDENTITY_APPROVED = 1'b0,
    parameter integer AW = $clog2(WORDS)
)(
    input wire clk, reset_n, invalidate, machine_quiesced,
    input wire load_begin, load_finish,
    input wire [31:0] declared_size,
    input wire write_valid,
    input wire [31:0] write_byte_address, write_data,
    output wire write_ready, busy, loading,
    output reg write_accepted, valid,
    output reg [3:0] error_code,
    output reg [31:0] computed_crc, unique_words,
    input wire read_enable,
    input wire [AW-1:0] read_word_address,
    output reg [31:0] read_data,
    output reg read_fault
);
    localparam integer PAYLOAD_WORDS = PAYLOAD_BYTES/4;
    localparam [3:0] IDLE=0, CLEAR=1, LOAD=2, WREAD=3, WCHECK=4, CREAD=5, CBYTE=6, DONE=7, ERROR=8;
    localparam [3:0] E_SIZE=1, E_RANGE=2, E_DUPLICATE=3, E_MISSING=4,
        E_CRC=5, E_UNAPPROVED=6, E_BUSY=7, E_ALIGNMENT=8, E_RELOAD=9, E_QUIESCENCE=10;
    reg [3:0] state;
    reg [31:0] memory [0:WORDS-1];
    reg covered [0:WORDS-1];
    reg [AW-1:0] clear_index, write_index, scan_index;
    reg [31:0] write_latch, word_q, crc;
    reg covered_q;
    reg [1:0] byte_index;
    reg [7:0] selected_byte;
    assign write_ready = (state==LOAD) && machine_quiesced;
    assign loading = (state>=CLEAR && state<=CBYTE);
    assign busy = loading && state!=LOAD;

    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] data;
        reg [31:0] next;
        integer bit_index;
        begin
            next=previous ^ {24'b0,data};
            for(bit_index=0;bit_index<8;bit_index=bit_index+1)
                next=next[0] ? (next>>1)^32'hEDB88320 : (next>>1);
            crc_byte=next;
        end
    endfunction
    always @(*) begin
        case(byte_index)
        0:selected_byte=word_q[31:24];
        1:selected_byte=word_q[23:16];
        2:selected_byte=word_q[15:8];
        3:selected_byte=word_q[7:0];
        endcase
    end
    wire [31:0] next_crc=crc_byte(crc,selected_byte);

    // Canonical dual-port inference: validation R/W and machine read-only.
    wire [AW-1:0] validation_address=state==CREAD ? scan_index : write_index;
    wire [AW-1:0] coverage_address=state==CLEAR ? clear_index : write_index;
    reg [31:0] machine_word;
    reg machine_read_valid;
    always @(posedge clk) begin
        if(state==WREAD || state==CREAD)word_q<=memory[validation_address];
        if(state==WCHECK && !covered_q && reset_n && !invalidate && machine_quiesced && !write_valid && !load_begin && !load_finish)
            memory[validation_address]<=write_latch;
        if(state==WREAD)covered_q<=covered[coverage_address];
        if(reset_n && !invalidate)begin
            if(state==CLEAR)covered[coverage_address]<=0;
            else if(state==WCHECK && !covered_q && machine_quiesced && !write_valid && !load_begin && !load_finish)
                covered[coverage_address]<=1;
        end
    end
    // Keep reset/valid muxes outside the physical RAM read register.
    // The public port retains its one-cycle read/hold/zero-on-fault contract.
    always @(posedge clk)begin
        if(read_enable)machine_word<=memory[read_word_address];
    end
    always @* read_data=machine_read_valid ? machine_word : 32'b0;
    always @(posedge clk) begin
        if(!reset_n || invalidate)begin machine_read_valid<=0;read_fault<=0;end
        else begin
            read_fault<=0;
            if(read_enable)begin
                machine_read_valid<=valid && state==DONE && read_word_address<PAYLOAD_WORDS;
                if(!(valid && state==DONE && read_word_address<PAYLOAD_WORDS))read_fault<=1;
            end
        end
    end

    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            state<=IDLE;valid<=0;error_code<=0;computed_crc<=0;unique_words<=0;
            write_accepted<=0;clear_index<=0;write_index<=0;scan_index<=0;byte_index<=0;crc<=32'hFFFFFFFF;
        end else if(invalidate) begin
            state<=IDLE;valid<=0;error_code<=0;computed_crc<=0;unique_words<=0;
            write_accepted<=0;clear_index<=0;write_index<=0;scan_index<=0;byte_index<=0;crc<=32'hFFFFFFFF;
        end else begin
            write_accepted<=0;
            if(!machine_quiesced && (loading || load_begin || load_finish || write_valid)) begin
                valid<=0;error_code<=E_QUIESCENCE;state<=ERROR;
            end else if((write_valid || load_finish) && state!=LOAD) begin
                valid<=0;error_code<=E_BUSY;state<=ERROR;
            end else if(load_begin) begin
                if(state!=IDLE) begin valid<=0;error_code<=E_RELOAD;state<=ERROR;end
                else if(declared_size!=PAYLOAD_BYTES) begin error_code<=E_SIZE;state<=ERROR;end
                else begin clear_index<=0;unique_words<=0;state<=CLEAR;end
            end else begin
                case(state)
                CLEAR: begin
                    if(clear_index==PAYLOAD_WORDS-1) state<=LOAD;
                    else clear_index<=clear_index+1'b1;
                end
                LOAD: begin
                    if(write_valid) begin
                        if(write_byte_address[1:0]!=0) begin error_code<=E_ALIGNMENT;state<=ERROR;end
                        else if(write_byte_address>=PAYLOAD_BYTES) begin error_code<=E_RANGE;state<=ERROR;end
                        else begin write_index<=write_byte_address[AW+1:2];write_latch<=write_data;state<=WREAD;end
                    end else if(load_finish) begin
                        if(unique_words!=PAYLOAD_WORDS) begin error_code<=E_MISSING;state<=ERROR;end
                        else begin scan_index<=0;crc<=32'hFFFFFFFF;state<=CREAD;end
                    end
                end
                WREAD: state<=WCHECK;
                WCHECK: begin
                    if(covered_q && word_q!=write_latch) begin error_code<=E_DUPLICATE;state<=ERROR;end
                    else begin
                        if(!covered_q)unique_words<=unique_words+1'b1;
                        write_accepted<=1;state<=LOAD;
                    end
                end
                CREAD: begin byte_index<=0;state<=CBYTE;end
                CBYTE: begin
                    crc<=next_crc;
                    if(byte_index==3) begin
                        if(scan_index==PAYLOAD_WORDS-1) begin
                            computed_crc<=~next_crc;
                            if((~next_crc)!=EXPECTED_CRC) begin error_code<=E_CRC;state<=ERROR;end
                            else if(!IDENTITY_APPROVED) begin error_code<=E_UNAPPROVED;state<=ERROR;end
                            else begin valid<=1;state<=DONE;end
                        end else begin scan_index<=scan_index+1'b1;state<=CREAD;end
                    end else byte_index<=byte_index+1'b1;
                end
                default: ;
                endcase
            end
        end
    end
endmodule
`default_nettype wire
