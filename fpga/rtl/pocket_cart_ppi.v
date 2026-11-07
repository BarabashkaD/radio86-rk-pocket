// Pocket-only mode-0 8255 subset for the pinned parallel ROM cartridge.
`default_nettype none
module pocket_cart_ppi(
    input wire clk,reset,
    input wire write_strobe,
    input wire [1:0] register_address,
    input wire [7:0] write_data,
    output reg [7:0] read_data,
    input wire rom_valid,
    output wire [14:0] rom_address,
    input wire [14:0] rom_tag,
    input wire [7:0] rom_data,
    output wire read_ready
);
    reg [7:0] mode,port_a,port_b,port_c;
    wire mode_zero=mode[6:5]==0 && !mode[2];
    wire address_outputs=!mode[1] && !mode[3] && !mode[0];
    wire selected=!reset && mode_zero && mode[4] && address_outputs && !port_c[7] && rom_valid;
    assign rom_address={port_c[6:0],port_b};
    assign read_ready=register_address!=0 || !selected || rom_tag==rom_address;
    always @* begin
        read_data=8'hff;
        if(!reset && mode_zero)case(register_address)
            0:if(selected && rom_tag==rom_address)read_data=rom_data;
            1:if(!mode[1])read_data=port_b;
            2:read_data={(mode[3] ? 4'hf : port_c[7:4]),(mode[0] ? 4'hf : port_c[3:0])};
            default:read_data=8'hff; // Control register read is outside the contract.
        endcase
    end
    always @(posedge clk)begin
        if(reset)begin mode<=8'h9b;port_a<=0;port_b<=0;port_c<=0;end
        else if(write_strobe)case(register_address)
            0:port_a<=write_data; // Output mode does not expose ROM data.
            1:port_b<=write_data;
            2:port_c<=write_data;
            3:if(write_data[7])begin
                mode<=write_data;port_a<=0;port_b<=0;port_c<=0;
            end else port_c[write_data[3:1]]<=write_data[0];
        endcase
    end
endmodule
`default_nettype wire
