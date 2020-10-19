/**
*@info top module
*@info Sub-Modules: Processor_Top.sv, main_memory.sv
*
*
* @brief Initializes the Processor and the main memory controller, and connects them
*
*/
`ifdef MODEL_TECH
    `include "structs.sv"
    `include "vstructs.sv"
    `include "params.sv"
    `include "../vector_simulator/decoder_results/autogenerated_params.sv"
`endif
module vector_sim_top ();

    logic clk;
    logic rst_n;

    logic                 req_rd_l2_dcache_valid;
    logic                 resp_l2_dcache_valid  ;
    logic                 write_l2_valid        ;
    logic [ADDR_BITS-1:0] req_rd_l2_dcache_addr ;
    logic [ADDR_BITS-1:0] resp_l2_dcache_addr   ;
    logic [ADDR_BITS-1:0] req_wr_l2_dcache_addr ;
    logic [    DC_DW-1:0] req_wr_l2_dcache_data ;
    logic [    DC_DW-1:0] resp_l2_dcache_data   ;
    logic                 req_wr_l2_dcache_valid;
    logic                 valid_instr           ;
    to_vector             vector_instr          ;
    logic                 vector_pop            ;
    logic                 mem_req_valid         ;
    vector_mem_req        mem_req               ;
    logic                 cache_vector_ready    ;
    logic                 mem_resp_valid        ;
    vector_mem_resp       mem_resp              ;
    logic                 vector_idle           ;

    // generate clock
    always
        begin
        clk = 1; #5; clk = 0; #5;
    end

    // generate reset
    initial begin
        $display("Testbench Starting...");
        rst_n=0;
        @(posedge clk);
        rst_n=0;
        @(posedge clk);
        rst_n=1;
        @(posedge clk);
        @(posedge clk);@(posedge clk);
        $display("Exiting Reset...");
    end

    // autofinish simulation
    logic [63:0] previous_total_issues ;
    logic [31:0] idle_counter          ;
    logic [31:0] deadlock_counter      ;
    logic        force_end_sim_empty   ;
    logic        force_end_sim_deadlock;
    logic        memory_empty          ;
    logic        pipeline_empty        ;
    logic        sim_finished          ;
    logic        sim_stop              ;

    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            previous_total_issues <= 0;
        end else begin
            previous_total_issues <= vector_top.vis.total_issues;
        end
    end

    assign memory_empty   = ~(vector_driver.head < SIM_VECTOR_INSTRS);
    assign pipeline_empty = memory_empty & ~vector_top.vis.valid_in;
    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            idle_counter <= 0;
        end else begin
            if(pipeline_empty) idle_counter <= idle_counter +1;
            else               idle_counter <= 0;
        end
    end

    assign deadlock_en = valid_instr & (vector_top.vis.total_issues === previous_total_issues);
    always_ff @(posedge clk or negedge rst_n) begin
        if(~rst_n) begin
            deadlock_counter <= 0;
        end else begin
            if(deadlock_en) deadlock_counter <= deadlock_counter +1;
            else            deadlock_counter <= 0;
        end
    end

    assign sim_finished           = vector_idle & memory_empty & rst_n;
    assign force_end_sim_empty    = (idle_counter == 100) & rst_n;
    assign force_end_sim_deadlock = (deadlock_counter == 300) & rst_n;

    assign sim_stop               = sim_finished | force_end_sim_empty | force_end_sim_deadlock;

    initial begin
        wait(sim_stop);
        if (force_end_sim_empty | force_end_sim_deadlock) begin
            $display("====================================");
            $display("Deadlock detected.. -> Forcing end of Simulation!!");
        end
        print_perf_stats();
        @(posedge clk);
        @(posedge clk);
        $finish();
    end

    //////////////////////////////////////////////////
    //             Instruction Driver               //
    //////////////////////////////////////////////////
    vector_driver #(
        .DEPTH           (SIM_VECTOR_INSTRS       ),
        .DATA_WIDTH      (DATA_WIDTH              ),
        .VECTOR_REGISTERS(VECTOR_REGISTERS        ),
        .VECTOR_LANES    (VECTOR_LANES            ),
        .MICROOP_WIDTH   (VECTOR_MEM_MICROOP_WIDTH)
    ) vector_driver (
        .clk    (clk         ),
        .rst_n  (rst_n       ),

        .valid_o(valid_instr ),
        .instr_o(vector_instr),
        .pop_i  (vector_pop  )
    );
    //////////////////////////////////////////////////
    //                   Processor                  //
    //////////////////////////////////////////////////
    vector_top #(
        .VECTOR_REGISTERS  (VECTOR_REGISTERS        ),
        .VECTOR_LANES      (VECTOR_LANES            ),
        .DATA_WIDTH        (DATA_WIDTH              ),
        .MEM_MICROOP_WIDTH (VECTOR_MEM_MICROOP_WIDTH),
        .MICROOP_WIDTH     (VECTOR_MICROOP_WIDTH    ),
        .VECTOR_TICKET_BITS(VECTOR_TICKET_BITS      ),
        .VECTOR_REQ_WIDTH  (VECTOR_MAX_REQ_WIDTH    ),
        .FWD_POINT_A       (VECTOR_FWD_POINT_A      ),
        .FWD_POINT_B       (VECTOR_FWD_POINT_B      ),
        .USE_HW_UNROLL     (USE_HW_UNROLL           )
    ) vector_top (
        .clk             (clk               ),
        .rst_n           (rst_n             ),
        .vector_idle_o   (vector_idle       ),
        //Instruction In
        .valid_in        (valid_instr       ),
        .instr_in        (vector_instr      ),
        .pop             (vector_pop        ),
        //Cache Request Interface
        .mem_req_valid_o (mem_req_valid     ),
        .mem_req_o       (mem_req           ),
        .cache_ready_i   (cache_vector_ready),
        //Cache Response Interface
        .mem_resp_valid_i(mem_resp_valid    ),
        .mem_resp_i      (mem_resp          )
    );
    //////////////////////////////////////////////////
    //                Caches' Subsection            //
    //////////////////////////////////////////////////

    data_cache #(
        .DATA_WIDTH          (DATA_WIDTH              ),
        .ADDR_BITS           (ADDR_BITS               ),
        .R_WIDTH             (R_WIDTH                 ),
        .MICROOP             (MICROOP_W               ),
        .ROB_TICKET          (ROB_TICKET_W            ),
        .ENTRIES             (DC_ENTRIES              ),
        .BLOCK_WIDTH         (DC_DW                   ),
        .BUFFER_SIZES        (4                       ),
        .ASSOCIATIVITY       (DC_ASC                  ),
        .VECTOR_ENABLED      (VECTOR_ENABLED          ),
        .VECTOR_MICROOP_WIDTH(VECTOR_MEM_MICROOP_WIDTH),
        .VECTOR_REQ_WIDTH    (VECTOR_MAX_REQ_WIDTH    ),
        .VECTOR_LANES        (VECTOR_LANES            )
    ) data_cache (
        .clk                 (clk                   ),
        .rst_n               (rst_n                 ),
        .output_used         (                      ),
        //Load Input Port
        .load_valid          (1'b0                  ),
        .load_address        (                      ),
        .load_dest           (                      ),
        .load_microop        (                      ),
        .load_ticket         (                      ),
        //Store Input Port
        .store_valid         (1'b0                  ),
        .store_address       (                      ),
        .store_data          (                      ),
        .store_microop       (                      ),
        //Vector Req Input Port
        .mem_req_valid_i     (mem_req_valid         ),
        .mem_req_i           (mem_req               ),
        .cache_vector_ready_o(cache_vector_ready    ),
        //Request Write Port to L2
        .write_l2_valid      (req_wr_l2_dcache_valid),
        .write_l2_addr       (req_wr_l2_dcache_addr ),
        .write_l2_data       (req_wr_l2_dcache_data ),
        //Request Read Port to L2
        .request_l2_valid    (req_rd_l2_dcache_valid),
        .request_l2_addr     (req_rd_l2_dcache_addr ),
        // Update Port from L2
        .update_l2_valid     (resp_l2_dcache_valid  ),
        .update_l2_addr      (resp_l2_dcache_addr   ),
        .update_l2_data      (resp_l2_dcache_data   ),
        //Output Port
        .cache_will_block    (                      ),
        .cache_blocked       (                      ),
        .served_output       (                      ),
        //Vector Output Port
        .vector_resp_valid_o (mem_resp_valid        ),
        .vector_resp         (mem_resp              )
    );
    //////////////////////////////////////////////////
    //               Main Memory Module             //
    //////////////////////////////////////////////////
    main_memory #(
        .L2_BLOCK_DW    (L2_DW       ),
        .L2_ENTRIES     (L2_ENTRIES  ),
        .ADDRESS_BITS   (ADDR_BITS   ),
        .ICACHE_BLOCK_DW(IC_DW       ),
        .DCACHE_BLOCK_DW(DC_DW       ),
        .REALISTIC      (REALISTIC   ),
        .DELAY_CYCLES   (DELAY_CYCLES),
        .FILE_NAME      ("../vector_simulator/decoder_results/init_main_memory.txt")
    ) main_memory (
        .clk              (clk                   ),
        .rst_n            (rst_n                 ),
        //Read Request Input from ICache
        .icache_valid_i   (1'b0                  ),
        .icache_address_i (                      ),
        //Output to ICache
        .icache_valid_o   (                      ),
        .icache_data_o    (                      ),
        //Read Request Input from DCache
        .dcache_valid_i   (req_rd_l2_dcache_valid),
        .dcache_address_i (req_rd_l2_dcache_addr ),
        //Output to DCache
        .dcache_valid_o   (resp_l2_dcache_valid  ),
        .dcache_address_o (resp_l2_dcache_addr   ),
        .dcache_data_o    (resp_l2_dcache_data   ),
        //Write Request Input from DCache
        .dcache_valid_wr  (req_wr_l2_dcache_valid),
        .dcache_address_wr(req_wr_l2_dcache_addr ),
        .dcache_data_wr   (req_wr_l2_dcache_data )
    );

    function print_perf_stats ();
        int f;
        //---------------------------------------
        f = $fopen("../vector_simulator/perf_results/results.log","w");
        $fwrite(f,"Total Cycles                    : %d \n",vector_top.vis.total_cycles);
        $fwrite(f,"Total Issued Instrs             : %d \n",vector_top.vis.total_issues);
        $fwrite(f,"Total Idle                      : %d \n",vector_top.vis.total_idle);
        $fwrite(f,"Total Idle due to no valid instr: %d \n",vector_top.vis.idle_no_valid);
        $fwrite(f,"Total Idle due to pending       : %d \n",vector_top.vis.stall_pending);
        $fwrite(f,"Total Idle due to locked        : %d \n",vector_top.vis.stall_locked);
        $fwrite(f,"Total memory stalled due to IS  : %d \n",vector_top.vmu.vmu_ld_eng.total_ld_stalled_due_is);
        $fclose(f);
        //---------------------------------------
        $display("====================================");
        $display("Total Cycles: %d",vector_top.vis.total_cycles);
        $display("Total Issued Instrs: %d",vector_top.vis.total_issues);
        $display("Total Idle: %d",vector_top.vis.total_idle);
        $display("Total Idle due to no valid instr: %d",vector_top.vis.idle_no_valid);
        $display("Total Idle due to pending: %d",vector_top.vis.stall_pending);
        $display("Total Idle due to locked: %d",vector_top.vis.stall_locked);
        $display("Total memory stalled due to IS: %d",vector_top.vmu.vmu_ld_eng.total_ld_stalled_due_is);
        $display("====================================");
    endfunction :print_perf_stats

endmodule : vector_sim_top