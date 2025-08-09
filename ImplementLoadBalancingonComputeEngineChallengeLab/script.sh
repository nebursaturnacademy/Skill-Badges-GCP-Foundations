#!/bin/bash
# ======================================================================================
#         SCRIPT FINAL - LABORATORIO DE BALANCEO DE CARGA
# ======================================================================================

# --- FASE 0: CONFIGURACIÓN INICIAL ---
# Establecemos la región y la zona para no tener que escribirlas en cada comando.
# Recuerda que debe ser la region y zona que te indica el laboratorio
export REGION="europe-west1"
export ZONE="us-west3-c"

echo "✅ FASE 0: Configurando la región por defecto a $REGION y la zona a $ZONE..."
gcloud config set compute/region $REGION
gcloud config set compute/zone $ZONE


# ======================================================================================
#                             TAREA 1: CREAR INSTANCIAS DE SERVIDOR WEB
# Objetivo: Crear 3 VMs, instalar Apache en ellas y abrir el firewall para el tráfico web.
# ======================================================================================
echo "➡️  INICIANDO TAREA 1: Creando las 3 VMs base (web1, web2, web3)..."

# --- Creación de la VM web1 ---
# Usamos --tags para etiquetar la VM. Esto es crucial para que la regla de firewall sepa a quién aplicar.
# Usamos --metadata=startup-script para instalar Apache automáticamente cuando la VM se enciende.
gcloud compute instances create web1 \
    --zone=$ZONE \
    --machine-type=e2-small \
    --tags=network-lb-tag \
    --image-family=debian-11 \
    --image-project=debian-cloud \
    --metadata=startup-script='#!/bin/bash
      apt-get update
      apt-get install apache2 -y
      service apache2 restart
      echo "<h3>Web Server: web1</h3>" | tee /var/www/html/index.html'

# --- Creación de la VM web2 ---
gcloud compute instances create web2 \
    --zone=$ZONE \
    --machine-type=e2-small \
    --tags=network-lb-tag \
    --image-family=debian-11 \
    --image-project=debian-cloud \
    --metadata=startup-script='#!/bin/bash
      apt-get update
      apt-get install apache2 -y
      service apache2 restart
      echo "<h3>Web Server: web2</h3>" | tee /var/www/html/index.html'

# --- Creación de la VM web3 ---
gcloud compute instances create web3 \
    --zone=$ZONE \
    --machine-type=e2-small \
    --tags=network-lb-tag \
    --image-family=debian-11 \
    --image-project=debian-cloud \
    --metadata=startup-script='#!/bin/bash
      apt-get update
      apt-get install apache2 -y
      service apache2 restart
      echo "<h3>Web Server: web3</h3>" | tee /var/www/html/index.html'

echo "✅ TAREA 1: VMs creadas. Creando regla de firewall..."

# --- Creación de la Regla de Firewall para la Tarea 1 ---
# Esta regla permite el tráfico entrante (ingress) en el puerto TCP 80
# únicamente para las VMs que tengan la etiqueta 'network-lb-tag'.
gcloud compute firewall-rules create www-firewall-network-lb \
    --allow tcp:80 \
    --target-tags network-lb-tag

echo "✅ TAREA 1: Completada."


# ======================================================================================
#                     TAREA 2: CONFIGURAR EL BALANCEADOR DE CARGA DE RED
# Objetivo: Crear un balanceador de carga de red (Capa 4) que distribuya el tráfico
# entre las 3 VMs que acabamos de crear.
# ======================================================================================
echo "➡️  INICIANDO TAREA 2: Creando el Balanceador de Carga de Red..."

# --- 1. Reservar una IP Externa Estática ---
# Le damos un nombre a nuestra IP pública para que no cambie si reiniciamos el balanceador.
gcloud compute addresses create network-lb-ip-1 --region=$REGION

# --- 2. Crear una Comprobación de Estado (Health Check) ---
# El balanceador usará esto para preguntar a las VMs si están "vivas" antes de enviarles tráfico.
gcloud compute http-health-checks create basic-check

# --- 3. Crear el Grupo de Destino (Target Pool) ---
# Este es el grupo de VMs que recibirán el tráfico. Es crucial enlazar la comprobación de estado al crearlo.
gcloud compute target-pools create www-pool \
    --region=$REGION \
    --http-health-check basic-check

# --- 4. Añadir las Instancias al Grupo ---
# Le decimos al grupo cuáles son sus miembros.
gcloud compute target-pools add-instances www-pool \
   --instances=web1,web2,web3 \
    --zone=$ZONE 

