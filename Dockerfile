FROM node:22-slim

WORKDIR /app/web_app

ENV NODE_ENV=production \
    CLOUD_MODE=1 \
    PORT=3000

COPY web_app/package.json web_app/package-lock.json ./
RUN npm ci --omit=dev

COPY web_app/ ./

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/healthz').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
