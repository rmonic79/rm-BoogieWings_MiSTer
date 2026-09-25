derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ============================================================
# BoogieWings audio (modulo boogwings_audio, istanza emu|game|u_audio).
# NON esiste z80/darius_audio_z80: usa HuC6280 + YM2151(jt51) + 2x OKI(jt6295),
# tutti CE-gated da contatori su clk_sys 96MHz (Template.sv divisori ce_*).
# Multicycle per-istanza col rapporto REALE di ogni divisore (intra-dominio).
# NO multicycle globale: il mixer (mix_l/mix_r) gira su clk PURO = single-cycle
# reale, risolto in RTL con pipeline. I crossing fra enable diversi restano 1-ck.
# ============================================================
# HuC6280 u_cpu : ce_audio = 96/12 -> setup 12, hold 11
set_multicycle_path -setup -from [get_registers {*u_cpu*}] -to [get_registers {*u_cpu*}] 12
set_multicycle_path -hold  -from [get_registers {*u_cpu*}] -to [get_registers {*u_cpu*}] 11
# YM2151 jt51 u_ym : ce_ym = 96/27 (cen_p1 = /54) -> usa il piu' veloce 27
set_multicycle_path -setup -from [get_registers {*u_ym*}] -to [get_registers {*u_ym*}] 27
set_multicycle_path -hold  -from [get_registers {*u_ym*}] -to [get_registers {*u_ym*}] 26
# OKI#0 jt6295 u_oki0 : ce_oki0 = 96/95 -> setup 95, hold 94
set_multicycle_path -setup -from [get_registers {*u_oki0*}] -to [get_registers {*u_oki0*}] 95
set_multicycle_path -hold  -from [get_registers {*u_oki0*}] -to [get_registers {*u_oki0*}] 94
# OKI#1 jt6295 u_oki1 : ce_oki1 = 96/48 -> setup 48, hold 47
set_multicycle_path -setup -from [get_registers {*u_oki1*}] -to [get_registers {*u_oki1*}] 48
set_multicycle_path -hold  -from [get_registers {*u_oki1*}] -to [get_registers {*u_oki1*}] 47

# ============================================================
# DOWNLOAD decrypt path (de102 + deco56 COMBINATORI in cascata).
# Attivo SOLO durante il caricamento ROM: ioctl_addr/dout_raw da hps_io sono
# statici durante il gioco. hps_io eroga 1 word, il bridge alza prog_wr e ferma
# hps_io via ioctl_wait (prog_ack) -> fra una word e l'altra passano molti ck.
# Il path decrypt->write-data NON serve in 1 ck @96MHz. Multicycle 4 (41.6 ns).
# NON e' un path di gioco: zero impatto runtime, zero rischio pacing.
# ============================================================
# From ROBUSTO ai refit: il fitter rinomina i nodi interni (ioctl_addr_out/dout_out
# spariscono, launch reali diventano game|comb~N, in_data, in_op, Add). Quindi
# ancoro il -from a NOMI STABILI (hps_io ioctl_addr = radice di TUTTO il fan-out
# download; gp_outr = strobe HPS) + le gerarchie decrypt + game|comb (launch decrypt),
# e il -to a TUTTI gli endpoint download (tile1 BRAM, prog_*, ddr_dl_*, dl_data_word,
# audio_rom_*, sdram_a). Cosi' nessun refit fa decadere il multicycle.
set DL_FROM {*hps_io*ioctl_addr* *boogwings_top:game|comb* \
             *de102_ioctl_decrypt* *deco56_ioctl_decrypt* \
             *sdram_bridge*prog_wr* *gp_outr*}
set DL_TO   {*game*tile1_* *sdram_bridge*prog_* *ddr_dl_* *dl_data_word* \
             *audio_rom_* *u_sdram_jt|sdram_a* *u_sdram_jt|sdram_*}
set_multicycle_path -setup -from [get_registers $DL_FROM] -to [get_registers $DL_TO] 4
set_multicycle_path -hold  -from [get_registers $DL_FROM] -to [get_registers $DL_TO] 3
