# 빌드 스테이지
FROM node:20-slim AS builder
WORKDIR /app
COPY package*.json tsconfig.json ./
RUN npm ci
COPY src/ ./src/
RUN npm run build

# 실행 스테이지
FROM node:20-slim AS runner
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY --from=builder /app/lib/ ./lib/
EXPOSE 3000
CMD ["npm", "start"]
