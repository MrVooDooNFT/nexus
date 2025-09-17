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

# 7) Başlat
./target/release/nexus-network start --node-id $NODEID --max-threads 1 --per-task-threads $THREADS --max-difficulty extra_large_2
