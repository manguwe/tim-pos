# TIM-POS server with the vendor dashboard. Build from the project root:  docker build -f server/Dockerfile -t tim-pos .
# The server needs no npm packages at run time: Node 22 provides the HTTP server, SQLite and TypeScript support.
FROM node:22-slim AS dashboard
WORKDIR /dash
COPY dashboard/package.json ./
RUN npm install --no-audit --no-fund
COPY dashboard/tsconfig.json dashboard/build.mjs ./
COPY dashboard/src ./src
RUN npm run build

FROM node:22-slim
ENV NODE_ENV=production DATA_DIR=/data PORT=8080 TRUST_PROXY=1 NODE_NO_WARNINGS=1 DASHBOARD_DIR=/app/dashboard
WORKDIR /app
COPY server/package.json ./
COPY server/migrations ./migrations
COPY server/src ./src
COPY --from=dashboard /dash/dist ./dashboard
RUN mkdir -p /data && chown -R node:node /data /app
USER node
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD node -e "fetch('http://127.0.0.1:8080/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "src/server.ts"]
