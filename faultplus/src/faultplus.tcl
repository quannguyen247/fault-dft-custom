# Fault+ 0.1: a Tcl interface backed by AUCOHL Fault.
namespace eval ::fp {
    variable version 0.1.0
    variable cfg [dict create clock {} reset rst reset_active_low 0 bypassing {} input_kind {} dff {} scl_config {} cell_model {} atpg_options {-v 100 -r 50 -m 80 --ceiling 1000}]
    variable st [dict create liberty {} hdl {} top {} netlist {} mode {} model 0 faultmodel 0 cut {} result {} experiment {} auto_kind {} auto_dff {} mapped_dff {} workdir [pwd] shift shift test test sin sin sout sout shift_name {} default_mode {}]
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable backend [expr {[info exists ::env(FAULTPLUS_FAULT)] ? $::env(FAULTPLUS_FAULT) : "fault"}]
}
proc ::fp::warn {msg} {puts stderr "Fault+ WARNING: $msg"}
proc ::fp::fail {msg} {return -code error "Fault+: $msg"}
proc ::fp::need_file {p what} {
    if {![file isfile $p] || ![file readable $p]} {fail "$what not found or not readable: $p"}
    return [file normalize $p]
}
proc ::fp::need {key} {
    variable cfg
    set v [dict get $cfg $key]
    if {$v eq ""} {fail "configure -$key first (faultplus help configure)"}
    return $v
}
proc ::fp::options {args allowed} {
    set result [dict create]
    if {[llength $args] % 2} {fail "options require a value: $args"}
    foreach {k v} $args {
        if {$k ni $allowed} {fail "unsupported option '$k'; not silently ignored"}
        if {[dict exists $result $k]} {fail "duplicate option '$k'"}
        dict set result $k $v
    }
    return $result
}
proc ::fp::invoke {args} {
    variable backend
    if {![llength $args]} {fail "missing Fault subcommand"}
    if {[lindex $args 0] eq "atpg" && ![info exists ::env(FAULT_THREADS)]} {
        set ::env(FAULT_THREADS) 1
        warn "Using one Fault ATPG worker by default after an observed concurrent backend crash; set FAULT_THREADS explicitly to override."
    }
    if {[lindex $args 0] eq "atpg" && (![string is integer -strict $::env(FAULT_THREADS)] || $::env(FAULT_THREADS) < 1)} {
        fail "FAULT_THREADS must be a positive integer"
    }
    # Tcl exec interprets redirection and pipeline tokens even in expanded lists.
    # Reject them; no user input is passed through a shell.
    foreach arg [linsert $args 0 $backend] {
        if {[regexp {^(\||<|>|2>|2>@|&$)} $arg]} {fail "unsafe exec redirection/pipeline token: $arg"}
    }
    puts stderr "Fault+ -> [list $backend {*}$args]"
    if {[catch {exec -- $backend {*}$args >@stdout 2>@stderr} err opts]} {
        if {[lindex $args 0] eq "asm"} {append err "; asm expects a matching Fault scan-inserted netlist with FAULT METADATA"}
        return -options $opts "Fault+ backend failed: $err"
    }
}
# Fault 0.9.4 can report a successful exit after Yosys prints ERROR in its
# interactive script. Capture and inspect the synthesis log, not just exit code.
proc ::fp::invoke_synth {args} {
    variable backend
    set log [file join [output_dir] synth.log]
    foreach arg [linsert $args 0 $backend] {
        if {[regexp {^(\||<|>|2>|2>@|&$)} $arg]} {fail "unsafe exec redirection/pipeline token: $arg"}
    }
    puts stderr "Fault+ -> [list $backend {*}$args] (log: $log)"
    set rc [catch {exec -- $backend {*}$args > $log 2>@1} err opts]
    set f [open $log r]; try {set data [read $f]} finally {close $f}
    set errors [regexp -all -inline -line {^ERROR:.*} $data]
    if {$rc || [llength $errors]} {
        if {[llength $errors]} {set err [join $errors {; }]}
        fail "Fault synthesis failed: $err; inspect $log"
    }
}
proc ::fp::common {} {
    variable cfg
    set out [list --clock [need clock] --reset [dict get $cfg reset]]
    if {[dict get $cfg reset_active_low]} {lappend out --reset-active-low}
    foreach p [dict get $cfg bypassing] {lappend out --bypassing $p}
    return $out
}
proc ::fp::cut_options {} {
    variable cfg
    set out {}
    foreach {key flag} {dff --dff scl_config --scl-config} {
        set v [dict get $cfg $key]
        if {$v ne ""} {lappend out $flag $v}
    }
    return $out
}
proc ::fp::invalidate {} {
    variable st
    foreach k {faultmodel cut result experiment auto_kind auto_dff} {dict set st $k {}}
}
proc ::fp::invalidate_design {} {
    variable st
    invalidate
    foreach k {netlist model mode mapped_dff} {dict set st $k {}}
}
proc ::fp::classify {netlist} {
    variable root; variable st
    set cmd [list python3 [file join $root src design_probe.py] classify --netlist $netlist --models [need cell_model] --top [dict get $st top] --clock [need clock]]
    foreach pin [dict get $::fp::cfg bypassing] {lappend cmd --bypass $pin}
    if {[catch {exec -- {*}$cmd 2>@1} result]} {fail "cannot safely classify design: $result"}
    return $result
}
proc ::fp::configure {args} {
    variable cfg
    if {![llength $args]} {return $cfg}
    set opts [options $args {-clock -reset -reset_active_low -bypassing -input_kind -dff -scl_config -cell_model -atpg_options}]
    set next $cfg
    dict for {k v} $opts {
        set key [string range $k 1 end]
        switch -- $key {
            input_kind {if {$v ni {combinational cut sequential}} {fail "input_kind must be combinational, cut, or sequential"}}
            reset_active_low {if {$v ni {0 1}} {fail "reset_active_low must be 0 or 1"}}
            cell_model - scl_config {if {$v ne ""} {set v [need_file $v $key]}}
            atpg_options {
                # Keep output, model and clock ownership in the compatibility layer.
                set legal {-v --tv-count -r --increment -m --min-coverage --ceiling --tv-gen --rng-seed -g --etv-gen -b --bench --iterating-upon -D --define -I --include}
                if {[llength $v] % 2} {fail "atpg_options must be option/value pairs"}
                foreach {o value} $v {if {$o ni $legal} {fail "unsupported atpg_options entry $o; use faultplus run atpg for native options"}}
            }
        }
        dict set next $key $v
    }
    set cfg $next
    invalidate
    return $cfg
}
proc ::fp::get_workdir {opts} {
    variable st
    set wd [dict get $st workdir]
    if {[dict exists $opts -workdir]} {
        set given [file normalize [dict get $opts -workdir]]
        if {$given ne $wd} {fail "-workdir differs from build_model workdir; multiple Modus databases are not supported"}
    }
    return $wd
}
proc ::fp::parse_mode {opts} {
    variable st
    if {[dict get $st mode] eq ""} {fail "build_testmode first"}
    if {[dict exists $opts -testmode] && [dict get $opts -testmode] ne [dict get $st mode]} {fail "unknown testmode: [dict get $opts -testmode]"}
}
proc ::fp::output_dir {} {
    variable st
    set dir [file join [dict get $st workdir] .faultplus]
    file mkdir $dir
    return $dir
}
proc ::fp::check_product {path} {
    if {![file isfile $path] || [file size $path] == 0} {fail "Fault returned success but did not create expected output: $path"}
}
# Native Fault escape hatch: the installed tool remains the source of truth for all options.
proc faultplus {subcommand args} {
    switch -- $subcommand {
        configure {return [::fp::configure {*}$args]}
        run {
            if {![llength $args] || [lindex $args 0] ni {synth cut atpg chain tap asm help}} {::fp::fail "usage: faultplus run {synth|cut|atpg|chain|tap|asm|help} ..."}
            ::fp::invoke {*}$args
            return
        }
        status {return [::fp::status {*}$args]}
        export {return [::fp::export {*}$args]}
        help {return [::fp::help {*}$args]}
        default {::fp::fail "unknown faultplus subcommand '$subcommand'; try faultplus help"}
    }
}
# Genus common-UI subset. These prepare inputs; actual synthesis occurs at syn_map.
proc read_libs {args} {
    if {[llength $args] != 1} {::fp::fail "read_libs supports exactly one Liberty file"}
    set p [::fp::need_file [lindex $args 0] Liberty]
    ::fp::invalidate_design
    dict set ::fp::st liberty $p
    ::fp::warn "read_libs records one Liberty file; Fault/Yosys loads it during syn_map."
}
proc read_hdl {args} {
    if {![llength $args]} {::fp::fail "read_hdl expects Verilog files"}
    if {[lindex $args 0] eq "-language"} {
        if {[llength $args] < 3 || [lindex $args 1] ni {v1995 v2001}} {::fp::fail "only Verilog v1995/v2001 is supported by this alias"}
        set args [lrange $args 2 end]
    }
    set files {}
    foreach item $args {
        if {[file isfile $item]} {set items [list $item]} else {set items $item}
        foreach p $items {
            if {[string match -* $p]} {::fp::fail "unsupported read_hdl option $p"}
            lappend files [::fp::need_file $p Verilog]
        }
    }
    if {![llength $files]} {::fp::fail "no HDL files"}
    ::fp::invalidate_design
    dict set ::fp::st hdl $files
    ::fp::warn "read_hdl records filenames; parsing/elaboration occurs inside Fault synth."
}
proc elaborate {args} {
    if {[llength $args] != 1} {::fp::fail "elaborate requires an explicit top module"}
    if {![llength [dict get $::fp::st hdl]]} {::fp::fail "read_hdl first"}
    ::fp::invalidate_design
    dict set ::fp::st top [lindex $args 0]
    ::fp::warn "elaborate records the top; actual elaboration occurs during syn_map."
}
proc syn_generic {args} {
    if {[llength $args]} {::fp::fail "syn_generic options are unsupported"}
    if {[dict get $::fp::st top] eq ""} {::fp::fail "elaborate first"}
    ::fp::warn "syn_generic is staged: Fault synth performs generic and mapped synthesis together at syn_map."
}
proc syn_map {args} {
    if {[llength $args]} {::fp::fail "syn_map options are unsupported"}
    set lib [dict get $::fp::st liberty]; set top [dict get $::fp::st top]; set files [dict get $::fp::st hdl]
    if {$lib eq "" || $top eq "" || ![llength $files]} {::fp::fail "read_libs, read_hdl, and elaborate are required"}
    ::fp::invalidate_design
    set out [file join [::fp::output_dir] mapped.v]
    # Avoid accepting an old artifact if the backend exits successfully without writing.
    if {[file exists $out]} {file delete -- $out}
    ::fp::invoke_synth synth --blackbox-models [file join $::fp::root src empty_blackboxes.v] --liberty $lib --top $top {*}$files --output $out
    ::fp::check_product $out
    dict set ::fp::st netlist $out
    set fh [open [file join [::fp::output_dir] synth.log] r]
    try {set log [read $fh]} finally {close $fh}
    set mapped {}
    foreach line [split $log \n] {
        if {[regexp {mapped [0-9]+ .* cells to \\([^ ]+) cells\.} $line -> cell] && $cell ni $mapped} {lappend mapped $cell}
    }
    dict set ::fp::st mapped_dff [join $mapped ,]
    if {[llength $mapped]} {::fp::warn "FF types inferred from Yosys mapping log: [join $mapped ,]; verify the scan result."}
    ::fp::warn "Fault/Yosys synthesis is not Genus synthesis; no SDC or timing constraints were applied."
    return $out
}
proc write_hdl {args} {
    set p [dict get $::fp::st netlist]
    if {$p eq ""} {::fp::fail "no mapped/chained netlist; run syn_map or connect_scan_chains"}
    ::fp::check_product $p
    if {[llength $args] == 2 && [lindex $args 0] eq ">"} {
        set out [lindex $args 1]
        if {[file normalize $out] ne [file normalize $p]} {file copy -force -- $p $out}
        puts stderr "Fault+ wrote $out"
        return
    }
    if {[llength $args]} {::fp::fail "usage: write_hdl ? > output.v ?"}
    set f [open $p r]; try {puts -nonewline [read $f]} finally {close $f}
}
# Cadence common UI form with a positional clock port.
proc define_test_clock {args} {
    if {[llength $args] < 1} {::fp::fail "usage: define_test_clock -name name ?-period value? port"}
    set port [lindex $args end]; set opts [::fp::options [lrange $args 0 end-1] {-name -period}]
    if {[string match -* $port]} {::fp::fail "missing clock port"}
    ::fp::configure -clock $port
    if {[dict exists $opts -period]} {::fp::warn "Fault has no equivalent timing waveform; -period is not applied."}
    ::fp::warn "Only the clock port name is mapped to Fault --clock."
}
proc define_test_signal {args} {
    if {![llength $args]} {::fp::fail "usage: define_test_signal -function async_set_reset -active high|low port"}
    set port [lindex $args end]
    set opts [::fp::options [lrange $args 0 end-1] {-function -name -active}]
    if {$port eq "" || [string match -* $port] || ![dict exists $opts -function] || [dict get $opts -function] ne "async_set_reset" || ![dict exists $opts -active]} {::fp::fail "only define_test_signal -function async_set_reset -active high|low port is supported"}
    set active [dict get $opts -active]
    if {$active ni {high low}} {::fp::fail "reset polarity must be high or low"}
    ::fp::configure -reset $port -reset_active_low [expr {$active eq "low"}]
    ::fp::warn "Reset name and inactive value are mapped to Fault; no Genus DFT object is built."
}
proc define_shift_enable {args} {
    set pos [lsearch -exact $args -create_port]
    if {$pos >= 0} {
        set args [lreplace $args $pos $pos]
        if {[lsearch -exact $args -create_port] >= 0} {::fp::fail "duplicate -create_port"}
        ::fp::warn "Fault chain creates its own ports; -create_port is not a Genus database operation."
    }
    set port [lindex $args end]
    set opts [::fp::options [lrange $args 0 end-1] {-name -active}]
    if {$port eq "" || [string match -* $port]} {::fp::fail "usage: define_shift_enable -name name -active high port"}
    if {[dict exists $opts -active] && [dict get $opts -active] ne "high"} {::fp::fail "active-low shift enable is not mapped"}
    dict set ::fp::st shift $port
    dict set ::fp::st shift_name [expr {[dict exists $opts -name] ? [dict get $opts -name] : $port}]
    ::fp::invalidate
    ::fp::warn "Records scan shift port for Fault chain; Genus DFT rules are not checked."
}
proc define_test_mode {args} {
    set pos [lsearch -exact $args -create_port]
    if {$pos >= 0} {
        set args [lreplace $args $pos $pos]
        if {[lsearch -exact $args -create_port] >= 0} {::fp::fail "duplicate -create_port"}
        ::fp::warn "Fault chain creates its own ports; -create_port is not a Genus database operation."
    }
    set port [lindex $args end]
    set opts [::fp::options [lrange $args 0 end-1] {-name -active}]
    if {$port eq "" || [string match -* $port]} {::fp::fail "usage: define_test_mode -name name -active high port"}
    if {[dict exists $opts -active] && [dict get $opts -active] ne "high"} {::fp::fail "active-low test mode is not mapped"}
    dict set ::fp::st test $port
    ::fp::invalidate
    ::fp::warn "Records Fault chain's --test port; Genus mode constraints are not built."
}
proc define_scan_chain {args} {
    # -create_ports has no value in Genus.
    set norm {}; set create 0
    foreach a $args {if {$a eq "-create_ports"} {if {$create} {::fp::fail "duplicate -create_ports"}; set create 1} else {lappend norm $a}}
    set opts [::fp::options $norm {-name -sdi -sdo -shift_enable}]
    foreach k {-sdi -sdo} {if {![dict exists $opts $k]} {::fp::fail "define_scan_chain requires $k"}}
    if {[dict exists $opts -shift_enable] && [dict get $opts -shift_enable] ne [dict get $::fp::st shift_name]} {::fp::fail "unknown shift_enable; define it first"}
    dict set ::fp::st sin [dict get $opts -sdi]; dict set ::fp::st sout [dict get $opts -sdo]
    ::fp::invalidate
    ::fp::warn "Records a single Fault scan chain and port names; no Genus scan object is created."
}
proc connect_scan_chains {args} {
    if {[llength $args]} {::fp::fail "connect_scan_chains options, including auto/multichain, are unsupported"}
    set net [dict get $::fp::st netlist]; set lib [dict get $::fp::st liberty]
    if {$net eq "" || $lib eq ""} {::fp::fail "syn_map and read_libs are required before scan chaining"}
    set cutopts [::fp::cut_options]
    if {![llength $cutopts]} {
        set inferred [dict get $::fp::st mapped_dff]
        if {$inferred eq ""} {::fp::fail "cannot infer DFF types from synthesis log; no internal scan chain was created"}
        set cutopts [list --dff $inferred]
        ::fp::warn "Using DFF types inferred from the synthesis log: $inferred."
    }
    set out [file join [::fp::output_dir] chained.v]
    if {[file normalize $net] eq [file normalize $out]} {::fp::fail "netlist is already the Fault+ chained output; reload the original netlist"}
    if {[file exists $out]} {file delete -- $out}
    ::fp::invalidate
    ::fp::invoke chain --liberty $lib {*}[::fp::common] {*}$cutopts --sin [dict get $::fp::st sin] --sout [dict get $::fp::st sout] --shift [dict get $::fp::st shift] --test [dict get $::fp::st test] --output $out $net
    ::fp::check_product $out
    dict set ::fp::st netlist $out
    ::fp::warn "Fault chain was run; this does not establish Genus DRC or scan-chain verification."
    return $out
}
# Modus ATPG subset, with Fault's pseudo-primary-I/O assumptions made explicit.
proc build_model {args} {
    set opts [::fp::options $args {-workdir -source -designsource -techlib -cell -designtop}]
    set source {}; set top {}
    foreach k {-source -designsource} {if {[dict exists $opts $k]} {if {$source ne ""} {::fp::fail "use only one source option"}; set source [dict get $opts $k]}}
    foreach k {-cell -designtop} {if {[dict exists $opts $k]} {if {$top ne ""} {::fp::fail "use only one top option"}; set top [dict get $opts $k]}}
    if {$source eq "" || $top eq ""} {::fp::fail "build_model requires one -source/-designsource and -cell/-designtop"}
    set source [::fp::need_file $source netlist]
    if {[dict exists $opts -techlib]} {
        set tech [dict get $opts -techlib]
        if {![string equal -nocase [file extension $tech] .v]} {::fp::fail "-techlib supports one Verilog cell model (.v), not a Modus techlib directory/database"}
        ::fp::configure -cell_model [::fp::need_file $tech {Verilog cell model}]
    }
    set wd [dict get $::fp::st workdir]
    if {[dict exists $opts -workdir]} {set wd [file normalize [dict get $opts -workdir]]}
    if {![file isdirectory $wd]} {::fp::fail "workdir must already exist: $wd"}
    ::fp::invalidate
    dict set ::fp::st netlist $source; dict set ::fp::st top $top; dict set ::fp::st workdir $wd
    dict set ::fp::st model 1; dict set ::fp::st mode {}
    ::fp::warn "build_model records inputs only; Fault does not construct a Modus design database or validate -cell here."
}
# A deliberately small Modus assign-file subset. Never source the file as Tcl.
proc ::fp::read_assignfile {path} {
    set path [need_file $path -assignfile]
    set f [open $path r]; try {set data [read $f]} finally {close $f}
    regsub -all -line {#.*$|//.*$} $data {} data
    set clock {}; set bypass [dict get $::fp::cfg bypassing]; set seen {}
    foreach statement [split $data {;}] {
        set statement [string trim $statement]
        if {$statement eq ""} continue
        if {![regexp -nocase {^assign\s+pin\s*=?\s*"?([A-Za-z_][A-Za-z0-9_$]*)"?\s+test_function\s*=?\s*([+-](?:ES|TI))\s*$} $statement -> pin function]} {
            fail "unsupported -assignfile statement: $statement (only +/-ES and +/-TI are mapped)"
        }
        if {$pin in $seen} {fail "duplicate assignfile pin: $pin"}
        lappend seen $pin
        set function [string toupper $function]
        if {[string range $function 1 end] eq "ES"} {
            if {$clock ne ""} {fail "multiple test clocks in -assignfile are unsupported"}
            set clock $pin
        } else {
            set value [expr {[string index $function 0] eq "+" ? 1 : 0}]
            if {$pin eq [dict get $::fp::cfg reset]} {
                if {$value != [dict get $::fp::cfg reset_active_low]} {fail "assignfile value for reset conflicts with reset polarity; define_test_signal first"}
            }
            foreach prior $bypass {
                set parts [split $prior =]
                if {[lindex $parts 0] eq $pin} {
                    set prior_value [expr {[llength $parts] == 1 ? 1 : [lindex $parts 1]}]
                    if {$prior_value ne "$value"} {fail "conflicting constant assignments for $pin"}
                }
            }
            if {"$pin=$value" ni $bypass} {lappend bypass "$pin=$value"}
        }
    }
    if {$clock eq ""} {fail "-assignfile requires one +/-ES clock assignment"}
    if {[dict get $::fp::cfg clock] ne "" && [dict get $::fp::cfg clock] ne $clock} {fail "assignfile clock conflicts with define_test_clock"}
    configure -clock $clock -bypassing $bypass
    warn "Only ES clock and constant TI pin assignments were mapped; Fault holds its clock high and does not create Modus test sequences."
}
proc build_testmode {args} {
    set opts [::fp::options $args {-workdir -testmode -assignfile}]
    ::fp::get_workdir $opts
    if {[dict get $::fp::st model] ne "1"} {::fp::fail "build_model first"}
    if {[dict exists $opts -testmode]} {
        set mode [dict get $opts -testmode]
    } else {
        set mode [dict get $::fp::st default_mode]
        if {$mode eq ""} {::fp::fail "build_testmode requires -testmode or set_option testmode NAME"}
    }
    if {$mode eq ""} {::fp::fail "empty testmode"}
    if {[dict exists $opts -assignfile]} {::fp::read_assignfile [dict get $opts -assignfile]}
    ::fp::invalidate
    dict set ::fp::st mode $mode
    ::fp::warn "Testmode name is a label only: no Modus testmode database or scan sequences are built."
}
proc build_faultmodel {args} {
    set opts [::fp::options $args {-workdir -includedynamic}]
    ::fp::get_workdir $opts
    if {[dict get $::fp::st mode] eq ""} {::fp::fail "build_testmode first"}
    if {[dict exists $opts -includedynamic] && [string tolower [dict get $opts -includedynamic]] ne "no"} {::fp::fail "dynamic/transition fault model is unsupported"}
    ::fp::need clock; ::fp::need cell_model
    set kind [dict get $::fp::cfg input_kind]; set inferred {}
    if {$kind eq ""} {
        set probe [::fp::classify [dict get $::fp::st netlist]]
        set kind [string tolower [lindex $probe 0]]; set inferred [lindex $probe 1]
        if {$kind ni {combinational sequential}} {::fp::fail "unexpected structural check: $probe"}
        ::fp::warn "Yosys structural check: $kind; this is not Modus DRC."
    }
    ::fp::invalidate
    dict set ::fp::st faultmodel 1
    dict set ::fp::st auto_kind $kind; dict set ::fp::st auto_dff $inferred
    ::fp::warn "Fault sites are generated during create_logic_tests, not at build_faultmodel; static stuck-at only."
}
proc create_logic_tests {args} {
    set opts [::fp::options $args {-workdir -testmode -experiment}]
    ::fp::get_workdir $opts; ::fp::parse_mode $opts
    if {[dict get $::fp::st faultmodel] ne "1"} {::fp::fail "build_faultmodel first"}
    set exp logic
    if {[dict exists $opts -experiment]} {set exp [dict get $opts -experiment]}
    if {![regexp {^[A-Za-z0-9_][A-Za-z0-9_.-]*$} $exp] || $exp in {. ..}} {::fp::fail "experiment must be a simple name"}
    set d [::fp::output_dir]; set net [dict get $::fp::st netlist]; set kind [dict get $::fp::st auto_kind]
    dict set ::fp::st result {}; dict set ::fp::st experiment {}
    if {$kind eq "sequential"} {
        set cutopts [::fp::cut_options]
        if {![llength $cutopts]} {
            set inferred [dict get $::fp::st auto_dff]
            if {$inferred eq ""} {::fp::fail "sequential input requires supported D/Q cell models or explicit DFF mapping"}
            set cutopts [list --dff $inferred]
            ::fp::warn "DFF types inferred from cell models: $inferred."
        }
        set cut [file join $d ${exp}.cut.v]
        if {[file exists $cut]} {file delete -- $cut}
        ::fp::invoke cut {*}[::fp::common] {*}$cutopts --output $cut $net
        ::fp::check_product $cut
        set postcut [::fp::classify $cut]
        if {[lindex $postcut 0] ne "COMBINATIONAL"} {::fp::fail "cut netlist still contains sequential logic: $postcut"}
        dict set ::fp::st cut $cut
        set net $cut
        ::fp::warn "Flip-flops were cut into pseudo-I/O. This does not produce Modus scan loading/capture sequences."
    } elseif {[dict get $::fp::cfg input_kind] ne ""} {
        ::fp::warn "Using input_kind=$kind as declared; Fault+ does not independently prove the netlist is combinational/cut."
    }
    set json [file join $d ${exp}.json]; set cov [file join $d ${exp}.coverage.yml]
    foreach p [list $json $cov] {if {[file exists $p]} {file delete -- $p}}
    ::fp::invoke atpg --cell-model [::fp::need cell_model] {*}[::fp::common] {*}[dict get $::fp::cfg atpg_options] --output-coverage-metadata $cov --output $json $net
    ::fp::check_product $json; ::fp::check_product $cov
    dict set ::fp::st result [dict create json $json coverage $cov]; dict set ::fp::st experiment $exp
    ::fp::warn "Results are Fault JSON and stuck-at coverage, not a Modus experiment database or tester-ready scan vectors."
    return $json
}
proc report_faults {args} {
    set opts [::fp::options $args {-workdir -testmode -experiment}]
    ::fp::get_workdir $opts; ::fp::parse_mode $opts
    set result [dict get $::fp::st result]
    if {$result eq ""} {::fp::fail "no successful Fault ATPG result"}
    if {[dict exists $opts -experiment] && [dict get $opts -experiment] ne [dict get $::fp::st experiment]} {::fp::fail "unknown experiment"}
    set p [dict get $result coverage]; ::fp::check_product $p
    set f [open $p r]; try {set data [read $f]} finally {close $f}
    puts "Fault coverage metadata (not Modus fault classes):\n$data"
    return $p
}
proc write_vectors {args} {
    set opts [::fp::options $args {-workdir -testmode -inexperiment -language -outputfilename}]
    ::fp::get_workdir $opts; ::fp::parse_mode $opts
    if {![dict exists $opts -language] || [string tolower [dict get $opts -language]] ne "verilog"} {::fp::fail "write_vectors cannot generate STIL/WGL/TDL or Modus scan vectors; only scalar combinational Verilog replay is supported"}
    if {![dict exists $opts -outputfilename]} {::fp::fail "write_vectors -language verilog requires -outputfilename"}
    set result [dict get $::fp::st result]
    if {$result eq ""} {::fp::fail "create_logic_tests first"}
    if {[dict exists $opts -inexperiment] && [dict get $opts -inexperiment] ne [dict get $::fp::st experiment]} {::fp::fail "unknown experiment"}
    set out [dict get $opts -outputfilename]
    set cmd [list python3 [file join $::fp::root src design_probe.py] replay \
        --netlist [dict get $::fp::st netlist] --models [::fp::need cell_model] --top [dict get $::fp::st top] \
        --json [dict get $result json] --output $out --clock [dict get $::fp::cfg clock] \
        --reset [dict get $::fp::cfg reset] --reset-active-low [dict get $::fp::cfg reset_active_low]]
    foreach pin [dict get $::fp::cfg bypassing] {lappend cmd --bypass $pin}
    if {[catch {exec -- {*}$cmd 2>@1} message]} {::fp::fail "write_vectors: $message"}
    ::fp::check_product $out
    ::fp::warn "Wrote $message combinational functional replay vectors to $out; not Modus scan/timing/tester data."
    return $out
}
proc set_db {args} {
    if {[llength $args] != 2 || [lindex $args 0] ne "workdir"} {::fp::fail "set_db supports only: set_db workdir directory"}
    set wd [file normalize [lindex $args 1]]
    if {![file isdirectory $wd]} {::fp::fail "workdir must already exist: $wd"}
    ::fp::invalidate
    dict set ::fp::st workdir $wd
    ::fp::warn "workdir sets the Fault+ output directory, not a Modus database."
}
proc set_option {args} {
    if {[llength $args] != 2 || [lindex $args 0] ne "testmode" || [lindex $args 1] eq ""} {::fp::fail "set_option supports only: set_option testmode NAME"}
    dict set ::fp::st default_mode [lindex $args 1]
    ::fp::warn "Default testmode is a Fault+ label only."
}
proc set_context {args} {
    set opts [::fp::options $args {-testmode}]
    if {![dict exists $opts -testmode]} {::fp::fail "set_context supports only -testmode"}
    ::fp::parse_mode $opts
    ::fp::warn "Testmode is a Fault+ label; no Modus context database exists."
}
foreach {name reason} {
    verify_test_structures {Fault+ does not implement Modus scan DRC or test-mode verification}
    report_test_structures {Fault+ does not construct a Modus test-structure database}
    create_scanchain_tests {Fault does not generate Modus scan-chain integrity test experiments}
    commit_tests {Fault has no Modus experiment commit or master fault database}
    syn_opt {incremental Genus optimization is not mapped to Fault}
    check_dft_rules {Fault+ does not implement Genus DFT design-rule checks}
    read_sdc {Fault synth does not apply Genus timing constraints}
    report_timing {Fault+ does not perform static timing analysis}
    report_area {Genus area report is not mapped to Fault+}
    report_power {Fault+ does not perform power analysis}
} {
    proc ::$name {args} [format {::fp::fail %s} [list "$name: $reason"]]
}
proc ::fp::export {args} {
    variable st
    set opts [options $args {-format -output}]
    foreach k {-format -output} {if {![dict exists $opts $k]} {fail "usage: faultplus export -format {json|coverage} -output file"}}
    set fmt [dict get $opts -format]
    if {$fmt ni {json coverage}} {fail "only Fault JSON and coverage YAML are available"}
    if {[dict get $st result] eq ""} {fail "no successful Fault ATPG result"}
    set from [dict get $st result $fmt]; set to [dict get $opts -output]
    check_product $from
    if {[file normalize $from] ne [file normalize $to]} {file copy -force -- $from $to}
    warn "Exported Fault's native $fmt; it is not Modus/STIL/WGL/Verilog scan data."
    return $to
}
proc ::fp::status {args} {
    variable cfg; variable st; variable backend
    if {[llength $args]} {fail "usage: faultplus status"}
    puts "Fault backend: $backend\nConfiguration: $cfg\nState: $st"
}
proc ::fp::help {args} {
    if {[llength $args] && [lindex $args 0] eq "configure"} {
        puts "faultplus configure -clock NAME -cell_model cells.v -input_kind combinational|cut|sequential\n  Optional: -reset NAME -reset_active_low 0|1 -bypassing {PIN=0 PIN2=1}\n  -dff DFF_NAME -scl_config file.yml -atpg_options {Fault-option value ...}\nSee README.md for limitations and examples."
        return
    }
    if {[llength $args]} {fail "usage: faultplus help ?configure?"}
    puts {Fault+ 0.1 - Tcl interface using Fault
Genus subset: read_libs, read_hdl, elaborate, syn_generic, syn_map, write_hdl,
  define_test_clock, define_test_signal, define_shift_enable, define_test_mode, define_scan_chain,
  connect_scan_chains.
Modus subset: build_model, build_testmode, build_faultmodel, create_logic_tests,
  report_faults, write_vectors (scalar combinational replay only).
These are partial mappings; see warnings and README.
Fault+ extensions: faultplus configure|run|status|export|help
Any other command/option is unsupported. Native Tcl commands are available.}
}
proc ::fp::main {args} {
    variable version
    if {[llength $args] && [lindex $args 0] in {-h --help}} {help; puts "Usage: faultplus ?-f script.tcl?"; return}
    if {[llength $args] && [lindex $args 0] eq "--version"} {puts "Fault+ $version"; return}
    if {[llength $args]} {
        if {[llength $args] != 2 || [lindex $args 0] ne "-f"} {puts stderr "Usage: faultplus ?-f script.tcl?"; exit 2}
        set script [lindex $args 1]
        if {[catch {uplevel #0 [list source $script]} msg opts]} {puts stderr "ERROR: $msg\n[dict get $opts -errorinfo]"; exit 1}
        return
    }
    puts "Fault+ $version: Cadence-style Tcl interface using Fault. Type 'faultplus help'."
    set buf {}
    while {1} {
        puts -nonewline [expr {$buf eq "" ? "fault+> " : "    ...> "}]; flush stdout
        if {[gets stdin line] < 0} break
        append buf $line "\n"
        if {![info complete $buf]} continue
        if {[catch {uplevel #0 $buf} result]} {puts stderr "ERROR: $result"} elseif {$result ne ""} {puts $result}
        set buf {}
    }
    if {$buf ne ""} {puts stderr "ERROR: incomplete Tcl command at EOF"; exit 1}
}
