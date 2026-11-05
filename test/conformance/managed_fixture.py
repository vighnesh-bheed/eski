import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tarfile

READINESS = r'''
proc wait_server_started {config_file stdout pid} {
    set early 0
    if {[uplevel 1 {info exists wait_ready}]} {set early [expr {![uplevel 1 {set wait_ready}]}]}
    if {[uplevel 1 {info exists code}] && [uplevel 1 {set code}] eq "undefined"} {set early 1}
    set descriptor [open $config_file r]
    set port 0
    set unixsocket ""
    set bound 1
    set addresses {127.0.0.1 ::1}
    while {[gets $descriptor line] >= 0} {
        if {[catch {llength $line}]} {continue}
        if {[lindex $line 0] eq "port"} {set port [lindex $line 1]}
        if {[lindex $line 0] eq "unixsocket"} {set unixsocket [lindex $line 1]}
        if {[lindex $line 0] eq "bind" && [string trim [join [lrange $line 1 end] " "]] eq ""} {set bound 0}
    }
    close $descriptor
    for {set attempt 0} {$attempt < 300} {incr attempt} {
        if {[catch {exec kill -0 $pid}]} {
            if {$early} {return 0}
            start_server_error $config_file "Managed server exited before readiness: [exec cat $stdout]"
            return 0
        }
        foreach address $addresses {
            if {$port > 0 && ![catch {socket $address $port} channel]} {
                fconfigure $channel -blocking 0 -translation binary -buffering none
                puts -nonewline $channel "PING\r\n"
                set reply ""
                for {set retry 0} {$retry < 20} {incr retry} {
                    append reply [read $channel]
                    if {[string first "\r\n" $reply] >= 0} {break}
                    after 5
                }
                close $channel
                if {[string first "+PONG\r\n" $reply] == 0 || [string first "-NOAUTH " $reply] == 0 || ($early && ([string first "-LOADING " $reply] == 0 || [string first "-DENIED " $reply] == 0))} {return 0}
            }
        }
        if {($port == 0 || !$bound) && $unixsocket ne "" && [file exists $unixsocket] && [file type $unixsocket] eq "socket"} {return 0}
        after 100
    }
    start_server_error $config_file "Managed server did not answer on configured TCP port $port: [exec cat $stdout]"
    return 0
}
'''


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(archive, destination, prefix, server, expected, client, aof_checker=None):
    archive = Path(archive)
    destination = Path(destination)
    if digest(archive.read_bytes()) != expected:
        raise ValueError('pinned upstream archive checksum mismatch')
    destination.mkdir(parents=True, exist_ok=False)
    originals = {}
    with tarfile.open(archive, 'r:gz') as source:
        for entry in source:
            relative = Path(entry.name).relative_to(prefix)
            if not relative.parts or relative.parts[0] != 'tests' or not entry.isfile():
                continue
            if '..' in relative.parts:
                raise ValueError('unsafe archive path')
            data = source.extractfile(entry).read()
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(entry.mode & 0o777)
            originals[str(relative)] = digest(data)
    support = destination / 'tests/support/server.tcl'
    data = support.read_text()
    for option in ('tls-cluster', 'tls-replication'):
        topology = '        dict set config "' + option + '" "yes"\n'
        if data.count(topology) != 1:
            raise ValueError('unexpected unconditional distributed TLS fixture option')
        data = data.replace(topology, '', 1)
    declaration = 'proc wait_server_started {config_file stdout pid} {'
    if data.count(declaration) != 1:
        raise ValueError('unexpected upstream readiness procedure')
    data = data.replace(declaration, 'proc upstream_wait_server_started {config_file stdout pid} {', 1)
    for counter in ('previous_ready_count', 'prev_ready_count'):
        original = 'if {[count_message_lines $stdout "Ready to accept"] > $' + counter + '} {'
        if data.count(original) != 1:
            raise ValueError('unexpected upstream readiness log gate')
        replacement = 'if {[server_is_up $host $port 2]} {' if counter == 'previous_ready_count' else 'if {[server_is_up [dict get $srv host] [dict get $srv port] 2]} {'
        data = data.replace(original, replacement, 1)
    support.write_text(data + READINESS)
    binaries = destination / 'src'
    binaries.mkdir()
    launcher = binaries / 'redis-server'
    launcher.write_text('#!/usr/bin/env python3\nimport os, sys\nos.execv(' + repr(str(Path(server).resolve())) + ', [' + 'sys.argv[0]] + sys.argv[1:])\n')
    launcher.chmod(0o755)
    if client:
        shutil.copy2(Path(client).resolve(), binaries / 'redis-cli')
    if aof_checker:
        shutil.copy2(Path(aof_checker).resolve(), binaries / 'redis-check-aof')
        (binaries / 'redis-check-aof').chmod(0o755)
    receipt = {'archive': str(archive.resolve()), 'sha256': expected,
               'server': str(Path(server).resolve()), 'server_sha256': digest(Path(server).read_bytes()),
               'launcher_sha256': digest(launcher.read_bytes()),
               'original_files': originals,
               'changes': [{'path': 'tests/support/server.tcl', 'original_sha256': originals['tests/support/server.tcl'],
                            'adapted_sha256': digest(support.read_bytes()),
                            'reason': 'Owned-process readiness uses actual TCP/Unix initialization instead of Redis-specific log format; omit unconditional distributed tls-cluster/tls-replication fixture setup for single-node TLS. Upstream test assertions unchanged.'}],
               'assertions_modified': False, 'external_skip_lifted': False,
               'client': str(Path(client).resolve()) if client else None,
               'aof_checker': {'path': str(Path(aof_checker).resolve()),
                               'sha256': digest((binaries / 'redis-check-aof').read_bytes())} if aof_checker else None}
    (destination / 'fixture-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description='Prepare isolated harness-managed Eski fixtures from a pinned upstream test archive.')
    parser.add_argument('--archive', required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--prefix', required=True)
    parser.add_argument('--server', required=True)
    parser.add_argument('--sha256', required=True)
    parser.add_argument('--client')
    parser.add_argument('--aof-checker')
    args = parser.parse_args()
    prepare(args.archive, args.destination, args.prefix, args.server, args.sha256, args.client, args.aof_checker)


if __name__ == '__main__':
    main()
