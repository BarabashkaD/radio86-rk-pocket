// Hello-world test bench for the rk86-vvp remote runner.
module hello;
  integer i;
  integer sum;
  initial begin
    sum = 0;
    for (i = 1; i <= 100; i = i + 1) sum = sum + i * i;
    $display("sum of squares 1..100 = %0d", sum);
    $display("PASS: hello");
    $finish;
  end
endmodule
