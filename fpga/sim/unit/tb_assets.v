`timescale 1ns/1ps
module tb_assets;
    reg clk=0,reset_n=0,quiesced=1,request=0,complete=0,wr=0;
    reg [15:0] id=0;
    reg [31:0] size=0,address=0,data=0;
    wire ack,ok,valid,error;
    wire cart_valid;
    wire [31:0] status,crc_m,crc_f,crc_c;
    reg [14:0] cart_address=0;
    wire [14:0] tag;
    wire [7:0] cart_data;
    reg [7:0] monitor[0:2047],font[0:1023],cart[0:32255];
    always #5 clk=~clk;
    pocket_boot_assets dut(.clk(clk),.reset_n(reset_n),.machine_quiesced(quiesced),
        .request_write(request),.request_id(id),.request_size(size),.request_ack(ack),.request_ok(ok),
        .allcomplete(complete),.bridge_wr(wr),.bridge_address(address),.bridge_data(data),
        .assets_valid(valid),.asset_error(error),
        .cartridge_valid(cart_valid),.status(status),.monitor_crc(crc_m),.font_crc(crc_f),.cartridge_crc(crc_c),
        .monitor_address(11'b0),.monitor_data(),.monitor_tag(),.font_address(10'b0),.font_data(),
        .cartridge_address(cart_address),.cartridge_tag(tag),.cartridge_data(cart_data));
    task slot(input [15:0] slot_id,input [31:0] bytes,input accepted);
        integer guard;
        begin
            @(negedge clk);id=slot_id;size=bytes;request=1;guard=0;
            while(!ack && guard<20000)begin @(negedge clk);guard=guard+1;end
            if(!ack || ok!==accepted)$fatal(1,"slot %h accepted=%b expected=%b status=%h",id,ok,accepted,status);
            request=0;repeat(3)@(negedge clk);
        end
    endtask
    task word_write(input [31:0] a,input [31:0] d);
        begin @(negedge clk);address=a;data=d;wr=1;@(negedge clk);wr=0;repeat(4)@(negedge clk);end
    endtask
    task pulse_reset;
        begin reset_n=0;complete=0;request=0;wr=0;quiesced=1;repeat(3)@(negedge clk);reset_n=1;repeat(3)@(negedge clk);end
    endtask
    task small_assets;
        integer j;
        begin
            slot(0,2048,1);
            for(j=0;j<512;j=j+1)word_write(32'h20000000+j*4,{monitor[j*4],monitor[j*4+1],monitor[j*4+2],monitor[j*4+3]});
            slot(1,1024,1);
            for(j=0;j<256;j=j+1)word_write(32'h21000000+j*4,{font[j*4],font[j*4+1],font[j*4+2],font[j*4+3]});
        end
    endtask
    integer i,guard;
    reg [31:0] word_data;
    initial begin
        $readmemh("monitor.hex",monitor);$readmemh("font.hex",font);$readmemh("cartridge.hex",cart);
        pulse_reset();slot(3,32256,0);slot(2,32768,0);slot(2,32255,0);
        // Non-default slot order and descending cartridge writes, including retry.
        slot(2,32256,1);
        for(i=8063;i>=0;i=i-1)begin
            word_data={cart[i*4],cart[i*4+1],cart[i*4+2],cart[i*4+3]};
            word_write(32'h22000000+i*4,word_data);
            if(i==12)word_write(32'h22000000+i*4,word_data);
        end
        small_assets();complete=1;guard=0;
        while(!valid && !error && guard<150000)begin @(negedge clk);guard=guard+1;end
        if(!valid || error || crc_m!==32'hbf1ceea5 || crc_f!==32'h21e9ed84 || crc_c!==32'h4b1c86d6)
            $fatal(1,"three asset CRC/coverage failure status=%h CRC=%h/%h/%h",status,crc_m,crc_f,crc_c);
        if(!cart_valid)$fatal(1,"ROM disk loaded but cartridge_valid low");
        for(i=0;i<32768;i=i+1)begin
            cart_address=i;repeat(2)@(negedge clk);
            if(tag!==i[14:0] || cart_data!==(i<32256 ? cart[i] : 8'hff))$fatal(1,"cartridge read byte=%h actual=%h",i,cart_data);
        end
        quiesced=0;slot(2,32256,0);if(!valid)$fatal(1,"running reload destroyed assets");
        pulse_reset();small_assets();repeat(15)@(negedge clk);
        if(valid)$fatal(1,"assets valid before allcomplete");
        complete=1;guard=0;
        while(!valid && !error && guard<150000)begin @(negedge clk);guard=guard+1;end
        if(!valid || error || cart_valid)$fatal(1,"missing ROM disk must be legal: valid=%b error=%b cart=%b status=%h",valid,error,cart_valid,status);
        pulse_reset();slot(1,1024,1);
        for(i=0;i<256;i=i+1)word_write(32'h21000000+i*4,{font[i*4],font[i*4+1],font[i*4+2],font[i*4+3]});
        complete=1;repeat(15)@(negedge clk);
        if(valid || !error || status[19:16]!==4'hb)$fatal(1,"missing monitor not diagnosed %h",status);
        pulse_reset();slot(2,32256,1);
        word_write(32'h22000000,32'h21000011);word_write(32'h22000000,32'h21000010);
        if(!error || status[23:20]!==3)$fatal(1,"conflicting cartridge retry not diagnosed %h",status);
        pulse_reset();slot(2,32256,1);word_write(32'h22007e00,0);
        if(!error || status[23:20]!==2)$fatal(1,"payload tail write not rejected %h",status);
        pulse_reset();slot(2,32256,1);word_write(32'h22000002,0);
        if(!error || status[23:20]!==8)$fatal(1,"unaligned cartridge write not rejected %h",status);
        $display("PASS assets: three slots/order/CRC, optional ROM disk, missing monitor, shuffled addresses/retry, 32768 reads with FF tail, reload/conflict/range/alignment/reset");$finish;
    end
endmodule
