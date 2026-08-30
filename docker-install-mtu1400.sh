#!/bin/bash
set -e
echo "=== Actualizando sistema ==="
sudo apt update
sudo apt upgrade -y
echo "=== Eliminando versiones antiguas de Docker ==="
sudo apt remove -y docker docker-engine docker.io containerd runc || true
echo "=== Instalando dependencias ==="
sudo apt install -y ca-certificates curl gnupg lsb-release
echo "=== Configurando repositorio oficial de Docker ==="
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
echo "=== Instalando Docker ==="
sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin
echo "=== Configurando MTU de Docker en 1400 ==="
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "mtu": 1400
}
EOF
echo "=== Reiniciando Docker ==="
sudo systemctl enable docker
sudo systemctl restart docker
echo "=== Verificando Docker ==="
sudo docker run --rm hello-world
echo "=== Agregando usuario al grupo docker ==="
sudo usermod -aG docker "$USER"
echo
echo "=============================================="
echo " Docker instalado correctamente"
echo " MTU configurado: 1400"
echo "=============================================="
echo
echo "IMPORTANTE:"
echo "Cerrá sesión y volvé a ingresar para poder"
echo "usar Docker sin sudo."

echo
