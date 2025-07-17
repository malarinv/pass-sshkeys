#!/usr/bin/env bash

# pass ssh extension for importing/exporting SSH keys and configs

VERSION="0.1.0"
SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"
PASS_DIR="$PASSWORD_STORE_DIR"

# Helper functions
die() { echo "Error: $*" >&2; exit 1; }
yesno() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" =~ [Yy] ]]
}

# Import SSH keys and config into pass
cmd_import() {
    local hostname="$1"
    [[ -z "$hostname" ]] && die "Usage: pass ssh import <hostname>"

    # Find Host block in SSH config
    local in_block=0
    local host_block=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue  # Skip comments
        fi
        if (( in_block )); then
            if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+ ]]; then
                break
            fi
            host_block+=("$line")
        else
            if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+$hostname([[:space:]]+|$) ]]; then
                in_block=1
                host_block+=("$line")
            fi
        fi
    done < "$CONFIG_FILE"

    (( ${#host_block[@]} )) || die "Host '$hostname' not found in $CONFIG_FILE"

    # Extract IdentityFiles
    local identity_files=()
    for line in "${host_block[@]}"; do
        if [[ "$line" =~ ^[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]]+([^[:space:]]+) ]]; then
            identity_files+=("${BASH_REMATCH[1]}")
        fi
    done

    # Process each IdentityFile
    for identity_file in "${identity_files[@]}"; do
        # Expand path
        local expanded_path="${identity_file/#\~/$HOME}"
        expanded_path=$(realpath -m "$expanded_path" 2>/dev/null)

        # Resolve relative to SSH_DIR
        if [[ "$expanded_path" != "$SSH_DIR"/* ]]; then
            expanded_path="$SSH_DIR/$identity_file"
        fi

        # Check if private key exists
        if [[ -f "$expanded_path" ]]; then
            # Determine store path
            local rel_path="${expanded_path#$SSH_DIR/}"
            rel_path="${rel_path//../_dotdot_}"  # Sanitize ..

            local store_path="ssh/$hostname/$rel_path"
            echo "Importing $expanded_path to $store_path"

            # Insert into pass
            pass insert --multiline "$store_path" < "$expanded_path" || die "Failed to insert $store_path"
        else
            echo "Skipping non-existent IdentityFile: $identity_file"
        fi
    done

    # Save Host block
    local config_store="ssh/$hostname/config"
    echo "Storing Host block in $config_store"
    printf "%s\n" "${host_block[@]}" | pass insert --multiline "$config_store" >/dev/null || die "Failed to save config"
}

# Export SSH keys and config from pass
cmd_export() {
    local hostname="$1"
    [[ -z "$hostname" ]] && die "Usage: pass ssh export <hostname>"

    # Retrieve Host block
    local config_store="ssh/$hostname/config"
    local host_block
    host_block=$(pass show "$config_store" 2>/dev/null) || die "No config found for $hostname"

    # Check existing Host entries
    local existing_patterns=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+([^#]+) ]]; then
            existing_patterns+=("${BASH_REMATCH[1]}")
        fi
    done < "$CONFIG_FILE"

    # Check if exported Host patterns exist
    local exported_patterns
    if [[ "$host_block" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+([^[:space:]#]+) ]]; then
        exported_patterns="${BASH_REMATCH[1]}"
    else
        die "Invalid Host block in $config_store"
    fi

    # Check for conflicts
    local conflict=0
    for pattern in $exported_patterns; do
        for existing in "${existing_patterns[@]}"; do
            if [[ " $existing " == *" $pattern "* ]]; then
                echo "Conflict: Host pattern '$pattern' exists in $CONFIG_FILE"
                conflict=1
            fi
        done
    done

    if (( conflict )) && ! yesno "Overwrite conflicting Host entries?"; then
        die "Export aborted"
    fi

    # Backup original config
    local backup="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup" || die "Failed to backup config"

    # Remove conflicting Host blocks
    awk -v patterns="$exported_patterns" '
        BEGIN { in_block=0; delete_lines=0 }
        /^[Hh][Oo][Ss][Tt][[:space:]]+/ {
            if (in_block) { in_block=0 }
            split($0, parts, /[[:space:]]+/)
            for (i=2; i<=NF; i++) {
                for (p in patterns_arr) {
                    if (parts[i] == patterns_arr[p]) {
                        delete_lines=1
                        in_block=1
                        next
                    }
                }
            }
        }
        in_block { next }
        delete_lines { delete_lines=0; next }
        { print }
    ' "$backup" > "$CONFIG_FILE" || die "Failed to remove conflicts"

    # Append new Host block
    echo "Appending Host block for $hostname to $CONFIG_FILE"
    echo "$host_block" >> "$CONFIG_FILE"

    # Export IdentityFiles
    local identity_files=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]]+([^[:space:]]+) ]]; then
            identity_files+=("${BASH_REMATCH[1]}")
        fi
    done <<< "$host_block"

    for identity_file in "${identity_files[@]}"; do
        local expanded_path="${identity_file/#\~/$HOME}"
        expanded_path=$(realpath -m "$expanded_path")

        # Resolve relative to SSH_DIR
        if [[ "$expanded_path" != "$SSH_DIR"/* ]]; then
            expanded_path="$SSH_DIR/$identity_file"
        fi

        local rel_path="${expanded_path#$SSH_DIR/}"
        rel_path="${rel_path//../_dotdot_}"
        local store_path="ssh/$hostname/$rel_path"

        if ! pass show "$store_path" >/dev/null 2>&1; then
            echo "Warning: $store_path not found in pass"
            continue
        fi

        if [[ -f "$expanded_path" ]] && ! yesno "Overwrite $expanded_path?"; then
            echo "Skipping $expanded_path"
            continue
        fi

        echo "Exporting $store_path to $expanded_path"
        mkdir -p "$(dirname "$expanded_path")"
        pass show "$store_path" > "$expanded_path"
        chmod 600 "$expanded_path"
    done

    echo "Export complete. Original config backed up to $backup"
}

# Bulk operations
cmd_import_all() {
    echo "Importing all hosts from $CONFIG_FILE"
    local hostname=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+([^#[:space:]]+) ]]; then
            hostname="${BASH_REMATCH[1]}"
            echo "Importing host: $hostname"
            cmd_import "$hostname" || echo "Failed to import $hostname"
        fi
    done < "$CONFIG_FILE"
}

cmd_export_all() {
    echo "Exporting all hosts to $CONFIG_FILE"
    local hosts=()
    while IFS= read -r -d '' path; do
        if [[ "$path" =~ ^ssh/([^/]+)/config ]]; then
            hosts+=("${BASH_REMATCH[1]}")
        fi
    done < <(pass ls ssh | grep -F /config | tr '\n' '\0')

    for host in "${hosts[@]}"; do
        echo "Exporting host: $host"
        cmd_export "$host" || echo "Failed to export $host"
    done
}

# Main command handler
case "$1" in
    import) shift; cmd_import "$@" ;;
    export) shift; cmd_export "$@" ;;
    import-all) shift; cmd_import_all "$@" ;;
    export-all) shift; cmd_export_all "$@" ;;
    *) die "Usage: pass ssh import|export|import-all|export-all <hostname>" ;;
esac
