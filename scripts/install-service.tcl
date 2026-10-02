#!/usr/bin/env tclsh
#
# install-service.tcl — build agento as a release and lay down what a systemd
# user unit needs to run it as the private LLM hub.
#
#   tclsh scripts/install-service.tcl ?--prefix DIR? ?--default-host NAME?
#                                     ?--name NAME? ?--port N? ?--dry-run?
#
# The hub has no fixed address. It takes a free port each time it starts and
# registers with busybody under NAME (default "agento"); clients ask busybody
# where it is (scripts/hub-url.tcl). --port pins a port for the rare case
# that something cannot look it up.
#
# Under PREFIX (default: your home directory) it writes:
#
#   .local/lib/agento/                     the release
#   .local/share/agento/                   data: turn log, durable event log
#   .config/agento/hub.edn                 clients and routing      (mode 0600)
#   .config/agento/env                     the unit's environment   (mode 0600)
#   .config/systemd/user/agento.service    the unit
#
# hub.edn and env hold secrets and are written only if absent: running this
# again rebuilds the release and the unit and leaves both alone.
#
# It does not call systemctl. It prints the commands to enable the unit and
# how to point Claude Code at the hub.
#
# AGENTO_INSTALL_BUILD_CMD replaces the release build with another command;
# the tests use it so they do not build a release.

package require Tcl 8.6

proc fail {message} {
    puts stderr "install-service: $message"
    exit 1
}

proc parse_args {argv} {
    set opts [dict create prefix $::env(HOME) default_host "" name agento port "" dry_run 0]
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set arg [lindex $argv $i]
        switch -- $arg {
            --prefix       { dict set opts prefix [file normalize [lindex $argv [incr i]]] }
            --default-host { dict set opts default_host [lindex $argv [incr i]] }
            --name         { dict set opts name [lindex $argv [incr i]] }
            --port         { dict set opts port [lindex $argv [incr i]] }
            --dry-run      { dict set opts dry_run 1 }
            default        { fail "unknown option $arg" }
        }
    }
    set port [dict get $opts port]
    if {$port ne "" && (![string is integer -strict $port] || $port < 1 || $port > 65535)} {
        fail "--port must be a number between 1 and 65535, got \"$port\""
    }
    if {![regexp {^[A-Za-z0-9_-]+$} [dict get $opts name]]} {
        fail "--name must be letters, digits, - and _"
    }
    if {![regexp {^[A-Za-z0-9._-]*$} [dict get $opts default_host]]} {
        fail "--default-host must be a hostname"
    }
    return $opts
}

proc random_bytes {n} {
    set fh [open /dev/urandom rb]
    set bytes [read $fh $n]
    close $fh
    return $bytes
}

# Create a file that only its owner can read, failing if it already exists,
# so a secret is never written into a file someone else made readable.
proc write_secret {path content} {
    set fh [open $path {WRONLY CREAT EXCL} 0600]
    puts -nonewline $fh $content
    close $fh
}

proc write_file {path content} {
    set fh [open $path w]
    puts -nonewline $fh $content
    close $fh
}

proc hub_edn {token default_host data_dir} {
    set edn "; agento hub configuration. Holds tokens: keep it mode 0600.\n"
    append edn "; See priv/hub.example.edn in the agento repository for every key.\n"
    append edn "{:clients \[{:name \"claude-code\" :token \"$token\"}\]\n"
    if {$default_host ne ""} {
        append edn " :default-host \"$default_host\"\n"
    }
    append edn " :data-dir \"$data_dir\"}\n"
    return $edn
}

proc env_file {secret name port hub_edn} {
    set env "SECRET_KEY_BASE=$secret\n"
    append env "PHX_SERVER=true\n"
    append env "PHX_HOST=localhost\n"
    # No PORT unless one was asked for: the hub takes a free port and tells
    # busybody, under this name, where it ended up.
    if {$port ne ""} {
        append env "PORT=$port\n"
    }
    append env "AGENTO_BUSYBODY_NAME=$name\n"
    # Every interface, plain HTTP: the hub is for this network, not just this
    # machine. Change to 127.0.0.1 to keep it local.
    append env "AGENTO_BIND=0.0.0.0\n"
    # A release also listens for Erlang distribution (bin/agento rpc, stop).
    # That, and the port mapper, stay on loopback whatever the HTTP listener
    # binds: the cookie that guards them is all that stands between a peer
    # and running code here. The node is named
    # at 127.0.0.1 so that rpc and stop look for it where it listens; a short
    # name would resolve to the machine's LAN address.
    append env "ERL_EPMD_ADDRESS=127.0.0.1\n"
    append env "ERL_AFLAGS=\"-kernel inet_dist_use_interface {127,0,0,1}\"\n"
    append env "RELEASE_DISTRIBUTION=name\n"
    append env "RELEASE_NODE=$name@127.0.0.1\n"
    append env "AGENTO_HUB_CONFIG=$hub_edn\n"
    return $env
}

