#!/usr/bin/env bash

# pass ssh extension for importing/exporting SSH keys and configs

VERSION="0.1.0"
SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"
PASS_DIR="$PASSWORD_STORE_DIR"
VERBOSE=0

# Helper functions
die() {
    echo "Error: $*" >&2
    exit 1
}
debug() { [[ $VERBOSE -eq 1 ]] && echo "DEBUG: $*" >&2; }
yesno() {
    local answer
    read -r -p "$1 [y/N] " answer
    [[ "$answer" =~ [Yy] ]]
}

# Import a host and its dependencies
cmd_import_with_deps() {
    local hostname="$1"
    local is_dep="${2:-false}"
    [[ -z "$hostname" ]] && die "Usage: pass ssh import <hostname>"

    debug "Starting import for host: $hostname (dependency: $is_dep)"

    # Skip if already imported in this session
    local imported_key="imported_$hostname"
    if [[ "${!imported_key}" == "1" ]]; then
        debug "Host $hostname already imported in this session, skipping"
        return
    fi
    declare -g "$imported_key=1"
    debug "Marking $hostname as imported"

    # Find Host block in SSH config
    debug "Searching for Host block in $CONFIG_FILE"
    local in_block=0
    local host_block=()
    while IFS= read -r line; do
        debug "Processing line: $line"
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            debug "Skipping comment line"
            continue
        fi
        if ((in_block)); then
            if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+ ]]; then
                debug "Found next Host block, stopping"
                break
            fi
            debug "Adding line to host block"
            host_block+=("$line")
        else
            if [[ "$line" =~ ^[Hh][Oo][Ss][Tt][[:space:]]+$hostname([[:space:]]+|$) ]]; then
                debug "Found matching Host block"
                in_block=1
                host_block+=("$line")
            fi
        fi
    done <"$CONFIG_FILE"

    ((${#host_block[@]})) || die "Host '$hostname' not found in $CONFIG_FILE"
    debug "Found ${#host_block[@]} lines in host block"

    # Check for ProxyJump directive and import dependencies
    debug "Checking for ProxyJump directives"
    local proxy_hosts=()
    for line in "${host_block[@]}"; do
        debug "Checking line for ProxyJump: $line"
        if [[ "$line" =~ ^[[:space:]]*[Pp][Rr][Oo][Xx][Yy][Jj][Uu][Mm][Pp][[:space:]]+([^[:space:]]+) ]]; then
            debug "Found ProxyJump directive: ${BASH_REMATCH[1]}"
            IFS=',' read -ra proxy_hosts <<<"${BASH_REMATCH[1]}"
            for proxy in "${proxy_hosts[@]}"; do
                # Remove leading/trailing whitespace
                proxy="${proxy#"${proxy%%[![:space:]]*}"}"
                proxy="${proxy%"${proxy##*[![:space:]]}"}"
                debug "Processing proxy host: $proxy"
                if [[ "$proxy" != "none" && "$proxy" != "NONE" ]]; then
                    if $is_dep; then
                        echo "    Importing nested ProxyJump dependency: $proxy"
                    else
                        echo "Importing ProxyJump dependency: $proxy"
                    fi
                    cmd_import_with_deps "$proxy" true
                else
                    debug "Skipping 'none' ProxyJump value"
                fi
            done
        fi
    done

    # Extract IdentityFiles and paths
    debug "Extracting IdentityFiles"
    local identity_files=()
    local identity_paths=()
    for line in "${host_block[@]}"; do
        debug "Checking line for IdentityFile: $line"
        if [[ "$line" =~ ^[[:space:]]*[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]]+([^[:space:]]+) ]]; then
            identity_file="${BASH_REMATCH[1]}"
            debug "Found IdentityFile: $identity_file"
            identity_files+=("$identity_file")

            # Store original path relative to SSH_DIR
            if [[ "$identity_file" == "$SSH_DIR"/* ]]; then
                rel_path="${identity_file#$SSH_DIR/}"
            else
                rel_path="$identity_file"
            fi
            debug "Relative path: $rel_path"
            identity_paths+=("$rel_path")
        fi
    done

    # Process each IdentityFile with path tracking
    debug "Processing ${#identity_files[@]} IdentityFiles"
    for i in "${!identity_files[@]}"; do
        identity_file="${identity_files[$i]}"
        rel_path="${identity_paths[$i]}"
        debug "Processing IdentityFile $((i + 1))/${#identity_files[@]}: $identity_file"

        # Expand path
        local expanded_path="${identity_file/#\~/$HOME}"
        expanded_path=$(realpath -m "$expanded_path")
        debug "Expanded path: $expanded_path"

        # Resolve relative to SSH_DIR if needed
        if [[ "$expanded_path" != "$SSH_DIR"/* ]]; then
            debug "Path not under SSH_DIR, adjusting"
            expanded_path="$SSH_DIR/$identity_file"
        fi

        # Check if private key exists
        if [[ -f "$expanded_path" ]]; then
            # Determine store path
            local rel_path="${expanded_path#$SSH_DIR/}"
            rel_path="${rel_path//../_dotdot_}" # Sanitize ..
            debug "Sanitized relative path: $rel_path"

            local store_path="ssh/$hostname/$rel_path"
            debug "Store path: $store_path"
            if $is_dep; then
                echo "    Importing $expanded_path to $store_path"
            else
                echo "Importing $expanded_path to $store_path"
            fi

            # Insert into pass
            debug "Inserting key into pass store"
            pass insert --multiline "$store_path" <"$expanded_path" || die "Failed to insert $store_path"
        else
            debug "IdentityFile not found: $expanded_path"
            echo "Skipping non-existent IdentityFile: $identity_file"
        fi
    done

    # Save Host block
    local config_store="ssh/$hostname/config"
    debug "Saving Host block to $config_store"
    if $is_dep; then
        echo "    Storing Host block in $config_store"
    else
        echo "Storing Host block in $config_store"
    fi
    printf "%s\n" "${host_block[@]}" | pass insert --multiline "$config_store" >/dev/null || die "Failed to save config"
    debug "Host block saved successfully"
}

# Import SSH keys and config into pass
cmd_import() {
    cmd_import_with_deps "$1"
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
    done <"$CONFIG_FILE"

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

    if ((conflict)) && ! yesno "Overwrite conflicting Host entries?"; then
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
    ' "$backup" >"$CONFIG_FILE" || die "Failed to remove conflicts"

    # Append new Host block
    echo "Appending Host block for $hostname to $CONFIG_FILE"
    echo "$host_block" >>"$CONFIG_FILE"

    # Export IdentityFiles
    local identity_files=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]]+([^[:space:]]+) ]]; then
            identity_files+=("${BASH_REMATCH[1]}")
        fi
    done <<<"$host_block"

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
        pass show "$store_path" >"$expanded_path"
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
            cmd_import_with_deps "$hostname" || echo "Failed to import $hostname"
        fi
    done <"$CONFIG_FILE"
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

# Connect directly using stored keys
cmd_connect() {
    local hostname="$1"
    [[ -z "$hostname" ]] && die "Usage: pass ssh connect <hostname>"

    # Create temporary directory for keys
    local tmp_dir=$(mktemp -d)
    debug "Created temporary directory: $tmp_dir"
    trap 'rm -rf "$tmp_dir"' EXIT

    # Create empty temporary SSH config
    local tmp_config="$tmp_dir/config"
    touch "$tmp_config"
    debug "Created temporary config: $tmp_config"

    # Function to process a host and its ProxyJump dependencies
    process_host() {
        local host="$1"
        debug "Processing host: $host"

        # Retrieve Host block
        local config_store="ssh/$host/config"
        local host_block
        host_block=$(pass show "$config_store" 2>/dev/null) || die "No config found for $host"
        debug "Retrieved host block from $config_store:"
        debug "$host_block"

        # Append to temporary SSH config
        echo "$host_block" >>"$tmp_config"

        # Extract and restore keys
        while IFS= read -r line; do
            debug "Processing config line: $line"
            if [[ "$line" =~ ^[[:space:]]*[Pp][Rr][Oo][Xx][Yy][Jj][Uu][Mm][Pp][[:space:]]+([^[:space:]]+) ]]; then
                debug "Found ProxyJump: ${BASH_REMATCH[1]}"
                IFS=',' read -ra proxy_hosts <<<"${BASH_REMATCH[1]}"
                for proxy in "${proxy_hosts[@]}"; do
                    # Remove leading/trailing whitespace
                    proxy="${proxy#"${proxy%%[![:space:]]*}"}"
                    proxy="${proxy%"${proxy##*[![:space:]]}"}"
                    if [[ "$proxy" != "none" && "$proxy" != "NONE" ]]; then
                        debug "Processing ProxyJump host: $proxy"
                        process_host "$proxy"
                    fi
                done
            elif [[ "$line" =~ ^[[:space:]]*[Ii][Dd][Ee][Nn][Tt][Ii][Tt][Yy][Ff][Ii][Ll][Ee][[:space:]]+([^[:space:]]+) ]]; then
                local identity_file="${BASH_REMATCH[1]}"
                debug "Found IdentityFile: $identity_file"

                local expanded_path="${identity_file/#\~/$HOME}"
                expanded_path=$(realpath -m "$expanded_path")
                debug "Expanded path: $expanded_path"

                # Resolve relative to SSH_DIR if needed
                if [[ "$expanded_path" != "$SSH_DIR"/* ]]; then
                    debug "Path not under SSH_DIR, adjusting"
                    expanded_path="$SSH_DIR/$identity_file"
                fi
                debug "Final expanded path: $expanded_path"

                local rel_path="${expanded_path#$SSH_DIR/}"
                rel_path="${rel_path//../_dotdot_}"
                local store_path="ssh/$host/$rel_path"
                local tmp_key="$tmp_dir/$(basename "$identity_file")"
                debug "Store path: $store_path"
                debug "Temporary key path: $tmp_key"

                # Restore key to temporary location
                if pass show "$store_path" >"$tmp_key" 2>/dev/null; then
                    chmod 600 "$tmp_key"
                    debug "Restored key $store_path to $tmp_key"
                    # Update config to use temporary key
                    debug "Updating config to use temporary key"
                    debug "Replacing: $identity_file"
                    debug "With: $tmp_key"
                    sed -i "s|${identity_file}|${tmp_key}|g" "$tmp_config"
                else
                    debug "Failed to retrieve key from $store_path"
                    echo "Warning: Key $store_path not found in pass"
                fi
            fi
        done <<<"$host_block"

        debug "Finished processing host: $host"
        debug "Current temporary config contents:"
        debug "$(cat "$tmp_config")"
    }

    # Process the main host and its dependencies
    process_host "$hostname"

    # Execute SSH command with temporary config
    echo "Connecting to $hostname..."
    debug "Running: ssh -F \"$tmp_config\" \"$hostname\""
    ssh -F "$tmp_config" "$hostname"
}

# Main command handler
case "$1" in
-v | --verbose)
    VERBOSE=1
    debug "Verbose mode enabled"
    shift
    ;;
esac

case "$1" in
import)
    shift
    cmd_import_with_deps "$@"
    ;;
import-all)
    shift
    cmd_import_all
    ;;
export)
    shift
    cmd_export "$@"
    ;;
export-all)
    shift
    cmd_export_all
    ;;
connect)
    shift
    cmd_connect "$@"
    ;;
*) die "Usage: pass ssh [-v|--verbose] import|import-all|export|export-all|connect [hostname]" ;;
esac
