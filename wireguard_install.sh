#!/bin/bash

#判断系统
if [ ! -e '/etc/redhat-release' ]; then
echo "仅支持centos7"
exit
fi
if  [ -n "$(grep ' 6\.' /etc/redhat-release)" ] ;then
echo "仅支持centos7"
exit
fi



#更新内核
update_kernel(){

    yum -y install epel-release curl
    sed -i "0,/enabled=0/s//enabled=1/" /etc/yum.repos.d/epel.repo
    yum remove -y kernel-devel
    rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
    rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-2.el7.elrepo.noarch.rpm
    yum --disablerepo="*" --enablerepo="elrepo-kernel" list available
    yum -y --enablerepo=elrepo-kernel install kernel-ml
    sed -i "s/GRUB_DEFAULT=saved/GRUB_DEFAULT=0/" /etc/default/grub
    grub2-mkconfig -o /boot/grub2/grub.cfg
    wget https://elrepo.org/linux/kernel/el7/x86_64/RPMS/kernel-ml-devel-4.19.1-1.el7.elrepo.x86_64.rpm
    rpm -ivh kernel-ml-devel-4.19.1-1.el7.elrepo.x86_64.rpm
    yum -y --enablerepo=elrepo-kernel install kernel-ml-devel
    read -p "需要重启VPS，再次执行脚本选择安装wireguard，是否现在重启 ? [Y/n] :" yn
	[ -z "${yn}" ] && yn="y"
	if [[ $yn == [Yy] ]]; then
		echo -e "VPS 重启中..."
		reboot
	fi
}

#生成随机端口
rand(){
    min=$1
    max=$(($2-$min+1))
    num=$(cat /dev/urandom | head -n 10 | cksum | awk -F ' ' '{print $1}')
    echo $(($num%$max+$min))  
}

wireguard_update(){
    yum update -y wireguard-dkms wireguard-tools
    echo "更新完成"
}

wireguard_remove(){
    wg-quick down wg0
    yum remove -y wireguard-dkms wireguard-tools
    rm -rf /etc/wireguard/
    echo "卸载完成"
}

config_client(){
cat > /etc/wireguard/client.conf <<-EOF
[Interface]
PrivateKey = $c1
Address = 10.77.77.2/32
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $s2
Endpoint = $serverip:$port
AllowedIPs = 0.0.0.0/0, ::0/0
PersistentKeepalive = 25
EOF

}

