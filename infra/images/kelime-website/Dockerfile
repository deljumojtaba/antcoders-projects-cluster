# Kelime Savaşı landing site. Build context: the kelime-savasi repo root.
#   docker build -f deploy/k8s/kelime-website/Dockerfile .
FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY deploy/k8s/kelime-website/nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=nginx:nginx website/ /usr/share/nginx/html/
