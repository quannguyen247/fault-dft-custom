# Optional Fault-specific operations; the Cadence-style flow is full_flow.tcl.
set here [file dirname [file normalize [info script]]]
source [file join $here full_flow.tcl]
faultplus run asm -o vectors.bin -O golden.bin [file join [pwd] .faultplus seq.json] chained.v
faultplus run tap --clock clk --reset rst --liberty [file join $here tech_lib.lib] \
    --output jtag.v chained.v
