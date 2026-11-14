# Genus-style scan, then Modus-style stuck-at ATPG on the original netlist.
set here [file dirname [file normalize [info script]]]
source [file join $here genus_scan.tcl]
build_model -workdir [pwd] -designsource [file join [pwd] .faultplus mapped.v] \
    -techlib [file join $here cells_sim.v] -designtop seq_design
build_testmode -testmode FULLSCAN
build_faultmodel -includedynamic no
create_logic_tests -testmode FULLSCAN -experiment seq
report_faults -testmode FULLSCAN -experiment seq
# Fault uses cut/pseudo-I/O here. It cannot produce Modus scan/timing vectors.
