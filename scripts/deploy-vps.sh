#!/bin/sh
# Colmeia Hub — Script de instalação e implantação nativa em VPS Linux (sem Docker).
# Compila e configura o binário `colmeia-hub` como um serviço nativo do sistema (systemd).

set -e

PORT="${PORT:-9620}"
HUB_DIR="${HUB_DIR:-/var/lib/colmeia}"
SERVICE_FILE="/etc/systemd/system/colmeia-hub.service"

echo "=== Implantação Nativa do Colmeia Hub em VPS Linux ==="
echo "Porta: $PORT"
echo "Diretório de dados: $HUB_DIR"

# 1. Compilar o binário em modo Release
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

echo "\n[1/3] Compilando colmeia-hub e colmeia CLI em modo Release..."
swift build -c release --product colmeia-hub
swift build -c release --product colmeia

BIN_PATH=$(swift build -c release --product colmeia-hub --show-bin-path)/colmeia-hub
CLI_PATH=$(swift build -c release --product colmeia --show-bin-path)/colmeia

if [ ! -f "$BIN_PATH" ]; then
    echo "Erro: binário $BIN_PATH não foi encontrado."
    exit 1
fi

echo "Binário Hub: $BIN_PATH"
echo "Binário CLI: $CLI_PATH"

# 2. Criar usuário de sistema e diretórios se não existirem
echo "\n[2/3] Configurando diretórios de persistência e binários..."
sudo mkdir -p "$HUB_DIR"
sudo mkdir -p /usr/local/bin

sudo systemctl stop colmeia-hub || true
sudo cp -f "$BIN_PATH" /usr/local/bin/colmeia-hub
sudo chmod +x /usr/local/bin/colmeia-hub

if [ -f "$CLI_PATH" ]; then
    sudo cp -f "$CLI_PATH" /usr/local/bin/colmeia
    sudo chmod +x /usr/local/bin/colmeia
fi

# 3. Gerar arquivo de serviço Systemd
echo "\n[3/3] Criando serviço systemd em $SERVICE_FILE..."

sudo tee "$SERVICE_FILE" > /dev/null <<EOF
[Unit]
Description=Colmeia Hub — Servidor de Colaboração Multiplayer
After=network.target

[Service]
Type=simple
User=colmeia
ExecStart=/usr/local/bin/colmeia-hub --port $PORT
Restart=always
RestartSec=5
Environment=COLMEIA_ROOT=$HUB_DIR
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable colmeia-hub
sudo systemctl restart colmeia-hub

echo "\n======================================================="
echo "✅ Colmeia Hub implantado com sucesso!"
echo "Status do serviço: sudo systemctl status colmeia-hub"
echo "Logs ao vivo:      sudo journalctl -u colmeia-hub -f"
echo "======================================================="
echo "\nPara configurar WSS (WebSocket seguro com SSL) com NGINX:"
echo "Adicione ao seu NGINX (/etc/nginx/sites-available/colmeia):"
echo ""
echo "server {"
echo "    listen 443 ssl;"
echo "    server_name hub.seudominio.com;"
echo ""
echo "    ssl_certificate /etc/letsencrypt/live/hub.seudominio.com/fullchain.pem;"
echo "    ssl_certificate_key /etc/letsencrypt/live/hub.seudominio.com/privkey.pem;"
echo ""
echo "    location / {"
echo "        proxy_pass http://127.0.0.1:$PORT;"
echo "        proxy_http_version 1.1;"
echo "        proxy_set_header Upgrade \$http_upgrade;"
echo "        proxy_set_header Connection \"Upgrade\";"
echo "        proxy_set_header Host \$host;"
echo "    }"
echo "}"