#centos7安装wireguard
wireguard_install(){
    curl -Lo /etc/yum.repos.d/wireguard.repo https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo
    yum install -y dkms gcc-c++ gcc-gfortran glibc-headers glibc-devel libquadmath-devel libtool systemtap systemtap-devel
    yum -y install wireguard-dkms wireguard-tools
    yum -y install qrencode
    mkdir /etc/wireguard
    cd /etc/wireguard
    wg genkey | tee sprivatekey | wg pubkey > spublickey
    wg genkey | tee cprivatekey | wg pubkey > cpublickey
    s1=$(cat sprivatekey)
    s2=$(cat spublickey)
    c1=$(cat cprivatekey)
    c2=$(cat cpublickey)
    serverip=$(curl ipv4.icanhazip.com)
    port=$(rand 10000 60000)
    eth=$(ls /sys/class/net | grep e | head -1)
    chmod 777 -R /etc/wireguard
    systemctl stop firewalld
    systemctl disable firewalld
    yum install -y iptables-services 
    systemctl enable iptables 
    systemctl start iptables 
    iptables -P INPUT ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F
    service iptables save
    service iptables restart
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p
cat > /etc/wireguard/wg0.conf <<-EOF
[Interface]
PrivateKey = $s1
Address = 10.77.0.1/16 
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -I FORWARD -s 10.77.77.1/24 -d 10.77.77.1/24 -j DROP; iptables -t nat -A POSTROUTING -o $eth -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -D FORWARD -s 10.77.77.1/24 -d 10.77.77.1/24 -j DROP; iptables -t nat -D POSTROUTING -o $eth -j MASQUERADE
ListenPort = $port
DNS = 8.8.8.8
MTU = 1420

[Peer]
PublicKey = $c2
AllowedIPs = 10.77.77.2/32
EOF

    config_client
    wg-quick up wg0
    systemctl enable wg-quick@wg0
    content=$(cat /etc/wireguard/client.conf)
    echo "电脑端请下载client.conf，手机端可直接使用软件扫码"
    echo "${content}" | qrencode -o - -t UTF8
}
add_user(){
    echo -e "\033[37;41m给新用户起个名字，不能和已有用户重复\033[0m"
    read -p "请输入用户名：" newname
    cd /etc/wireguard/
    cp client.conf $newname.conf
    wg genkey | tee temprikey | wg pubkey > tempubkey
    ipnum=$(grep Allowed /etc/wireguard/wg0.conf | tail -1 | awk -F '[ ./]' '{print $6}')
    newnum=$((10#${ipnum}+1))
    sed -i 's%^PrivateKey.*$%'"PrivateKey = $(cat temprikey)"'%' $newname.conf
    sed -i 's%^Address.*$%'"Address = 10.77.77.$newnum\/32"'%' $newname.conf

cat >> /etc/wireguard/wg0.conf <<-EOF
[Peer]
PublicKey = $(cat tempubkey)
AllowedIPs = 10.77.77.$newnum/32
EOF
    wg set wg0 peer $(cat tempubkey) allowed-ips 10.77.77.$newnum/32
    echo -e "\033[37;41m添加完成，文件：/etc/wireguard/$newname.conf\033[0m"
    rm -f temprikey tempubkey
}
add_multipleUser(){
    # Disable history expansion globally
    set +H
    # Enable extended globbing
    shopt -s extglob
    
    # Clear previous files for sftp
    rm -rf /etc/wireguard/sftp/*
    rmdir /etc/wireguard/sftp
    mkdir /etc/wireguard/sftp

    echo -e "\033[37;41m给新用户起个名字，不能和已有用户重复（用分号;分隔多个用户名）\033[0m"
    echo -e "\033[37;41mNew created username cannot be repeated with existed confile file name (use ; to create multiple user, example, test;test1;test2) \033[0m"
    read -p "请输入用户名 / Please input username：" user_input

    # Split the input string by semicolons
    IFS=';' read -r -a usernames <<< "$user_input"

    cd /etc/wireguard/ || { echo "Failed to change directory to /etc/wireguard/"; exit 1; }

    ipnum=$(grep -oP 'AllowedIPs\s*=\s*\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' /etc/wireguard/wg0.conf | tail -1)
    if [ -z "$ipnum" ]; then
        ipnum="10.77.77.1"
    fi

    # Loop through each username
    for newname in "${usernames[@]}"; do
        newname=$(echo "$newname" | xargs) # Remove any leading/trailing whitespace
        newname="${newname}113"
        if [ -z "$newname" ]; then
            echo "用户名为空，跳过..."
            continue
        fi
        if [ -f "$newname.conf" ]; then
            echo "配置文件 $newname.conf 已存在，跳过..."
            continue
        fi

        local key_dir="/etc/wireguard/wireguard_keys"
        mkdir -p "$key_dir"
        wg genkey | tee "/etc/wireguard/wireguard_keys/${newname}_temprikey" | wg pubkey > "/etc/wireguard/wireguard_keys/${newname}_tempubkey"

        subnet=$(echo $ipnum | awk -F'.' '{print $1 "." $2 "." $3}')
        last_octet=$(echo $ipnum | awk -F'.' '{print $4}')

        if ! [[ "$last_octet" =~ ^[0-9]+$ ]]; then
            echo "Invalid IP address detected: $ipnum. Skipping user creation for $newname."
            continue
        fi

        if [ "$last_octet" -eq 255 ]; then
            subnet=$(echo $subnet | awk -F'.' '{print $1 "." $2 "." $3+1}')
            ipnum="${subnet}.1"
        else
            ipnum="${subnet}.$((last_octet + 1))"
        fi

        cp client.conf "$newname.conf"
        sed -i 's%^PrivateKey.*$%'"PrivateKey = $(cat "/etc/wireguard/wireguard_keys/${newname}_temprikey")"'%' "$newname.conf"
        sed -i 's%^Address.*$%'"Address = $ipnum/32"'%' "$newname.conf"

        cat >> /etc/wireguard/wg0.conf <<-EOF

[Peer]
PublicKey = $(cat "/etc/wireguard/wireguard_keys/${newname}_tempubkey")
AllowedIPs = $ipnum/32
EOF

        # Update WireGuard with new peer
        wg set wg0 peer $(cat "/etc/wireguard/wireguard_keys/${newname}_tempubkey") allowed-ips $ipnum/32
        echo -e "\033[37;41m添加完成，文件：/etc/wireguard/$newname.conf\033[0m"

        # Clean up temporary files
        rm -rf /etc/wireguard/wireguard_keys/*
        rmdir /etc/wireguard/wireguard_keys

        cp /etc/wireguard/"$newname".conf /etc/wireguard/sftp/"$newname".conf

        # Run rm command with extended globbing in a subshell to ensure proper interpretation of the pattern
        (
            # Enable extglob in the subshell, just in case
            shopt -s extglob

            # The globbing pattern to remove unwanted files
            rm -fv !(sprivatekey|spublickey|others|sftp|dev|cs|backups|cprivatekey|cpublickey|client.conf|wg0.conf)
        )
    done
}


categorized(){
    mkdir /etc/wireguard/cs
    mkdir /etc/wireguard/dev
    mkdir /etc/wireguard/others

    clear
    echo "1. CS"
    echo "2. Dev"
    echo "3. Others"
    echo

    read -p "Input Choices: " dept
    case "$dept" in

    1)
        add_multipleUser
        cp /etc/wireguard/sftp/* /etc/wireguard/cs
    ;;
    2)
        add_multipleUser
        cp /etc/wireguard/sftp/* /etc/wireguard/dev
    ;;
    3)
        add_multipleUser
        cp /etc/wireguard/sftp/* /etc/wireguard/others
    ;;
    esac
}

remove_user(){
    # Define the directory to scan (e.g., /etc/wireguard/)
    config_directory="/etc/wireguard"
    backup_directory_wg0="/etc/wireguard/backups/wg0"  # Backup directory for wg0 configuration files
    backup_directory_user="/etc/wireguard/backups/user"  # Backup directory for user configuration files

    # Create the backup directories if they don't exist
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
        read -p "Enter the filenames you want to delete (space-separated, e.g., alex113 abc113): " filenames
        
        # Split the input into an array and check each file
        valid_files=()
        invalid_files=()

        for file in $filenames; do
            # Use find to search for the file recursively in the config_directory
            # This will handle multiple results correctly and return the full file paths
            while IFS= read -r full_file_path; do
                valid_files+=("$full_file_path")
            done < <(find "$config_directory" -type f -name "$file.conf" 2>/dev/null)

            # If no valid file is found, add it to invalid_files
            if [ ${#valid_files[@]} -eq 0 ]; then
                invalid_files+=("$file")
            fi
        done

        # If we have valid files, break out of the loop
        if [ ${#valid_files[@]} -gt 0 ]; then
            echo "Valid filenames: ${valid_files[@]}"
            break  # Exit the loop if valid filenames were entered
        else
            echo "No valid files were entered. Please enter valid filenames."
        fi
    done


    # Define the path to the wg0 configuration file
    config_file="/etc/wireguard/wg0.conf"

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
        
        # Extract the IP address from the current file
        ip_address=$(extract_ip_from_file "$file")
        
        if [ -z "$ip_address" ]; then
            echo "No IP address found in the file: $file"
            continue
        else
            echo "Found IP address: $ip_address in file $file"
        fi

        # Extract only the filename from the full path to create a proper backup path
        filename=$(basename "$file")

        # Backup the user configuration file
        user_backup_file="$backup_directory_user/$filename.conf.backup.$timestamp"
        echo "Creating a backup of $file at $user_backup_file..."
        cp "$file" "$user_backup_file"
        
        if [ $? -eq 0 ]; then
            echo "Backup of $file created successfully."
        else
            echo "Failed to create backup for $file"
            exit 1
        fi

        # Search the wg0.conf file for the IP address and get the line number of the match
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

        # Confirm file deletion
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
    if [ -x "/root/wireguardRestart.sh" ]; then
        sh /root/wireguardRestart.sh
        echo "
    Restarting WireGuard service...
    WireGuard service restarted successfully.
    Script completed successfully.
    "
    else
        echo "WireGuard restart script not found or not executable. Please restart WireGuard manually."
    fi
}

#开始菜单
start_menu(){
    clear
    echo "========================="
    echo " 介绍：适用于CentOS7"
    echo " 作者：A"
    echo "========================="
    #echo "1. 升级系统内核"
    #echo "2. 安装wireguard"
    #echo "3. 升级wireguard"
    #echo "4. 卸载wireguard"
    echo "1. 显示客户端二维码 / Generate QR code (Incomplete)"
    #echo "6. 增加用户"
    echo "2. 增加多用户 / Create User "
    echo "3. 删除用户 / Delete User "
    echo "0. 退出脚本"
    echo
    read -p "请输入数字 / Input choices:" num
    case "$num" in
    #1)
	#update_kernel
	#;;
	#2)
	#wireguard_install
	#;;
	#3)
	#wireguard_update
	#;;
	#4)
	#wireguard_remove
	#;;
	1)
	content=$(cat /etc/wireguard/client.conf)
    	echo "${content}" | qrencode -o - -t UTF8
	;;
	#6)
	#add_user
	#;;
	2)
	categorized
	;;
    3)
    remove_user
    ;;
	0)
	exit 1
	;;
	*)
	clear
	echo "请输入正确数字"
    echo "Please Enter a valid number"
	sleep 1s
	start_menu
	;;
    esac
}

start_menu



