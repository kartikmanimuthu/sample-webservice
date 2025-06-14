# Sample Node.js Application

This is a simple Express.js application designed for the Packer vs EC2 Image Builder POC. It provides basic endpoints for health checks, system information, and metrics.

## Features

- **Health Check Endpoint** (`/health`) - Required for ALB health checks
- **System Information** (`/info`) - Displays application and system details
- **Metrics Endpoint** (`/metrics`) - Basic application metrics
- **Echo Endpoint** (`/echo`) - For testing POST requests
- **Security Headers** - Using Helmet.js
- **Request Logging** - Using Morgan
- **Graceful Shutdown** - Handles SIGTERM and SIGINT

## API Endpoints

### GET /health
Returns application health status for load balancer health checks.

```json
{
  "status": "healthy",
  "timestamp": "2023-12-01T10:00:00.000Z",
  "uptime": 3600,
  "environment": "production",
  "version": "1.0.0",
  "build_tool": "packer",
  "instance_id": "i-1234567890abcdef0"
}
```

### GET /
Root endpoint with basic application information.

### GET /info
Detailed system and application information.

### GET /metrics
Application metrics including memory usage and uptime.

### POST /echo
Echo endpoint that returns the request body.

## Environment Variables

- `PORT` - Server port (default: 3000)
- `NODE_ENV` - Environment (development/production)
- `BUILD_TOOL` - Build tool used (packer/imagebuilder)
- `INSTANCE_ID` - AWS instance ID
- `AWS_REGION` - AWS region
- `AWS_AZ` - Availability zone

## Development

```bash
# Install dependencies
npm install

# Start development server with auto-reload
npm run dev

# Start production server
npm start

# Run tests
npm test

# Health check
npm run health-check
```

## Docker Support

```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
EXPOSE 3000
USER node
CMD ["npm", "start"]
```

## Deployment Notes

- Application listens on `0.0.0.0:3000`
- Health check endpoint is required for ALB
- Graceful shutdown implemented for container environments
- Logs are output to stdout for CloudWatch integration