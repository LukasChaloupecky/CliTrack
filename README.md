# clitrack

> Keep track of the command-line tools installed on your machine.

`clitrack` is a small Bash utility for maintaining a personal inventory
of CLI tools. It records each tool's name, version command, installation
origin, date added, notes, and last known version so you can quickly see
what is installed, missing, or has changed.

Each user gets a private tab-separated data file by default, stored at:

``` text
~/.local/share/clitrack/tools.tsv
```

## Features

-   Track installed command-line tools in a simple local database
-   Automatically detect installed versions
-   Remember where a tool came from (`apt`, `npm`, `cargo`, `pip`,
    `manual`, etc.)
-   Check whether tracked tools are missing or have changed versions
-   Scan common locations for untracked tools
-   Search tracked tools by name, origin, or note
-   Export and import your tool inventory
-   Edit version commands, origins, and notes
-   JSON output for scripting and automation
-   Optional color output with `NO_COLOR` support
-   Automatic database backups before destructive/update operations

## Requirements

-   Bash **4.4+**
-   `awk`
-   `grep`
-   `sort`

Optional utilities such as `timeout`, `dpkg`, and `rpm` are used when
available.

## Installation

Clone the repository and make the script executable:

``` bash
git clone "https://github.com/LukasChaloupecky/CliTrack.git"
cd clitrack

chmod +x clitrack.sh
mkdir -p ~/.local/bin
mv clitrack.sh ~/.local/bin/clitrack
```

Make sure `~/.local/bin` is on your `PATH`:

``` bash
export PATH="$HOME/.local/bin:$PATH"
```

Then verify the installation:

``` bash
clitrack --version
clitrack --help
```

## Quick start

Add a few tools:

``` bash
clitrack --add git curl jq
```

List everything being tracked:

``` bash
clitrack --list
```

Check whether tools are still installed and whether their versions
changed:

``` bash
clitrack --check
```

Refresh the recorded versions:

``` bash
clitrack --sync
```

Discover installed tools that are not tracked yet:

``` bash
clitrack --scan
```

## Usage

### Add tools

``` bash
clitrack --add git curl jq
```

You can specify a custom version command:

``` bash
clitrack --add npm --cmd "npm -v"
```

Or provide a note and installation origin:

``` bash
clitrack --add mytool \
  --cmd "-version" \
  --origin manual \
  --note "Internal development tool"
```

Short options are also supported:

``` bash
clitrack -a git curl jq
clitrack -a npm -c "npm -v" -n "Node package manager"
```

If a tool is not currently in `PATH`, `clitrack` can still track it.

### List tracked tools

``` bash
clitrack --list
```

The normal output includes:

-   tool name
-   installation status
-   detected version
-   origin
-   date added
-   note

Filter by origin:

``` bash
clitrack --list --origin npm
```

Use the last recorded versions without executing the tools:

``` bash
clitrack --list --fast
```

Get JSON output:

``` bash
clitrack --list --json
```

### Show a tool's version

For a tracked or untracked tool:

``` bash
clitrack --tool-version npm
```

Print only the version number:

``` bash
clitrack --tool-version node --quiet
```

### Inspect a tool

Show detailed information about a tool:

``` bash
clitrack --info git
```

This can include:

-   whether it is tracked
-   date added
-   executable path
-   resolved path
-   current version
-   recorded version
-   version command
-   detected origin
-   note

### Check for changes

Run a complete inventory check:

``` bash
clitrack --check
```

The check reports tools as:

-   `ok` --- installed and unchanged
-   `CHANGED` --- installed version differs from the recorded version
-   `MISSING` --- no longer found in `PATH`

### Sync recorded versions

Update the stored version for every tracked tool:

``` bash
clitrack --sync
```

Or sync selected tools:

``` bash
clitrack --sync git node npm
```

### Search

Search tool names, origins, and notes:

``` bash
clitrack --find docker
```

### Scan for installed tools

Discover common CLI tools and executables in typical user bin
directories:

``` bash
clitrack --scan
```

Use `--yes` to add discovered tools without confirmation:

``` bash
clitrack --scan --yes
```

The scan checks a built-in list of common tools as well as directories
such as:

``` text
~/.local/bin
~/bin
~/.cargo/bin
~/go/bin
~/.npm-global/bin
~/.bun/bin
~/.deno/bin
```

If npm is installed, its user-level global binary directory is also
considered when applicable.

### Remove tools

Remove one or more tracked tools:

``` bash
clitrack --remove jq
```

A database backup is kept before removal.

### Edit tracked tools

Change a version command, note, or origin:

``` bash
clitrack --edit npm --cmd "npm -v"
```

