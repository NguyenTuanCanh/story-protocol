#!/bin/bash

# Function to verify if a command is available
command_exists() {
  command -v "$1" &> /dev/null
}

# Function to install a package if it's not present
install_package_if_needed() {
  if ! command_exists "$1"; then
    echo -e "\033[33mInstalling $1...\033[0m"
    sudo apt update && sudo apt install -y "$1" < "/dev/null"
  fi
}

# Ensure curl and figlet are installed
install_package_if_needed curl
install_package_if_needed figlet

# Source the .bash_profile if it exists
[ -f "$HOME/.bash_profile" ] && . "$HOME/.bash_profile"

# Show banner with figlet
figlet Story Protocol

# Define color codes
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[1;34m'
COLOR_RESET='\033[0m'

# Check the Ubuntu version (must be 22.04 or higher)
ubuntu_version=$(lsb_release -r | awk '{print $2}' | sed 's/\.//')
required_version=2204
if [ "$ubuntu_version" -lt "$required_version" ]; then
  echo -e "${COLOR_RED}Current Ubuntu Version: $(lsb_release -r | awk '{print $2}').${COLOR_RESET}"
  echo -e "${COLOR_RED}Minimum required Ubuntu version: 22.04 or higher.${COLOR_RESET}"
  exit 1
fi

# Set up DAEMON and service paths
SERVICE_NAME="story"
DAEMON_PATH="$HOME/.story/story"
BINARY_NAME="story"
if [ -d "$DAEMON_PATH" ]; then
  backup_dir="${DAEMON_PATH}_backup_$(date +'%Y%m%d_%H%M%S')"
  mv "$DAEMON_PATH" "$backup_dir"
fi

# Prompt for validator name if not already set
if [ -z "$VALIDATOR" ]; then
  read -p "Enter validator name: " VALIDATOR
  echo "export VALIDATOR='$VALIDATOR'" >> "$HOME/.bash_profile"
fi

# Update bash profile and apply changes
echo 'source $HOME/.bashrc' >> "$HOME/.bash_profile"
. "$HOME/.bash_profile"
sleep 1

# Install necessary dependencies
cd "$HOME"
echo -e "\n\033[42mInstalling required packages...\033[0m" && sleep 1
sudo apt update
sudo apt install make unzip clang pkg-config lz4 libssl-dev build-essential git jq ncdu bsdmainutils htop -y < "/dev/null"

# Install Go
GO_VERSION=1.23.0
echo -e "\n\033[42mInstalling Go version $GO_VERSION...\033[0m\n" && sleep 1
wget -O go.tar.gz "https://go.dev/dl/go$GO_VERSION.linux-amd64.tar.gz"
sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf go.tar.gz && rm go.tar.gz
echo 'export GOROOT=/usr/local/go' >> "$HOME/.bash_profile"
echo 'export GOPATH=$HOME/go' >> "$HOME/.bash_profile"
echo 'export GO111MODULE=on' >> "$HOME/.bash_profile"
echo 'export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin' >> "$HOME/.bash_profile"
. "$HOME/.bash_profile"
go version

# Install Story software
echo -e "\n\033[42mSetting up Story software...\033[0m\n" && sleep 1

cd "$HOME"
rm -rf story

wget -O story-linux-amd64-0.10.1-57567e5.tar.gz "https://story-geth-binaries.s3.us-west-1.amazonaws.com/story-public/story-linux-amd64-0.10.1-57567e5.tar.gz"
tar -xvf story-linux-amd64-0.10.1-57567e5.tar.gz
sudo chmod +x story-linux-amd64-0.10.1-57567e5/story
sudo mv story-linux-amd64-0.10.1-57567e5/story /usr/local/bin/
story version

# Install Story Geth software
cd "$HOME"
rm -rf story-geth

wget -O geth-linux-amd64-0.9.3-b224fdf.tar.gz "https://story-geth-binaries.s3.us-west-1.amazonaws.com/geth-public/geth-linux-amd64-0.9.3-b224fdf.tar.gz"
tar -xvf geth-linux-amd64-0.9.3-b224fdf.tar.gz
sudo chmod +x geth-linux-amd64-0.9.3-b224fdf/geth
sudo mv geth-linux-amd64-0.9.3-b224fdf/geth /usr/local/bin/story-geth

# Initialize the Story daemon
$BINARY_NAME init --network iliad --moniker "$VALIDATOR"
sleep 1
$BINARY_NAME validator export --export-evm-key --evm-key-path "$HOME/.story/.env"
$BINARY_NAME validator export --export-evm-key >>"$HOME/.story/story/config/wallet.txt"
cat "$HOME/.story/.env" >>"$HOME/.story/story/config/wallet.txt"

# Configure systemd services
sudo tee /etc/systemd/system/story-geth.service > /dev/null <<EOF  
[Unit]
Description=Story execution daemon
After=network-online.target

[Service]
User=$USER
ExecStart=/usr/local/bin/story-geth --iliad --syncmode full
Restart=always
RestartSec=3
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/$SERVICE_NAME.service > /dev/null <<EOF  
[Unit]
Description=Story consensus daemon
After=network-online.target

[Service]
User=$USER
WorkingDirectory=$HOME/.story/story
ExecStart=/usr/local/bin/story run
Restart=always
RestartSec=3
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF

# Enable persistent logging
sudo tee /etc/systemd/journald.conf > /dev/null <<EOF
Storage=persistent
EOF

# Check for port conflicts and modify config files if needed
BASE_PORT=335
for default_port in 26656 26657 26658 1317; do
  if ss -tulpen | awk '{print $5}' | grep -q ":${default_port}$"; then
    echo -e "${COLOR_RED}Port $default_port is already in use.${COLOR_RESET}"
    sed -i "s|:${default_port}\"|:${BASE_PORT}${default_port: -2}\"|" "$DAEMON_PATH/config/config.toml"
    echo -e "${COLOR_YELLOW}Changed port $default_port to ${BASE_PORT}${default_port: -2}.${COLOR_RESET}"
    sleep 2
  fi
done

# Restart services
sudo systemctl restart systemd-journald
sudo systemctl daemon-reload
sudo systemctl enable $SERVICE_NAME
sudo systemctl restart $SERVICE_NAME
sudo systemctl enable story-geth
sudo systemctl restart story-geth
sleep 5

# Verify node status
echo -e "\n\033[42mChecking node status...\033[0m\n" && sleep 1
if systemctl status "$SERVICE_NAME" | grep -q "active (running)"; then
  echo -e "Your $SERVICE_NAME node is \033[32mrunning successfully!\033[0m"
  echo -e "Use \033[32mjournalctl -fu $SERVICE_NAME\033[0m to check the logs."
else
  echo -e "Your $SERVICE_NAME node \033[31mfailed to start.\033[0m"
  echo -e "Check logs with \033[32mjournalctl -fu $SERVICE_NAME\033[0m"
fi
