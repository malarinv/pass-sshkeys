#!/usr/bin/env bash

# pass ssh extension for SSH key/config management

VERSION="0.2.0"
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

# Process a Host block and store in pass
process_host_block() {
    local hostname="$1"
    local -a host_block=("${!2}")

    # Extract IdentityFiles
    local identity_files=()
    for line in "${host_block[@]}"; do
        if [[ "$line" =~ ^[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee[[:space:]]+([^[:space:]]+) ]]; then
            identity_files+=("${BASH_REMATCH[1]}")
        fi
    done

    # Process each IdentityFile
    for identity_file in "${identity_files[@]}"; do
        local expanded_path="${identity_file/#\~/$HOME}"
        expanded_path=$(realpath -m "$expanded_path" 2>/dev/null)

        # Resolve relative to SSH_DIR
        [[ "$expanded_path" != "$SSH_DIR"/* ]] && expanded_path="$SSH_DIR/$identity_file"

        if [[ -f "$expanded_path" ]]; then
            local rel_path="${expanded_path#$SSH_DIR/}"
            rel_path="${rel_path//../_dotdot_}"
            local store_path="ssh/$hostname/$rel_path"
            echo "Importing $expanded_path to $store_path"
            pass insert --multiline "$store_path" < "$expanded_path" || die "Failed to insert $store_path"
        else
            echo "Skipping non-existent IdentityFile: $identity_file"
        fi
    done

    # Store Host block
    local config_store="ssh/$hostname/config"
    echo "Storing Host block in $config_store"
    printf "%s\n" "${host_block[@]}" | pass insert --multiline "$config_store" >/dev/null || die "Failed to save config"
}

# Import single host
cmd_import() {
    local hostname="$1"
    [[ -z "$hostname" ]] && die "Usage: pass ssh import <hostname>"

    # Find Host block
    local in_block=0
    local host_block=()
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if (( in_block )); then
            if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+ ]]; then
                break
            fi
            host_block+=("$line")
        elif [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+$hostname([[:space:]]+|$) ]]; then
            in_block=1
            host_block+=("$line")
        fi
    done < "$CONFIG_FILE"

    (( ${#host_block[@]} )) || die "Host '$hostname' not found in $CONFIG_FILE"
    process_host_block "$hostname" host_block[@]
}

# Import all hosts from SSH config
cmd_import_all() {
    echo "Parsing SSH config to find all Host blocks..."

    # Parse all Host blocks
    local current_host="" in_block=0
    declare -a current_block all_hosts
    while IFS= read -r line; do
        # Skip comments
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+([^#]*) ]]; then
            # New Host block
            if (( in_block )); then
                all_hosts+=("$current_host" "${current_block[@]}")
            fi
            current_host="${BASH_REMATCH[1]%% *}"  # First hostname
            current_block=("$line")
            in_block=1
        elif [[ "$line" =~ ^[Mm][Aa][Tt][Cc][Hh][[:space:]] ]] && (( in_block )); then
            # End of Host block
            all_hosts+=("$current_host" "${current_block[@]}")
            current_host=""
            current_block=()
            in_block=0
        elif (( in_block )); then
            current_block+=("$line")
        fi
    done < "$CONFIG_FILE"
    (( in_block )) && all_hosts+=("$current_host" "${current_block[@]}")

    # Process all found Host blocks
    local i=0
    while (( i < ${#all_hosts[@]} )); do
        local host="${all_hosts[i]}"
        ((i++))
        local -a block=()
        while (( i < ${#all_hosts[@]} )) && [[ ${all_hosts[i]} != "" ]]; do
            block+=("${all_hosts[i]}")
            ((i++))
        done
        echo "Importing host: $host"
        process_host_block "$host" block[@]
    done
}

# Export single host
cmd_export() {
    local hostname="$1"
    [[ -z "$hostname" ]] && die "Usage: pass ssh export <hostname>"

    # Retrieve Host block
    local config_store="ssh/$hostname/config"
    local host_block
    host_block=$(pass show "$config_store" 2>/dev/null) || die "No config found for $hostname"

    # Check conflicts
    local exported_patterns="${host_block%%$'\n'*}"
    exported_patterns="${exported_patterns#Host }"
    local conflict=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+ ]]; then
            local existing_patterns="${line#Host }"
            for pattern in $exported_patterns; do
                [[ " $existing_patterns " == *" $pattern "* ]] && conflict=1
            done
        fi
    done < "$CONFIG_FILE"

    if (( conflict )) && ! yesno "Overwrite conflicting Host entries?"; then
        die "Export aborted"
    fi

    # Backup and merge config
    local backup="${CONFIG_FILE}.bak.$(date +%s)"
    cp "$CONFIG_FILE" "$backup" || die "Failed to backup config"
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
    echo "$host_block" >> "$CONFIG_FILE"

    # Export keys
    while IFS= read -r line; do
        [[ "$line" =~ ^[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee[[:space:]]+([^[:space:]]+) ]] || continue
        local identity_file="${BASH_REMATCH[1]}"
        local expanded_path="${identity_file/#\~/$HOME}"
        expanded_path=$(realpath -m "$expanded_path")
        [[ "$expanded_path" != "$SSH_DIR"/* ]] && expanded_path="$SSH_DIR/$identity_file"
        local rel_path="${expanded_path#$SSH_DIR/}"
        rel_path="${rel_path//../_dotdot_}"
        local store_path="ssh/$hostname/$rel_path"

        if [[ -f "$expanded_path" ]] && ! yesno "Overwrite $expanded_path?"; then
            echo "Skipping $expanded_path"
            continue
        fi

        pass show "$store_path" > "$expanded_path" || echo "Warning: $store_path missing"
        chmod 600 "$expanded_path"
    done <<< "$host_block"

    echo "Exported $hostname. Backup: $backup"
}

# Export all hosts
cmd_export_all() {
    # Find all imported hosts
    local hostname
    while IFS= read -r -d '' hostname; do
        hostname="${hostname#ssh/}"
        hostname="${hostname%/}"
        echo "Exporting host: $hostname"
        cmd_export "$hostname"
    done < <(find "$PASS_DIR/ssh" -mindepth 1 -maxdepth 1 -type d -printf '%P\0' 2>/dev/null)
}

# Main handler
case "$1" in
    import) shift; cmd_import "$@" ;;
    import-all) shift; cmd_import_all ;;
    export) shift; cmd_export "$@" ;;
    export-all) shift; cmd_export_all ;;
    *) die "Usage: pass ssh import|import-all|export|export-all [hostname]" ;;
esac