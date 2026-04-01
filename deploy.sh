#!/bin/bash

# Sinan Website Deployment Script
# This script automates the deployment process for both frontend and backend

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Functions
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if .env file exists
check_env_file() {
    if [ ! -f ".env" ]; then
        print_warning ".env file not found. Creating from .env.example..."
        if [ -f ".env.example" ]; then
            cp .env.example .env
            print_info "Please edit .env file with your configuration before deploying."
            exit 1
        else
            print_error ".env.example not found. Please create .env file manually."
            exit 1
        fi
    fi
}

# Build and start services
deploy_all() {
    print_info "Starting deployment..."
    
    # Check environment file
    check_env_file
    
    # Load environment variables
    export $(cat .env | grep -v '^#' | xargs)
    
    # Build and start services
    print_info "Building Docker images..."
    docker-compose build --no-cache
    
    print_info "Starting services..."
    docker-compose up -d
    
    print_info "Checking service health..."
    sleep 5
    docker-compose ps
    
    print_info "Deployment completed successfully!"
    print_info "Frontend: http://localhost"
    print_info "Backend: http://localhost:3000"
}

# Deploy frontend only
deploy_frontend() {
    print_info "Deploying frontend..."
    check_env_file
    export $(cat .env | grep -v '^#' | xargs)
    
    docker-compose build frontend
    docker-compose up -d frontend
    
    print_info "Frontend deployed successfully!"
    print_info "Frontend: http://localhost"
}

# Deploy backend only
deploy_backend() {
    print_info "Deploying backend..."
    check_env_file
    export $(cat .env | grep -v '^#' | xargs)
    
    docker-compose build backend
    docker-compose up -d backend
    
    print_info "Backend deployed successfully!"
    print_info "Backend: http://localhost:3000"
}

# Stop services
stop_services() {
    print_info "Stopping services..."
    docker-compose down
    print_info "Services stopped."
}

# View logs
view_logs() {
    docker-compose logs -f
}

# Clean up
cleanup() {
    print_warning "This will remove all containers, images, and volumes. Are you sure? (y/N)"
    read -r response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        print_info "Cleaning up..."
        docker-compose down -v --rmi all
        print_info "Cleanup completed."
    else
        print_info "Cleanup cancelled."
    fi
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [COMMAND]

Commands:
    all         Deploy both frontend and backend (default)
    frontend    Deploy frontend only
    backend     Deploy backend only
    stop        Stop all services
    logs        View service logs
    cleanup     Remove all containers, images, and volumes
    help        Show this help message

Examples:
    $0              # Deploy all services
    $0 frontend     # Deploy frontend only
    $0 logs         # View logs
    $0 stop         # Stop all services

EOF
}

# Main script logic
case "${1:-all}" in
    all)
        deploy_all
        ;;
    frontend)
        deploy_frontend
        ;;
    backend)
        deploy_backend
        ;;
    stop)
        stop_services
        ;;
    logs)
        view_logs
        ;;
    cleanup)
        cleanup
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        print_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac

