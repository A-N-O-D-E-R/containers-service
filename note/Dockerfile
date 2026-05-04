FROM node:20-alpine AS builder
ARG VERSION=0.10.9
RUN apk add --no-cache git python3 make g++ bash openjdk17
WORKDIR /build
RUN git clone --depth 1 --branch ${VERSION} https://github.com/logseq/logseq .
RUN yarn install --frozen-lockfile && yarn release

FROM nginx:alpine
COPY --from=builder /build/static /usr/share/nginx/html
EXPOSE 80
