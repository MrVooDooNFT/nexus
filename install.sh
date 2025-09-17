#!/bin/bash

echo ">>> Nexus Node Installer by MrVooDoo <<<"

# 1) Root yetkisi kontrol
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (use: sudo bash install.sh)"
  exit
fi

# 2) Sistem paketleri
apt update
apt install -y build-essential gcc make pkg-config libssl-dev protobuf-compiler \
               curl git clang cmake unzip exfat-fuse exfat-utils

# 3) Rust kurulumu
if ! command -v rustc &> /dev/null; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source $HOME/.cargo/env
  rustup default stable
fi

# 4) Derleme
cd "$(dirname "$0")/clients/cli"
cargo build --release -j $(nproc)

# 5) Node ID sor
read -p "Enter your NODEID: " NODEID

# 6) CPU çekirdek sayısı
CPU=$(nproc)
echo "Detected $CPU cores."
read -p "Threads per task (1-$CPU): " THREADS

# RAM kontrol (1 GB = 1 Thread kuralı)
RAM=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}')
if [ "$THREADS" -gt "$RAM" ]; then
  echo "⚠️ Warning: You selected $THREADS threads but system has only ${RAM}GB RAM."
  echo "Recommended: Threads <= RAM size (1GB RAM per thread)."
fi

# 7) Zorluk seviyesi menüsü (default LARGE)
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
  4|"") DIFF="LARGE" ;;   # boş bırakılırsa LARGE
  5) DIFF="EXTRA_LARGE" ;;
  6) DIFF="EXTRA_LARGE_2" ;;
  *) echo "Invalid choice, defaulting to LARGE"; DIFF="LARGE" ;;
esac

# 8) Başlat
echo ">>> Starting Nexus Node with difficulty: $DIFF <<<"
./target/release/nexus-network start --node-id $NODEID --max-threads 1 --per-task-threads $THREADS --max-difficulty $DIFF
