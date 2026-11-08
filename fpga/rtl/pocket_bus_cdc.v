// A W-bit bus from src_clk to dst_clk by a toggle handshake. The source holds the value in
// `held` and toggles `req_token`; the destination synchronizes it in 3 flip-flops (`req_sync`),
// copies `held` into `dst_data` when `req_sync[2]` differs from `ack_token`, and returns
// `ack_token` through 3 flip-flops (`ack_sync`); the source loads the next value only when
// `ack_sync[2]` equals `req_token`. The source reloads at every return, so the last source value
// always arrives, and `dst_data` changes only as a whole, to a value `src_data` had. `held` is
// stable for more than 3 dst_clk periods before it is copied (pocket_bus_cdc.sdc cuts held ->
// dst_data and the paths into the two first synchronizer stages). Latency: `dst_data` takes a
// loaded `held` 3-4 dst_clk later; one round trip is about 4 dst_clk + 4 src_clk (0.4 us at
// 12.288 / 74.25 MHz), and a new `src_data` waits at most one round trip before it is loaded.
`default_nettype none
module pocket_bus_cdc #(parameter W = 78) (
    input  wire         src_clk,
    input  wire         src_reset_n,
    input  wire [W-1:0] src_data,
    input  wire         dst_clk,
    input  wire         dst_reset_n,
    output reg  [W-1:0] dst_data = {W{1'b0}}
);
reg [W-1:0] held = {W{1'b0}};
reg req_token = 1'b0, ack_token = 1'b0;
(* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] ack_sync = 3'd0;
(* preserve, altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *) reg [2:0] req_sync = 3'd0;
always @(posedge src_clk or negedge src_reset_n)
    if (!src_reset_n) begin
        held <= {W{1'b0}}; req_token <= 1'b0; ack_sync <= 3'd0;
    end else begin
        ack_sync <= {ack_sync[1:0], ack_token};
        if (ack_sync[2] == req_token) begin held <= src_data; req_token <= !req_token; end
    end
always @(posedge dst_clk or negedge dst_reset_n)
    if (!dst_reset_n) begin
        dst_data <= {W{1'b0}}; ack_token <= 1'b0; req_sync <= 3'd0;
    end else begin
        req_sync <= {req_sync[1:0], req_token};
        if (req_sync[2] != ack_token) begin dst_data <= held; ack_token <= req_sync[2]; end
    end
endmodule
`default_nettype wire
