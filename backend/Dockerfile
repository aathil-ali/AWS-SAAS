# Use the official Node.js 20 lightweight Alpine image
FROM node:20-alpine

# Set working directory
WORKDIR /usr/src/app

# Copy package.json and package-lock.json
COPY package*.json ./

# Install production dependencies
RUN npm ci --only=production

# Copy the application code
COPY . .

# Expose the application port
EXPOSE 8080

# Run the application
CMD ["node", "src/index.js"]
