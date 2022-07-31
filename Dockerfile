# syntax=docker/dockerfile:1
# escape=\
FROM node:16-alpine AS builder
WORKDIR /builder
COPY package* ./
RUN npm install
COPY . ./
RUN npm run build

FROM nginx:1.23.0-alpine
COPY --from=builder /builder/build /usr/share/nginx/html