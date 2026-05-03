# Use the full Bookworm image for better compatibility with native modules
FROM node:20-bookworm

# Create app directory
WORKDIR /usr/src/app

# Install build essentials
RUN apt-get update && apt-get install -y \
    python3 \
    make \
    g++ \
    && rm -rf /var/lib/apt/lists/*

# Copy package files
COPY package*.json ./

# Install dependencies and force a fresh build of sqlite3 from source
RUN npm install
RUN npm rebuild sqlite3 --build-from-source

# Copy app source
COPY . .

# Expose the port the app runs on
EXPOSE 3000

# Command to run the app
CMD [ "node", "index.js" ]
