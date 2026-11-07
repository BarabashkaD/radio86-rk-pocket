`timescale 1ns/1ps
module tb_cart_ppi;
    reg clk=0,reset=1,write_strobe=0,rom_valid=1;
    reg [1:0] register_address=0;
    reg [7:0] write_data=0,rom_data=0;
    reg [14:0] rom_tag=0;
    wire [14:0] rom_address;
    wire [7:0] read_data;
    wire ready;
    always #5 clk=~clk;
    function [7:0] pattern(input [14:0] address);
        pattern=address>=15'h7e00 ? 8'hff : ((address*37)^address[14:8]^8'ha5);
    endfunction
    always @(posedge clk)begin rom_tag<=rom_address;rom_data<=pattern(rom_address);end
    pocket_cart_ppi dut(.clk(clk),.reset(reset),.write_strobe(write_strobe),.register_address(register_address),
        .write_data(write_data),.read_data(read_data),.rom_valid(rom_valid),.rom_address(rom_address),
        .rom_tag(rom_tag),.rom_data(rom_data),.read_ready(ready));
    task write_reg(input [1:0] a,input [7:0] d);
        begin @(negedge clk);register_address=a;write_data=d;write_strobe=1;
            @(negedge clk);write_strobe=0;repeat(2)@(negedge clk);end
    endtask
    task expect_read(input [1:0] a,input [7:0] d);
        begin register_address=a;#1;if(!ready || read_data!==d)$fatal(1,"cart PPI reg=%h got=%h ready=%b want=%h",a,read_data,ready,d);end
    endtask
    integer i;
    initial begin
        repeat(3)@(negedge clk);reset=0;
        expect_read(0,255);expect_read(1,255);expect_read(2,255);
        write_reg(3,8'h90);expect_read(1,0);expect_read(2,0);expect_read(0,pattern(0));
        for(i=0;i<32768;i=i+1)begin
            write_reg(1,i[7:0]);write_reg(2,{1'b0,i[14:8]});
            if(rom_address!==i[14:0])$fatal(1,"ROM address wiring %h want %h",rom_address,i);
            expect_read(0,pattern(i));
        end
        write_reg(3,8'h0f);expect_read(0,255); // BSR PC7 set: /CE off.
        write_reg(3,8'h0e);expect_read(0,255); // Last address is defined FF tail.
        write_reg(1,0);write_reg(2,0);expect_read(0,pattern(0));
        write_reg(0,8'h11);expect_read(0,pattern(0)); // ROM is read-only.
        // Assert a stale tag directly to verify the CPU-facing wait contract.
        force rom_tag=15'h1234;register_address=0;#1;
        if(ready || read_data!==255)$fatal(1,"stale ROM data exposed");
        release rom_tag;repeat(2)@(negedge clk);expect_read(0,pattern(0));
        rom_valid=0;expect_read(0,255);rom_valid=1;
        write_reg(3,8'h91);expect_read(0,255); // C low input.
        write_reg(3,8'h98);expect_read(0,255); // C high input.
        write_reg(3,8'h92);expect_read(0,255); // B input.
        write_reg(3,8'h80);expect_read(0,255); // A output.
        write_reg(3,8'h94);expect_read(0,255); // Unsupported group-B mode 1.
        write_reg(3,8'hb0);expect_read(0,255); // Unsupported group-A mode 1.
        write_reg(3,8'h90);expect_read(3,255);expect_read(0,pattern(0));
        reset=1;#1;expect_read(0,255);
        $display("PASS cart PPI: all 32768 addresses, 00FF/0100, payload/tail, mode/direction, BSR CE, read-only, stale tag and reset");$finish;
    end
endmodule
