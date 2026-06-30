#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Alluvi single-container image builder (frontend + nginx + services)
# Layout expected:
#   /var/www/frontend   (already built static files)
#   /var/www/backend    (contains server/* microservices + .env)
# ============================================================

# ===== CONFIG =====
FRONTEND_SRC="/var/www/frontend"
BACKEND_SRC="/var/www/backend"

resolve_home_dir() {
  # When running with sudo, SUDO_USER is the original login user.
  # Prefer that user's home to avoid writing into /root or a non-existent /home/ubuntu.
  local u
  u="${SUDO_USER:-$(whoami)}"
  local h
  h="$(getent passwd "$u" | cut -d: -f6)"
  if [[ -n "$h" && -d "$h" ]]; then
    echo "$h"
    return 0
  fi
  echo "$HOME"
}

DEPLOY_ROOT="${DEPLOY_ROOT:-$(resolve_home_dir)/deploy}"
CONTEXT_DIR="${CONTEXT_DIR:-${DEPLOY_ROOT}/alluvi_single_image}"

IMAGE_NAME="alluvi-single"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# Save a portable tar for restoring on another VPS
SAVE_TAR="${SAVE_TAR:-1}" # 1=yes, 0=no
TAR_PATH="${DEPLOY_ROOT}/${IMAGE_NAME}-${IMAGE_TAG}.tar"

# ===== Helpers =====
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }; }

echo "== Checking requirements =="
need_cmd docker
need_cmd rsync

if [[ ! -d "$FRONTEND_SRC" ]]; then
  echo "ERROR: Missing frontend folder: $FRONTEND_SRC"
  exit 1
fi

if [[ ! -d "$BACKEND_SRC" ]]; then
  echo "ERROR: Missing backend folder: $BACKEND_SRC"
  exit 1
fi

# You want env baked into image, so it must exist.
if [[ ! -f "${BACKEND_SRC}/.env" ]]; then
  echo "ERROR: Missing backend .env at: ${BACKEND_SRC}/.env"
  echo "Create it first (this script bakes it into the image)."
  exit 1
fi

echo "== Preparing build context at: $CONTEXT_DIR =="
mkdir -p "$DEPLOY_ROOT"
rm -rf "$CONTEXT_DIR"
mkdir -p "$CONTEXT_DIR"

echo "== Copying frontend + backend into context =="
# Exclude node_modules to keep context small; npm install happens in Docker build.
rsync -a --delete --exclude "node_modules" --exclude ".git" "${FRONTEND_SRC}/" "${CONTEXT_DIR}/frontend/"
rsync -a --delete --exclude "node_modules" --exclude ".git" "${BACKEND_SRC}/" "${CONTEXT_DIR}/backend/"

# Safety check .env is present in context
if [[ ! -f "${CONTEXT_DIR}/backend/.env" ]]; then
  echo "ERROR: .env did not copy into build context."
  exit 1
fi

echo "== Writing Docker runtime files (nginx + supervisor) =="

# --- entrypoint.sh ---
cat > "${CONTEXT_DIR}/entrypoint.sh" <<'EOF'
#!/usr/bin/env sh
set -e
mkdir -p /run/nginx
mkdir -p /var/log/supervisor
exec /usr/bin/supervisord -n -c /etc/supervisor/conf.d/supervisord.conf
EOF
chmod +x "${CONTEXT_DIR}/entrypoint.sh"

