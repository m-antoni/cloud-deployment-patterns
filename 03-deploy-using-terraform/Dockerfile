FROM node:22-alpine

WORKDIR /app

COPY package*.json ./

RUN npm install --production

COPY . .

# Install Nginx and OpenSSL
RUN apk add --no-cache nginx openssl

# Create directories for SSL certs and Nginx cache
RUN mkdir -p /etc/ssl/certs /etc/ssl/private /var/cache/nginx

# Generate self-signed SSL certificate (for testing only)
RUN openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout /etc/ssl/private/nginx.key \
    -out /etc/ssl/certs/nginx.crt \
    -subj "/C=PH/ST=Metro Manila/L=Manila/O=Dev/CN=localhost"

# Copy Nginx config (from local nginx.conf)
COPY nginx.conf /etc/nginx/http.d/default.conf

# Expose HTTP and HTTPS ports
EXPOSE 80 443

# Start both Nginx and Node.js
CMD ["sh", "-c", "nginx && node src/app.js"]
