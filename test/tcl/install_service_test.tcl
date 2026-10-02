#!/usr/bin/env tclsh
#
# Tests for scripts/install-service.tcl. The release build is replaced by a
# stub (AGENTO_INSTALL_BUILD_CMD) so these run in a second; everything else
# is the real script, run as a subprocess against a temporary prefix.
#
# Run: tclsh test/tcl/install_service_test.tcl

package require tcltest 2.5
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
set ::script [file join $here .. .. scripts install-service.tcl]
set ::env(AGENTO_INSTALL_BUILD_CMD) "true"

# Everything is written under one scratch root outside the repository, removed
# at the end.
set ::scratch [file join /tmp agento_install_test_[pid]]
file mkdir $::scratch

proc fresh_prefix {} {
    set dir [file join $::scratch prefix_[clock clicks]]
    file mkdir $dir
    return $dir
}

# Run the installer; returns {exit_status output}.
proc install {prefix args} {
    set status [catch {exec tclsh $::script --prefix $prefix {*}$args 2>@1} output]
    return [list $status $output]
}

proc slurp {path} {
    set fh [open $path r]
    set data [read $fh]
    close $fh
    return $data
}

proc mode {path} { return [file attributes $path -permissions] }

proc paths {prefix} {
    return [dict create \
        edn  [file join $prefix .config agento hub.edn] \
        env  [file join $prefix .config agento env] \
        unit [file join $prefix .config systemd user agento.service] \
        rule [file join $prefix .config agento rules hub-routing.rule] \
        data [file join $prefix .local share agento]]
}

test writes-three-files {a run against an empty prefix writes the config, the env file and the unit} -body {
    set prefix [fresh_prefix]
    lassign [install $prefix --default-host big.local] status output
    set p [paths $prefix]
    list $status [file exists [dict get $p edn]] [file exists [dict get $p env]] \
         [file exists [dict get $p unit]] [file isdirectory [dict get $p data]]
} -result {0 1 1 1 1}

test secrets-are-owner-only {the config and the env file are mode 0600} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local
    set p [paths $prefix]
    list [mode [dict get $p edn]] [mode [dict get $p env]]
} -result {00600 00600}

test unit-has-no-template-markers {the unit file names the prefix's paths and no marker survives} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local
    set unit [slurp [dict get [paths $prefix] unit]]
    list [regexp {@[A-Z_]+@} $unit] \
         [expr {[string first "EnvironmentFile=$prefix/.config/agento/env" $unit] >= 0}] \
         [expr {[string first "ExecStart=$prefix/.local/lib/agento/bin/agento start" $unit] >= 0}] \
         [expr {[string first "WorkingDirectory=$prefix/.local/share/agento" $unit] >= 0}]
} -result {0 1 1 1}

test no-port-by-default {with no --port the env file pins no port, so the hub takes a free one} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local
    set envtext [slurp [dict get [paths $prefix] env]]
    list [regexp -line {^PORT=} $envtext] [regexp -line {^AGENTO_BUSYBODY_NAME=agento$} $envtext]
} -result {0 1}

test name-option {--name sets both the busybody name and the node name} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local --name hub-two
    set envtext [slurp [dict get [paths $prefix] env]]
    list [regexp -line {^AGENTO_BUSYBODY_NAME=hub-two$} $envtext] \
         [regexp -line {^RELEASE_NODE=hub-two@127\.0\.0\.1$} $envtext]
} -result {1 1}

test env-file-binds-every-interface {the env file binds every interface and points at this prefix's config} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local --port 4999
    set envtext [slurp [dict get [paths $prefix] env]]
    list [regexp -line {^AGENTO_BIND=0\.0\.0\.0$} $envtext] \
         [regexp -line {^PORT=4999$} $envtext] \
         [regexp -line {^PHX_SERVER=true$} $envtext] \
         [regexp -line {^SECRET_KEY_BASE=\S{64,}$} $envtext] \
         [regexp -line "^AGENTO_HUB_CONFIG=$prefix/.config/agento/hub.edn\$" $envtext]
} -result {1 1 1 1 1}

test env-file-keeps-distribution-on-loopback {Erlang distribution and epmd are bound to loopback too} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local
    set envtext [slurp [dict get [paths $prefix] env]]
    list [regexp -line {^ERL_EPMD_ADDRESS=127\.0\.0\.1$} $envtext] \
         [regexp -line {^ERL_AFLAGS="-kernel inet_dist_use_interface \{127,0,0,1\}"$} $envtext] \
         [regexp -line {^RELEASE_DISTRIBUTION=name$} $envtext] \
         [regexp -line {^RELEASE_NODE=agento@127\.0\.0\.1$} $envtext]
} -result {1 1 1 1}

