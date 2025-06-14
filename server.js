const express = require('express');
const morgan = require('morgan');
const helmet = require('helmet');
const cors = require('cors');

const app = express();
const port = process.env.PORT || 3000;
const environment = process.env.NODE_ENV || 'development';

// Security middleware
app.use(helmet());
app.use(cors());

// Logging middleware
app.use(morgan('combined'));

// Parse JSON bodies
app.use(express.json());

// Health check endpoint (required for ALB health checks)
app.get('/health', (req, res) => {
    const healthStatus = {
        status: 'healthy',
        timestamp: new Date().toISOString(),
        uptime: process.uptime(),
        environment: environment,
        version: '1.0.0',
        build_tool: process.env.BUILD_TOOL || 'unknown',
        instance_id: process.env.INSTANCE_ID || 'local',
        memory: {
            used: process.memoryUsage().heapUsed / 1024 / 1024,
            total: process.memoryUsage().heapTotal / 1024 / 1024
        }
    };

    res.status(200).json(healthStatus);
});

// Root endpoint
app.get('/', (req, res) => {
    res.json({
        message: 'Sample Node.js Application - Packer vs EC2 Image Builder POC',
        timestamp: new Date().toISOString(),
        environment: environment,
        build_tool: process.env.BUILD_TOOL || 'unknown',
        endpoints: {
            health: '/health',
            info: '/info',
            metrics: '/metrics'
        }
    });
});

// Info endpoint with system information
app.get('/info', (req, res) => {
    const info = {
        application: {
            name: 'sample-node-app',
            version: '1.0.0',
            environment: environment,
            build_tool: process.env.BUILD_TOOL || 'unknown'
        },
        system: {
            platform: process.platform,
            arch: process.arch,
            node_version: process.version,
            uptime: process.uptime(),
            timestamp: new Date().toISOString()
        },
        aws: {
            region: process.env.AWS_REGION || 'unknown',
            instance_id: process.env.INSTANCE_ID || 'local',
            availability_zone: process.env.AWS_AZ || 'unknown'
        }
    };

    res.json(info);
});

// Metrics endpoint for basic application metrics
app.get('/metrics', (req, res) => {
    const metrics = {
        timestamp: new Date().toISOString(),
        uptime_seconds: Math.floor(process.uptime()),
        memory_usage: {
            heap_used_mb: Math.round(process.memoryUsage().heapUsed / 1024 / 1024),
            heap_total_mb: Math.round(process.memoryUsage().heapTotal / 1024 / 1024),
            external_mb: Math.round(process.memoryUsage().external / 1024 / 1024),
            rss_mb: Math.round(process.memoryUsage().rss / 1024 / 1024)
        },
        cpu_usage: process.cpuUsage(),
        environment: environment,
        build_tool: process.env.BUILD_TOOL || 'unknown'
    };

    res.json(metrics);
});

// Test endpoint for load testing
app.post('/echo', (req, res) => {
    res.json({
        message: 'Echo response',
        received: req.body,
        timestamp: new Date().toISOString()
    });
});

// Error handling middleware
app.use((err, req, res, next) => {
    console.error('Error:', err.message);
    res.status(500).json({
        error: 'Internal Server Error',
        timestamp: new Date().toISOString()
    });
});

// 404 handler
app.use((req, res) => {
    res.status(404).json({
        error: 'Not Found',
        path: req.path,
        timestamp: new Date().toISOString()
    });
});

// Graceful shutdown
process.on('SIGTERM', () => {
    console.log('SIGTERM received, shutting down gracefully...');
    server.close(() => {
        console.log('Process terminated');
        process.exit(0);
    });
});

process.on('SIGINT', () => {
    console.log('SIGINT received, shutting down gracefully...');
    server.close(() => {
        console.log('Process terminated');
        process.exit(0);
    });
});

const server = app.listen(port, '0.0.0.0', () => {
    console.log(`Sample Node.js application listening on port ${port}`);
    console.log(`Environment: ${environment}`);
    console.log(`Build Tool: ${process.env.BUILD_TOOL || 'unknown'}`);
    console.log(`Health check: http://localhost:${port}/health`);
});

module.exports = app;