proc build {repo release_dir} {
    if {[info exists ::env(AGENTO_INSTALL_BUILD_CMD)]} {
        set commands [list $::env(AGENTO_INSTALL_BUILD_CMD)]
    } else {
        foreach tool {mix tclsh} {
            if {[auto_execok $tool] eq ""} { fail "$tool is not on PATH" }
        }
        set commands [list \
            "mix deps.get --only prod" \
            "mix assets.deploy" \
            "mix release --path [list $release_dir] --overwrite" \
            "mix phx.digest.clean --all"]
    }
    # The last step removes the digested copies assets.deploy leaves in
    # priv/static; the release already has its own.
    set ::env(MIX_ENV) prod
    foreach command $commands {
        puts "  running: $command"
        if {[catch {exec sh -c "cd [list $repo] && $command" >@stdout 2>@stderr} err]} {
            fail "build step failed: $command"
        }
    }
}

proc main {argv} {
    set opts [parse_args $argv]
    set prefix [dict get $opts prefix]
    set port [dict get $opts port]
    set repo [file dirname [file dirname [file normalize [info script]]]]

    set config_dir  [file join $prefix .config agento]
    set unit_dir    [file join $prefix .config systemd user]
    set release_dir [file join $prefix .local lib agento]
    set data_dir    [file join $prefix .local share agento]
    set hub_edn     [file join $config_dir hub.edn]
    set env_path    [file join $config_dir env]
    set unit_path   [file join $unit_dir agento.service]

    if {[dict get $opts dry_run]} {
        puts "dry run; nothing will be written. Would:"
        puts "  build the release into $release_dir"
        puts "  create $data_dir"
        foreach path [list $hub_edn $env_path] {
            puts "  [expr {[file exists $path] ? "keep" : "write"}] $path"
        }
        puts "  write $unit_path"
        return
    }

    puts "building the release"
    build $repo $release_dir

    file mkdir $config_dir $unit_dir $data_dir
    file attributes $config_dir -permissions 0700
    file attributes $data_dir -permissions 0700

    if {[file exists $hub_edn]} {
        puts "keeping $hub_edn"
    } else {
        set token [binary encode hex [random_bytes 32]]
        write_secret $hub_edn [hub_edn $token [dict get $opts default_host] $data_dir]
        puts "wrote $hub_edn"
    }

    if {[file exists $env_path]} {
        puts "keeping $env_path"
    } else {
        set secret [string map {"\n" ""} [binary encode base64 [random_bytes 48]]]
        write_secret $env_path [env_file $secret [dict get $opts name] $port $hub_edn]
        puts "wrote $env_path"
    }

    set fh [open [file join $repo rel agento.service.in] r]
    set unit [read $fh]
    close $fh
    set unit [string map [list @CONFIG_DIR@ $config_dir @DATA_DIR@ $data_dir @RELEASE_DIR@ $release_dir] $unit]
    write_file $unit_path $unit
    puts "wrote $unit_path"

    # Report from what is on disk, so a kept config reports its real token.
    set fh [open $hub_edn r]
    set edn [read $fh]
    close $fh
    set token "<the :token of the client in $hub_edn>"
    regexp {:token "([^"]+)"} $edn -> token
    set fh [open $env_path r]
    set kept_env [read $fh]
    close $fh
    set kept_name agento
    regexp -line {^AGENTO_BUSYBODY_NAME=(.+)$} $kept_env -> kept_name
    set resolver "tclsh [file join $repo scripts hub-url.tcl]"
    if {$kept_name ne "agento"} { append resolver " --name $kept_name" }

    puts ""
    puts "To run the hub now and at every login:"
    puts "  systemctl --user daemon-reload"
    puts "  systemctl --user enable --now agento"
    puts "  systemctl --user status agento"
    puts ""
    puts "The hub takes a free port each start and registers with busybody as"
    puts "\"$kept_name\". To point Claude Code at wherever it is now:"
    puts "  export ANTHROPIC_BASE_URL=\$($resolver)"
    puts "  export ANTHROPIC_AUTH_TOKEN=$token"
    if {![regexp {:default-host} $edn]} {
        puts ""
        puts "No :default-host is set in $hub_edn. Requests for a model no host"
        puts "serves - every request Claude Code makes - will get a 404 until you add one,"
        puts "for example  :default-host \"skynet001.local\""
    }
}

if {[info exists ::argv0] &&
    [file normalize $::argv0] eq [file normalize [info script]]} {
    main $::argv
}
