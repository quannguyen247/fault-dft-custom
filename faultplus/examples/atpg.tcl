# Modus-style stuck-at flow. Run from a separate work directory.
set example_dir [file dirname [file normalize [info script]]]
build_model -workdir [pwd] \
    -designsource [file join $example_dir and2_netlist.v] \
    -techlib [file join $example_dir and2_cells.v] -designtop and2_top
build_testmode -testmode COMB -assignfile [file join $example_dir and2.pinassign]
build_faultmodel -includedynamic no
create_logic_tests -testmode COMB -experiment and2
report_faults -testmode COMB -experiment and2
write_vectors -testmode COMB -inexperiment and2 -language verilog -outputfilename and2_vectors.v
