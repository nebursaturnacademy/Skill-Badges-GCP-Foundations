#!/bin/bash
# ======================================================================================
#         SCRIPT - LABORATORIO SET UP AN APP DEV ENVIRONMENT
# ======================================================================================

# --- FASE 0: PREPARACIÓN Y DEFINICIÓN DE VARIABLES ---
# Un buen ingeniero siempre define sus variables primero. Esto hace que el script
# sea legible y fácil de adaptar. Obtenemos los nombres exactos del laboratorio.
# Recuerda ajustar las variables exactas que se indican en el laboratorio.

echo "✅ FASE 0: Definiendo las variables del entorno..."
export REGION="us-west1"
export ZONE="us-west1-a"
export BUCKET_NAME="qwiklabs-gcp-02-59ae4ae62378-bucket"
export TOPIC_NAME="topic-memories-430"
export FUNCTION_NAME="memories-thumbnail-generator"

# Obtenemos el ID y el Número del Proyecto automáticamente.
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

# Verificamos su configuración
echo "Bucket: $BUCKET_NAME"
echo "Topic: $TOPIC_NAME"
echo "Función: $FUNCTION_NAME"

# ======================================================================================
#         FASE 1: PREPARAR EL TERRENO (APIs Y PERMISOS DE IAM)
# Esta es la parte más importante y la que más a menudo se olvida.
# Sin esto, nuestros servicios no pueden hablar entre sí. Es como construir
# una casa sin pedir los permisos de construcción.
# ======================================================================================
echo "➡️  INICIANDO FASE 1: Habilitando APIs y configurando permisos..."

# --- 1.1 Habilitar las APIs ---
# Le decimos a nuestro proyecto: "Oye, vamos a usar todas estas herramientas. Por favor, actívalas."
gcloud services enable \
  artifactregistry.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudbuild.googleapis.com \
  eventarc.googleapis.com \
  run.googleapis.com \
  logging.googleapis.com \
  pubsub.googleapis.com

# --- 1.2 Otorgar Permisos Clave ---
# Lección Clave: Una función de 2ª Gen. activada por Storage usa Eventarc como intermediario.
# Necesitamos construir el "puente" de permisos para que el evento llegue a su destino.

# Permiso para que Eventarc pueda "despertar" a nuestra función.
echo "Otorgando rol 'Eventarc Event Receiver' a la cuenta de servicio de Compute..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$PROJECT_NUMBER-compute@developer.gserviceaccount.com" \
    --role="roles/eventarc.eventReceiver"

# Permiso para que el servicio de Storage pueda publicar mensajes en Pub/Sub (un paso interno).
echo "Otorgando rol 'Pub/Sub Publisher' a la cuenta de servicio de Storage..."
SERVICE_ACCOUNT="$(gsutil kms serviceaccount -p $PROJECT_ID)"
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:${SERVICE_ACCOUNT}" \
    --role='roles/pubsub.publisher'

# Permiso para que Pub/Sub pueda autenticarse y crear tokens para invocar la función.
echo "Otorgando rol 'Service Account Token Creator' a la cuenta de servicio de Pub/Sub..."
gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:service-$PROJECT_NUMBER@gcp-sa-pubsub.iam.gserviceaccount.com" \
    --role="roles/iam.serviceAccountTokenCreator"

echo "✅ FASE 1: Permisos configurados."

# ======================================================================================
#                             TAREAS 1 Y 2: CREAR LOS RECURSOS BASE
# ======================================================================================
echo "➡️  INICIANDO TAREAS 1 Y 2: Creando el Bucket y el Tema de Pub/Sub..."

# --- Tarea 1: Crear el Bucket ---
gsutil mb -l $REGION gs://$BUCKET_NAME

# --- Tarea 2: Crear el Tema de Pub/Sub ---
gcloud pubsub topics create $TOPIC_NAME

echo "✅ TAREAS 1 Y 2: Completadas."

# ======================================================================================
#                         TAREA 3: CREAR Y DESPLEGAR LA CLOUD FUNCTION
# ======================================================================================
echo "➡️  INICIANDO TAREA 3: Creando los archivos de la función..."

# --- 3.1 Crear el Directorio y los Archivos de Código ---
# Creamos una carpeta para mantener nuestro código organizado.
mkdir thumbnail-function && cd thumbnail-function

