package main

import "core:os"
import "core:sys/linux"

VERSION :: "0.1.0"
REDIS_COMPAT_VERSION :: "7.4.11"
PROJECT_LICENSE :: "Apache-2.0"

usage :: proc(fd: linux.Fd) {
	write_fd(fd, "Usage: ./eski [/path/to/redis.conf] [options] [-]\n       ./eski - (read config from stdin)\n       ./eski -v or --version\n       ./eski -h or --help\n\nEvery parameter of the reference's configuration file can also be given on the\ncommand line as --name value, for example --port 6380 --maxmemory 100mb.\nThe Eski specific parameters are --memcached-port N (default 0, off) and\n--memcached-max-item-size N (1k to 512m, default 1m).\nOptional LCS compute workers use --compute-threads N (0 to 64, default 0)\nand --compute-max-memory N (default 128mb). Both are startup-only.\nOptional keyspace workers use --keyspace-threads N (0 to 64, default 0)\nand --keyspace-max-memory N (default 128mb). Both are startup-only.\nGlobal operations and commands requiring serialization use the coordinator.\n\nExamples:\n       ./eski (run the server with default config, port 6399)\n       ./eski /etc/redis/6379.conf\n       ./eski --port 7777\n       ./eski /etc/myredis.conf --loglevel verbose -\n")
}

main :: proc() {
	config_init()
	acl_init()
	info_startup(os.args[0] if len(os.args) > 0 else "")
	srv.port = 6399
	args := make([dynamic]string, 0, len(os.args))
	for a, i in os.args {
		if i > 0 && a == "-p" {
			append(&args, "--port")
			continue
		}
		append(&args, a)
	}
	if len(args) >= 2 {
		switch args[1] {
		case "-v", "--version":
			write_fd(1, "eski v=" + VERSION + " license=" + PROJECT_LICENSE + "\n")
			linux.exit_group(0)
		case "--help", "-h":
			usage(2)
			linux.exit_group(1)
		}
		filename, from_stdin, options := config_parse_command_line(args[:])
		if filename != "" {
			config_file = info_absolute_path(filename)
		}
		config_load_file(filename, from_stdin, options)
	}
	config_startup()
	if mc_port != 0 && mc_port == srv.port {
		write_fd(2, "eski: the memcached port must differ from the port\n")
		linux.exit_group(2)
	}
	if !diagnostics_init() {
		write_fd(2, "eski: native diagnostics initialization failed\n")
		runtime_operations_shutdown()
		linux.exit_group(1)
	}
	context.assertion_failure_proc = diagnostics_assertion_failure
	runtime_tuning_enter(.Server)
	if !server_run() {
		diagnostics_shutdown()
		runtime_operations_shutdown()
		linux.exit_group(1)
	}
}
