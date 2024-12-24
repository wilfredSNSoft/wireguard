#!/bin/bash

# Define the directory to scan (e.g., /etc/wireguard/)
config_directory="/etc/wireguard"
backup_directory_wg0="/etc/wireguard/backups/wg0"  # Backup directory for wg0 configuration files
backup_directory_user="/etc/wireguard/backups/user"  # Backup directory for user configuration files

# Create the backup directory if it doesn't exist
mkdir -p "$backup_directory_wg0"
mkdir -p "$backup_directory_user"

# Function to extract IP address from the configuration file
extract_ip_from_file() {
    local file=$1
    # Extract the IP address associated with the Address field (assuming it's in the format Address = <IP>/xx)
    ip_address=$(grep -oP '^Address\s*=\s*\K(\d+\.\d+\.\d+\.\d+)' "$file")
    echo "$ip_address"
}

# Ask user for filenames (space-separated, e.g., e113)
while true; do
    read -p "Enter the filenames you want to delete (space-separated, e.g., e113 e114): " filenames
    
    # Split the input into an array and check each file
    valid_files=()
    invalid_files=()

    for file in $filenames; do
        full_file_path="$config_directory/$file.conf"  # Append .conf to the file name
        if [ -f "$full_file_path" ]; then
            valid_files+=("$full_file_path")
        else
            invalid_files+=("$file")
        fi
    done

    if [ ${#valid_files[@]} -gt 0 ]; then
        echo "Valid filenames: ${valid_files[@]}"
        break  # Exit the loop if valid filenames were entered
    else
        echo "No valid files were entered. Please enter valid filenames."
    fi
done

# Define the path to the new configuration file
config_file="/etc/wireguard/wg0.conf"  # Path to the WireGuard configuration file

# Create a backup of the wg0.conf file before making any changes
timestamp=$(date +'%Y%m%d%H%M')

backup_file="$backup_directory_wg0/wg0.conf.backup.$timestamp"

echo "Creating a backup of $config_file at $backup_file..."
cp "$config_file" "$backup_file"
if [ $? -eq 0 ]; then
    echo "Backup of wg0.conf created successfully."
else
    echo "Failed to create backup for wg0.conf"
    exit 1
fi

# Iterate over each valid file and process it
for file in "${valid_files[@]}"; do
    echo "Processing file: $file"
    
    # Extract the IP address from the current file (e.g., w113.conf)
    ip_address=$(extract_ip_from_file "$file")
    
    if [ -z "$ip_address" ]; then
        echo "No IP address found in the file: $file"
        continue
    else
        echo "Found IP address: $ip_address in file $file"
    fi

    # Extract only the filename from the full path to create a proper backup path
    filename=$(basename "$file")

    # Backup the user configuration file (e.g., w113.conf)
    user_backup_file="$backup_directory_user/$filename.conf.backup.$timestamp"
    echo "Creating a backup of $file at $user_backup_file..."
    cp "$file" "$user_backup_file"
    
    # Check if the backup was successful
    if [ $? -eq 0 ]; then
        echo "Backup of $file created successfully."
    else
        echo "Failed to create backup for $file"
        exit 1
    fi

    # Search the config file for the IP address and get the line number of the match
    line_num=$(grep -n "$ip_address" "$config_file" | cut -d: -f1)

    if [ -z "$line_num" ]; then
        echo "No matching entry found for IP address: $ip_address"
    else
        echo "Matching entry found at line number: $line_num"
        
        # Calculate the line range (2 lines above and the matching line)
        start_line=$((line_num - 2))
        end_line=$line_num

        # Prompt for user confirmation to delete the IP and its 2 preceding lines
        read -p "Are you sure you want to delete the IP address $ip_address and its 2 preceding lines from $config_file? (yes/no): " confirmation
        if [[ "$confirmation" =~ ^[Yy][Ee][Ss]$ ]]; then
            # Create a temporary file to store the updated content
            temp_file=$(mktemp)

            # Use sed to delete the lines: 2 lines above and the line with the IP
            sed "${start_line},${end_line}d" "$config_file" > "$temp_file"

            # Replace the original file with the updated file
            mv "$temp_file" "$config_file"

            echo "Removed the IP address $ip_address and its 2 preceding lines from $config_file."
        else
            echo "Operation canceled for $ip_address. No changes were made."
        fi
    fi

    # Now, let's confirm file deletion
    read -p "Do you want to delete the configuration file $file? (yes/no): " delete_confirmation
    if [[ "$delete_confirmation" =~ ^[Yy][Ee][Ss]$ ]]; then
        # Delete the file
        rm "$file"
        echo "Deleted the file: $file"
    else
        echo "Skipped deletion of $file."
    fi
done

# Restart WireGuard to apply changes
sh /root/wireguardRestart.sh
echo "
Restarting WireGuard service...
WireGuard service restarted successfully.
Script completed successfully.
"
