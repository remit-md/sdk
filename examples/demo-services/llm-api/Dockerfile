FROM node:20-slim
WORKDIR /app
COPY package.json ./
RUN npm install --production
COPY dist ./dist
EXPOSE 3001
ENV PORT=3001
CMD ["node", "dist/index.js"]
