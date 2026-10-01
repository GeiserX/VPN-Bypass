# MCP server

[vpn-bypass-mcp](https://github.com/GeiserX/vpn-bypass-mcp) is an MCP server for VPN Bypass. With it, an AI agent such as Claude Code can read what the app is doing and change its routing. It talks to the app over the same control socket as [`vpnb`](usage.md#command-line-control-vpnb), so it reaches what `vpnb` reaches: the mode, the Bypass and VPN Only lists, the services, the routes the app has installed, the log, and Custom-mode routes and rules.

It needs VPN Bypass 4.9.0 or later, running, on macOS. The client starts the server itself as a local process (stdio), through `npx`, so Node.js must be installed. The tools it offers, with their arguments, are listed on the [vpn-bypass-mcp usage page](https://github.com/GeiserX/vpn-bypass-mcp/blob/main/docs/usage.md#tools).

## Add it to a client

Claude Code, for every project:

```bash
claude mcp add --scope user vpn-bypass -- npx -y vpn-bypass-mcp
```

Without `--scope user`, Claude Code adds the server for the current directory only.

A client configured by JSON (Claude Desktop, Cursor and most others) takes an `mcpServers` entry in its MCP config file:

```json
{
  "mcpServers": {
    "vpn-bypass": {
      "command": "npx",
      "args": ["-y", "vpn-bypass-mcp"]
    }
  }
}
```

Restart the client or reload its MCP servers, then ask it for the VPN Bypass status. VPN Bypass must be running, because the app is what answers on the socket.

## What an agent can do with it

A few requests that work once the server is added:

- "Send example.com around the VPN." The agent adds `example.com` to the Bypass list, the same as typing it into the dropdown in Bypass mode.
- "Netflix stalls on the VPN. Turn on the Netflix service and show me the routes it installed." The agent turns the service on, then reads the installed routes for Netflix. The routes appear only in Bypass mode and while a VPN is connected.
- "My routes stopped working after I reconnected. What went wrong?" The agent reads the status and the latest errors from the app's log, and can start a route refresh, the same as Refresh Routes in the dropdown.

A change is saved in the app's config before the agent gets its answer. The kernel routes for that entry are added or removed a moment later, and only while a VPN is connected and the app is in the mode that uses that list: Bypass mode for the Bypass list and the services, VPN Only mode for the VPN Only list. The agent reads the installed routes or the log to see the effect.

## Read-only mode

Set `VPN_BYPASS_MCP_READ_ONLY=1` and the server offers only the tools that read: status, the lists, the services, the installed routes and the log. An agent can then look but cannot change anything.

```bash
claude mcp add --scope user vpn-bypass --env VPN_BYPASS_MCP_READ_ONLY=1 \
  -- npx -y vpn-bypass-mcp
```

In a JSON config, add an `env` block to the entry:

```json
"env": { "VPN_BYPASS_MCP_READ_ONLY": "1" }
```

## Settings

| Variable | Default | What it does |
|---|---|---|
| `VPNB_SOCKET` | `~/Library/Application Support/VPNBypass/control.sock` | The control socket path, the same variable `vpnb` reads. |
| `VPN_BYPASS_MCP_READ_ONLY` | unset | `1` offers only the read tools. |

## Security

The control socket accepts connections from your own macOS account only, and the MCP server runs as you, so it can do what you can do in the app and nothing more. It cannot install the privileged helper or reach another account's app. Anything the agent changes shows up in the dropdown and in Settings, and you can undo it there. The dropdown names the agent's last change at its foot ("Last change: added en.wikipedia.org via the command line, 2 min ago"), and in Settings > Logs every line the agent's requests wrote ends in "via the command line".
