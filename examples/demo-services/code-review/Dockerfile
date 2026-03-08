FROM node:20-slim
WORKDIR /app
COPY package.json ./
RUN npm install --production
COPY dist ./dist
EXPOSE 3003
ENV PORT=3003
CMD ["node", "dist/index.js"]