# --- nginx.conf ---
# Serves static frontend and proxies API routes to internal services.
# Ports are fixed to match your stack.
cat > "${CONTEXT_DIR}/nginx.conf" <<'EOF'
server {
  listen 80;
  server_name _;

  root /var/www/frontend;
  index index.html;

  # Frontend SPA
  location / {
    try_files $uri $uri/ /index.html;
  }

  # legacy API (4000)
  location /api/ {
    proxy_pass http://127.0.0.1:4000;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  # admin service (5001)
  location /api/admin/ {
    proxy_pass http://127.0.0.1:5001;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  # trackingdetail (5002)
  location /api/trackingdetail/ {
    proxy_pass http://127.0.0.1:5002;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  # user-order-creation (5003)
  location /api/user-orders/ {
    proxy_pass http://127.0.0.1:5003;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  # payment verification (5004)
  location /api/payment-verification/ {
    proxy_pass http://127.0.0.1:5004;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
  }

  # chat service websocket + http (3013)
  location /api/chat/ {
    proxy_pass http://127.0.0.1:3013;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
  }

  # shipping service (3014)
  location /api/shipping/ {
    proxy_pass http://127.0.0.1:3014;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
  }
}
EOF

# --- supervisord.conf ---
cat > "${CONTEXT_DIR}/supervisord.conf" <<'EOF'
[supervisord]
nodaemon=true
logfile=/dev/null
pidfile=/tmp/supervisord.pid

[program:nginx]
command=/usr/sbin/nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:legacy-api]
directory=/var/www/backend/server/_legacy
command=/usr/local/bin/node index.js
autostart=true
autorestart=true
environment=NODE_ENV="production",PORT="4000",DOTENV_PATH="/var/www/backend/.env"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:admin-service]
directory=/var/www/backend/server/admin-service
command=/usr/local/bin/node index.js
autostart=true
autorestart=true
environment=NODE_ENV="production",ADMIN_SERVICE_PORT="5001",DOTENV_PATH="/var/www/backend/.env"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:trackingdetail]
directory=/var/www/backend/server/trackingdetail
command=/usr/local/bin/node index.js
autostart=true
autorestart=true
environment=NODE_ENV="production",TRACKING_SERVICE_PORT="5002",DOTENV_PATH="/var/www/backend/.env"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:user-order-creation]
directory=/var/www/backend/server/user-order-creation
command=/usr/local/bin/node index.js
autostart=true
autorestart=true
environment=NODE_ENV="production",USER_ORDER_CREATION_PORT="5003",DOTENV_PATH="/var/www/backend/.env"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:payment-verification]
directory=/var/www/backend/server/payment-verification-service-node
command=/usr/local/bin/node index.js
autostart=true
autorestart=true
environment=NODE_ENV="production",PAYMENT_VERIFICATION_PORT="5004",DOTENV_PATH="/var/www/backend/.env"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:chat-service]
directory=/var/www/backend/server/services/chat-service
command=/usr/local/bin/node src/index.js
autostart=true
autorestart=true
environment=NODE_ENV="production",CHAT_SERVICE_PORT="3013",DOTENV_PATH="/var/www/backend/.env"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0

[program:shipping-service]
directory=/var/www/backend/server/shipping-service
command=/usr/local/bin/node src/index.js
autostart=true
autorestart=true
environment=NODE_ENV="production",SHIPPING_SERVICE_PORT="3014",DOTENV_PATH="/var/www/backend/.env"
stdout_logfile=/dev/fd/1
stdout_logfile_maxbytes=0
stderr_logfile=/dev/fd/2
stderr_logfile_maxbytes=0
EOF

# --- Dockerfile ---
# IMPORTANT: no PM2 needed; supervisor starts node directly.
# Installs deps for each microservice folder exactly like your repo’s single-container design.
cat > "${CONTEXT_DIR}/Dockerfile" <<'EOF'
FROM node:18-bullseye

RUN apt-get update \
  && apt-get install -y --no-install-recommends nginx supervisor ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Copy frontend (already built static files)
RUN mkdir -p /var/www/frontend
COPY frontend/ /var/www/frontend/

# Copy backend code
RUN mkdir -p /var/www/backend
COPY backend/ /var/www/backend/

# Bake .env into the image (as requested)
# (If backend/.env already copied, this ensures final path is correct.)
COPY backend/.env /var/www/backend/.env

# Install backend deps (top-level server + each service)
# If any folder doesn't exist, build will fail fast (better than silent broken image).
RUN cd /var/www/backend/server \
  && if [ -f package.json ]; then npm install --omit=dev; fi \
  && cd _legacy && npm install --omit=dev \
  && cd ../admin-service && npm install --omit=dev \
  && cd ../trackingdetail && npm install --omit=dev \
  && cd ../user-order-creation && npm install --omit=dev \
  && cd ../payment-verification-service-node && npm install --omit=dev \
  && cd ../services/chat-service && npm install --omit=dev \
  && cd ../../shipping-service && npm install --omit=dev

RUN rm -f /etc/nginx/sites-enabled/default || true
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
EOF

echo "== Building image ${IMAGE_NAME}:${IMAGE_TAG} =="
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$CONTEXT_DIR"

echo "== Image built: ${IMAGE_NAME}:${IMAGE_TAG} =="

if [[ "$SAVE_TAR" == "1" ]]; then
  echo "== Saving tarball to: $TAR_PATH =="
  docker save -o "$TAR_PATH" "${IMAGE_NAME}:${IMAGE_TAG}"
  echo "Saved."
fi

echo ""
echo "Run it on this server:"
echo "  docker run -d --name alluvi --restart unless-stopped -p 80:80 ${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "To restore on another VPS:"
if [[ "$SAVE_TAR" == "1" ]]; then
  echo "  scp ${TAR_PATH} ubuntu@NEW_SERVER:/home/ubuntu/"
  echo "  docker load -i /home/ubuntu/${IMAGE_NAME}-${IMAGE_TAG}.tar"
  echo "  docker run -d --name alluvi --restart unless-stopped -p 80:80 ${IMAGE_NAME}:${IMAGE_TAG}"
fi