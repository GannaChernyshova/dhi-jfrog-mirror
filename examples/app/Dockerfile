# syntax=docker/dockerfile:1

# Base images come from Artifactory, never from Docker Hub directly.
# BASE_IMAGE is the DHI Node repository behind the consumer URL (virtual repo),
# e.g. acme.jfrog.io/docker/dhi-node. Tags can carry a digest for
# reproducible builds: NODE_TAG=24@sha256:...
ARG BASE_IMAGE=acme.jfrog.io/docker/dhi-node
ARG NODE_TAG=24
ARG NODE_DEV_TAG=24-dev

FROM ${BASE_IMAGE}:${NODE_DEV_TAG} AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.js ./

# Runtime: no shell, no package manager, runs as non-root.
FROM ${BASE_IMAGE}:${NODE_TAG} AS runtime
WORKDIR /app
COPY --from=build /app /app
ENV NODE_ENV=production
EXPOSE 3000
CMD ["node", "server.js"]
