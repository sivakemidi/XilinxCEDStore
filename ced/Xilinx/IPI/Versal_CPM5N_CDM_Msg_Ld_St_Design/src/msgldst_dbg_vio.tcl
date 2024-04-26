create_ip -name axis_vio -vendor xilinx.com -library ip -module_name msgld_st_vio
set_property -dict [list \
  CONFIG.C_NUM_PROBE_IN {3} \
  CONFIG.C_NUM_PROBE_OUT {19} \
  CONFIG.C_PROBE_OUT1_WIDTH {15} \
  CONFIG.C_PROBE_OUT2_WIDTH {32} \
  CONFIG.C_PROBE_OUT4_WIDTH {15} \
  CONFIG.C_PROBE_OUT5_WIDTH {32} \
  CONFIG.C_PROBE_OUT11_WIDTH {5} \
  CONFIG.C_PROBE_OUT12_WIDTH {9} \
  CONFIG.C_PROBE_OUT11_INIT_VAL {0x4} \
  CONFIG.C_PROBE_OUT12_INIT_VAL {0x80} \
  CONFIG.C_PROBE_OUT13_WIDTH {12} \
  CONFIG.C_PROBE_OUT14_WIDTH {12} \
  CONFIG.C_PROBE_OUT15_WIDTH {1} \
  CONFIG.C_PROBE_OUT16_WIDTH {3} \
  CONFIG.C_PROBE_OUT17_WIDTH {3} \
] [get_ips msgld_st_vio]