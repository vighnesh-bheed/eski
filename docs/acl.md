# ACL and authentication

ACL users combine an enabled state, password rules, command permissions, key patterns and pub/sub channel patterns. The default startup user permits unauthenticated access unless configured otherwise. Binding to loopback is the quick-start default in these docs; set authentication and network policy before exposing a listener.

`ACL SETUSER` applies rules incrementally. `reset` clears the user's rules, `on`/`off` changes its enabled state, `>password` adds a password, and `nopass` allows passwordless authentication. Command rules use `+command`, `-command`, categories such as `+@read`, and subcommand permissions where applicable. Key patterns use `~pattern` or separate read/write forms `%R~pattern` and `%W~pattern`; channel patterns use `&pattern`. Selectors group alternative sets of command/key/channel permissions. Quote rules so the shell does not interpret `>`, `&`, `*` or parentheses.

```sh
redis-cli -p 6399 ACL SETUSER demo-reader reset on '>replace-this-password' '~demo:*' +get +mget +ping
redis-cli -p 6399 ACL DRYRUN demo-reader GET demo:message
redis-cli -p 6399 ACL DRYRUN demo-reader SET demo:message hello
```

Use `AUTH demo-reader password` or `HELLO 3 AUTH demo-reader password` on a persistent client connection to authenticate. The first dry run above should be allowed and the second denied. Example passwords are placeholders. Prefer a client credential mechanism that does not retain secrets in shell history or process arguments. `requirepass` configures the default user's authentication requirement rather than creating an independent access-control system.

`ACL GETUSER`, `LIST`, `USERS` and `WHOAMI` inspect rules/identity. `ACL CAT` lists metadata categories, `GENPASS` creates a random password string, `DELUSER` removes users, and `LOG` inspects/reset denied-access records. `DRYRUN` checks a command under a user's rules without executing it. A category can describe registry metadata for an excluded feature; it does not implement that feature.

Configure `aclfile` at startup to use `ACL LOAD` and `ACL SAVE`. Runtime rule changes need an explicit save if they should survive restart. Treat that file and configuration files containing credentials as secrets. Test a new administrative login before removing access from the current default account.

ACL covers the RESP command path and key/channel access. The optional [memcached text endpoint](memcached.md) does not provide this authentication flow; enable and isolate it separately. ACL is not transport encryption; this node does not implement TLS listeners.

Verify with `bash test/run_packages.sh`, `bash test/smoke.sh` and `./test/conformance/run.sh --suite redis --units auth,acl,acl-v2`. Package checks include selector/key specifications, command permissions and protected sort lookups. See [conformance](conformance.md) for the test runner's external-server constraints and recorded coverage.
