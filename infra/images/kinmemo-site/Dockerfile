# kinmemo.app landing site. Build context: the kinmemo repo root.
#   docker build -f deploy/k8s/kinmemo-site/Dockerfile .
FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY deploy/k8s/kinmemo-site/nginx.conf /etc/nginx/conf.d/default.conf
COPY deploy/k8s/kinmemo-site/security.conf /etc/nginx/snippets/security.conf
COPY --chown=nginx:nginx website/ /usr/share/nginx/html/
# Build-time helpers that the old deploy.sh excluded from the public site.
USER root
RUN rm -rf /usr/share/nginx/html/tools /usr/share/nginx/html/README.md
USER nginx
