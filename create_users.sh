#!/usr/bin/env bash
#
# ================================================================
#  Project: User Management Automation (SysOps Challenge)
#  Script Name: create_users.sh
#
#  Description:
#  This script automates user account setup on Linux systems.
#  It reads a formatted text file that contains:
#
#      username; group1,group2,group3
#
#  The script performs the following:
#    1. Reads usernames and group names from the input file.
#    2. Skips blank lines and comments (#).
#    3. Creates a primary group with the same name as the username.
#    4. Adds users to additional groups.
#    5. Creates a home directory (if missing).
#    6. Sets secure permissions for home directories.
#    7. Generates random 12-character passwords.
#    8. Saves credentials securely in /var/secure/.
#    9. Logs all actions and errors to /var/log/.
# ================================================================

# -------------------------
# CONFIGURATION VARIABLES
# -------------------------
INPUT_FILE="$1"                                # Input file provided as argument
PASSWORD_STORE=""/var/secure/user_passwords.txt"" # File to store username:password pairs
LOG_FILE="/var/log/user_management.log"         # File to log all operations
PASSWORD_LENGTH=12                              # Random password length

# -------------------------
# LOGGING FUNCTIONS
# -------------------------
# Logs messages with timestamps and levels (INFO, WARN, ERROR)
log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "$ts [$level] $msg" | tee -a "$LOG_FILE"
}
info()  { log "INFO"  "$*"; }
warn()  { log "WARN"  "$*"; }
error() { log "ERROR" "$*"; }

# -------------------------
# UTILITY FUNCTIONS
# -------------------------
# Removes whitespace from both ends of a string
trim() { echo "$1" | xargs; }

# Generates a random alphanumeric password
generate_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c"$PASSWORD_LENGTH"
}

# Ensures secure directories and files exist for password and log storage
ensure_files() {
  mkdir -p "$(dirname "$PASSWORD_STORE")" "$(dirname "$LOG_FILE")"
  [ -f "$PASSWORD_STORE" ] || : > "$PASSWORD_STORE"
  [ -f "$LOG_FILE" ] || : > "$LOG_FILE"
  chmod 600 "$PASSWORD_STORE" "$LOG_FILE"
  chown root:root "$PASSWORD_STORE" "$LOG_FILE"
}

# -------------------------
# SYSTEM HELPER FUNCTIONS
# -------------------------
user_exists()  { id "$1" >/dev/null 2>&1; }
group_exists() { getent group "$1" >/dev/null 2>&1; }

# Creates a group if it doesn’t exist
add_group_if_missing() {
  local g="$1"
  [ -z "$g" ] && return
  if group_exists "$g"; then
    info "Group '$g' already exists"
  else
    groupadd "$g" && info "Created group '$g'" || error "Failed to create group '$g'"
  fi
}

# -------------------------
# CREATE OR UPDATE USER FUNCTION
# -------------------------
add_or_update_user() {
  local username="$1"
  local extra_groups_csv="$2"

  # Ensure a primary group with the same name exists
  add_group_if_missing "$username"

  # Check if user already exists
  if user_exists "$username"; then
    info "User '$username' already exists — updating groups"
    [ -n "$extra_groups_csv" ] && usermod -a -G "$extra_groups_csv" "$username"
  else
    # Create user and add to groups
    if [ -n "$extra_groups_csv" ]; then
      useradd -m -s /bin/bash -g "$username" -G "$extra_groups_csv" "$username" \
        && info "Created user '$username' with groups ($extra_groups_csv)"
    else
      useradd -m -s /bin/bash -g "$username" "$username" \
        && info "Created user '$username' (no additional groups)"
    fi
  fi

  # Create home directory and set permissions
  local home="/home/$username"
  mkdir -p "$home"
  chown "$username:$username" "$home"
  chmod 700 "$home"
  info "Home directory set with correct ownership and permissions for '$username'"

  # Generate and set password
  local password
  password="$(generate_password)"
  echo "${username}:${password}" | chpasswd
  info "Password assigned to user '$username'"

  # Save credentials securely
  echo "${username}:${password}  # $(date '+%Y-%m-%d %H:%M:%S')" >> "$PASSWORD_STORE"
  info "Credentials stored securely in $PASSWORD_STORE"
}

# -------------------------
# MAIN EXECUTION
# -------------------------
# Ensure script runs as root
if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

# Ensure input file is provided
if [ -z "$INPUT_FILE" ]; then
  echo "Usage: $0 /path/to/user_list.txt" >&2
  exit 2
fi

# Ensure input file exists
if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: Input file not found: $INPUT_FILE" >&2
  exit 3
fi

# Prepare secure directories and files
ensure_files
info "Starting user import from '$INPUT_FILE'"

# Read file line-by-line
line_no=0
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line_no=$((line_no + 1))
  line="$(trim "${raw_line//$'\xEF\xBB\xBF'/}")"

  # Skip empty or commented lines
  [ -z "$line" ] && info "Line $line_no: Empty — skipped" && continue
  [[ "$line" =~ ^# ]] && info "Line $line_no: Comment — skipped" && continue

  # Check line format
  if ! echo "$line" | grep -q ';'; then
    warn "Line $line_no: Invalid format (missing ';') — skipped"
    continue
  fi

  # Extract username and groups
  username="$(trim "$(echo "$line" | cut -d';' -f1)")"
  groups_raw="$(trim "$(echo "$line" | cut -d';' -f2-)")"

  # Validate username
  [[ ! "$username" =~ ^[a-zA-Z0-9_.-]+$ ]] && warn "Line $line_no: Invalid username '$username' — skipped" && continue

  # Process group list
  IFS=',' read -ra groups_arr <<< "$groups_raw"
  clean_groups=()
  for g in "${groups_arr[@]}"; do
    g="$(trim "$g")"
    [ -n "$g" ] && clean_groups+=("$g")
  done

  # Ensure all listed groups exist
  for g in "${clean_groups[@]}"; do add_group_if_missing "$g"; done

  # Combine group list for user creation
  extra_csv="$(IFS=','; echo "${clean_groups[*]}")"

  # Create or update user
  add_or_update_user "$username" "$extra_csv"

  echo "Created or updated user: $username"
  # Add visual separation in console output
  echo "-------------------------------------------------------------"
done < "$INPUT_FILE"

info "User import completed successfully"
exit 0
