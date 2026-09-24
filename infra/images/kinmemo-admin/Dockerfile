# Kinmemo admin dashboard (plain static files). Build context: kinmemo repo root.
#   docker build -f deploy/k8s/kinmemo-admin/Dockerfile .
FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY deploy/k8s/kinmemo-admin/nginx.conf /etc/nginx/conf.d/default.conf
COPY --chown=nginx:nginx admin/ /usr/share/nginx/html/
