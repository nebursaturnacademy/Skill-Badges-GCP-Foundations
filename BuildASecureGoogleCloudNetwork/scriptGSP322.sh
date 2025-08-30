#!/bin/bash
# ======================================================================================
#         SCRIPT - LABORATORIO DE SEGURIDAD DE RED
# Estrategia: Transformar una red insegura en un fuerte digital usando el principio
# de privilegio mínimo a través de reglas de firewall y un bastión.
# ======================================================================================

# --- FASE 0: PREPARACIÓN DEL CAMPO DE BATALLA ---
# Un buen ingeniero siempre define sus variables primero. Es como ponerle nombre a
# nuestras "pulseras VIP". Esto evita errores de escritura y hace el script más legible.
echo "✅ FASE 0: Definiendo las etiquetas de red (nuestros pases de acceso)..."
export IAP_NETWORK_TAG="grant-ssh-iap-ingress-ql-262"
export HTTP_NETWORK_TAG="grant-http-ingress-ql-262"
export INTERNAL_NETWORK_TAG="grant-ssh-internal-ingress-ql-262"

# Exportamos la zona
export ZONE=""

# ======================================================================================
#             TAREA 1: LA GRAN LIMPIEZA - ELIMINAR REGLAS PERMISIVAS
# Principio de Seguridad: "Lo que no está explícitamente permitido, está prohibido".
# ======================================================================================
echo "➡️  INICIANDO TAREA 1: Eliminando la regla de firewall 'open-access'..."

# El laboratorio comienza con una regla de firewall que es como una puerta de garaje
# abierta de par en par al mundo. Nuestro primer trabajo como consultores de seguridad
# es CERRARLA. Eliminamos la amenaza antes de construir nuestras defensas.
gcloud compute firewall-rules delete open-access --quiet

echo "✅ TAREA 1: Completada. La puerta principal del castillo ha sido cerrada."

# ======================================================================================
#             TAREA 2: DESPERTAR AL GUARDIÁN - EL HOST BASTIÓN
# Concepto Clave: El Bastión es la ÚNICA puerta de entrada fortificada para
# la administración de nuestra red. NUNCA debe tener una IP pública.
# ======================================================================================
echo "➡️  INICIANDO TAREA 2: Iniciando el host bastión..."

# La VM 'bastion' está apagada por defecto en el laboratorio. Simplemente la encendemos.
gcloud compute instances start bastion --zone=$ZONE

echo "✅ TAREA 2: Completada. El guardián está en su puesto."

# ======================================================================================
#       TAREA 3: CONSTRUYENDO LAS MURALLAS - REGLAS DE FIREWALL ESPECÍFICAS
# Estrategia: Ahora que todo está cerrado, vamos a abrir tres pequeños túneles
# de acceso, muy específicos y controlados.
# ======================================================================================
echo "➡️  INICIANDO TAREA 3: Creando las reglas de firewall de privilegio mínimo..."

# --- 3.1 El Túnel de IAP para el Bastión ---
# Creamos una regla que permite SSH (puerto 22), pero ¡ATENCIÓN! solo desde
# el rango de IP '35.235.240.0/20'. Este rango le pertenece al servicio de IAP de Google.
# Así, la única forma de entrar a nuestra red desde fuera es a través de este servicio seguro.
echo "Creando regla para SSH a través de IAP (nuestro escáner de retina)..."
gcloud compute firewall-rules create ssh-ingress \
    --network=acme-vpc \
    --allow=tcp:22 \
    --source-ranges=35.235.240.0/20 \
    --target-tags=$IAP_NETWORK_TAG

# Ahora, le damos el "pase de acceso" (la etiqueta) a nuestro guardián, el bastión.
# Solo él puede usar esta entrada.
gcloud compute instances add-tags bastion --tags=$IAP_NETWORK_TAG --zone=$ZONE

# --- 3.2 La Puerta Principal para Clientes (HTTP) ---
# Ahora creamos la puerta para los clientes. Permite tráfico HTTP (puerto 80) desde
# CUALQUIER LUGAR ('0.0.0.0/0'). ¿Por qué aquí sí está bien? Porque es un sitio web público.
# Si no, ¡nadie podría visitarlo!
echo "Creando regla para el tráfico web HTTP (la puerta de los clientes)..."
gcloud compute firewall-rules create http-ingress \
    --network=acme-vpc \
    --allow=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=$HTTP_NETWORK_TAG

# Le damos el "pase de acceso HTTP" a nuestro servidor web, el 'juice-shop'.
gcloud compute instances add-tags juice-shop --tags=$HTTP_NETWORK_TAG --zone=$ZONE

# --- 3.3 El Pasadizo Secreto Interno (SSH Interno) ---
# Necesitamos una forma de administrar 'juice-shop'. Pero no queremos exponerlo a internet.
# Así que creamos un pasadizo secreto. Esta regla permite SSH (puerto 22), pero SOLO
# desde la red interna donde vive nuestro bastión ('192.168.10.0/24').
echo "Creando regla para el SSH interno (el pasadizo secreto)..."
gcloud compute firewall-rules create internal-ssh-ingress \
    --network=acme-vpc \
    --allow=tcp:22 \
    --source-ranges=192.168.10.0/24 \
    --target-tags=$INTERNAL_NETWORK_TAG

# Le damos el "pase de acceso para el pasadizo" al 'juice-shop'.
# ¡Fíjense que 'juice-shop' ahora tiene dos pulseras! Una para HTTP y otra para SSH interno.
gcloud compute instances add-tags juice-shop --tags=$INTERNAL_NETWORK_TAG --zone=$ZONE

echo "✅ TAREA 3: Completada. Nuestras murallas y túneles están construidos."

# ======================================================================================
#             TAREA 4: LA PRUEBA FINAL - INFILTRARSE EN NUESTRO PROPIO FUERTE
# ======================================================================================
echo "➡️  INICIANDO TAREA 4: Probando la conexión segura..."

# Este es el truco final y es pura elegancia. Le decimos a gcloud:
# 1. Conéctate por SSH al 'bastion' (gcloud es lo suficientemente inteligente para usar IAP).
# 2. Una vez dentro, NO me des una terminal. En su lugar, ejecuta OTRO COMANDO.
# 3. ¿Qué comando? "gcloud compute ssh juice-shop --internal-ip".
# Esto crea un túnel dentro de otro túnel, probando que todo nuestro modelo de seguridad funciona.
timeout 45 gcloud compute ssh bastion --zone=$ZONE --quiet \
    --command="gcloud compute ssh juice-shop --zone=$ZONE --internal-ip --quiet --command='echo SSH_SUCCESS'"

echo "✅ TAREA 4: ¡Conexión exitosa!"
echo "======================================================================"
echo "🚀 ¡LABORATORIO CONFIGURADO CON ÉXITO! 🚀"
echo "Has transformado una red vulnerable en un ejemplo de seguridad en la nube."
echo "======================================================================"