# Kelime Savaşı admin panel (Next.js static export). Build context: repo root.
#   docker build -f deploy/k8s/kelime-admin/Dockerfile .
FROM node:22-alpine AS build
WORKDIR /app
COPY admin/package.json admin/package-lock.json ./
RUN npm ci
COPY admin/ .
ARG NEXT_PUBLIC_API_URL=https://api.kelimesavasi.app
ENV NEXT_PUBLIC_API_URL=$NEXT_PUBLIC_API_URL
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.30-alpine
COPY deploy/k8s/kelime-admin/nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build --chown=nginx:nginx /app/out /usr/share/nginx/html
