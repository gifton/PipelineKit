.PHONY: up down logs ps clean

# Start all services
up:
	docker-compose up -d
	@./scripts/wait-for-services.sh

# Stop all services
down:
	docker-compose down

# View logs
logs:
	docker-compose logs -f

# Show running containers
ps:
	docker-compose ps

# Clean up (including volumes)
clean:
	docker-compose down -v

# Run integration tests (to be used later)
test-integration: up
	@echo "Services are up. Run integration tests from the project root."

# CI-specific commands
ci-up:
	docker-compose -f docker-compose.yml -f docker-compose.ci.yml up -d
	@./scripts/wait-for-services.sh

ci-down:
	docker-compose -f docker-compose.yml -f docker-compose.ci.yml down -v

ci-test: ci-up
	@echo "Services are up. Run integration tests from the project root."

# Restart a specific service
restart-%:
	docker-compose restart $*

# View logs for a specific service
logs-%:
	docker-compose logs -f $*

# Health check for all services
health:
	@./scripts/health-check.sh