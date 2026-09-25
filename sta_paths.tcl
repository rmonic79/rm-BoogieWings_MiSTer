project_open rmBoogieWings
create_timing_netlist -model slow
read_sdc
update_timing_netlist
report_timing -setup -npaths 20 -detail path_only -file output_files/worst_paths.rpt
delete_timing_netlist
project_close
