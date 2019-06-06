// MBT 7/24/2014
//
// Updated by Paul Gao 02/2019
//
//
// this implements:
//     - outgoing source-synchronous launch flops
//     - outgoing token channel to go from core domain deque to out of chip
//     - outgoing source-synchronous launch flops for token
//     - center-aligned DDR source sync output clock
//
//
// Note, for token clock reset, there is a certain pattern that must be asserted
// and deasserted during io reset.
//


module bsg_link_source_sync_upstream
     #(  parameter channel_width_p                 = 16
       , parameter lg_fifo_depth_p                 = 6
       , parameter lg_credit_to_token_decimation_p = 3

       // we explicit set the "inactive pattern"
       // on data lines when valid bit is not set
       //  to (10)+ = 0xA*
       //
       // the inactive pattern should balance the current
       // across I/O V33 and VZZ pads, reducing
       // electromigration for the common case of not
       // sending.
       //
       // for example, in TSMC 250, the EM limit is 41 mA
       // and the ratio of signal to I/O V33 and VZZ is
       // 4:1:1.
       //

       , parameter inactive_pattern_p = {channel_width_p { 2'b10 } }
       
       // Reset pattern is 0xF*
       // This is a remote reset from link_upstream to link_downstream
       // When channel data bits are in reset pattern, downstream link is on reset
       // Note that this pattern must be the same for upstream and downstream links
       
       , parameter reset_pattern_p = {channel_width_p {1'b1} }
       
       )
       
   (// control signals  
      input                         core_clk_i
    , input                         core_link_reset_i
    , input                         core_link_enable_i
    
    , input                         io_master_clk_i
    , output                        io_reset_o
    
    // Input from chip core
    , input [channel_width_p-1:0]   core_data_i
    , input                         core_valid_i
    , output                        core_ready_o  

    // source synchronous output channel to chip edge
    , output logic  [channel_width_p-1:0] io_data_o    // output data
    , output logic                        io_valid_o   // output valid
    , input                               io_ready_i   // output PHY is ready
    , input                               token_clk_i  // input token clock
   );

   
  // reset signals
  logic core_link_reset_lo, io_reset_lo;
  logic core_link_enable_lo, io_enable_lo;
  assign io_reset_o = io_reset_lo;
   
  bsg_launch_sync_sync
 #(.width_p(1)
  ) reset_blss
  (.iclk_i      (core_clk_i)
  ,.iclk_reset_i(1'b0)
  ,.oclk_i      (io_master_clk_i)
  ,.iclk_data_i (core_link_reset_i)
  ,.iclk_data_o (core_link_reset_lo)
  ,.oclk_data_o (io_reset_lo)
  );
  
  bsg_launch_sync_sync
 #(.width_p(1)
  ) enable_blss
  (.iclk_i      (core_clk_i)
  ,.iclk_reset_i(1'b0)
  ,.oclk_i      (io_master_clk_i)
  ,.iclk_data_i (core_link_enable_i)
  ,.iclk_data_o (core_link_enable_lo)
  ,.oclk_data_o (io_enable_lo)
  );


  // internal reset signal
  logic core_internal_reset_lo, io_internal_reset_lo;
  
  // Internal reset mode if reset asserted or link not enabled
  assign core_internal_reset_lo = ~core_link_enable_lo | core_link_reset_lo;
  assign io_internal_reset_lo   = ~io_enable_lo        | io_reset_lo;


  logic core_fifo_valid, core_fifo_yumi;
  logic [channel_width_p-1:0] core_fifo_data;

  // MBT: we insert a two-element fifo here to
  // decouple the async fifo logic which can be on the critical
  // path in some cases. possibly this is being overly conservative
  // and may introduce too much latency. but certainly in the
  // case of the bsg_comm_link code, it is necessary.
  // fixme: possibly make it a parameter as to whether we instantiate
  // this fifo
   
  bsg_two_fifo
 #(.width_p(channel_width_p)
  ) core_fifo
  (.clk_i  (core_clk_i)
  ,.reset_i(core_internal_reset_lo)
  
  ,.ready_o(core_ready_o)
  ,.data_i (core_data_i)
  ,.v_i    (core_valid_i)

  ,.v_o    (core_fifo_valid)
  ,.data_o (core_fifo_data)
  ,.yumi_i (core_fifo_yumi)
  );
  
  
  logic core_fifo_full;
  assign core_fifo_yumi = core_fifo_valid & ~core_fifo_full;
  
  logic io_fifo_valid, io_fifo_yumi;
  logic [channel_width_p-1:0] io_fifo_data;
  
  
  // ******************************************
  // clock-crossing async fifo
  // this is just an output fifo and does not
  // need to cover the round trip latency
  // of the channel; just the clock domain crossing
  //
  // Assuming (A and B are registers with the corresponding clocks)
  // this is the structure of the roundtrip path:
  //
  //                 /--  B <-- B <-- A <--\
  //                |                      |
  //                 \--> B --> A --> A ---/
  //
  // Suppose we have cycleTimeA and cycleTimeB, with cycleTimeA > cycleTimeB
  // the bandwidth*delay product of the roundtrip is:
  //
  //   3 * (cycleTimeA + cycleTimeB) * min(1/cycleTimeA, 1/cycleTimeB)
  // = 3 + 3 * cycleTimeB / cycleTimeA
  //
  // w.c. is cycleTimeB == cycleTimeA
  //
  // --> 6 elements
  //
  // however, for the path from A to B and B to A
  // we need to clear not only the cycle time of A/B
  // but the two setup times, which are guaranteed to
  // be less than a cycle each. So we get 8 elements total.
  //
   
  bsg_async_fifo
 #(.lg_size_p(3)
  ,.width_p(channel_width_p)
  ) async_fifo
  (.w_clk_i  (core_clk_i)
  ,.w_reset_i(core_internal_reset_lo)

  ,.w_enq_i  (core_fifo_yumi)
  ,.w_data_i (core_fifo_data)
  ,.w_full_o (core_fifo_full)

  ,.r_clk_i  (io_master_clk_i)
  ,.r_reset_i(io_internal_reset_lo)

  ,.r_deq_i  (io_fifo_yumi)
  ,.r_data_o (io_fifo_data)
  ,.r_valid_o(io_fifo_valid)
  );
  

   // ******************************************
   // Output valid and data signals
   
   
   // when fifo has valid data and token credit is available
   logic io_fifo_valid_credit_avail;
   
   always_comb
     begin
        if (io_internal_reset_lo)
          begin
             io_valid_o = 1'b0;
             io_data_o  = reset_pattern_p[0+:channel_width_p];
          end
        else
          begin
             io_valid_o = io_fifo_valid_credit_avail;
             if (io_fifo_valid_credit_avail)
               io_data_o = io_fifo_data;
             else
               io_data_o = inactive_pattern_p[0+:channel_width_p];
          end
     end
   
   
    //
    // token async reset rules:
    //
    // Token counters use asynchronous reset signal, which means write clock 
    // token_clk_i CANNOT oscillate during reset (constant 0).
    // Token reset procedure:
    // **************************************************************
    //                   io_reset_lo   io_enable_lo   token_reset_lo
    //    Initial value       1              0              0
    //    Step 1              0              0              1
    //    Step 2              0              1              0    
    // **************************************************************
    // As shown above, token_reset_lo signal has a 0->1->0 pattern, where the
    // posedge (0->1) resets the token counter.
    //
    
    logic token_reset_lo;
    assign token_reset_lo = ~io_reset_lo & ~io_enable_lo;
    

   // we need to track whether the credits are coming from
   // posedge or negedge tokens.

   // high bit indicates which counter we are grabbing from
   logic [lg_credit_to_token_decimation_p+1-1:0] token_alternator_r;

   always_ff @(posedge io_master_clk_i)
     begin
        if (io_internal_reset_lo)
          // this will start us on the posedge token
          token_alternator_r <= '0;
        else
          if (io_fifo_yumi)
            token_alternator_r <= token_alternator_r + (lg_credit_to_token_decimation_p+1)'(1);
     end

   // high bit set means we have exceeded number of posedge credits
   // and are doing negedge credits
   wire on_negedge_token = token_alternator_r[lg_credit_to_token_decimation_p];

   logic io_negedge_credits_avail, io_posedge_credits_avail;

   wire io_credit_avail = on_negedge_token
        ? io_negedge_credits_avail
        : io_posedge_credits_avail;

   // we send if we have both data to send and credits to send with
   assign io_fifo_valid_credit_avail = io_credit_avail & io_fifo_valid;
   // dequeue from fifo when io_ready
   assign io_fifo_yumi = io_fifo_valid_credit_avail & io_ready_i;

   wire io_negedge_credits_deque = io_fifo_yumi & on_negedge_token;
   wire io_posedge_credits_deque = io_fifo_yumi & ~on_negedge_token;

   // **********************************************
   // token channel
   //
   // these are tokens coming from off chip that need to
   // cross into the io clock domain.
   //
   // note that we are a little unconventional here; we use the token
   // itself as a clock. this because we don't know the phase of the
   // token signal coming in.
   //
   // we count both edges of the token separately, and assume that they
   // will alternate in lock-step. we use two separate counters to do this.
   //
   // an alternative would be to use
   // dual-edged flops, but they are not available in most ASIC libraries
   // and although you can synthesize these out of XOR'd flops, they
   // violate the async maxim that all signals crossing clock boundaries
   // must come from a launch flop.

   bsg_async_credit_counter
     #(// half the credits will be positive edge tokens
       .max_tokens_p(2**(lg_fifo_depth_p-1-lg_credit_to_token_decimation_p))
       ,.lg_credit_to_token_decimation_p(lg_credit_to_token_decimation_p)
       ,.count_negedge_p(1'b0)
       // we enable extra margin in case downstream module wants more tokens
       ,.extra_margin_p(2)
       ,.start_full_p(1)
       ,.use_async_w_reset_p(1'b1)
       ) pos_credit_ctr
       (
        .w_clk_i   (token_clk_i)
        ,.w_inc_token_i(1'b1)
        ,.w_reset_i(token_reset_lo)

        // the I/O clock domain is responsible for tabulating tokens
        ,.r_clk_i  (io_master_clk_i)
        ,.r_reset_i(io_internal_reset_lo)
        ,.r_dec_credit_i      (io_posedge_credits_deque)
        ,.r_infinite_credits_i(io_internal_reset_lo)
        ,.r_credits_avail_o   (io_posedge_credits_avail)
        );

   bsg_async_credit_counter
     #(// half the credits will be negative edge tokens
       .max_tokens_p(2**(lg_fifo_depth_p-1-lg_credit_to_token_decimation_p))
       ,.lg_credit_to_token_decimation_p(lg_credit_to_token_decimation_p)
       ,.count_negedge_p(1'b1)
       // we enable extra margin in case downstream module wants more tokens
       ,.extra_margin_p(2)
       ,.start_full_p(1)
       ,.use_async_w_reset_p(1'b1)
       ) neg_credit_ctr
       (
        .w_clk_i   (token_clk_i)
        ,.w_inc_token_i(1'b1)
        ,.w_reset_i(token_reset_lo)

        // the I/O clock domain is responsible for tabulating tokens
        ,.r_clk_i             (io_master_clk_i         )
        ,.r_reset_i           (io_internal_reset_lo       )
        ,.r_dec_credit_i      (io_negedge_credits_deque)
        ,.r_infinite_credits_i(io_internal_reset_lo)
        ,.r_credits_avail_o   (io_negedge_credits_avail)
        );


endmodule