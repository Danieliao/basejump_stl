module bsg_mem_1rw_sync_mask_write_byte #( parameter els_p = -1
                                          ,parameter addr_width_lp = `BSG_SAFE_CLOG2(els_p)

                                          ,parameter data_width_p = -1
                                          ,parameter write_mask_width_lp = data_width_p>>3
                                         )
  ( input clk_i
   ,input reset_i

   ,input v_i
   ,input w_i

   ,input [addr_width_lp-1:0]       addr_i
   ,input [data_width_p-1:0]        data_i
   ,input [write_mask_width_lp-1:0] write_mask_i
    
   ,output [data_width_p-1:0] data_o
  );
  
  // synopsys translate off
  always_comb
    assert (data_width_p % 8 == 0)
      else $error("data width should be a multiple of 8 for byte masking");
  // synopsys translate on

  genvar i;
  
  for(i=0; i<write_mask_width_lp; i=i+1)
  begin: mem_gen
    bsg_mem_1rw_sync #( .width_p      (8)
                       ,.els_p        (els_p)
                       ,.addr_width_lp(addr_width_lp)
                      ) mem_1rw_sync
                      ( .clk_i  (clk_i)
                       ,.reset_i(reset_i)
                       ,.data_i (data_i[(i*8)+:8])
                       ,.addr_i (addr_i)
                       ,.v_i    (v_i)
                       ,.w_i    (w_i & ~write_mask_i[i])
                       ,.data_o (data_o[(i*8)+:8])
                      );
  end

endmodule