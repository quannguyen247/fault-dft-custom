// Copyright (C) 2019 The American University in Cairo
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Defile
import Foundation

// Modified in this fork: preserve paths when passing commands to Yosys.
enum Synthesis {
    static func quoted(_ value: String) -> String {
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func run(_ script: String, silent: Bool = false) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [yosysExecutable, "-Q", "-T", "-p", script]
        if silent { process.standardOutput = FileHandle.nullDevice }
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Stderr.print("Could not run Yosys: \(error)")
            return EX_UNAVAILABLE
        }
    }

    static func script(
        for module: String,
        in files: [String],
        cutting: Bool = false,
        checkHierarchy: Bool = true,
        liberty libertyFile: String,
        blackboxing blackboxedModules: [String] = [],
        output: String,
        optimize: Bool = true
    ) -> String {
        let opt = optimize ? "opt" : ""
        return """
            # read liberty
            read_liberty -lib -ignore_miss_dir -setattr blackbox \(quoted(libertyFile))

            # read black boxes
            \(blackboxedModules.isEmpty ? "" : "read_verilog -sv -lib " + blackboxedModules.map { quoted($0) }.joined(separator: " "))

            # read design
            read_verilog -sv \(files.map { quoted($0) }.joined(separator: " "))

            # check design hierarchy
            hierarchy \(checkHierarchy ? "-check" : "") -top \(module)
            flatten;

            # translate processes (always blocks)
            proc; \(opt)

            # detect and optimize FSM encodings
            fsm; \(opt)

            # implement memories (arrays)
            memory; \(opt)

            # convert to gate logic
            techmap; \(opt)

            # flatten
            flatten; \(opt)

            # mapping flip-flops to mycells.lib
            dfflibmap -liberty \(quoted(libertyFile))

            # expose dff
            \(cutting ? "expose -cut -evert-dff; \(opt)" : "")

            # mapping logic to mycells.lib
            abc -liberty \(quoted(libertyFile))
            splitnets

            # print gate count
            stat

            # cleanup
            opt_clean -purge

            # names
            # autoname

            write_verilog -noexpr -nohex -nodec -defparam \(quoted(output + "+attrs"))
            write_verilog -noexpr -noattr -noexpr -nohex -nodec -defparam \(quoted(output))
            # write_blif -gates -unbuf DFFSR D Q \(quoted(output)).blif
            """
    }
}
