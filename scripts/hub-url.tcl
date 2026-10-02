#!/usr/bin/env tclsh
#
# hub-url.tcl — print where the hub is right now.
#
#   tclsh scripts/hub-url.tcl ?--name NAME? ?--registry-url URL?
#
# The hub does not live at a fixed address. It takes a free port each time it
# starts and registers itself with busybody; this asks busybody where it is
# and prints http://HOST:PORT. Typical use:
#
#   ANTHROPIC_BASE_URL=$(tclsh scripts/hub-url.tcl) claude
#
# --name defaults to "agento". The registry is --registry-url, else
# $BUSYBODY_URL, else http://localhost:5150.
#
# Exits 1, printing nothing on stdout, when the hub is not registered or
# busybody cannot be reached.

package require Tcl 8.6
package require http
package require json

# The URL of the app registered as `name` in a busybody /api/apps response,
# or the empty string if it is not there.
proc url_for {apps_json name} {
    set directory [json::json2dict $apps_json]
    if {![dict exists $directory apps]} { return "" }
    foreach app [dict get $directory apps] {
        if {[dict exists $app name] && [dict get $app name] eq $name
            && [dict exists $app host] && [dict exists $app port]} {
            return "http://[dict get $app host]:[dict get $app port]"
        }
    }
    return ""
}

proc fail {message} {
    puts stderr "hub-url: $message"
    exit 1
}

proc main {argv} {
    set name agento
    set registry http://localhost:5150
    if {[info exists ::env(BUSYBODY_URL)]} { set registry $::env(BUSYBODY_URL) }

    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        switch -- $arg {
            --name         { set name [lindex $argv [incr i]] }
            --registry-url { set registry [lindex $argv [incr i]] }
            default        { fail "unknown option $arg" }
        }
    }

    set endpoint "[string trimright $registry /]/api/apps"
    if {[catch {http::geturl $endpoint -timeout 3000} token]} {
        fail "cannot reach busybody at $registry: $token"
    }
    set status [http::status $token]
    set code [http::ncode $token]
    set body [http::data $token]
    http::cleanup $token
    if {$status ne "ok" || $code != 200} {
        fail "busybody at $registry did not answer ($status, HTTP $code)"
    }

    if {[catch {url_for $body $name} url]} {
        fail "busybody at $registry answered with something that is not its directory"
    }
    if {$url eq ""} {
        fail "\"$name\" is not registered with busybody at $registry; is the hub running?"
    }
    puts $url
}

if {[info exists ::argv0] &&
    [file normalize $::argv0] eq [file normalize [info script]]} {
    main $::argv
}