# --- 3.2 Crear index.js ---
# Usamos el código EXACTO del laboratorio. Este usa la librería 'sharp'.
cat > index.js <<'EOF'
const functions = require('@google-cloud/functions-framework');
const { Storage } = require('@google-cloud/storage');
const { PubSub } = require('@google-cloud/pubsub');
const sharp = require('sharp');

functions.cloudEvent('memories-thumbnail-generator', async cloudEvent => {
  const event = cloudEvent.data;
  const fileName = event.name;
  const bucketName = event.bucket;
  const bucket = new Storage().bucket(bucketName);
  const topicName = "topic-memories-967";
  const pubsub = new PubSub();

  if (fileName.search("64x64_thumbnail") === -1) {
    const filename_split = fileName.split('.');
    const filename_ext = filename_split[filename_split.length - 1].toLowerCase();
    const filename_without_ext = fileName.substring(0, fileName.length - filename_ext.length - 1);

    if (filename_ext === 'png' || filename_ext === 'jpg' || filename_ext === 'jpeg') {
      const gcsObject = bucket.file(fileName);
      const newFilename = `${filename_without_ext}_64x64_thumbnail.${filename_ext}`;
      const gcsNewObject = bucket.file(newFilename);
      try {
        const [buffer] = await gcsObject.download();
        const resizedBuffer = await sharp(buffer)
          .resize(64, 64, { fit: 'inside', withoutEnlargement: true })
          .toFormat(filename_ext)
          .toBuffer();
        await gcsNewObject.save(resizedBuffer, { metadata: { contentType: `image/${filename_ext}` } });
        console.log(`Success: ${fileName} → ${newFilename}`);
        await pubsub.topic(topicName).publishMessage({ data: Buffer.from(newFilename) });
        console.log(`Message published to ${topicName}`);
      } catch (err) { console.error(`Error: ${err}`); }
    } else { console.log(`gs://${bucketName}/${fileName} is not an image I can handle`); }
  } else { console.log(`gs://${bucketName}/${fileName} already has a thumbnail`); }
});
EOF

# --- 3.3 Crear package.json ---
# Lección Clave: Creamos el package.json que corresponde al index.js (con 'sharp').
# Y lo más importante: ELIMINAMOS la sección "scripts" para evitar conflictos con
# el sistema de Buildpacks de 'gcloud functions deploy'.
cat > package.json <<'EOF'
{
 "name": "thumbnails",
 "version": "1.0.0",
 "description": "Create Thumbnail of uploaded image",
 "dependencies": {
   "@google-cloud/functions-framework": "^3.0.0",
   "@google-cloud/pubsub": "^2.0.0",
   "@google-cloud/storage": "^6.11.0",
   "sharp": "^0.32.1"
 },
 "devDependencies": {},
 "engines": {
   "node": ">=16.0.0"
 }
}
EOF

echo "✅ TAREA 3: Archivos creados. Desplegando la función..."

# --- 3.4 Desplegar la Función ---
# Este es el comando final. Usa las variables que definimos, especifica la 2ª generación,
# el runtime correcto, y apunta al bucket como el disparador del evento.
gcloud functions deploy $FUNCTION_NAME \
    --gen2 \
    --runtime nodejs22 \
    --trigger-resource $BUCKET_NAME \
    --trigger-event google.storage.object.finalize \
    --entry-point $FUNCTION_NAME \
    --region=$REGION \
    --source . \
    --quiet

echo "✅ TAREA 3: Despliegue completado."

# ======================================================================================
#                                TAREA 4: PROBAR Y LIMPIAR
# ======================================================================================
echo "➡️  INICIANDO TAREA 4: Probando la función y eliminando el usuario..."

# --- 4.1 Probar la Función ---
# Descargamos una imagen de prueba y la subimos a nuestro bucket para disparar la función.
curl -o map.jpg https://storage.googleapis.com/cloud-training/gsp315/map.jpg
gsutil cp map.jpg gs://$BUCKET_NAME/map.jpg

# --- 4.2 Eliminar el Ingeniero Anterior (DESDE CONSOLA DE GCP) ---

echo "✅ TAREA 4: Completada."
echo "======================================================================"
echo "🚀 ¡LABORATORIO CONFIGURADO CON ÉXITO! 🚀"
echo "Puedes verificar el bucket para ver el thumbnail y hacer clic en 'Check my progress'."
echo "======================================================================"