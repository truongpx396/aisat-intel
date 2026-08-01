# syntax=docker/dockerfile:1
#
# React 19 + Vite SPA, served by Caddy (plan.md: "Caddy — static SPA serving").
# Build with Node, then bake the static bundle into the Caddy image at /srv.
# This image IS the edge: the production Caddyfile (mounted at runtime) adds TLS
# and the /api + SSE reverse proxies. Node is not in the runtime image.
#
# TODO(supply-chain): pin base images by @sha256 digest.
FROM node:25-alpine AS build
WORKDIR /app
ENV CI=true
RUN corepack enable
# Dependency layer first — supports pnpm or npm lockfiles.
COPY package.json pnpm-lock.yaml* package-lock.json* ./
RUN if [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; \
    elif [ -f package-lock.json ]; then npm ci; \
    else npm install; fi
COPY . .
# Same-origin API by default (Caddy routes /api and /query to the backends).
ARG VITE_API_BASE_URL=/api
ENV VITE_API_BASE_URL=$VITE_API_BASE_URL
RUN if [ -f pnpm-lock.yaml ]; then pnpm run build; else npm run build; fi

FROM caddy:2.8-alpine
# SPA assets only — routing/TLS come from the mounted deploy/Caddyfile.
COPY --from=build /app/dist /srv
EXPOSE 80 443