test config-names-host-and-client {the config has one client with a long token and the default host} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local
    set edn [slurp [dict get [paths $prefix] edn]]
    list [regexp {:name "claude-code" :token "[0-9a-f]{64}"} $edn] \
         [regexp {:default-host "big.local"} $edn]
} -result {1 1}

test prints-the-token-and-next-steps {the output tells the operator what to run and what to set} -body {
    set prefix [fresh_prefix]
    lassign [install $prefix --default-host big.local] status output
    regexp {:token "([0-9a-f]{64})"} [slurp [dict get [paths $prefix] edn]] -> token
    list [expr {[string first "systemctl --user enable --now agento" $output] >= 0}] \
         [expr {[string first "ANTHROPIC_BASE_URL=\$(tclsh " $output] >= 0 && [string first "hub-url.tcl" $output] >= 0}] \
         [expr {[string first "ANTHROPIC_AUTH_TOKEN=$token" $output] >= 0}]
} -result {1 1 1}

test second-run-keeps-secrets {running again leaves the config and env file byte-identical} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local
    set p [paths $prefix]
    set before [list [slurp [dict get $p edn]] [slurp [dict get $p env]]]
    lassign [install $prefix --default-host other.local] status output
    set after [list [slurp [dict get $p edn]] [slurp [dict get $p env]]]
    list $status [expr {$before eq $after}]
} -result {0 1}

test dry-run-writes-nothing {--dry-run reports and writes nothing} -body {
    set prefix [fresh_prefix]
    lassign [install $prefix --default-host big.local --dry-run] status output
    list $status [glob -nocomplain -directory $prefix -types {f d} * .config .local] \
         [expr {[string first "hub.edn" $output] >= 0}]
} -result {0 {} 1}

test ships-the-routing-rule {a fresh install writes the routing rule file, and keeps an edited one} -body {
    set prefix [fresh_prefix]
    install $prefix --default-host big.local
    set rule [dict get [paths $prefix] rule]
    set shipped [slurp [file join $::here .. .. priv rules hub-routing.rule]]
    set first [expr {[slurp $rule] eq $shipped}]
    set fh [open $rule w]; puts $fh "rule mine { when HUB_ROUTE { log 1 } }"; close $fh
    lassign [install $prefix --default-host big.local] status output
    list $first [expr {[string first "keeping $rule" $output] >= 0}] [string trim [slurp $rule]]
} -result {1 1 {rule mine { when HUB_ROUTE { log 1 } }}}

test tokens-differ {two fresh installs generate different tokens} -body {
    set a [fresh_prefix]
    set b [fresh_prefix]
    install $a --default-host big.local
    install $b --default-host big.local
    regexp {:token "([0-9a-f]+)"} [slurp [dict get [paths $a] edn]] -> ta
    regexp {:token "([0-9a-f]+)"} [slurp [dict get [paths $b] edn]] -> tb
    expr {$ta ne $tb}
} -result 1

test without-default-host-warns {omitting --default-host still installs, and says requests will not route} -body {
    set prefix [fresh_prefix]
    lassign [install $prefix] status output
    set edn [slurp [dict get [paths $prefix] edn]]
    list $status [regexp {:default-host} $edn] [expr {[string first "default-host" $output] >= 0}]
} -result {0 0 1}

test failed-build-stops {a build that fails stops the install before anything is written} -body {
    set prefix [fresh_prefix]
    set ::env(AGENTO_INSTALL_BUILD_CMD) "false"
    lassign [install $prefix --default-host big.local] status output
    set ::env(AGENTO_INSTALL_BUILD_CMD) "true"
    list [expr {$status != 0}] [file exists [dict get [paths $prefix] edn]]
} -result {1 0}

test bad-arguments-refused {an unknown option or a bad port is refused} -body {
    set prefix [fresh_prefix]
    lassign [install $prefix --bogus] s1 o1
    lassign [install $prefix --port notaport] s2 o2
    list [expr {$s1 != 0}] [expr {$s2 != 0}] [file exists [dict get [paths $prefix] edn]]
} -result {1 1 0}

file delete -force $::scratch
cleanupTests
