#!/bin/bash

echo ">>> Nexus Node Auto Installer by MrVooDoo <<<"

# 1) Root kontrolü
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use: sudo bash install.sh)"
  exit
fi

# 2) Paket güncelle
apt update -y

# 3) Gerekli paketleri kur
echo ">>> Installing required packages..."
apt install -y build-essential gcc make pkg-config libssl-dev protobuf-compiler \
               curl git clang cmake unzip || { echo "❌ Package installation failed!"; exit 1; }

# 4) Rust & Cargo kontrol
if ! command -v cargo &> /dev/null; then
  echo ">>> Installing Rust..."
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

# 5) Cargo ortamını yükle
if [ -f "$HOME/.cargo/env" ]; then
  source $HOME/.cargo/env
  if ! grep -q ".cargo/env" ~/.bashrc; then
    echo 'source $HOME/.cargo/env' >> ~/.bashrc
  fi
else
  echo "❌ Rust environment not found. Please re-run: source \$HOME/.cargo/env"
  exit 1
fi

rustup default stable

# 6) Repo izinlerini düzelt
USER_NAME=$(logname)
echo ">>> Fixing file permissions for user: $USER_NAME"
chown -R $USER_NAME:$USER_NAME "$(dirname "$(realpath "$0")")"

# 7) Doğru dizine git (Cargo.toml kontrolü)
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
if [ -f "$SCRIPT_DIR/clients/cli/Cargo.toml" ]; then
  cd "$SCRIPT_DIR/clients/cli"
elif [ -f "$SCRIPT_DIR/Cargo.toml" ]; then
  cd "$SCRIPT_DIR"
else
  echo "❌ Cargo.toml not found! Please check your repo."
  exit 1
fi

# 8) Eski build temizle
echo ">>> Cleaning old builds..."
cargo clean

# 9) Derleme
echo ">>> Building Nexus CLI <<<"
cargo build --release -j $(nproc) || { echo "❌ Build failed. Please check errors above."; exit 1; }

# 10) Binary kontrol
if [ ! -f "./target/release/nexus-network" ]; then
  echo "❌ nexus-network binary not found after build!"
  exit 1
fi

# 11) Node ID sor
read -p "Enter your NODEID: " NODEID

# 12) CPU & RAM kontrol
CPU=$(nproc)
RAM=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}')
echo "Detected $CPU cores and ${RAM}GB RAM."
read -p "Threads per task (1-$CPU): " THREADS

if [ "$THREADS" -gt "$RAM" ]; then
  echo "⚠️ Warning: You selected $THREADS threads but system has only ${RAM}GB RAM."
  echo "Recommended: 1GB RAM per thread."
fi

# 13) Zorluk seçimi
echo "Select difficulty level:"
echo "1) SMALL"
echo "2) SMALL_MEDIUM"
echo "3) MEDIUM"
echo "4) LARGE (default)"
echo "5) EXTRA_LARGE"
echo "6) EXTRA_LARGE_2"
read -p "Choice [1-6]: " choice

case $choice in
  1) DIFF="SMALL" ;;
  2) DIFF="SMALL_MEDIUM" ;;
  3) DIFF="MEDIUM" ;;
  4|"") DIFF="LARGE" ;;
  5) DIFF="EXTRA_LARGE" ;;
  6) DIFF="EXTRA_LARGE_2" ;;
  *) echo "Invalid choice, defaulting to LARGE"; DIFF="LARGE" ;;
esac

# 14) Node başlat
echo ">>> Starting Nexus Node with difficulty: $DIFF <<<"
./target/release/nexus-network start --node-id $NODEID --max-threads 1 --per-task-threads $THREADS --max-difficulty $DIFF
