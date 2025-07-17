# pass-sshkeys

A [pass](https://www.passwordstore.org/) extension for managing SSH keys and configurations securely.

## Description

`pass-sshkeys` allows you to store and manage your SSH private keys and configurations within your password store. This enables you to:

- Securely store SSH keys encrypted with GPG
- Import/export SSH keys and configurations between machines
- Connect to hosts directly using stored keys without permanent import
- Keep your `.ssh` directory clean and manage keys on a per-host basis

## Installation

### Dependencies

- `pass` >= 1.7.0
- `bash` >= 4.0
- Standard Unix tools (`awk`, `sed`, etc.)

### From Git

```bash
git clone https://github.com/malarinv/pass-sshkeys
cd pass-sshkeys
sudo make install
```

### Manual Installation

1. Copy `sshkeys.bash` to `/usr/lib/password-store/extensions/` or `~/.password-store/.extensions/`
2. Ensure it's executable: `chmod +x sshkeys.bash`

### User Extensions

If you don't want to install this as a system extension, you can enable user extensions with:

```bash
export PASSWORD_STORE_ENABLE_EXTENSIONS=true
```

For convenience, add this alias to your `.bashrc`:

```bash
alias pass='PASSWORD_STORE_ENABLE_EXTENSIONS=true pass'
```

## Usage

### Import SSH Keys and Config

Import a single host:

```bash
pass sshkeys import hostname
```

When importing a host, the extension automatically detects and handles ProxyJump configurations:

- Recursively imports any ProxyJump hosts found in the config
- Maintains the complete chain of proxy hosts
- Stores all necessary keys and configurations for the entire connection chain

Import all hosts from SSH config:

```bash
pass sshkeys import-all
```

### Export SSH Keys and Config

Export a single host:

```bash
pass sshkeys export hostname
```

Export all stored hosts:

```bash
pass sshkeys export-all
```

### Direct Connection

Connect to a host using stored keys without importing:

```bash
pass sshkeys connect hostname
```

The connect command:

- Automatically sets up all ProxyJump hosts in the connection chain
- Creates temporary configurations and keys for both the target host and any proxy hosts
- Cleans up temporary files after the connection ends

## Storage Structure

Keys and configurations are stored in your password store under the `ssh/` prefix:

```fs
Password Store
└── ssh
    └── hostname
        ├── config
        ├── id_rsa
        └── id_ed25519
```

## Security Considerations

- All keys are encrypted using your GPG key(s)
- Temporary keys created during `connect` operations are stored in `/tmp` and cleaned up automatically
- Original SSH config files are backed up before modifications

## License

This extension is licensed under the GNU General Public License v3.0 or later.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