``` bash
clitrack --edit mytool --note "Updated internal utility"
```

``` bash
clitrack --edit mytool --origin manual
```

Options can be combined:

``` bash
clitrack --edit mytool \
  --cmd "--version" \
  --origin cargo \
  --note "CLI utility"
```

### Export and import

Export the current inventory to standard output:

``` bash
clitrack --export
```

Export it to a file:

``` bash
clitrack --export backup.tsv
```

Import an inventory:

``` bash
clitrack --import backup.tsv
```

Existing tracked tools are preserved during import.

### Count tracked tools

``` bash
clitrack --count
```

### Show the data file path

``` bash
clitrack --path
```

### Clear the inventory

Remove all tracked tools:

``` bash
clitrack --clear
```

A backup is kept before the inventory is cleared.

## Data storage

The inventory is stored as a tab-separated file:

``` text
~/.local/share/clitrack/tools.tsv
```

The default location can be changed with `CLITRACK_DIR`:

``` bash
export CLITRACK_DIR="$HOME/.config/clitrack"
```

The data file contains these fields:

``` text
name
version_cmd
origin
added
note
last_version
```

For example:

``` text
git --version   apt 2026-01-15  Version control 2.47.1
```

Backups use the `.bak` suffix:

``` text
~/.local/share/clitrack/tools.tsv.bak
```

## Environment variables

### `CLITRACK_DIR`

Override the directory used for the local database:

``` bash
CLITRACK_DIR="$HOME/.config/clitrack" clitrack --list
```

### `NO_COLOR`

Disable colored output:

``` bash
NO_COLOR=1 clitrack --list
```

## Version detection

When no custom version command is supplied, `clitrack` tries common
version arguments including:

``` text
--version
-V
-version
version
-v
```

For custom commands, use `--cmd` / `-c`:

``` bash
clitrack --add mytool --cmd "--version"
```

Commands are executed without stdin and are limited to a short execution
window when the `timeout` utility is available.

## Origin detection

`clitrack` makes a best-effort guess about where an executable came from
based on its path and available system package managers.

Possible origins include:

``` text
apt
rpm
pacman
npm
nvm
cargo
go
bun
deno
pip
pipx
snap
brew
manual
user
opt
system
unknown
```

You can always override the detected value with:

``` bash
clitrack --add mytool --origin manual
```

## Common commands

  Command                   Description
  ------------------------- ------------------------------------
  `clitrack -a TOOL...`     Add tools
  `clitrack -r TOOL...`     Remove tools
  `clitrack -e TOOL`        Edit a tracked tool
  `clitrack -l`             List tracked tools
  `clitrack -v TOOL...`     Show installed version
  `clitrack -i TOOL...`     Show detailed information
  `clitrack -k`             Check for missing or changed tools
  `clitrack -s [TOOL...]`   Sync recorded versions
  `clitrack -f TERM`        Search the inventory
  `clitrack -S`             Scan for untracked tools
  `clitrack -x [FILE]`      Export inventory
  `clitrack -I FILE`        Import inventory
  `clitrack --count`        Count tracked tools
  `clitrack --path`         Show database path
  `clitrack --clear`        Remove all tracked tools
  `clitrack -V`             Show clitrack version
  `clitrack -h`             Show help

## Examples

Track a typical development environment:

``` bash
clitrack --add git curl wget jq node npm python3 pip3 go rustc cargo docker
```

Find tools installed through npm:

``` bash
clitrack --list --origin npm
```

Check one tool's current version:

``` bash
clitrack --tool-version node
```

Export the inventory before moving to another machine:

``` bash
clitrack --export ~/clitrack-backup.tsv
```

Restore it on the new machine:

``` bash
clitrack --import ~/clitrack-backup.tsv
```

Use JSON from a script:

``` bash
clitrack --list --json
```

## Safety and behavior

`clitrack` is designed to **track** tools rather than install, upgrade,
or remove the tools themselves.

Operations such as `--remove` and `--clear` modify only the `clitrack`
inventory. They do not uninstall the corresponding system packages or
executables.

Before modifying the inventory, the script keeps a backup of the
database where applicable.

## Shell compatibility

The script requires Bash 4.4 or newer:

``` bash
bash --version
```

It intentionally uses Bash features such as associative arrays and
modern parameter expansion.

## Project structure

A minimal installation can consist of the executable script:

``` text
clitrack/
└── clitrack.sh
```

After installation, it can be exposed as:

``` text
~/.local/bin/clitrack
```

## License

Add your preferred license here, for example MIT, Apache-2.0, or
GPL-3.0.

If this project is already licensed, replace this section with the
corresponding license text or a link to the repository's `LICENSE` file.
