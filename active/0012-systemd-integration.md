# Integration With Systemd

## Changelog

* 2021-06-09: @zhongwencool Initial draft


## Abstract

Emqx currently uses a simple systemd forking type to start emqx in demon mode. The other benefits of systemd are not fully exploited, for example, systemd does not restart all emqx processes that exit abnormally (`kill GroupChildrenPid`). Systemd  just acts as a starter.

## Motivation

The benefits of [systemd](https://github.com/systemd/systemd) include, but are not limited to:

- The ability to configure specific system parameters for service such as `LimitNOFILE`.
- The reboot interval can be configured, and restart after the machine reboots.
- Journalctl logging can be configured.
- Very stable, easy and configurable way to manage services.

This will make the node more robust and the user will see more information about the operation of the node via `systemctl status emqx`, Make `start/stop/restart` work as expected.

## Design

Systemd is built into the mainstream Linux, Very versatile and flexible configuration with fine control, Please read [the full configurations first](https://www.freedesktop.org/software/systemd/man/systemd.exec.html). 

Since OTP/19 supports Unix sockets, you can integrate systemd's notify mode directly without relying on non-Erlang libraries. https://github.com/hauleth/erlang-systemd.

Configuration `emqx.service`:

```yaml
[Unit]
Description=emqx broker
After=syslog.target network.target

[Service]
Type=notify
User=emqx
Group=emqx

# https://www.freedesktop.org/software/systemd/man/systemd.service.html

# When the umask is set to 0027, the file permissions will be set to 640. This is #
# preferred for security reasons because this will restrict others not to
# read/write/execute that file/folder.
UMask=0027

# All services updates from all members of the service's control group are accepted.
NotifyAccess=all
# If a daemon service does not signal start-up completion within the configured time,
# the service will be considered failed and will be shut down again
TimeoutStartSec=600

# To override LimitNOFILE, create the following file:
#
# /etc/systemd/system/emqx.service.d/limits.conf
#
# with the following content:
#
# [Service]
# LimitNOFILE=65536

LimitNOFILE=1048576

# Restart:
Restart=on-failure
RestartSec=10
WorkingDirectory=/var/lib/emqx
ExecStart=/usr/bin/emqx foreground
ExecStop=/usr/bin/emqx stop
# TODO when exec emqx stop, conside the exit code as successExitStatus
# SuccessExitStatus= TREM

[Install]
WantedBy=multi-user.target
```


## Configuration Changes

Add journal log configurations.

```yaml
log.journald = true
log.journald.level = debug/info/notice/warning/error/critical/alert/emergency
log.journald.fields = SYSLOG_IDENTIFIER="emqx" syslog_timestamp syslog_pid priority ERL_PID=pid
```

`journalctl -f`  output:

```bash
6月 09 17:26:36 172.xx.xx.xx emqx[1024]: Starting emqx....
```



## Backwards Compatibility

NONE.

## Document Changes

**TODO**

## Testing Suggestions

**TODO**

### Declined Alternatives

NONE.


### Refer

- [systemd](https://github.com/systemd/systemd).
- [the biggest myths about systemd](http://0pointer.de/blog/projects/the-biggest-myths.html).
- [sytemd configurations documents](https://www.freedesktop.org/software/systemd/man/systemd.exec.html).
- [Learning to love systemd](https://opensource.com/article/20/4/systemd).

