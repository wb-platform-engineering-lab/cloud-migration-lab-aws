# ── Build stage ──────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --fetch-timeout=300000

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM node:20-alpine

WORKDIR /app

# Create a non-root user
RUN addgroup -S orderflow && adduser -S orderflow -G orderflow

# Copy dependencies from builder
COPY --from=builder /app/node_modules ./node_modules

# Copy application source
COPY src/      ./src/
COPY public/   ./public/
COPY package.json ./

RUN chown -R orderflow:orderflow /app

USER orderflow

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health | grep -q '"status":"ok"' || exit 1

CMD ["node", "src/app.js"]
