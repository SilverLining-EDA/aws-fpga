// Minimal CVA6 SoC for AWS F2: core + on-chip SRAM @ 0x8000_0000 + UART @ 0x1000_0000.
// Host can load SRAM while the core is held in reset.

`include "axi/assign.svh"
`include "rvfi_types.svh"

module cva6_f2_soc
  import ariane_soc::*;
#(
  parameter int unsigned NumWords = 16384  // 128 KiB of 64-bit SRAM
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        cpu_run_i,

  // Host SRAM access (active while cpu_run_i == 0), 32-bit, byte-addressed from DRAM base
  input  logic        host_req_i,
  input  logic        host_we_i,
  input  logic [31:0] host_addr_i,
  input  logic [31:0] host_wdata_i,
  input  logic [3:0]  host_be_i,
  output logic [31:0] host_rdata_o,

  output logic        uart_tx_valid_o,
  output logic [7:0]  uart_tx_data_o,
  input  logic        uart_tx_ready_i
);

  function automatic config_pkg::cva6_cfg_t build_fpga_config(config_pkg::cva6_user_cfg_t CVA6UserCfg);
    config_pkg::cva6_user_cfg_t cfg = CVA6UserCfg;
    cfg.RVZiCond = bit'(0);
    cfg.NrNonIdempotentRules = unsigned'(1);
    cfg.NonIdempotentAddrBase = 1024'({64'b0});
    cfg.NonIdempotentLength = 1024'({ariane_soc::DRAMBase});
    return build_config_pkg::build_config(cfg);
  endfunction

  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_fpga_config(cva6_config_pkg::cva6_cfg);

  localparam type rvfi_probes_instr_t = `RVFI_PROBES_INSTR_T(CVA6Cfg);
  localparam type rvfi_probes_csr_t = `RVFI_PROBES_CSR_T(CVA6Cfg);
  localparam type rvfi_probes_t = struct packed {
    logic csr;
    rvfi_probes_instr_t instr;
  };

  localparam int unsigned NBSlave        = 1;
  localparam int unsigned NBMaster       = 2;
  localparam int unsigned DRAM_IDX       = 0;
  localparam int unsigned UART_IDX       = 1;
  localparam int unsigned AxiAddrWidth   = 64;
  localparam int unsigned AxiDataWidth   = 64;
  localparam int unsigned AxiIdWidthM    = 4;
  localparam int unsigned AxiIdWidthS    = AxiIdWidthM;  // single slave port
  localparam int unsigned AxiUserWidth   = CVA6Cfg.AxiUserWidth;
  localparam int unsigned SRAM_BYTES     = NumWords * (AxiDataWidth / 8);

  rvfi_probes_t rvfi_probes;

  logic rst_core_n;
  assign rst_core_n = rst_ni & cpu_run_i;

  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidthM  ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) slave[NBSlave-1:0]();

  AXI_BUS #(
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_ID_WIDTH   ( AxiIdWidthS  ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) master[NBMaster-1:0]();

  axi_pkg::xbar_rule_64_t [NBMaster-1:0] addr_map;
  assign addr_map = '{
    '{ idx: DRAM_IDX, start_addr: ariane_soc::DRAMBase, end_addr: ariane_soc::DRAMBase + SRAM_BYTES },
    '{ idx: UART_IDX, start_addr: ariane_soc::UARTBase, end_addr: ariane_soc::UARTBase + ariane_soc::UARTLength }
  };

  localparam axi_pkg::xbar_cfg_t AXI_XBAR_CFG = '{
    NoSlvPorts:         unsigned'(NBSlave),
    NoMstPorts:         unsigned'(NBMaster),
    MaxMstTrans:        unsigned'(1),
    MaxSlvTrans:        unsigned'(1),
    FallThrough:        1'b0,
    LatencyMode:        axi_pkg::CUT_ALL_PORTS,
    AxiIdWidthSlvPorts: unsigned'(AxiIdWidthM),
    AxiIdUsedSlvPorts:  unsigned'(AxiIdWidthM),
    UniqueIds:          1'b0,
    AxiAddrWidth:       unsigned'(AxiAddrWidth),
    AxiDataWidth:       unsigned'(AxiDataWidth),
    NoAddrRules:        unsigned'(NBMaster)
  };

  axi_xbar_intf #(
    .AXI_USER_WIDTH ( AxiUserWidth            ),
    .Cfg            ( AXI_XBAR_CFG            ),
    .rule_t         ( axi_pkg::xbar_rule_64_t )
  ) i_axi_xbar (
    .clk_i                 ( clk_i      ),
    .rst_ni                ( rst_ni     ),
    .test_i                ( 1'b0       ),
    .slv_ports             ( slave      ),
    .mst_ports             ( master     ),
    .addr_map_i            ( addr_map   ),
    .en_default_mst_port_i ( '0         ),
    .default_mst_port_i    ( '0         )
  );

  ariane_axi::req_t  axi_ariane_req;
  ariane_axi::resp_t axi_ariane_resp;

  ariane #(
    .CVA6Cfg             ( CVA6Cfg             ),
    .rvfi_probes_instr_t ( rvfi_probes_instr_t ),
    .rvfi_probes_csr_t   ( rvfi_probes_csr_t   ),
    .rvfi_probes_t       ( rvfi_probes_t       ),
    .noc_req_t           ( ariane_axi::req_t   ),
    .noc_resp_t          ( ariane_axi::resp_t  )
  ) i_ariane (
    .clk_i         ( clk_i            ),
    .rst_ni        ( rst_core_n       ),
    .boot_addr_i   ( ariane_soc::DRAMBase ),
    .hart_id_i     ( '0               ),
    .irq_i         ( 2'b00            ),
    .ipi_i         ( 1'b0             ),
    .time_irq_i    ( 1'b0             ),
    .debug_req_i   ( 1'b0             ),
    .rvfi_probes_o ( rvfi_probes      ),
    .noc_req_o     ( axi_ariane_req   ),
    .noc_resp_i    ( axi_ariane_resp  )
  );

  `AXI_ASSIGN_FROM_REQ(slave[0], axi_ariane_req)
  `AXI_ASSIGN_TO_RESP(axi_ariane_resp, slave[0])

  // ---------------
  // SRAM (DRAM window)
  // ---------------
  logic                        ram_req, ram_we;
  logic [AxiAddrWidth-1:0]     ram_addr;
  logic [AxiDataWidth/8-1:0]   ram_be;
  logic [AxiUserWidth-1:0]     ram_wuser, ram_ruser;
  logic [AxiDataWidth-1:0]     ram_wdata, ram_rdata;

  logic                        cpu_req, cpu_we;
  logic [AxiAddrWidth-1:0]     cpu_addr;
  logic [AxiDataWidth/8-1:0]   cpu_be;
  logic [AxiUserWidth-1:0]     cpu_wuser;
  logic [AxiDataWidth-1:0]     cpu_wdata;

  axi2mem #(
    .AXI_ID_WIDTH   ( AxiIdWidthS  ),
    .AXI_ADDR_WIDTH ( AxiAddrWidth ),
    .AXI_DATA_WIDTH ( AxiDataWidth ),
    .AXI_USER_WIDTH ( AxiUserWidth )
  ) i_axi2mem (
    .clk_i  ( clk_i           ),
    .rst_ni ( rst_ni          ),
    .slave  ( master[DRAM_IDX]),
    .req_o  ( cpu_req         ),
    .we_o   ( cpu_we          ),
    .addr_o ( cpu_addr        ),
    .be_o   ( cpu_be          ),
    .user_o ( cpu_wuser       ),
    .data_o ( cpu_wdata       ),
    .user_i ( ram_ruser       ),
    .data_i ( ram_rdata       )
  );

  logic [AxiDataWidth-1:0]   host_wdata64;
  logic [AxiDataWidth/8-1:0] host_be64;
  logic [AxiAddrWidth-1:0]   host_addr64;

  always_comb begin
    host_addr64  = ariane_soc::DRAMBase + 64'(host_addr_i);
    host_wdata64 = '0;
    host_be64    = '0;
    if (host_addr_i[2]) begin
      host_wdata64[63:32] = host_wdata_i;
      host_be64[7:4]      = host_be_i;
    end else begin
      host_wdata64[31:0]  = host_wdata_i;
      host_be64[3:0]      = host_be_i;
    end
  end

  assign ram_req   = cpu_run_i ? cpu_req   : host_req_i;
  assign ram_we    = cpu_run_i ? cpu_we    : host_we_i;
  assign ram_addr  = cpu_run_i ? cpu_addr  : host_addr64;
  assign ram_be    = cpu_run_i ? cpu_be    : host_be64;
  assign ram_wdata = cpu_run_i ? cpu_wdata : host_wdata64;
  assign ram_wuser = cpu_run_i ? cpu_wuser : '0;

  sram #(
    .DATA_WIDTH ( AxiDataWidth ),
    .USER_WIDTH ( AxiUserWidth ),
    .USER_EN    ( 0            ),
    .SIM_INIT   ( "zeros"      ),
    .NUM_WORDS  ( NumWords     )
  ) i_sram (
    .clk_i   ( clk_i ),
    .rst_ni  ( rst_ni ),
    .req_i   ( ram_req ),
    .we_i    ( ram_we ),
    .addr_i  ( ram_addr[$clog2(NumWords)-1+$clog2(AxiDataWidth/8):$clog2(AxiDataWidth/8)] ),
    .wuser_i ( ram_wuser ),
    .wdata_i ( ram_wdata ),
    .be_i    ( ram_be ),
    .ruser_o ( ram_ruser ),
    .rdata_o ( ram_rdata )
  );

  always_ff @(posedge clk_i) begin
    if (host_addr_i[2])
      host_rdata_o <= ram_rdata[63:32];
    else
      host_rdata_o <= ram_rdata[31:0];
  end

  // ---------------
  // UART
  // ---------------
  logic        uart_penable, uart_pwrite, uart_psel, uart_pready, uart_pslverr;
  logic [31:0] uart_paddr, uart_pwdata, uart_prdata;

  axi2apb_64_32 #(
    .AXI4_ADDRESS_WIDTH ( AxiAddrWidth ),
    .AXI4_RDATA_WIDTH   ( AxiDataWidth ),
    .AXI4_WDATA_WIDTH   ( AxiDataWidth ),
    .AXI4_ID_WIDTH      ( AxiIdWidthS  ),
    .AXI4_USER_WIDTH    ( AxiUserWidth ),
    .BUFF_DEPTH_SLAVE   ( 2            ),
    .APB_ADDR_WIDTH     ( 32           )
  ) i_axi2apb_uart (
    .ACLK       ( clk_i                 ),
    .ARESETn    ( rst_ni                ),
    .test_en_i  ( 1'b0                  ),
    .AWID_i     ( master[UART_IDX].aw_id     ),
    .AWADDR_i   ( master[UART_IDX].aw_addr   ),
    .AWLEN_i    ( master[UART_IDX].aw_len    ),
    .AWSIZE_i   ( master[UART_IDX].aw_size   ),
    .AWBURST_i  ( master[UART_IDX].aw_burst  ),
    .AWLOCK_i   ( master[UART_IDX].aw_lock   ),
    .AWCACHE_i  ( master[UART_IDX].aw_cache  ),
    .AWPROT_i   ( master[UART_IDX].aw_prot   ),
    .AWREGION_i ( master[UART_IDX].aw_region ),
    .AWUSER_i   ( master[UART_IDX].aw_user   ),
    .AWQOS_i    ( master[UART_IDX].aw_qos    ),
    .AWVALID_i  ( master[UART_IDX].aw_valid  ),
    .AWREADY_o  ( master[UART_IDX].aw_ready  ),
    .WDATA_i    ( master[UART_IDX].w_data    ),
    .WSTRB_i    ( master[UART_IDX].w_strb    ),
    .WLAST_i    ( master[UART_IDX].w_last    ),
    .WUSER_i    ( master[UART_IDX].w_user    ),
    .WVALID_i   ( master[UART_IDX].w_valid   ),
    .WREADY_o   ( master[UART_IDX].w_ready   ),
    .BID_o      ( master[UART_IDX].b_id      ),
    .BRESP_o    ( master[UART_IDX].b_resp    ),
    .BVALID_o   ( master[UART_IDX].b_valid   ),
    .BUSER_o    ( master[UART_IDX].b_user    ),
    .BREADY_i   ( master[UART_IDX].b_ready   ),
    .ARID_i     ( master[UART_IDX].ar_id     ),
    .ARADDR_i   ( master[UART_IDX].ar_addr   ),
    .ARLEN_i    ( master[UART_IDX].ar_len    ),
    .ARSIZE_i   ( master[UART_IDX].ar_size   ),
    .ARBURST_i  ( master[UART_IDX].ar_burst  ),
    .ARLOCK_i   ( master[UART_IDX].ar_lock   ),
    .ARCACHE_i  ( master[UART_IDX].ar_cache  ),
    .ARPROT_i   ( master[UART_IDX].ar_prot   ),
    .ARREGION_i ( master[UART_IDX].ar_region ),
    .ARUSER_i   ( master[UART_IDX].ar_user   ),
    .ARQOS_i    ( master[UART_IDX].ar_qos    ),
    .ARVALID_i  ( master[UART_IDX].ar_valid  ),
    .ARREADY_o  ( master[UART_IDX].ar_ready  ),
    .RID_o      ( master[UART_IDX].r_id      ),
    .RDATA_o    ( master[UART_IDX].r_data    ),
    .RRESP_o    ( master[UART_IDX].r_resp    ),
    .RLAST_o    ( master[UART_IDX].r_last    ),
    .RUSER_o    ( master[UART_IDX].r_user    ),
    .RVALID_o   ( master[UART_IDX].r_valid   ),
    .RREADY_i   ( master[UART_IDX].r_ready   ),
    .PENABLE    ( uart_penable          ),
    .PWRITE     ( uart_pwrite           ),
    .PADDR      ( uart_paddr            ),
    .PSEL       ( uart_psel             ),
    .PWDATA     ( uart_pwdata           ),
    .PRDATA     ( uart_prdata           ),
    .PREADY     ( uart_pready           ),
    .PSLVERR    ( uart_pslverr          )
  );

  host_uart i_host_uart (
    .clk_i       ( clk_i            ),
    .rst_ni      ( rst_ni           ),
    .penable_i   ( uart_penable     ),
    .pwrite_i    ( uart_pwrite      ),
    .paddr_i     ( uart_paddr       ),
    .psel_i      ( uart_psel        ),
    .pwdata_i    ( uart_pwdata      ),
    .prdata_o    ( uart_prdata      ),
    .pready_o    ( uart_pready      ),
    .pslverr_o   ( uart_pslverr     ),
    .tx_valid_o  ( uart_tx_valid_o  ),
    .tx_data_o   ( uart_tx_data_o   ),
    .tx_ready_i  ( uart_tx_ready_i  )
  );

endmodule