# --- 5. Crear la Regla de Reenvío (Forwarding Rule) ---
# Esta es la pieza final que conecta la IP pública (la puerta de entrada) con nuestro grupo de VMs.
gcloud compute forwarding-rules create www-rule \
    --region=$REGION \
    --ports=80 \
    --address=network-lb-ip-1 \
    --target-pool=www-pool

echo "✅ TAREA 2: Completada."


# ======================================================================================
#                    TAREA 3: CREAR EL BALANCEADOR DE CARGA HTTP
# Objetivo: Crear un balanceador de carga de aplicación global (Capa 7), más inteligente y moderno.
# ======================================================================================
echo "➡️  INICIANDO TAREA 3: Creando el Balanceador de Carga HTTP..."

# --- 1. Crear la Plantilla de Instancia (con el script de inicio) ---
# NOTA CLAVE #1: A diferencia de las instrucciones literales, incluimos un script de inicio.
# Como descubrimos, sin un servidor web instalado, las comprobaciones de estado fallan y el sistema no funciona.
# Este script instala Apache y asegura que el sistema sea funcional para el calificador.
gcloud compute instance-templates create lb-backend-template \
    --tags=allow-health-check \
    --machine-type=e2-medium \
    --image-family=debian-11 \
    --image-project=debian-cloud \
    --metadata=startup-script='#!/bin/bash
      apt-get update
      apt-get install apache2 -y
      a2ensite default-ssl
      a2enmod ssl
      vm_hostname="$(curl -H "Metadata-Flavor:Google" http://169.254.169.254/computeMetadata/v1/instance/name)"
      echo "Page served from: $vm_hostname" | tee /var/www/html/index.html
      systemctl restart apache2'

# --- 2. Crear el Grupo de Instancias Administrado (con 2 instancias) ---
# NOTA CLAVE #2: Creamos el grupo con --size=2.
# Las instrucciones de prueba del lab insinúan que se espera una configuración de alta disponibilidad.
gcloud compute instance-groups managed create lb-backend-group \
    --template=lb-backend-template \
    --size=2 \
    --zone=$ZONE

# --- 3. Crear la Regla de Firewall para las Comprobaciones de Estado de Google ---
# Esta regla es específica para permitir que la infraestructura de Google (en esos rangos de IP)
# pueda acceder a nuestras VMs en el puerto 80 para verificar su estado.
gcloud compute firewall-rules create fw-allow-health-check \
    --network=default \
    --action=allow \
    --direction=ingress \
    --source-ranges=130.211.0.0/22,35.191.0.0/16 \
    --target-tags=allow-health-check \
    --rules=tcp:80

# --- 4. Crear los Componentes del Balanceador de Carga Global ---
echo "✅ TAREA 3: Creando los componentes del balanceador (IP, Health Check, Backend...)"
# IP Global: A diferencia del anterior, este balanceador es global, por lo que su IP también lo es.
gcloud compute addresses create lb-ipv4-1 --ip-version=IPV4 --global

# Health Check: Similar al anterior, pero para este nuevo grupo de backends.
gcloud compute health-checks create http http-basic-check --port=80

# Backend Service: Es el "cerebro" del balanceador. Organiza los grupos de instancias y las comprobaciones de estado.
# Usamos --port-name=http para cumplir con los requisitos de este tipo de balanceador.
gcloud compute backend-services create web-backend-service \
    --protocol=HTTP \
    --port-name=http \
    --health-checks=http-basic-check \
    --global

# Añadir Backend: Conectamos nuestro grupo de instancias al "cerebro".
gcloud compute backend-services add-backend web-backend-service \
    --instance-group=lb-backend-group \
    --instance-group-zone=$ZONE \
    --global

# URL Map: Define las reglas de enrutamiento. Para este lab, la regla es simple: todo el tráfico va a nuestro backend.
gcloud compute url-maps create web-map-http \
    --default-service web-backend-service

# Target Proxy: Es el "recepcionista" que recibe el tráfico y consulta el mapa de URL para saber a dónde enviarlo.
gcloud compute target-http-proxies create http-lb-proxy \
    --url-map=web-map-http

# Global Forwarding Rule: La pieza final. Conecta la IP pública global con el "recepcionista".
gcloud compute forwarding-rules create http-content-rule \
    --address=lb-ipv4-1 \
    --global \
    --target-http-proxy=http-lb-proxy \
    --ports=80

echo "✅ TAREA 3: Completada."
echo "======================================================================"
echo "🚀 ¡LABORATORIO CONFIGURADO! 🚀"
echo "El balanceador de carga HTTP puede tardar de 5 a 7 minutos en estar completamente funcional."
echo "======================================================================"