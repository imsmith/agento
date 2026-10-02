#!/usr/bin/env tclsh
#
# Tests for scripts/hub-url.tcl, which asks busybody where the hub is.
#
# test/fixtures/busybody_apps.json is a real `GET /api/apps` response from a
# running busybody. Do not edit it by hand.
#
# Run: tclsh test/tcl/hub_url_test.tcl

package require tcltest 2.5
namespace import ::tcltest::*

set here [file dirname [file normalize [info script]]]
set ::script [file join $here .. .. scripts hub-url.tcl]
set ::fixture [file join $here .. fixtures busybody_apps.json]
source $::script

proc slurp {path} {
    set fh [open $path r]
    set data [read $fh]
    close $fh
    return $data
}

set ::apps [slurp $::fixture]

# What the fixture says about an app, read with a different tool than the
# script uses.
proc expected_url {name} {
    set pattern "\"name\":\"$name\",\"pid\":\"\[0-9\]+\",\"port\":(\[0-9\]+),\"host\":\"(\[^\"\]+)\""
    regexp $pattern $::apps -> port host
    return "http://$host:$port"
}

# A registry that answers every request with the given body, on a free port.
proc fake_registry {body {status "200 OK"}} {
    set server [makeFile [format {
        proc serve {chan addr port} {
            fconfigure $chan -translation binary
            while {[gets $chan line] > 0 && [string trim $line] ne ""} {}
            set body [binary decode hex %s]
            puts -nonewline $chan "HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: [string length $body]\r\nConnection: close\r\n\r\n$body"
            close $chan
        }
        set s [socket -server serve -myaddr 127.0.0.1 0]
        puts [lindex [fconfigure $s -sockname] 2]
        flush stdout
        vwait forever
    } [binary encode hex $body] $status] registry_[clock clicks].tcl]
    set pipe [open "|tclsh $server" r]
    gets $pipe port
    return [list $pipe $port]
}

proc stop_registry {registry} {
    catch {exec kill [pid [lindex $registry 0]]}
    catch {close [lindex $registry 0]}
}

# Run the script; returns {exit_status stdout_and_stderr}.
proc run {args} {
    set status [catch {exec tclsh $::script {*}$args 2>@1} output]
    return [list $status $output]
}

test finds-a-registered-app {the URL is built from the app's registered host and port} -body {
    list [url_for $::apps agento] [url_for $::apps cns_lan]
} -result [list [expected_url agento] [expected_url cns_lan]]

test unknown-app-is-empty {an app that is not registered has no URL} -body {
    url_for $::apps no-such-app
} -result {}

test name-must-match-whole {a name that is only part of a registered name does not match} -body {
    url_for $::apps agent
} -result {}

test empty-directory {an empty directory has no URL for anything} -body {
    url_for {{"apps":[]}} agento
} -result {}

test prints-the-url {against a registry, the script prints the hub's URL and exits 0} -body {
    set registry [fake_registry $::apps]
    set result [run --registry-url http://127.0.0.1:[lindex $registry 1]]
    stop_registry $registry
    set result
} -result [list 0 [expected_url agento]]

test other-name {--name looks up a different app} -body {
    set registry [fake_registry $::apps]
    set result [run --name cns_lan --registry-url http://127.0.0.1:[lindex $registry 1]]
    stop_registry $registry
    set result
} -result [list 0 [expected_url cns_lan]]

test registry-from-environment {BUSYBODY_URL names the registry when no option does} -body {
    set registry [fake_registry $::apps]
    set ::env(BUSYBODY_URL) http://127.0.0.1:[lindex $registry 1]
    set result [run]
    unset ::env(BUSYBODY_URL)
    stop_registry $registry
    set result
} -result [list 0 [expected_url agento]]

test not-registered-fails {an app that is not registered exits non-zero and prints no URL} -body {
    set registry [fake_registry $::apps]
    lassign [run --name no-such-app --registry-url http://127.0.0.1:[lindex $registry 1]] status output
    stop_registry $registry
    list [expr {$status != 0}] [regexp -line {^http://} $output] [regexp {no-such-app} $output]
} -result {1 0 1}

test registry-down-fails {an unreachable registry exits non-zero and says so} -body {
    lassign [run --registry-url http://127.0.0.1:1] status output
    list [expr {$status != 0}] [regexp -nocase {busybody} $output]
} -result {1 1}

test registry-error-fails {a registry answering with an error exits non-zero} -body {
    set registry [fake_registry {{"error":"boom"}} "500 Internal Server Error"]
    lassign [run --registry-url http://127.0.0.1:[lindex $registry 1]] status output
    stop_registry $registry
    expr {$status != 0}
} -result 1

test garbage-fails {a registry answering with something that is not a directory exits non-zero} -body {
    set registry [fake_registry {<html>not json</html>}]
    lassign [run --registry-url http://127.0.0.1:[lindex $registry 1]] status output
    stop_registry $registry
    list [expr {$status != 0}] [regexp -line {^http://} $output]
} -result {1 0}

cleanupTests
