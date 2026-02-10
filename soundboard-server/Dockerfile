FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --production
COPY . .
RUN mkdir -p data/sounds
EXPOSE 3000
CMD ["node", "server.js"]
